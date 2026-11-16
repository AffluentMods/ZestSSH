import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/orchards/widgets/team_delete_dialog.dart' show teamDeletionDay;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import '../fake_crate_server.dart';

/// Deleting a team in words: every member is told when an owner
/// asks, with what goes and which owners can undo it; told again each day,
/// counting down, the one who asked too; told when it is kept; and the Trust
/// page and the event export say each change.

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final storages = <_MemoryStorage>[];

  setUpAll(() async {
    for (final uid in [_owner, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner)..newRecordKinds = true;
    for (final uid in [_owner, _alice]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  OrchardService device(String uid) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
    );
  }

  Future<String> team(OrchardService owner, OrchardService alice) async {
    final id = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single.id;
    await owner.invite(id, email: '$_alice@example.com', role: member);
    server.acceptAs(id, (await owner.invites(id)).single.id, _alice);
    await owner.confirmInvite(id, (await owner.invites(id)).single);
    await alice.refresh();
    return id;
  }

  Future<List<String>> titles(OrchardService s, String id, String me) async => [
        for (final n in await takeTeamNotifications({id: await s.databases.open(id)},
            me: me, l10n: l10n, orchardName: (name) => name ?? ''))
          n.title,
      ];

  test('every member is told when an owner asks: what goes, who asked and which owners can undo it', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, alice);
    await titles(alice, o, _alice); // what came before is on the Trust page
    final asked = await owner.deleteTeam(o);
    await alice.refresh();
    final notices = await takeTeamNotifications({o: await alice.databases.open(o)},
        me: _alice, l10n: l10n, orchardName: (name) => name ?? '');
    final told = notices.singleWhere((n) => n.title == l10n.noticeTeamDeletingTitle('Acme', teamDeletionDay(asked.purgeAt, l10n)));
    expect(told.body, l10n.noticeTeamDeletingBody('Production', l10n.teamDeleteHosts(0), '$_owner@example.com', '$_owner@example.com'));
    // Once a day: nothing more today.
    expect(await titles(alice, o, _alice), isEmpty);
  });

  test('an admin can undo it too: told so, and named to the members as one who can', () async {
    const bob = 'bob-uid';
    keys[bob] = await AccountKeys.generate();
    await server.publish(bob, keys[bob]!, email: '$bob@example.com');
    final owner = device(_owner);
    final alice = device(_alice);
    final bobby = device(bob);
    final o = await team(owner, alice);
    await owner.setMemberRole(o, _alice, FixedRoles.admin);
    final member = server.recordOf(o).roles.values.single.id;
    await owner.invite(o, email: '$bob@example.com', role: member);
    server.acceptAs(o, (await owner.invites(o)).single.id, bob);
    await owner.confirmInvite(o, (await owner.invites(o)).single);
    await alice.refresh();
    await bobby.refresh();
    await titles(alice, o, _alice);
    await titles(bobby, o, bob);
    await owner.deleteTeam(o);
    await alice.refresh();
    await bobby.refresh();
    Future<List<String?>> bodies(OrchardService s, String me) async => [
          for (final n in await takeTeamNotifications({o: await s.databases.open(o)},
              me: me, l10n: l10n, orchardName: (name) => name ?? ''))
            n.body,
        ];
    expect(await bodies(alice, _alice),
        contains(l10n.noticeTeamDeletingOwnerBody('Production', l10n.teamDeleteHosts(0), '$_owner@example.com')),
        reason: 'the admin is told they can undo it');
    expect(
        await bodies(bobby, bob),
        contains(l10n.noticeTeamDeletingBody('Production', l10n.teamDeleteHosts(0), '$_owner@example.com',
            ['$_owner@example.com', '$_alice@example.com'].join(l10n.listSeparator))),
        reason: 'a member hears the owners and the admins who can undo it');
  });

  test('each day after, everyone is told again, counting down, the one who asked too', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, alice);
    final db = await owner.databases.open(o);
    await takeTeamNotices(db, o); // what came before is on the Trust page
    await owner.deleteTeam(o);
    // The request itself, today (the one who asked is not shown it: see
    // takeTeamNotifications), and no countdown on top that day.
    final today = await takeTeamNotices(db, o);
    expect(today.map((n) => n.kind), [TeamNoticeKind.teamDeleting]);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final next = await takeTeamNotices(db, o, now: tomorrow);
    expect(next.single.kind, TeamNoticeKind.teamDeletingSoon);
    expect(next.single.forEveryone, isTrue);
    expect(await takeTeamNotices(db, o, now: tomorrow), isEmpty, reason: 'once a day');

    String title(DateTime purgeAt, DateTime now) => teamNoticeNotification(next.single,
            orchardId: o,
            orchard: 'Acme',
            nameOf: (uid) => uid ?? '',
            me: _owner,
            l10n: l10n,
            now: now,
            deletion: TeamDeletionWords(purgeAt: purgeAt, vaults: 'Production', hosts: 3, owners: '', meMayUndo: true))
        .title;
    final now = DateTime(2026, 11, 1, 10);
    expect(title(DateTime(2026, 11, 5, 9), now), l10n.noticeTeamDeletingInDaysTitle('Acme', 4));
    expect(title(DateTime(2026, 11, 2, 23), now), l10n.noticeTeamDeletingTomorrowTitle('Acme'));
    expect(title(DateTime(2026, 11, 1, 23), now), l10n.noticeTeamDeletingTodayTitle('Acme'));
    final body = teamNoticeNotification(next.single,
            orchardId: o,
            orchard: 'Acme',
            nameOf: (uid) => uid ?? '',
            me: _owner,
            l10n: l10n,
            now: now,
            deletion: TeamDeletionWords(purgeAt: DateTime(2026, 11, 5), vaults: 'Production', hosts: 3, owners: '', meMayUndo: true))
        .body;
    expect(body, l10n.noticeTeamDeletingYouBody('Production', l10n.teamDeleteHosts(3)));
  });

  test('every member is told when it is kept, and the Trust page says each change', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, alice);
    await titles(alice, o, _alice);
    await owner.deleteTeam(o);
    await owner.restoreTeam(o);
    await alice.refresh();
    expect(await titles(alice, o, _alice), contains(l10n.noticeTeamKeptTitle('Acme')));

    final local = await LocalRecord.load(await alice.databases.open(o), o);
    final changes = await teamChanges(o, local.entries);
    String said(TeamChange c) => teamChangeText(c, l10n, nameOf: (uid) => uid ?? '', crateName: (_) => '', roleName: (_) => '');
    expect(changes.where((c) => c.kind == TeamChangeKind.teamDeleted).map(said), [l10n.teamChangeTeamDeleted]);
    expect(changes.where((c) => c.kind == TeamChangeKind.teamRestored).map(said), [l10n.teamChangeTeamRestored]);
    expect(l10n.teamChangeTeamDeleted, 'Asked to delete the team');
    expect(changes.last.kind, TeamChangeKind.teamRestored);
    expect(local.latest.deleting, isNull);
    expect(RecordTypes.newKinds, containsAll([RecordTypes.teamDelete, RecordTypes.teamRestore]));
  });
}
