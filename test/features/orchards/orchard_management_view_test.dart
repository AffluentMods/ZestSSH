import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/record_statements.dart';

import 'fake_crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'vaults_window_helper.dart';

/// Running an Orchard from its screens (3.0): the Members screen
/// shows each person's role and standing and offers what this account may
/// change, and each change lands in the record (with the keys it leaves
/// waiting replaced); owners make, order and delete roles; whoever manages
/// a Crate sets what it allows and renames it; the banner says where the
/// Orchard on screen stands.

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

  late _MemoryStorage storage;
  late FakeCrateServer server;
  late OrchardService service;
  final keys = <String, AccountKeys>{};
  late String orchardId;
  late String production;
  late String staging;
  late String member;
  late String ops;
  late int aliceEnds;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = _MemoryStorage();
  });

  tearDown(() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  });

  /// The owner's Orchard: Production and Staging; the roles Member (use of
  /// Production) and Ops (edit on Staging); Alice a Member with Staging on
  /// top and an end date, Bob an admin, Carol a suspended Member. With
  /// [withKeys], a key with a password in Production and a host using it.
  Future<void> build(WidgetTester tester, {bool withKeys = false}) => tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in ['owner-1', 'alice', 'bob', 'carol']) {
          keys[uid] = await AccountKeys.generate();
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        service = OrchardService(
          server: server,
          databases:
              OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
          author: () async => CrateAuthor(uid: 'owner-1', keys: keys['owner-1']!),
        );
        orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        staging = await service.createCrate(orchardId, 'Staging');
        final first = server.recordOf(orchardId).roles.values.single;
        member = first.id;
        production = first.crates.keys.single;
        ops = await service.saveRole(orchardId,
            name: 'Ops', can: const {}, crates: {staging: levelSwitches(CrateLevel.edit)});
        Future<void> append(String type, Map<String, Object?> body) async {
          final r = server.recordOf(orchardId);
          await server.appendAs('owner-1', orchardId, [
            await signRecordEntry(keys['owner-1']!,
                orchardId: orchardId, seq: r.seq + 1, prev: r.head, type: type, body: body, by: 'owner-1'),
          ], checkCopies: false);
        }

        Future<Map<String, Object?>> joining(String uid) async => recordKeysBody(await keys[uid]!.publish(uid));
        aliceEnds = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day + 31).millisecondsSinceEpoch ~/ 1000; // through a day 30 days on
        await append(RecordTypes.memberAdd, {
          ...await joining('alice'),
          'uid': 'alice',
          'role': member,
          'grants': {staging: switchList(levelSwitches(CrateLevel.use))},
          'ends_at': aliceEnds,
        });
        await append(RecordTypes.memberAdd, {
          ...await joining('bob'),
          'uid': 'bob',
          'role': FixedRoles.admin,
          'verified': await comparedStatement(keys['owner-1']!, 'owner-1', orchardId, await keys['bob']!.publish('bob')),
        });
        await append(RecordTypes.memberAdd, {...await joining('carol'), 'uid': 'carol', 'role': member});
        await append(RecordTypes.memberSuspend, {'uid': 'carol'});
        await service.refresh();
        if (withKeys) {
          final db = await service.databases.open(orchardId);
          final at = DateTime(2026, 9, 24);
          await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: 'deploy', label: 'deploy', username: 'ubuntu', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
          await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: 'web1',
              label: 'web1',
              host: '10.0.0.1',
              port: const Value(22),
              identityId: const Value('deploy'),
              createdAt: at,
              updatedAt: at));
          await OrchardSyncCoordinator(service: service, server: server, databases: service.databases).syncAll();
        }
      });

  /// Pumps a button that runs [open], with the Orchard as this device reads
  /// it (read again whenever a screen says it changed), and taps it.
  Future<void> openWith(WidgetTester tester, void Function(BuildContext, WidgetRef) open) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardSummariesProvider.overrideWith((ref) async {
          ref.watch(orchardListVersionProvider);
          return [await readOrchardSummary(await service.databases.open(orchardId), orchardId)];
        }),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(onPressed: () => open(context, ref), child: const Text('open')),
                // Keeps the Orchard list read, as the app does.
                Text('${ref.watch(orchardSummariesProvider).valueOrNull?.length}'),
              ],
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Finder row(String uid) => find.byKey(ValueKey('member-$uid'));
  Finder inRow(String uid, Finder f) => find.descendant(of: row(uid), matching: f);

  Future<void> menu(WidgetTester tester, String uid, String item) async {
    await tester.tap(inRow(uid, find.byIcon(LucideIcons.moreHorizontal)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  List<String> menuItems(WidgetTester tester) => [
        for (final e in find.byType(PopupMenuItem<Object>).evaluate())
          (((((e.widget as PopupMenuItem<Object>).child as Row).children[2]) as Flexible).child as Text).data!,
      ];

  testWidgets("an owner's Members screen: each person's role and standing, and a menu of what may change",
      (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId));

    expect(inRow('owner-1', find.text(l10n.orchardMemberYou)), findsOneWidget);
    expect(inRow('owner-1', find.text(l10n.orchardRoleOwner)), findsOneWidget);
    final through = DateFormat.yMMMd('en').format(DateTime.fromMillisecondsSinceEpoch((aliceEnds - 1) * 1000));
    expect(inRow('alice', find.text('Member')), findsOneWidget, reason: 'the role by the name the owners gave it');
    expect(inRow('alice', find.text(l10n.orchardMemberEndsOn(through))), findsOneWidget);
    expect(inRow('alice', find.text(l10n.orchardMemberExtraCrates(1))), findsOneWidget);
    expect(inRow('bob', find.text(l10n.orchardRoleAdmin)), findsOneWidget);
    expect(inRow('carol', find.text(l10n.orchardMemberSuspended)), findsOneWidget);
    expect(find.byKey(const ValueKey('sole-owner')), findsOneWidget, reason: 'one owner: a nudge toward two');
    // The only owner cannot step down: their own row offers their approved
    // devices, and Leave, which offers a new owner or
    // deleting the team.
    await tester.tap(inRow('owner-1', find.byIcon(LucideIcons.moreHorizontal)));
    await tester.pumpAndSettle();
    expect(menuItems(tester), [l10n.memberDevicesTitle, l10n.orchardLeave]);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    // People are listed this account first, then by rank.
    final order = [
      for (final uid in ['owner-1', 'bob', 'alice']) tester.getTopLeft(row(uid)).dy,
    ];
    expect(order, orderedEquals([...order]..sort()));

    await tester.tap(inRow('alice', find.byIcon(LucideIcons.moreHorizontal)));
    await tester.pumpAndSettle();
    expect(menuItems(tester), [
      l10n.orchardMemberCheck,
      l10n.orchardMemberChangeRole,
      l10n.memberPanelCrates,
      l10n.orchardMemberEndDateAction,
      l10n.orchardMemberSuspend,
      l10n.orchardMemberRemove,
      l10n.orchardMemberExposure,
      l10n.memberDevicesTitle,
    ]);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(inRow('carol', find.byIcon(LucideIcons.moreHorizontal)));
    await tester.pumpAndSettle();
    expect(menuItems(tester), contains(l10n.orchardMemberResume));
    expect(menuItems(tester), isNot(contains(l10n.orchardMemberSuspend)));
    expect(menuItems(tester), isNot(contains(l10n.orchardMemberMakeOwner)));
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a role change, a suspension with its keys replaced, and the Orchard handed over', (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId));

    await menu(tester, 'alice', l10n.orchardMemberChangeRole);
    expect(find.byKey(ValueKey('pick-role-$ops')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-role-admin')), findsOneWidget, reason: 'an owner may make admins');
    // ...but only members they compared codes with: Alice is not yet.
    expect(tester.widget<RadioListTile<String>>(find.byKey(const ValueKey('pick-role-admin'))).enabled, isFalse);
    expect(find.textContaining(l10n.orchardPromoteCompareNote), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('pick-role-$ops')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await settle(tester);
    expect(server.recordOf(orchardId).members['alice']!.role, ops);
    expect(toasted(tester, l10n.orchardMemberRoleChanged('alice@example.com', 'Ops')), isTrue);
    expect(inRow('alice', find.text('Ops')), findsOneWidget);

    // Suspended: the keys Alice held are replaced right away.
    server.rotations.clear();
    await menu(tester, 'alice', l10n.orchardMemberSuspend);
    expect(find.text(l10n.orchardSuspendTitle('alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.orchardSuspendConfirm));
    await settle(tester);
    expect(server.recordOf(orchardId).members['alice']!.status, MemberStatus.suspended);
    expect(server.rotations, containsAll(['orchard:$orchardId', 'crate:$staging']));
    expect(inRow('alice', find.text(l10n.orchardMemberSuspended)), findsOneWidget);

    // Bob becomes an owner and this account steps down, in one step.
    server.appends.clear();
    // Owner is in Change role now.
    await menu(tester, 'bob', l10n.orchardMemberChangeRole);
    expect(find.text(l10n.orchardRolePickOwnerHint), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-role-owner')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await settle(tester);
    // Only members this account compared codes with become owners:
    // compare first, then go on.
    expect(find.text(l10n.orchardPromoteCompareTitle('bob@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.orchardCompareCodes));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.orchardVerifyMatch));
    await settle(tester);
    expect(server.verifications.map((v) => v.subjectUid), contains('bob'));
    await tester.tap(find.byKey(const ValueKey('owner-step-down')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.orchardMakeOwnerConfirm));
    await settle(tester);
    expect(server.appends, [
      [RecordTypes.memberSet, RecordTypes.memberSet],
    ]);
    final r = server.recordOf(orchardId);
    expect((r.members['bob']!.role, r.members['owner-1']!.role), (FixedRoles.owner, FixedRoles.admin));
    expect(inRow('owner-1', find.text(l10n.orchardRoleAdmin)), findsOneWidget);
    // An admin changes nothing about an owner; comparing keys, what they
    // could use, and their approved devices stay open.
    await tester.tap(inRow('bob', find.byIcon(LucideIcons.moreHorizontal)));
    await tester.pumpAndSettle();
    expect(menuItems(tester), [l10n.orchardMemberCheck, l10n.orchardMemberExposure, l10n.memberDevicesTitle]);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('suspending someone asks for a recent sign-in first; declining changes nothing', (tester) async {
    await build(tester);
    server.requireRecentSignIn = true;
    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId));

    await menu(tester, 'alice', l10n.orchardMemberSuspend);
    await tester.tap(find.text(l10n.orchardSuspendConfirm));
    // The row stays busy (a spinner) while the prompt waits: frames, not
    // settling.
    Future<void> frames() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await frames();
    // "Confirm it's you" says exactly what will happen first.
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    final summary = find.byKey(const ValueKey('step-up-summary'));
    expect(find.descendant(of: summary, matching: find.text(l10n.stepUpSuspend('alice@example.com', 'Acme'))),
        findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text(l10n.stepUpEffectCutOff('alice@example.com'))),
        findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text(l10n.stepUpEffectKeysReplaced)), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await frames();
    await settle(tester);
    expect(server.recordOf(orchardId).members['alice']!.status, MemberStatus.active);
    expect(inRow('alice', find.text(l10n.orchardMemberSuspended)), findsNothing);
    expect(inRow('alice', find.byType(CircularProgressIndicator)), findsNothing, reason: 'not left busy');
  });

  // Vault access per member on a phone: the panel's table over
  // the list, from the member's menu.
  testWidgets('Vault access from the menu: a vault taken away, what she could see there kept to change next',
      (tester) async {
    await build(tester, withKeys: true);
    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId));
    ZestSelect<VaultPick> select(String crate) =>
        tester.widget<ZestSelect<VaultPick>>(find.byKey(ValueKey('vault-pick-$crate')));

    await menu(tester, 'alice', l10n.memberPanelCrates);
    expect(find.byKey(const ValueKey('vault-access-alice')), findsOneWidget);
    // Staging: her extra Use, set apart from her role (which gives none).
    expect(select(staging).value, VaultPick.use);
    expect(select(staging).accent, isTrue);
    expect(select(production).value, VaultPick.fromRole);

    await tester.tap(find.byKey(ValueKey('vault-pick-$production')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('zest-select-item-VaultPick.none')));
    await settle(tester);
    await tester.tap(find.text(l10n.newKindsConfirm));
    await settle(tester);
    expect(find.text(l10n.vaultNoAccessTitle('Production', 'alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.vaultNoAccessConfirm));
    await settle(tester);
    expect(server.recordOf(orchardId).members['alice']!.limits[production], isEmpty);
    expect(server.recordOf(orchardId).switchesOf('alice', production), isEmpty);
    // What she could see there is kept to change next, under the entry that
    // took it, and shown.
    expect(find.text(l10n.orchardExposureTitle('alice@example.com')), findsOneWidget);
    expect(find.byKey(const ValueKey('exposed-deploy')), findsOneWidget);
    expect(find.byKey(const ValueKey('exposure-kept')), findsOneWidget);
    final kept = (await tester.runAsync(() => service.changeNext(orchardId)))!;
    expect([for (final i in kept) (i.subjectUid, i.label, i.crateId, i.couldReveal)],
        [('alice', 'deploy', production, true)]);
    expect(server.entriesOf(orchardId).singleWhere((e) => e.seq == kept.single.entrySeq).type, RecordTypes.memberLimit);
    // And the vault's key was replaced, sealed to those who still hold it.
    expect(server.entriesOf(orchardId).last.type, RecordTypes.keyRotate);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    // The table over the list follows the record.
    expect(select(production).value, VaultPick.none);
    expect(select(production).accent, isTrue);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    expect(inRow('alice', find.text(l10n.orchardMemberLimitedCrates(1))), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the toast times out
  });

  testWidgets('removing someone lists what they could use; owners and admins open it from the menu',
      (tester) async {
    await build(tester, withKeys: true);
    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId));

    await menu(tester, 'alice', l10n.orchardMemberRemove);
    await tester.tap(find.text(l10n.orchardRemoveConfirm));
    await settle(tester);
    expect(server.recordOf(orchardId).members['alice']!.status, MemberStatus.removed);
    expect(find.text(l10n.orchardExposureTitle('alice@example.com')), findsOneWidget);
    expect(find.byKey(const ValueKey('exposure-reveal')), findsOneWidget, reason: 'she had Use on Production');
    expect(find.byKey(const ValueKey('exposed-deploy')), findsOneWidget);
    expect(find.text(l10n.orchardExposureOpens('web1 (10.0.0.1)')), findsOneWidget);
    // Kept as the keys to change next, under the entry that removed her.
    expect(find.byKey(const ValueKey('exposure-kept')), findsOneWidget);
    final kept = (await tester.runAsync(() => service.changeNext(orchardId)))!;
    expect([for (final i in kept) (i.subjectUid, i.label, i.couldReveal, i.hosts, i.done)],
        [('alice', 'deploy', true, 1, false)]);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);

    // Carol (suspended, Use on Production by her role): the same key, only
    // looked at, so nothing more is kept.
    await menu(tester, 'carol', l10n.orchardMemberExposure);
    expect(find.text(l10n.orchardExposureTitle('carol@example.com')), findsOneWidget);
    expect(find.byKey(const ValueKey('exposed-deploy')), findsOneWidget);
    expect(find.byKey(const ValueKey('exposure-kept')), findsNothing);
    expect((await tester.runAsync(() => service.changeNext(orchardId)))!, hasLength(1));
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    await tester.pump(const Duration(seconds: 5)); // the toast times out
  });

  testWidgets('an account deleted since the record added it shows so', (tester) async {
    await build(tester);
    await tester.runAsync(() async {
      server.deletedAccounts.add('bob');
      await service.refresh();
    });
    await openWith(tester, (context, ref) => showOrchardMembers(context, ref, orchardId));
    expect(inRow('bob', find.text(l10n.orchardMemberAccountDeleted)), findsOneWidget);
    expect(inRow('alice', find.text(l10n.orchardMemberAccountDeleted)), findsNothing);
  });

  testWidgets('owners make, order and delete roles', (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRoles(context, ref, orchardId));

    expect(find.byKey(const ValueKey('role-owner')), findsOneWidget);
    expect(find.byKey(const ValueKey('role-admin')), findsOneWidget);
    // Each vault on the role's card, with its level there.
    expect(find.descendant(of: find.byKey(ValueKey('role-cell-$member-$production')), matching: find.text(l10n.crateLevelUse)),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('role-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('role-name')), matching: find.byType(TextField)), 'Contractors');
    await tester.tap(find.byKey(const ValueKey('role-can-invite')));
    await tester.tap(find.byKey(ValueKey('role-level-$production')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.crateLevelConnect).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await settle(tester);
    final made = server.recordOf(orchardId).roles.values.firstWhere((r) => !{member, ops}.contains(r.id));
    expect(made.can, {RoleCan.invite});
    expect(made.crates, {production: levelSwitches(CrateLevel.connect)});
    expect(made.rank, lessThan(server.recordOf(orchardId).roles[ops]!.rank), reason: 'below every other role');

    // Up one place: above Ops.
    await tester.tap(find.descendant(of: find.byKey(ValueKey('role-${made.id}')), matching: find.byKey(const ValueKey('up'))));
    await settle(tester);
    final r = server.recordOf(orchardId);
    expect(r.roles[made.id]!.rank, greaterThan(r.roles[ops]!.rank));
    expect(r.roles[made.id]!.rank, lessThan(r.roles[member]!.rank));

    // Ops deleted: its members would move to the role picked.
    await tester.tap(find.descendant(of: find.byKey(ValueKey('role-$ops')), matching: find.byKey(const ValueKey('delete'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.orchardRoleDeleteConfirm));
    await settle(tester);
    expect(server.recordOf(orchardId).roles.containsKey(ops), isFalse);
    expect(find.byKey(ValueKey('role-$ops')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('whoever manages a Crate sets what it allows and renames it; an owner opens up an owners-only one',
      (tester) async {
    await build(tester);
    late String vault;
    await tester.runAsync(() async {
      vault = await service.createCrate(orchardId, 'Vault', ownersOnly: true);
    });
    await openWith(tester, (context, ref) => showOrchardCrates(context, ref, orchardId));

    // The window lists every vault and shows one at a time (4.0).
    Finder inItem(String id, Finder f) => find.descendant(of: find.byKey(ValueKey('vault-item-$id')), matching: f);
    expect(inItem(vault, find.textContaining(l10n.crateOwnersOnly)), findsOneWidget);
    await openVaultTab(tester, production, VaultTab.access);
    await tester.tap(find.byKey(ValueKey('crate-allow-$production-agent')));
    await settle(tester);
    expect(server.recordOf(orchardId).crates[production]!.allow,
        {CrateSwitches.agent, CrateSwitches.forward, CrateSwitches.sftp});

    // Rename is in the vault's menu.
    await openVaultTab(tester, staging, VaultTab.access);
    await tester.tap(find.byKey(ValueKey('crate-more-$staging')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('crate-rename-$staging')));
    await tester.pumpAndSettle();
    // The window it opens takes the screen: the Vaults window steps aside
    // (kept, not drawn) while it is up, and is back when it closes.
    expect(find.byType(OrchardCratesView), findsNothing);
    expect(find.byType(OrchardCratesView, skipOffstage: false), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Stage');
    await tester.tap(find.text(l10n.crateRenameConfirm).last);
    await settle(tester);
    expect(find.byType(OrchardCratesView), findsOneWidget);
    expect(server.renames, ['crate:$staging']);
    expect(inItem(staging, find.text('Stage')), findsOneWidget);

    await openVaultTab(tester, vault, VaultTab.access);
    await tester.ensureVisible(find.byKey(ValueKey('crate-open-$vault')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('crate-open-$vault')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.crateOpenToAllConfirm));
    await settle(tester);
    expect(server.recordOf(orchardId).crates[vault]!.ownersOnly, isFalse);
    expect(find.byKey(ValueKey('crate-open-$vault')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the banner: suspended, then keys waiting that this account replaces', (tester) async {
    await build(tester);
    const suspended = OrchardSummary(
        id: 'o', name: 'Acme', role: FixedRoles.admin, crates: [], defaultCrateId: null, status: 'suspended');
    Future<void> show(OrchardSummary summary) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          orchardServiceProvider.overrideWithValue(service),
          activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: Column(children: [OrchardStatusBanner(), Text('open')])),
        ),
      ));
      await tester.pump();
    }

    await show(suspended);
    expect(find.text(l10n.orchardBannerSuspended(l10n.orchardNamed('Acme'))), findsOneWidget);

    // Carol's suspension left the keys she held waiting.
    late OrchardSummary waiting;
    await tester.runAsync(() async {
      waiting = await readOrchardSummary(await service.databases.open(orchardId), orchardId);
    });
    expect(waiting.keysWaiting, isTrue);
    await show(waiting);
    server.rotations.clear();
    await tester.tap(find.text(l10n.orchardBannerRotate));
    await settle(tester);
    expect(server.rotations, contains('orchard:$orchardId'));
    expect(toasted(tester, l10n.orchardBannerRotated), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  // Held back by the company's directory, and a standing this app does
  // not know: words of their own, in the banner and in the list.
  testWidgets('the banner and the list: held back by the directory, and a standing this app does not know',
      (tester) async {
    await build(tester);
    Future<void> show(OrchardSummary summary) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          orchardServiceProvider.overrideWithValue(service),
          activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Column(children: [
              const OrchardStatusBanner(),
              Consumer(builder: (context, ref, _) => Text(orchardSubtitle(summary, ref, l10n))),
            ]),
          ),
        ),
      ));
      await tester.pump();
    }

    const held = OrchardSummary(
        id: 'o', name: 'Acme', role: FixedRoles.admin, crates: [], defaultCrateId: null, status: 'directory-removed');
    await show(held);
    expect(find.text(l10n.orchardBannerDirectoryHeld(l10n.orchardNamed('Acme'))), findsOneWidget);
    expect(find.text(l10n.orchardTeamRole(l10n.directoryHeld)), findsOneWidget);

    // An entry a newer version wrote: said as that, with the
    // update; any other record problem keeps its own words.
    const newer = OrchardSummary(
        id: 'o', name: 'Acme', role: FixedRoles.admin, crates: [], defaultCrateId: null,
        recordProblem: 'entry 7: unknown type');
    await show(newer);
    expect(find.text(l10n.orchardBannerNewer(l10n.orchardNamed('Acme'))), findsOneWidget);
    expect(find.text(l10n.orchardBannerUpdate), findsOneWidget);
    const parted = OrchardSummary(
        id: 'o', name: 'Acme', role: FixedRoles.admin, crates: [], defaultCrateId: null,
        recordProblem: 'entry 7 came out of order');
    await show(parted);
    expect(find.text(l10n.orchardBannerRecordProblem(l10n.orchardNamed('Acme'))), findsOneWidget);

    const later = OrchardSummary(
        id: 'o', name: 'Acme', role: FixedRoles.admin, crates: [], defaultCrateId: null, status: 'something-new');
    await show(later);
    expect(find.text(l10n.orchardBannerUnavailable(l10n.orchardNamed('Acme'))), findsOneWidget);
    expect(find.text(l10n.orchardTeamRole(l10n.orchardNotSyncing)), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  // Found in a cryptography review: someone removed by a person who
  // may not replace that vault's key, and others go on writing secrets under
  // the generation the former member holds. Only those who may replace it were
  // told.
  testWidgets('a vault whose key waits: whoever writes there and may not replace it is told, and only told',
      (tester) async {
    await build(tester);
    Future<void> show(Set<String> switches, {bool due = true}) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          orchardServiceProvider.overrideWithValue(service),
          activeOrchardProvider.overrideWithValue(AsyncData(OrchardSummary(
            id: 'o',
            name: 'Acme',
            role: 'role-x',
            crates: [CrateSummary(id: 'c', name: 'Production', level: 'edit', switches: switches, rotationDue: due)],
            defaultCrateId: 'c',
          ))),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: Column(children: [OrchardStatusBanner()])),
        ),
      ));
      await tester.pump();
    }

    final words = l10n.orchardBannerRotationWaits('Production');
    await show({CrateSwitches.connect, CrateSwitches.add});
    expect(find.text(words), findsOneWidget);
    expect(find.text(l10n.orchardBannerRotate), findsNothing, reason: 'not theirs to do');

    await show({CrateSwitches.connect, CrateSwitches.edit});
    expect(find.text(words), findsOneWidget);

    await show({CrateSwitches.connect, CrateSwitches.add}, due: false);
    expect(find.text(words), findsNothing, reason: 'replaced: nothing to say');

    await show({CrateSwitches.connect, CrateSwitches.sftp});
    expect(find.text(words), findsNothing, reason: 'writes nothing there');

    await show({CrateSwitches.connect, CrateSwitches.add, CrateSwitches.manage});
    expect(find.text(words), findsNothing);
    expect(find.text(l10n.orchardBannerRotate), findsOneWidget, reason: 'theirs to do: the banner they had');
    await tester.pump(const Duration(seconds: 5));
  });
}

bool toasted(WidgetTester tester, String message) {
  if (find.text(message).evaluate().isNotEmpty) return true;
  final container = ProviderScope.containerOf(tester.element(find.text('open')));
  return container
      .read(notificationCenterProvider)
      .history
      .any((n) => n.title == message || n.body == message);
}

/// Lets the database and crypto work finish, then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
