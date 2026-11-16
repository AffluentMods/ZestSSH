import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show readOrchardSummary;
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'fake_crate_server.dart';

/// Deleting a team, from the devices: an owner asks with a
/// signed team.delete; every member's device then keeps what it holds,
/// reads the record (so that it holds the signed deletion) and syncs
/// nothing; anyone may leave, nothing else goes in; an owner undoes it
/// before the day, never after. Once the team is gone, a device removes it
/// unasked only when its own record ends in the signed deletion and it saw
/// that entry at least seven days before by its own clock; otherwise it asks
/// its person. The same against the real routes: team_deletion_contract_test.dart.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';

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
  _Device(FakeCrateServer shared, this.uid, this.keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      onTeamDeleted: gone.add,
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final AccountKeys keys;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  /// The notices of deleted teams that left this device.
  final gone = <TeamGone>[];

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get()) r.data.values.join(':'),
      ];

  Future<String> status(String orchardId) async => (await rows(orchardId, 'SELECT status FROM orchard_info')).single;

  Future<bool> holds(String orchardId) async => (await service.databases.onDevice()).contains(orchardId);

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  /// How far the clocks (the server's, and every device's) have been moved.
  var moved = Duration.zero;
  DateTime clock() => DateTime.now().add(moved);

  setUpAll(() async {
    for (final uid in [_owner, _alice, _bob]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    moved = Duration.zero;
    OrchardService.debugNow = clock;
    server = FakeCrateServer(accountUid: _owner)
      ..clock = clock
      ..newRecordKinds = true;
    for (final uid in [_owner, _alice, _bob]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    OrchardService.debugNow = DateTime.now;
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid) {
    final d = _Device(server, uid, keys[uid]!);
    devices.add(d);
    return d;
  }

  /// The owner's team, Acme, with Production (the first role, Member, has
  /// use of it), and each of [people] in it as a Member.
  Future<String> team(_Device owner, List<_Device> people) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single.id;
    for (final p in people) {
      await owner.service.invite(id, email: '${p.uid}@example.com', role: member);
      final invite = (await owner.service.invites(id)).single;
      server.acceptAs(id, invite.id, p.uid);
      await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
      expect(await p.service.refresh(), contains(id));
      await p.coordinator.syncAll();
    }
    return id;
  }

  test("an owner deletes the team: each member's device keeps what it holds, holds the signed deletion, "
      'syncs nothing, and says who asked and the day', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, [alice]);
    final vaults = await alice.rows(o, 'SELECT name FROM orchard_crates');

    final asked = await owner.service.deleteTeam(o);
    expect(asked.by, _owner);
    expect(asked.purgeAt.difference(asked.askedAt), const Duration(days: kTeamDeleteDays));
    expect(server.entriesOf(o).last.type, RecordTypes.teamDelete);
    expect(server.recordOf(o).deleting?.by, _owner);
    expect(await owner.status(o), kDeletingStatus);

    final reads = server.changesCalls;
    expect(await alice.coordinator.syncAll(), isEmpty, reason: 'nothing of it syncs');
    expect(server.changesCalls, reads);
    expect(await alice.status(o), kDeletingStatus);
    final local = await LocalRecord.load(await alice.db(o), o);
    expect(local.latest.deleting?.by, _owner, reason: "the device holds the owner's signed deletion");
    expect(await alice.rows(o, 'SELECT name FROM orchard_crates'), vaults, reason: 'what is here stays');
    final summary = await readOrchardSummary(await alice.db(o), o);
    expect(summary.status, kDeletingStatus);
    expect(summary.deleting?.by, _owner);
    expect(summary.deleting?.purgeAt, asked.purgeAt);
  });

  test('only an owner deletes the team, and only once new kinds of entry are on', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, [alice]);
    await expectLater(alice.service.deleteTeam(o), throwsA(isA<OrchardRecordRefused>()));
    expect(server.deletes, 0, reason: 'refused here, before anything was sent');

    server.newRecordKinds = false;
    await expectLater(
        owner.service.deleteTeam(o),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'feature-not-yet')));
    expect(server.recordOf(o).deleting, isNull);
    expect(await owner.status(o), 'active');
  });

  test('while it is being deleted anyone may leave; any other change is refused', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, [alice]);
    await owner.service.deleteTeam(o);
    await alice.service.refresh();

    await expectLater(owner.service.setMemberEndsAt(o, _alice, null), throwsA(isA<OrchardRecordRefused>()));
    await alice.service.leaveOrchard(o);
    expect(server.recordOf(o).members[_alice]?.status, MemberStatus.removed);
    expect(server.recordOf(o).deleting, isNotNull, reason: 'leaving undoes nothing');
    expect(await alice.holds(o), isFalse);
  });

  test('a sync that meets the hold before the list said so holds the team back', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, [alice]);
    await owner.service.deleteTeam(o);
    final report = await alice.coordinator.syncOne(o);
    expect(report.held, isTrue);
    expect(await alice.status(o), kDeletingStatus);
  });

  test('an owner undoes it before the day: everyone is let back in, and it syncs again', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, [alice]);
    await owner.service.deleteTeam(o);
    await alice.service.refresh();
    expect(await alice.status(o), kDeletingStatus);

    moved = const Duration(days: 6);
    await owner.service.restoreTeam(o);
    expect(server.entriesOf(o).last.type, RecordTypes.teamRestore);
    expect(server.recordOf(o).deleting, isNull);
    expect(await owner.status(o), 'active');
    expect(await alice.service.refresh(), contains(o));
    expect(await alice.rows(o, "SELECT status, COALESCE(held, '') FROM orchard_info"), ['active:']);
  });

  test('undo ends when the day comes', () async {
    final owner = device(_owner);
    final o = await team(owner, const []);
    await owner.service.deleteTeam(o);
    moved = const Duration(days: kTeamDeleteDays, minutes: 1);
    await expectLater(
        owner.service.restoreTeam(o),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'undo-too-late')));
    expect(server.recordOf(o).deleting, isNotNull);
  });

  test('once the team is gone, a device that saw the signed deletion seven days before removes it unasked, '
      'and says who deleted it', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, [alice]);
    await owner.service.deleteTeam(o);
    await alice.service.refresh();

    moved = const Duration(days: kTeamDeleteDays, hours: 1);
    server.purgeTeam(o);
    await alice.service.refresh();
    expect(await alice.holds(o), isFalse);
    expect(alice.gone.single.name, 'Acme');
    expect(alice.gone.single.byName, '$_owner@example.com');
    expect(alice.gone.single.byMe, isFalse);

    await owner.service.refresh();
    expect(await owner.holds(o), isFalse);
    expect(owner.gone.single.byMe, isTrue);
  });

  test('a device that saw the deletion less than seven days before, or never, asks before it removes the team',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await team(owner, [alice, bob]);
    await owner.service.deleteTeam(o);
    await alice.service.refresh();

    // Gone at once (a server that says so): alice saw it only now.
    server.purgeTeam(o);
    await alice.service.refresh();
    expect(await alice.holds(o), isTrue);
    expect(await alice.status(o), kDeletedStatus);
    final summary = await readOrchardSummary(await alice.db(o), o);
    expect(summary.deletedAt, isNotNull);
    expect(summary.deleting?.by, _owner, reason: 'who asked is still named');
    expect(alice.gone, isEmpty);

    // Bob's device was away the whole time: it never saw the signed deletion.
    moved = const Duration(days: 8);
    await bob.service.refresh();
    expect(await bob.status(o), kDeletedStatus);
    expect(deletionSeenLongEnough(await LocalRecord.load(await bob.db(o), o),
        nowSeconds: clock().millisecondsSinceEpoch ~/ 1000), isFalse);

    // Its person answers.
    await bob.service.removeDeletedTeam(o);
    expect(await bob.holds(o), isFalse);
    expect(bob.gone.single.byName, isNull, reason: 'nobody it holds says who asked');
    expect(bob.gone.single.byMe, isFalse);
  });

  test('a server that does not hold the entry is behind, as before: the team stays and waits', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await team(owner, [alice]);
    server.hidden.add(o);
    await server.rollBackRecord(o, server.entriesOf(o).length - 1);
    await alice.service.refresh();
    expect(await alice.holds(o), isTrue);
    expect(await alice.status(o), kServerBehindStatus);
    expect(alice.gone, isEmpty);
  });
}
