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
import 'package:zestssh/features/orchards/record/local_record.dart' show kUnlistedStatus;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show newRecordKindsOn;
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_settings.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/team_delete_dialog.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/redactor.dart';

import '../fake_crate_server.dart';

/// Deleting a team on screen: the Overview's Danger zone for
/// owners once new kinds of record entry are on, the confirmation that names
/// every vault and what is in it and waits for the team's name, the sign-in
/// from the last ten minutes, the banner while it is being deleted (Undo for
/// owners, Leave for everyone else), the question once ZestSSH Cloud says it
/// was deleted, and the only owner's Leave. Each account has its own device
/// and service against one (fake) server.

const _owner = 'owner-1';
const _alice = 'alice';

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

class _Device {
  _Device(this.shared, this.uid, this.keys, {_MemoryStorage? storage}) : storage = storage ?? _MemoryStorage() {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: this.storage);
    service = OrchardService(
      server: shared.as(uid),
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;
  final _MemoryStorage storage;
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;

  /// The same device with a service and a databases notifier of its own.
  _Device again() => _Device(shared, uid, keys, storage: storage);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    if (i >= 1 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeCrateServer server;
  late _Device owner;
  late _Device alice;
  late String orchardId;
  late String production;

  Future<void> setUpTeam(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner)..newRecordKinds = true;
    await tester.runAsync(() async {
      final devices = <_Device>[];
      for (final uid in [_owner, _alice]) {
        final keys = await AccountKeys.generate();
        await server.publish(uid, keys, email: '$uid@example.com');
        devices.add(_Device(server, uid, keys));
      }
      [owner, alice] = devices;
      orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single;
      production = member.crates.keys.single;
      await owner.service.invite(orchardId, email: '$_alice@example.com', role: member.id);
      final invite = (await owner.service.invites(orchardId)).single;
      server.acceptAs(orchardId, invite.id, _alice);
      await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
      await alice.service.refresh();
      // A host in Production, on the owner's device.
      final db = await owner.databases.open(orchardId);
      await CratePlacement(db).setDefaultCrate(production);
      final at = DateTime(2026, 10, 30);
      await db.into(db.connections).insert(
          ConnectionsCompanion.insert(id: 'h-1', label: 'db-primary', host: '192.0.2.10', createdAt: at, updatedAt: at));
      await owner.service.refresh();
    });
    addTearDown(() async {
      newRecordKindsOn.value = false;
      for (final d in [owner, alice]) {
        for (final db in d.storage.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
    });
  }

  /// The Overview as [as] sees it, on a computer, with [signIn] standing in
  /// for signing in again; or with [settings], Team settings (4.0: where
  /// Delete team is now).
  Future<ProviderContainer> pumpOverview(WidgetTester tester, _Device as,
      {SignInRefresher? signIn, bool settings = false}) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final view = as.again();
    final summary = (await tester.runAsync(() async {
      await view.service.refresh();
      return readOrchardSummary(await view.databases.open(orchardId), orchardId);
    }))!;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(view.service),
        orchardDatabasesProvider.overrideWith((ref) => view.databases),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        activeSidebarNavProvider.overrideWith((ref) => NavSection.team),
        if (signIn != null) signInRefresherProvider.overrideWithValue(signIn),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: settings
                ? TeamSettingsView(orchard: summary, onOpen: (_) {})
                : TeamOverview(orchard: summary, onOpen: (_) {}),
          ),
        ),
      ),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
  }

  bool canConfirm(WidgetTester tester) =>
      tester.widget<ZestDialogShell>(find.byType(ZestDialogShell).last).primaryAction!.onPressed != null;

  bool told(ProviderContainer container, String message) =>
      find.text(message).evaluate().isNotEmpty ||
      container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);

  Future<void> openConfirmation(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('team-delete')));
    await tester.tap(find.byKey(const ValueKey('team-delete')));
    await settle(tester);
  }

  testWidgets("an owner deletes the team from Team settings' Danger zone: the confirmation names every vault and "
      'what is in it, and Delete waits for the name', (tester) async {
    await setUpTeam(tester);
    newRecordKindsOn.value = true;
    // Not on the everyday Overview (4.0).
    await pumpOverview(tester, owner);
    expect(find.byKey(const ValueKey('team-delete-zone')), findsNothing);
    final container = await pumpOverview(tester, owner, settings: true);
    expect(find.byKey(const ValueKey('team-delete-zone')), findsOneWidget);
    // Under the app's own section header,
    // in red.
    expect(
        tester
            .widget<ZestSectionHeader>(
                find.descendant(of: find.byKey(const ValueKey('team-danger-title')), matching: find.byType(ZestSectionHeader)))
            .danger,
        isTrue);

    await openConfirmation(tester);
    expect(find.text(l10n.teamDeleteTitle('Acme')), findsOneWidget);
    final vault = find.byKey(ValueKey('team-delete-vault-$production'));
    expect(find.descendant(of: vault, matching: find.textContaining(l10n.teamDeleteHosts(1))), findsOneWidget);
    // Opened, it names what is in it.
    await tester.tap(find.descendant(of: vault, matching: find.text('Production')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: vault, matching: find.text('db-primary')), findsOneWidget);
    // Who loses access, this account first.
    expect(find.text(l10n.teamDeletePeople(2)), findsOneWidget);
    expect(find.text(l10n.teamDeleteYouName('$_owner@example.com')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-delete-no-refund')), findsOneWidget);
    expect(find.text(l10n.teamDeleteRecord), findsOneWidget);

    // Delete waits for the team's name, exactly.
    expect(canConfirm(tester), isFalse);
    await tester.enterText(find.byKey(const ValueKey('team-delete-name-field')), 'acme');
    await tester.pump();
    expect(canConfirm(tester), isFalse);
    await tester.enterText(find.byKey(const ValueKey('team-delete-name-field')), 'Acme');
    await tester.pump();
    expect(canConfirm(tester), isTrue);
    await tester.tap(find.text(l10n.teamDeleteConfirm('Acme')));
    await settle(tester);

    expect(server.deletes, 1);
    expect(server.recordOf(orchardId).deleting?.by, _owner);
    final day = teamDeletionDay(DateTime.now().add(const Duration(days: 7)), l10n);
    expect(told(container, l10n.teamDeletedToast('Acme', day)), isTrue);

    // Then the team is held back, with Undo for its owners, and no Danger zone.
    await pumpOverview(tester, owner, settings: true);
    expect(find.byKey(const ValueKey('orchard-banner-deleting')), findsOneWidget);
    expect(find.text(l10n.orchardBannerDeletingYou('Acme', day)), findsOneWidget);
    expect(find.text(l10n.orchardBannerUndo), findsOneWidget);
    expect(find.byKey(const ValueKey('team-delete-zone')), findsNothing);
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('deleting takes a sign-in from the last ten minutes: Confirm it\'s you says so, then it goes',
      (tester) async {
    await setUpTeam(tester);
    newRecordKindsOn.value = true;
    server.deleteSignInTooOld = true;
    var signIns = 0;
    await pumpOverview(tester, owner, settings: true, signIn: (context, ref, {wrongAccount}) async {
      signIns++;
      server.deleteSignInTooOld = false;
      return true;
    });
    await openConfirmation(tester);
    await tester.enterText(find.byKey(const ValueKey('team-delete-name-field')), 'Acme');
    await tester.pump();
    await tester.tap(find.text(l10n.teamDeleteConfirm('Acme')));
    await settle(tester);
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(find.text(l10n.stepUpWhyAccount), findsOneWidget, reason: 'the ten minutes of an account change');
    expect(find.text(l10n.stepUpDeleteTeam('Acme')), findsOneWidget);
    await tester.tap(find.text(l10n.devicesSignInAgainTitle));
    await settle(tester);
    expect(signIns, 1);
    expect(server.deletes, 2, reason: 'refused once, then asked again after the sign-in');
    expect(server.recordOf(orchardId).deleting, isNotNull);
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('no Danger zone before new kinds of record entry are on, nor for someone who is not an owner',
      (tester) async {
    await setUpTeam(tester);
    server.newRecordKinds = false;
    await pumpOverview(tester, owner, settings: true);
    expect(find.byKey(const ValueKey('team-delete-zone')), findsNothing);
    server.newRecordKinds = true;
    await pumpOverview(tester, alice, settings: true);
    expect(find.byKey(const ValueKey('team-delete-zone')), findsNothing);
  });

  testWidgets('an owner undoes it from the banner; a member sees who asked and the day, and may leave', (tester) async {
    await setUpTeam(tester);
    await tester.runAsync(() => owner.service.deleteTeam(orchardId));
    final day = teamDeletionDay(DateTime.now().add(const Duration(days: 7)), l10n);

    // A member: who asked and the day, and Leave.
    await pumpOverview(tester, alice);
    expect(find.text(l10n.orchardBannerDeleting('Acme', '$_owner@example.com', day)), findsOneWidget);
    expect(find.text(l10n.orchardBannerUndo), findsNothing);
    expect(find.text(l10n.orchardLeave), findsOneWidget);

    // An owner: Undo.
    final container = await pumpOverview(tester, owner);
    await tester.tap(find.text(l10n.orchardBannerUndo));
    await settle(tester);
    expect(find.text(l10n.teamUndoTitle('Acme')), findsOneWidget);
    await tester.tap(find.text(l10n.teamUndoConfirm));
    await settle(tester);
    expect(server.restores, 1);
    expect(server.recordOf(orchardId).deleting, isNull);
    expect(told(container, l10n.teamKeptToast('Acme')), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an admin undoes it too: a team whose only owner went bad can be stopped',
      (tester) async {
    await setUpTeam(tester);
    await tester.runAsync(() async {
      await owner.service.setMemberRole(orchardId, _alice, FixedRoles.admin);
      await alice.service.refresh();
      await owner.service.deleteTeam(orchardId);
    });
    final container = await pumpOverview(tester, alice);
    expect(find.text(l10n.orchardBannerUndo), findsOneWidget);
    expect(find.text(l10n.orchardLeave), findsNothing);
    server.accountUid = _alice;
    await tester.tap(find.text(l10n.orchardBannerUndo));
    await settle(tester);
    await tester.tap(find.text(l10n.teamUndoConfirm));
    await settle(tester);
    expect(server.restores, 1);
    expect(server.recordOf(orchardId).deleting, isNull, reason: 'the admin kept the team');
    expect(told(container, l10n.teamKeptToast('Acme')), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a member leaves a team being deleted from its banner', (tester) async {
    await setUpTeam(tester);
    await tester.runAsync(() => owner.service.deleteTeam(orchardId));
    await pumpOverview(tester, alice);
    await tester.tap(find.text(l10n.orchardLeave));
    await settle(tester);
    expect(find.text(l10n.orchardLeaveTitle('Acme')), findsOneWidget);
    await tester.tap(find.text(l10n.orchardLeaveConfirm));
    await settle(tester);
    expect(server.recordOf(orchardId).members[_alice]?.status, MemberStatus.removed);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a team ZestSSH Cloud says was deleted asks before it leaves this device', (tester) async {
    await setUpTeam(tester);
    await tester.runAsync(() async {
      await owner.service.deleteTeam(orchardId);
      await alice.service.refresh();
      server.purgeTeam(orchardId);
      await alice.service.refresh();
    });
    final summary = (await tester.runAsync(() async => readOrchardSummary(await alice.databases.open(orchardId), orchardId)))!;
    expect(summary.status, kDeletedStatus);
    await _pumpBanner(tester, alice, summary);
    expect(find.byKey(const ValueKey('orchard-banner-deleted')), findsOneWidget);
    await tester.tap(find.text(l10n.orchardBannerRemove));
    await settle(tester);
    expect(find.text(l10n.teamRemoveDeletedTitle('Acme')), findsOneWidget);
    await tester.tap(find.text(l10n.teamRemoveDeletedConfirm));
    await settle(tester);
    expect(await tester.runAsync(() => alice.databases.onDevice()), isNot(contains(orchardId)));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a team ZestSSH Cloud no longer lists, while the record here still has her in it, asks before it '
      'leaves this device', (tester) async {
    await setUpTeam(tester);
    await tester.runAsync(() async {
      server.hidden.add(orchardId);
      await alice.service.refresh();
    });
    final summary = (await tester.runAsync(() async => readOrchardSummary(await alice.databases.open(orchardId), orchardId)))!;
    expect(summary.status, kUnlistedStatus);
    expect(await tester.runAsync(() => alice.databases.onDevice()), contains(orchardId), reason: 'nothing went unasked');
    await _pumpBanner(tester, alice, summary);
    expect(find.byKey(const ValueKey('orchard-banner-unlisted')), findsOneWidget);
    expect(find.textContaining(l10n.orchardBannerUnlisted('Acme')), findsOneWidget);
    expect(find.textContaining('ZS-1411'), findsOneWidget);
    await tester.tap(find.text(l10n.orchardBannerRemove));
    await settle(tester);
    expect(find.text(l10n.teamRemoveDeletedTitle('Acme')), findsOneWidget);
    expect(find.text(l10n.teamRemoveUnlistedBody), findsOneWidget);
    await tester.tap(find.text(l10n.teamRemoveDeletedConfirm));
    await settle(tester);
    expect(await tester.runAsync(() => alice.databases.onDevice()), isNot(contains(orchardId)));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("the only owner's Leave offers a new owner, then leaves; or deleting the team", (tester) async {
    await setUpTeam(tester);
    newRecordKindsOn.value = true;
    final people = (await tester.runAsync(() => owner.service.people(orchardId)))!;
    final summary = (await tester.runAsync(() async => readOrchardSummary(await owner.databases.open(orchardId), orchardId)))!;
    var left = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(owner.service),
        orchardDatabasesProvider.overrideWith((ref) => owner.databases),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => soleOwnerLeave(context, ref, summary, people, onLeft: () => left++),
              child: const Text('leave'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('leave'));
    await settle(tester);
    expect(find.text(l10n.teamSoleOwnerLeaveTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('sole-owner-make-owner')), findsOneWidget);
    expect(find.byKey(const ValueKey('sole-owner-delete')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sole-owner-make-owner')));
    await settle(tester);
    expect(find.text(l10n.teamSoleOwnerPickTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sole-owner-pick-$_alice')));
    await settle(tester);
    final record = server.recordOf(orchardId);
    expect(record.isOwner(_alice), isTrue, reason: 'alice is the owner now');
    expect(record.members[_owner]?.status, MemberStatus.removed, reason: 'and the owner left');
    expect(left, 1);
    await tester.pump(const Duration(seconds: 5));
  });

  /// [run] behind a button, with the owner's device.
  Future<void> pumpButton(WidgetTester tester, Future<void> Function(BuildContext, WidgetRef) run) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(owner.service),
        orchardDatabasesProvider.overrideWith((ref) => owner.databases),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(onPressed: () => run(context, ref), child: const Text('go')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await settle(tester);
  }

  testWidgets('a team whose name does not read on this device is deleted by typing the words it is shown by '
      '(found in a review)', (tester) async {
    await setUpTeam(tester);
    newRecordKindsOn.value = true;
    final s = (await tester.runAsync(() async => readOrchardSummary(await owner.databases.open(orchardId), orchardId)))!;
    // As a team whose name is sealed under a key this device lacks reads.
    final unnamed = OrchardSummary(
        id: s.id, name: null, role: s.role, crates: s.crates, defaultCrateId: s.defaultCrateId, can: s.can);
    await pumpButton(tester, (context, ref) => deleteTeamFlow(context, ref, unnamed));
    expect(find.text(l10n.teamDeleteTypeName(l10n.orchardUnnamed)), findsOneWidget);
    expect(canConfirm(tester), isFalse);
    await tester.enterText(find.byKey(const ValueKey('team-delete-name-field')), l10n.orchardUnnamed);
    await tester.pump();
    expect(canConfirm(tester), isTrue);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("the only owner's Leave asks to compare safety words with a member not compared yet, before any "
      'sign-in, then makes them the owner', (tester) async {
    await setUpTeam(tester);
    newRecordKindsOn.value = true;
    // The owner has not compared with alice on this device.
    await tester.runAsync(() async {
      final db = await owner.databases.open(orchardId);
      await db.customStatement("UPDATE member_keys SET verified_by_me = 0, verified_by = '[]' WHERE uid = '$_alice'");
    });
    final people = (await tester.runAsync(() => owner.service.people(orchardId)))!;
    expect(people.members.firstWhere((m) => m.uid == _alice).trust?.verifiedByMe, isFalse);
    final summary = (await tester.runAsync(() async => readOrchardSummary(await owner.databases.open(orchardId), orchardId)))!;
    var left = 0;
    Future<void> leave(BuildContext context, WidgetRef ref) =>
        soleOwnerLeave(context, ref, summary, people, onLeft: () => left++);

    // Cancelled at the comparison: nothing changes.
    await pumpButton(tester, leave);
    await tester.tap(find.byKey(const ValueKey('sole-owner-make-owner')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('sole-owner-pick-$_alice')));
    await settle(tester);
    expect(find.byKey(const ValueKey('sole-owner-compare')), findsOneWidget);
    expect(find.text(l10n.orchardPromoteCompareTitle('$_alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).isOwner(_alice), isFalse);
    expect(left, 0);

    // Compared: she becomes the owner and the owner leaves.
    await tester.tap(find.text('go'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('sole-owner-make-owner')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('sole-owner-pick-$_alice')));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardVerifyMatch));
    await settle(tester);
    final record = server.recordOf(orchardId);
    expect(record.isOwner(_alice), isTrue);
    expect(record.members[_owner]?.status, MemberStatus.removed);
    expect(left, 1);
    await tester.pump(const Duration(seconds: 5));
  });
}

/// The banner alone, for [summary] on [device].
Future<void> _pumpBanner(WidgetTester tester, _Device device, OrchardSummary summary) async {
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: [
      orchardServiceProvider.overrideWithValue(device.service),
      orchardDatabasesProvider.overrideWith((ref) => device.databases),
      activeOrchardProvider.overrideWithValue(AsyncData(summary)),
      orchardSummariesProvider.overrideWith((ref) async => [summary]),
      deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('en'),
      home: Scaffold(body: OrchardStatusBanner()),
    ),
  ));
  await settle(tester);
}
