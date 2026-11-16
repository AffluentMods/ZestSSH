import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/join_readiness.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/teams/account_key_service.dart' show AccountKeyStatus;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

import '../fake_crate_server.dart';

/// Before joining a team, this device's team keys must be here (3.0):
/// accepting an invitation without them said "Your account keys
/// aren't on this device yet. Sign in and let sync run once", three times
/// for three taps, and nobody could act on it.
/// Now: with sync on and the keys only not made yet, they are made right
/// there and the invitation is accepted; with sync off, joining says it
/// needs sync and opens its setup; with the keys on another device, a sync
/// now brings them (and joining goes on), or the account page has Start
/// over; and taps while it works are one answer, with one message.

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

  group('what is found out first', () {
    late bool keysHere;
    late AccountKeyStatus status;
    late List<String> calls;

    JoinPreparer preparer() => JoinPreparer(
          hasKeys: () async {
            calls.add('hasKeys');
            return keysHere;
          },
          ensureKeys: () async {
            calls.add('ensureKeys');
            if (status == AccountKeyStatus.ready) keysHere = true;
            return status;
          },
          forgetKeys: () => calls.add('forget'),
          syncNow: () async {
            calls.add('syncNow');
            status = AccountKeyStatus.ready;
          },
        );

    setUp(() {
      keysHere = false;
      status = AccountKeyStatus.ready;
      calls = [];
    });

    test('keys here: ready, nothing else asked', () async {
      keysHere = true;
      expect(await preparer().prepare(), JoinReadiness.ready);
      expect(calls, ['hasKeys']);
    });

    test('the keys not made yet: they are made now, not at the next sync', () async {
      expect(await preparer().prepare(), JoinReadiness.ready);
      expect(calls, ['hasKeys', 'ensureKeys', 'forget', 'hasKeys']);
    });

    test('sync is not asked about: a new account makes its keys with sync off (it locked a new person out)',
        () async {
      // The preparer has no say on sync at all now; the keys are made the
      // same way whether it is on or not.
      expect(await preparer().prepare(), JoinReadiness.ready);
      expect(calls, contains('ensureKeys'));
      expect(JoinReadiness.values.map((r) => r.name), isNot(contains('needsSync')));
    });

    test('the keys published by another device, or replaced there: on another device; a sync brings them', () async {
      for (final elsewhere in [AccountKeyStatus.waitingForAnotherDevice, AccountKeyStatus.changedElsewhere]) {
        status = elsewhere;
        expect(await preparer().prepare(), JoinReadiness.keysOnOtherDevice, reason: '$elsewhere');
      }
      status = AccountKeyStatus.waitingForAnotherDevice;
      calls.clear();
      expect(await preparer().syncThenPrepare(), JoinReadiness.ready);
      expect(calls.first, 'syncNow');
    });

    test('ZestSSH Cloud could not tell: unavailable', () async {
      status = AccountKeyStatus.unavailable;
      expect(await preparer().prepare(), JoinReadiness.unavailable);
    });
  });

  group('accepting an invitation', () {
    late _MemoryStorage storage;
    late FakeCrateServer server;
    late AccountKeys myKeys;
    late bool keysHere;
    late AccountKeyStatus status;
    late int ensureCalls;
    late int syncCalls;
    late int prepareCalls;
    late List<String> opened;
    Completer<void>? hold;

    /// What the check finds of the keys, where it is not what the service
    /// finds (null: the same).
    bool? checkSays;

    /// What a sync now does here; the keys come with the second one.
    late AccountKeyStatus Function(int sync) afterSync;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      storage = _MemoryStorage();
      keysHere = false;
      status = AccountKeyStatus.ready;
      ensureCalls = 0;
      syncCalls = 0;
      prepareCalls = 0;
      opened = [];
      hold = null;
      checkSays = null;
      afterSync = (_) => AccountKeyStatus.ready;
    });

    tearDown(() async {
      for (final db in storage.dbs.values) {
        await db.close();
      }
    });

    Future<void> open(WidgetTester tester) async {
      server = FakeCrateServer(accountUid: 'new-1');
      await tester.runAsync(() async => myKeys = await AccountKeys.generate());
      server.mine.add(MyInvite(
        id: 'a',
        orchardId: 'orchard-a',
        role: 'member',
        crates: 1,
        expiresAt: DateTime.utc(2026, 11, 8),
        accepted: false,
        invitedBy: 'owner@example.com',
      ));
      final service = OrchardService(
        server: server,
        databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
        author: () async => keysHere ? CrateAuthor(uid: 'new-1', keys: myKeys) : null,
      );
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          orchardServiceProvider.overrideWithValue(service),
          orchardSummariesProvider.overrideWith((ref) async => const []),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
          joinPreparerProvider.overrideWithValue(JoinPreparer(
            hasKeys: () async {
              prepareCalls++;
              if (hold != null) await hold!.future;
              return checkSays ?? keysHere;
            },
            ensureKeys: () async {
              ensureCalls++;
              if (status == AccountKeyStatus.ready) keysHere = true;
              return status;
            },
            forgetKeys: () {},
            syncNow: () async {
              syncCalls++;
              status = afterSync(syncCalls);
            },
          )),
          accountPageOpenerProvider.overrideWithValue((_) => opened.add('account')),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMyInvitations(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byKey(const ValueKey('my-invite-accept-a')), findsOneWidget);
    }

    Finder accept() => find.byKey(const ValueKey('my-invite-accept-a'));

    /// Nothing on screen or in the bell says "account keys".
    void saysNoInternalWords(WidgetTester tester) {
      expect(find.textContaining('account keys'), findsNothing);
      final container = ProviderScope.containerOf(tester.element(find.text('open').first));
      for (final n in container.read(notificationCenterProvider).history) {
        expect('${n.title} ${n.body ?? ''}', isNot(contains('account keys')));
      }
    }

    testWidgets('a) sync on, keys not made yet: they are made right there, and the invitation is accepted',
        (tester) async {
      await open(tester);
      await tester.tap(accept());
      await settle(tester);
      expect(ensureCalls, 1);
      expect(server.accepted, ['a']);
      expect(find.text(l10n.myInvitationAcceptedNote), findsOneWidget);
      saysNoInternalWords(tester);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('b) a new account with sync off: the keys are made right there and the invitation is accepted, '
        'with no detour to set up sync', (tester) async {
      await open(tester);
      await tester.tap(accept());
      await settle(tester);
      expect(ensureCalls, 1, reason: 'the keys are made here, sync on or not');
      expect(server.accepted, ['a']);
      expect(opened, isEmpty, reason: 'nobody is sent to the account page to set up sync first');
      expect(find.text(l10n.myInvitationAcceptedNote), findsOneWidget);
      saysNoInternalWords(tester);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('c) the keys on another device: Sync now brings them and the invitation is accepted; a sync that '
        'did not bring them says so', (tester) async {
      status = AccountKeyStatus.waitingForAnotherDevice;
      afterSync = (sync) => sync >= 2 ? AccountKeyStatus.ready : AccountKeyStatus.waitingForAnotherDevice;
      await open(tester);
      await tester.tap(accept());
      await settle(tester);
      expect(find.text(l10n.joinKeysElsewhereTitle), findsOneWidget);
      expect(find.text(l10n.joinKeysElsewhereBody), findsOneWidget);
      expect(find.text(l10n.joinNoOtherDeviceHelp), findsOneWidget, reason: 'and where to go without that device');
      expect(server.accepted, isEmpty);
      saysNoInternalWords(tester);

      await tester.tap(find.byKey(const ValueKey('join-sync-now')));
      await settle(tester);
      expect(syncCalls, 1);
      expect(find.byKey(const ValueKey('join-keys-still-elsewhere')), findsOneWidget);
      expect(server.accepted, isEmpty);

      await tester.tap(find.byKey(const ValueKey('join-sync-now')));
      await settle(tester);
      expect(syncCalls, 2);
      expect(find.text(l10n.joinKeysElsewhereTitle), findsNothing);
      expect(server.accepted, ['a'], reason: 'once they are here, joining goes on');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('c) without that device: the account page, where Start over is', (tester) async {
      status = AccountKeyStatus.waitingForAnotherDevice;
      await open(tester);
      await tester.tap(accept());
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('join-no-other-device')));
      await settle(tester);
      expect(opened, ['account']);
      expect(find.text(l10n.joinKeysElsewhereTitle), findsNothing);
      expect(find.text(l10n.myInvitationsTitle), findsNothing);
      expect(server.accepted, isEmpty);
    });

    testWidgets('d) taps while it works are one answer: the button is busy, and what went wrong is said once',
        (tester) async {
      // The check finds the keys, and the service then finds none: what it
      // gives is said, once.
      checkSays = true;
      hold = Completer<void>();
      await open(tester);
      await tester.tap(accept());
      await tester.pump();
      expect(accept(), findsNothing, reason: 'busy while it works');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Two more taps where the button was.
      await tester.tap(find.byType(CircularProgressIndicator), warnIfMissed: false);
      await tester.tap(find.byType(CircularProgressIndicator), warnIfMissed: false);
      await tester.pump();
      expect(prepareCalls, 1);

      hold!.complete();
      await settle(tester);
      expect(server.accepted, isEmpty);
      final container = ProviderScope.containerOf(tester.element(find.text('open').first));
      final said = [
        for (final n in container.read(notificationCenterProvider).history)
          if (n.title == l10n.orchardErrorKeysNotReady || n.body == l10n.orchardErrorKeysNotReady) n,
      ];
      expect(said, hasLength(1), reason: 'said once');
      expect(said.single.repeats, 1);
      expect(said.single.details, isNotNull, reason: 'with what stands behind it to copy');
      expect(l10n.orchardErrorKeysNotReady, isNot(contains('account keys')));
      expect(l10n.orchardErrorKeysNotReady, contains('Set up sync'));
      expect(accept(), findsOneWidget, reason: 'ready for another try');
      await tester.pump(const Duration(seconds: 12));
    });
  });
}

/// Lets the database and crypto work finish, then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  // A spinner that stays (an answer waiting on a dialog over it) never
  // settles: frames enough for the dialogs to open or close.
  if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}
