import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/team_recovery_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/teams/crypto/fingerprint_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/redactor.dart';

import 'fake_crate_server.dart';

/// Team recovery on screen (3.0): the Team recovery section (off
/// until there are two owners, the owners' switch after a yes, who waits),
/// an owner comparing a waiting member's new words before approving,
/// completing or taking an approval back, the waiting member's banner and
/// words, and the Overview's row for owners. The (fake) server holds to the
/// same rules as ZestSSH Cloud's routes.

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
  late AccountKeys alice2;
  late FakeCrateServer server;
  late OrchardService owner;
  late OrchardService owner2;
  late String orchardId;
  final storages = <_MemoryStorage>[];

  /// Each device's databases and who it is: a screen gets a service of its
  /// own over them (a closed screen takes its service's notifier with it).
  final devices = <OrchardService, ({_MemoryStorage storage, String uid, AccountKeys keys})>{};

  setUpAll(() async {
    for (final uid in ['owner-1', 'owner-2', 'alice']) {
      keys[uid] = await AccountKeys.generate();
    }
    alice2 = await AccountKeys.generate(version: 2);
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

  OrchardService onStorage(_MemoryStorage storage, String uid, AccountKeys k) {
    final service = OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: k),
    );
    devices[service] = (storage: storage, uid: uid, keys: k);
    return service;
  }

  OrchardService serviceFor(String uid, AccountKeys k) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return onStorage(storage, uid, k);
  }

  /// Acme, with owner-1, owner-2 (unless not [secondOwner]) and alice (in
  /// the first role); team recovery [on]; alice started over when she
  /// [waits].
  Future<void> build(WidgetTester tester, {bool secondOwner = true, bool on = false, bool waits = false}) =>
      tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in keys.keys) {
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = serviceFor('owner-1', keys['owner-1']!);
        owner2 = serviceFor('owner-2', keys['owner-2']!);
        final alice = serviceFor('alice', keys['alice']!);
        orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        final member = server.recordOf(orchardId).roles.values.single.id;
        Future<void> join(OrchardService person, String uid, String role) async {
          await owner.invite(orchardId, email: '$uid@example.com', role: role);
          server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, uid);
          await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
          await person.refresh();
        }

        if (secondOwner) await join(owner2, 'owner-2', FixedRoles.owner);
        await join(alice, 'alice', member);
        if (on) await owner.setTeamRecovery(orchardId, true);
        if (waits) await server.resetKeys('alice', alice2);
        await owner.refresh();
        await owner2.refresh();
      });

  /// Lets the database and crypto work finish, then the frames.
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

  /// [child] for the Orchard as [as]'s device ([me], signed in with
  /// [myKeys]) has it.
  Future<void> pump(WidgetTester tester, OrchardService as, Widget Function(OrchardSummary) child,
      {String me = 'owner-1',
      AccountKeys? myKeys,
      Locale locale = const Locale('en'),
      ThemeData? theme,
      List<Override> extra = const []}) async {
    final device = devices[as]!;
    as = onStorage(device.storage, device.uid, device.keys);
    late OrchardSummary summary;
    await tester.runAsync(() async => summary = await readOrchardSummary(await as.databases.open(orchardId), orchardId));
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A scope of its own each time: another device's cached state never
    // carries over.
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(as),
        orchardDatabasesProvider.overrideWith((ref) => as.databases),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardAuthorProvider.overrideWithValue(
            OrchardAuthorSource(() async => CrateAuthor(uid: me, keys: myKeys ?? keys[me]!))),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        currentUserProvider.overrideWithValue(UserProfile(uid: me, email: '$me@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ...extra,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        theme: theme,
        home: Scaffold(body: SingleChildScrollView(child: child(summary))),
      ),
    ));
    await settle(tester);
  }

  Finder inKey(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  testWidgets('one owner: team recovery stays off, and the section says a second owner is needed', (tester) async {
    await build(tester, secondOwner: false);
    var opened = 0;
    await pump(tester, owner, (s) => TeamRecoveryPanel(orchard: s, onAddOwner: () => opened++));
    expect(find.byKey(const ValueKey('team-recovery-state-off')), findsOneWidget);
    expect(find.text(l10n.teamRecoveryNeedsTwoOwners), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('team-recovery-on'))).onPressed, isNull);
    // As the rules beside it: its state in its words, and an outlined Set up
    // at its end, beside its name (it had an Off pill of its own and Turn on
    // at its foot).
    expect(tester.widget<Text>(find.byKey(const ValueKey('team-recovery-state-off'))).data,
        '${l10n.teamRecoveryStateOff} · ${l10n.teamRecoveryBody}');
    expect(inKey('team-recovery', find.byType(ZestStatusPill)), findsNothing);
    expect(inKey('team-recovery-on', find.text(l10n.teamRecoverySetUp)), findsOneWidget);
    expect(tester.getCenter(find.byKey(const ValueKey('team-recovery-on'))).dy,
        lessThan(tester.getTopLeft(find.text(l10n.teamRecoveryNeedsTwoOwners)).dy),
        reason: 'at the head of the card, above what stops it');
    await tester.tap(find.byKey(const ValueKey('team-recovery-add-owner')));
    expect(opened, 1);
  });

  testWidgets('on, with one owner left: the section says it cannot finish without a second owner, and offers one',
      (tester) async {
    // Found in a docs check: the line showed only while
    // team recovery was off; on with one owner, nothing said it cannot finish.
    // Turned on with two owners; the second one has left since (the record
    // keeps it on; an owner cannot demote or remove another owner).
    await build(tester, on: true);
    var opened = 0;
    await pump(tester, owner, (s) => TeamRecoveryPanel(orchard: s, onAddOwner: () => opened++),
        extra: [teamRecoveryRuleProvider.overrideWith((ref, id) async => (on: true, owners: 1))]);
    expect(find.byKey(const ValueKey('team-recovery-state-on')), findsOneWidget);
    expect(inKey('team-recovery-one-owner-on', find.text(l10n.teamRecoveryOneOwnerOn)), findsOneWidget);
    expect(find.text(l10n.teamRecoveryNeedsTwoOwners), findsNothing);
    await tester.tap(find.byKey(const ValueKey('team-recovery-add-owner')));
    expect(opened, 1);
  });

  testWidgets('two owners: turned on only after a yes, and the record says so', (tester) async {
    await build(tester);
    await pump(tester, owner, (s) => TeamRecoveryPanel(orchard: s));
    expect(find.text(l10n.teamRecoveryNeedsTwoOwners), findsNothing);

    await tester.tap(find.byKey(const ValueKey('team-recovery-on')));
    await settle(tester);
    expect(find.text(l10n.teamRecoveryTurnOnTitle), findsOneWidget);
    expect(find.text(l10n.teamRecoveryTurnOnBody('Acme')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).teamRecovery, isFalse, reason: 'declined: nothing sent');

    await tester.tap(find.byKey(const ValueKey('team-recovery-on')));
    await settle(tester);
    await tester.tap(find.text(l10n.teamRecoveryTurnOn).last);
    await settle(tester);
    expect(server.recordOf(orchardId).teamRecovery, isTrue);
    expect(toasted(tester, l10n.teamRecoveryTurnedOn), isTrue);
    expect(find.byKey(const ValueKey('team-recovery-state-on')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-recovery-off')), findsOneWidget, reason: 'and can be turned off again');
    await tester.pump(const Duration(seconds: 10));

    // Off again, after a yes to what it means.
    await pump(tester, owner, (s) => TeamRecoveryPanel(orchard: s));
    await tester.tap(find.byKey(const ValueKey('team-recovery-off')));
    await settle(tester);
    expect(find.text(l10n.teamRecoveryTurnOffBody('Acme')), findsOneWidget);
    await tester.tap(find.text(l10n.teamRecoveryTurnOff).last);
    await settle(tester);
    expect(server.recordOf(orchardId).teamRecovery, isFalse);
    expect(toasted(tester, l10n.teamRecoveryTurnedOff), isTrue);
    expect(find.byKey(const ValueKey('team-recovery-state-off')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a member who waits: one owner compares and approves, a second compares and gives the access back',
      (tester) async {
    await build(tester, on: true, waits: true);
    final words = fingerprintWords((await tester.runAsync(() => alice2.publish('alice')))!.fingerprint);

    await pump(tester, owner, (s) => TeamRecoveryPanel(orchard: s));
    expect(inKey('team-recovery-wait-alice', find.text('alice@example.com')), findsOneWidget);
    expect(inKey('team-recovery-wait-alice', find.text(l10n.teamRecoveryRowNone)), findsOneWidget);
    await tester.tap(inKey('team-recovery-wait-alice', find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.recoveryReviewTitle('alice@example.com')), findsOneWidget);
    // The words to compare are alice's new keys'. (A word may stand more
    // than once among them: the keys are made anew for every run, and this
    // looked for the first word once, which failed now and then.)
    expect(inKey('compare-theirs', find.text(words.first)),
        findsNWidgets(words.where((word) => word == words.first).length));
    expect(find.text(l10n.recoveryReviewApproveBody), findsOneWidget);
    expect(find.text(l10n.recoveryReviewNoMatch('alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.recoveryApprove));
    await settle(tester);
    expect(server.recoveryApprovals[orchardId]!['alice']!.keys, ['owner-1']);
    expect(toasted(tester, l10n.recoveryApproved('alice@example.com')), isTrue);
    await tester.pump(const Duration(seconds: 10));

    // The second owner sees the first's approval, compares too, and completes.
    await pump(tester, owner2, (s) => TeamRecoveryPanel(orchard: s), me: 'owner-2');
    expect(inKey('team-recovery-wait-alice', find.text(l10n.teamRecoveryRowApprovedBy('owner-1@example.com'))),
        findsOneWidget);
    await tester.tap(inKey('team-recovery-wait-alice', find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.recoveryReviewCompleteBody('owner-1@example.com', 'alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.recoveryComplete));
    await settle(tester);
    expect(server.recordOf(orchardId).members['alice']!.currentKeys.version, 2);
    expect(toasted(tester, l10n.recoveryCompleted('alice@example.com')), isTrue);
    expect(find.byKey(const ValueKey('team-recovery-wait-alice')), findsNothing, reason: 'nobody waits any more');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('an owner who approved can take it back', (tester) async {
    await build(tester, on: true, waits: true);
    await tester.runAsync(() async =>
        owner.approveRecovery(orchardId, (await owner.teamRecovery(orchardId)).waiting.single));
    await pump(tester, owner, (s) => TeamRecoveryPanel(orchard: s));
    expect(inKey('team-recovery-wait-alice', find.text(l10n.teamRecoveryRowApprovedByYou)), findsOneWidget);
    await tester.tap(inKey('team-recovery-wait-alice', find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.recoveryReviewYouApproved), findsOneWidget);
    await tester.tap(find.text(l10n.recoveryWithdraw));
    await settle(tester);
    expect(server.recoveryApprovals[orchardId]!['alice'], isEmpty);
    expect(toasted(tester, l10n.recoveryWithdrawn), isTrue);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('owners see a member who waits on the Overview, with a way to review', (tester) async {
    await build(tester, on: true, waits: true);
    await pump(tester, owner, (s) => TeamOverview(orchard: s));
    expect(find.byKey(const ValueKey('team-attn-recovery-alice')), findsOneWidget);
    expect(find.text(l10n.teamAttnRecoveryWaiting('alice@example.com')), findsOneWidget);
    expect(find.text(l10n.teamAttnRecoveryWaitingBody), findsOneWidget);
    await tester.tap(inKey('team-attn-recovery-alice', find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.recoveryReviewTitle('alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // Once one owner approved: the other is asked to complete, the one who
    // approved waits for them.
    await tester.runAsync(() async =>
        owner2.approveRecovery(orchardId, (await owner2.teamRecovery(orchardId)).waiting.single));
    await pump(tester, owner, (s) => TeamOverview(orchard: s));
    expect(find.text(l10n.teamAttnRecoveryApprovedByOther('owner-2@example.com')), findsOneWidget);
    await pump(tester, owner2, (s) => TeamOverview(orchard: s), me: 'owner-2');
    expect(find.text(l10n.teamAttnRecoveryApprovedByYou), findsOneWidget);
  });

  testWidgets('the member who waits: why nothing opens, and their new words to read to two owners', (tester) async {
    await build(tester, on: true, waits: true);
    final aliceNew = serviceFor('alice', alice2);
    expect(await tester.runAsync(aliceNew.refresh), isEmpty);
    final words = fingerprintWords((await tester.runAsync(() => alice2.publish('alice')))!.fingerprint);

    await pump(tester, aliceNew, (s) => const OrchardStatusBanner(), me: 'alice', myKeys: alice2);
    expect(find.byKey(const ValueKey('orchard-banner-recovery')), findsOneWidget);
    expect(find.text(l10n.orchardBannerRecoveryWait(l10n.orchardUnnamed)), findsOneWidget,
        reason: "the Orchard's name opens with its key, which is not here yet");
    await tester.tap(find.text(l10n.orchardBannerRecoveryShowWords));
    await settle(tester);
    expect(find.text(l10n.recoveryWaitTitle), findsOneWidget);
    expect(inKey('recovery-my-words', find.text(words.first)),
        findsNWidgets(words.where((word) => word == words.first).length));
    expect(find.text(l10n.recoveryWaitApprovals(0)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery-show-qr')));
    await settle(tester);
    expect(find.text(l10n.fpHideMyCode), findsOneWidget);
  });

  testWidgets('in every language: the section, the review at its longest button, and the banner, nothing clipped',
      (tester) async {
    // The shipped font: the test font draws every glyph as a square, far
    // wider than real text.
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf']) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
      }
      await loader.load();
    });
    final theme = ThemeData(fontFamily: 'GeistSans');
    await build(tester, on: true, waits: true);
    await tester.runAsync(() async =>
        owner2.approveRecovery(orchardId, (await owner2.teamRecovery(orchardId)).waiting.single));
    final aliceNew = serviceFor('alice', alice2);
    await tester.runAsync(aliceNew.refresh);
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      // The owner who completes: the longest button there is.
      await pump(tester, owner, (s) => TeamRecoveryPanel(orchard: s), locale: locale, theme: theme);
      expect(tester.takeException(), isNull, reason: '$locale: the section');
      await tester.tap(inKey('team-recovery-wait-alice', find.text(t.teamReview)));
      await settle(tester);
      expect(find.text(t.recoveryComplete), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the review');
      await tester.tap(find.text(t.cancel).last);
      await settle(tester);
      // The member who waits.
      await pump(tester, aliceNew, (s) => const OrchardStatusBanner(),
          me: 'alice', myKeys: alice2, locale: locale, theme: theme);
      await tester.tap(find.text(t.orchardBannerRecoveryShowWords));
      await settle(tester);
      expect(find.text(t.recoveryWaitTitle), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the words');
      await tester.tap(find.text(t.close).last);
      await settle(tester);
    }
  });

  testWidgets('a member who waits where team recovery is off is told whom to ask', (tester) async {
    await build(tester, waits: true);
    final aliceNew = serviceFor('alice', alice2);
    await tester.runAsync(aliceNew.refresh);
    await pump(tester, aliceNew, (s) => const OrchardStatusBanner(), me: 'alice', myKeys: alice2);
    await tester.tap(find.text(l10n.orchardBannerRecoveryShowWords));
    await settle(tester);
    expect(find.text(l10n.recoveryWaitOff(l10n.orchardUnnamed)), findsOneWidget);
  });
}
