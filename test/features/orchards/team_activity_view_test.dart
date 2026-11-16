import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_activity_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

import 'fake_crate_server.dart';

/// The owners' activity page (3.0): while activity is off it says
/// so and where to turn it on; while on, what members did, newest first, in
/// words, with events that do not check out left out and counted.

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

  Future<void> pump(WidgetTester tester, OrchardService as, {VoidCallback? onOpenRules}) async {
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
        home: Scaffold(body: SingleChildScrollView(child: TeamActivityView(orchard: summary, onOpenRules: onOpenRules))),
      ),
    ));
    await settle(tester);
  }

  testWidgets('off: it says so, and where an owner turns it on', (tester) async {
    await build(tester);
    var opened = 0;
    await pump(tester, owner, onOpenRules: () => opened++);
    expect(find.text(l10n.teamActivityOff), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('team-activity-open-rules')));
    expect(opened, 1);
  });

  testWidgets('on: what members did, newest first, in words; one that does not check out is counted', (tester) async {
    await build(tester, tracking: const RecordTracking(activity: true));
    await tester.runAsync(() async {
      await alice.recordActivity(orchardId, ActivityKind.reveal, itemKind: 'key', itemKey: 'k1', name: 'Deploy key');
      await alice.recordActivity(orchardId, ActivityKind.connect, itemKind: 'host', itemKey: 'web1', name: 'Web 1');
      await alice.activityRound(orchardId);
      // One the server says alice sent, naming nobody it can open.
      await server.as('alice').sendActivity(orchardId, [SealedActivity(keyGeneration: 1, sealed: Uint8List(64))]);
    });
    await pump(tester, owner);
    final lines = [
      l10n.activityConnected('alice@example.com', 'Web 1'),
      l10n.activityRevealed('alice@example.com', 'Deploy key'),
    ];
    for (final line in lines) {
      expect(find.text(line), findsOneWidget);
    }
    expect(tester.getTopLeft(find.text(lines[0])).dy, lessThan(tester.getTopLeft(find.text(lines[1])).dy),
        reason: 'newest first');
    expect(find.text(l10n.activityUnreadable(1)), findsOneWidget);
    expect(find.byKey(const ValueKey('team-activity-older')), findsNothing);
  });

  testWidgets('on, with nothing yet: it says members send it when they next sync', (tester) async {
    await build(tester, tracking: const RecordTracking(activity: true));
    await pump(tester, owner);
    expect(find.text(l10n.teamActivityEmpty), findsOneWidget);
  });
}
