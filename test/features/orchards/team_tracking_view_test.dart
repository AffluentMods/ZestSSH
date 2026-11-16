import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/team_tracking_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

import 'fake_crate_server.dart';

/// What the team records on screen (3.0): owners switch version
/// history and activity after a yes that says what the change means (who is
/// told, that history starts now, that activity recorded so far goes);
/// members see where things stand and cannot change it; devices and sign-in
/// addresses show only while on, and an owner can turn them off.

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late OrchardService owner;
  late OrchardService alice;
  late String orchardId;
  final storages = <_MemoryStorage>[];
  final devices = <OrchardService, ({_MemoryStorage storage, String uid})>{};

  setUpAll(() async {
    for (final uid in ['owner-1', 'alice']) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  OrchardService onStorage(_MemoryStorage storage, String uid) {
    final service = OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
    );
    devices[service] = (storage: storage, uid: uid);
    return service;
  }

  OrchardService serviceFor(String uid) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return onStorage(storage, uid);
  }

  /// Acme with the owner and alice (a member), recording [tracking].
  Future<void> build(WidgetTester tester, {RecordTracking tracking = RecordTracking.none}) =>
      tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in keys.keys) {
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = serviceFor('owner-1');
        alice = serviceFor('alice');
        orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        await owner.invite(orchardId, email: 'alice@example.com', role: server.recordOf(orchardId).roles.values.single.id);
        server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'alice');
        await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
        if (!tracking.isNone) await owner.setTracking(orchardId, tracking);
        await owner.refresh();
        await alice.refresh();
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  bool toasted(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    return container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);
  }

  Future<void> pump(WidgetTester tester, OrchardService as) async {
    final device = devices[as]!;
    as = onStorage(device.storage, device.uid);
    late OrchardSummary summary;
    await tester.runAsync(() async => summary = await readOrchardSummary(await as.databases.open(orchardId), orchardId));
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final me = device.uid;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(as),
        orchardDatabasesProvider.overrideWith((ref) => as.databases),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => CrateAuthor(uid: me, keys: keys[me]!))),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        currentUserProvider.overrideWithValue(UserProfile(uid: me, email: '$me@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: TeamTrackingPanel(orchard: summary))),
      ),
    ));
    await settle(tester);
  }

  Finder switchOf(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(ZestSwitch));
  /// Save shows (and takes a press) only once something changed.
  bool canSave(WidgetTester tester) {
    final found = find.byKey(const ValueKey('team-tracking-save'));
    return found.evaluate().isNotEmpty && tester.widget<FilledButton>(found).onPressed != null;
  }

  testWidgets('an owner turns version history on after a yes that says it starts now', (tester) async {
    await build(tester);
    await pump(tester, owner);
    expect(find.byKey(const ValueKey('team-tracking-state-none')), findsOneWidget);
    expect(find.text(l10n.trackingHistoryBody), findsOneWidget);
    expect(find.byKey(const ValueKey('team-tracking-devices')), findsNothing, reason: 'not collected: no switch');
    expect(find.byKey(const ValueKey('team-tracking-ips')), findsNothing);
    expect(canSave(tester), isFalse, reason: 'nothing changed yet');

    await tester.tap(switchOf('team-tracking-history'));
    await tester.pump();
    expect(canSave(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('team-tracking-save')));
    await settle(tester);
    expect(find.text(l10n.trackingConfirmTitle('Acme')), findsOneWidget);
    expect(find.textContaining(l10n.trackingConfirmBody('version history')), findsOneWidget);
    expect(find.textContaining(l10n.trackingHistoryStartsNow), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).tracking, RecordTracking.none, reason: 'declined: nothing sent');

    await tester.tap(find.byKey(const ValueKey('team-tracking-save')));
    await settle(tester);
    await tester.tap(find.text(l10n.trackingSaveChange).last);
    await settle(tester);
    expect(server.recordOf(orchardId).tracking, const RecordTracking(history: true));
    expect(toasted(tester, l10n.trackingSaved), isTrue);
    expect(find.byKey(const ValueKey('team-tracking-state-some')), findsOneWidget);
    expect(canSave(tester), isFalse, reason: 'saved: nothing more to save');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('turning activity off says what recorded so far is deleted', (tester) async {
    await build(tester, tracking: const RecordTracking(activity: true));
    await pump(tester, owner);
    expect(tester.widget<ZestSwitch>(switchOf('team-tracking-activity')).value, isTrue);
    await tester.tap(switchOf('team-tracking-activity'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('team-tracking-save')));
    await settle(tester);
    expect(find.textContaining(l10n.trackingConfirmNoneBody), findsOneWidget);
    expect(find.textContaining(l10n.trackingActivityDeleted), findsOneWidget);
    expect(find.textContaining(l10n.trackingHistoryStartsNow), findsNothing);
    await tester.tap(find.text(l10n.trackingSaveChange).last);
    await settle(tester);
    expect(server.recordOf(orchardId).tracking, RecordTracking.none);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a member sees where things stand, and cannot change it', (tester) async {
    await build(tester, tracking: const RecordTracking(history: true));
    await pump(tester, alice);
    expect(find.byType(ZestSwitch), findsNothing);
    expect(find.byKey(const ValueKey('team-tracking-save')), findsNothing);
    expect(find.text(l10n.trackingOwnersOnly), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('team-tracking-history')), matching: find.text(l10n.teamRecoveryStateOn)),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('team-tracking-activity')), matching: find.text(l10n.teamRecoveryStateOff)),
        findsOneWidget);
    expect(find.byKey(const ValueKey('team-tracking-state-some')), findsOneWidget);
  });

  testWidgets('devices turned on by another app show while on, and an owner can turn them off', (tester) async {
    await build(tester, tracking: const RecordTracking(devices: true));
    await pump(tester, owner);
    expect(find.byKey(const ValueKey('team-tracking-devices')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-tracking-ips')), findsNothing);
    // Off, and back on: that only undoes it.
    await tester.tap(switchOf('team-tracking-devices'));
    await tester.pump();
    expect(canSave(tester), isTrue);
    await tester.tap(switchOf('team-tracking-devices'));
    await tester.pump();
    expect(canSave(tester), isFalse);
    await tester.tap(switchOf('team-tracking-devices'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('team-tracking-save')));
    await settle(tester);
    await tester.tap(find.text(l10n.trackingSaveChange).last);
    await settle(tester);
    expect(server.recordOf(orchardId).tracking, RecordTracking.none);
    await tester.pump(const Duration(seconds: 10));
  });
}
