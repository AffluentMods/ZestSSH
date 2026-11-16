import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart' show kUnlistedStatus;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'fake_crate_server.dart';

/// Running an Orchard from a device (3.0): a member's role, extra
/// Crates and end date; ownership moved in one step; suspension, the keys
/// replaced after it, resuming and removal; leaving; the owners' roles made,
/// ordered and dropped; a Crate's settings and names. Every change is an
/// entry the (fake) server checks with the record's rules, and the keys
/// follow access both ways.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};
  final deleted = <String>[];

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async {
    deleted.add(orchardId);
    dbs.remove(orchardId);
  }

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Device {
  _Device(FakeCrateServer shared, this.uid, AccountKeys keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
  }

  final String uid;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await service.databases.open(orchardId)).customSelect(sql).get())
          r.data.values.join(':'),
      ];

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

  setUpAll(() async {
    for (final uid in [_owner, _alice, _bob]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _alice, _bob]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
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

  /// An Orchard of the owner's: Production (the first role, Member, has use
  /// of it) and Staging. Returns its id, the two Crates and the role.
  Future<({String id, String production, String staging, String member})> orchard(_Device owner) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(id, 'Staging');
    final r = server.recordOf(id);
    final member = r.roles.values.single;
    return (id: id, production: member.crates.keys.single, staging: staging, member: member.id);
  }

  /// [person] joins [orchardId] as [role], added by [by] after comparing.
  Future<void> join(_Device by, _Device person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    final invite = (await by.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, person.uid);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    expect(await person.service.refresh(), contains(orchardId));
  }

  test('a new role opens its Crates to whoever is given it, with their keys; what they lose waits for new keys',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    expect(await alice.rows(o.id, 'SELECT name, level FROM orchard_crates'), ['Production:use']);

    final ops = await owner.service.saveRole(o.id,
        name: ' Ops ', can: {RoleCan.invite}, crates: {o.staging: levelSwitches(CrateLevel.edit)});
    expect(server.recordOf(o.id).roles[ops]!.rank, lessThan(kDefaultMemberRank), reason: 'below every other role');
    expect((await owner.service.roles(o.id)).map((r) => r.name), ['Member', 'Ops']);

    await owner.service.setMemberRole(o.id, _alice, ops);
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT name, level FROM orchard_crates'), ['Staging:edit']);
    expect(await alice.rows(o.id, 'SELECT role, can FROM orchard_info'), ['$ops:["invite"]']);
    expect(await alice.rows(o.id, "SELECT generation FROM space_keys WHERE scope_id = '${o.staging}'"), ['1']);

    // Production was taken from her: its key waits for a new generation,
    // which reaches only those who may still open it.
    await owner.service.refresh();
    expect(await owner.rows(o.id, 'SELECT name, rotation_due FROM orchard_crates ORDER BY name'),
        ['Production:1', 'Staging:0']);
    expect(await owner.service.rotateDue(o.id), isEmpty);
    expect(server.rotations, ['crate:${o.production}'], reason: 'only what was due');
    expect(await owner.rows(o.id, 'SELECT name, key_generation, rotation_due FROM orchard_crates ORDER BY name'),
        ['Production:2:0', 'Staging:1:0']);
  });

  test('extra Crates and an end date, set and cleared', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);

    await owner.service.setMemberGrants(o.id, _alice, {o.staging: levelSwitches(CrateLevel.use)});
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT name, level FROM orchard_crates ORDER BY name'),
        ['Production:use', 'Staging:use']);

    final ends = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400 * 7;
    await owner.service.setMemberEndsAt(o.id, _alice, ends);
    expect(server.recordOf(o.id).members[_alice]!.endsAt, ends);
    final people = await owner.service.people(o.id);
    final her = people.members.firstWhere((p) => p.uid == _alice);
    expect(her.endsAt, ends);
    expect(her.grants.keys, [o.staging]);
    expect(her.email, 'alice@example.com');
    expect(her.actions.endDate && her.actions.grants && her.actions.makeOwner, isTrue);

    await owner.service.setMemberEndsAt(o.id, _alice, null);
    await owner.service.setMemberGrants(o.id, _alice, const {});
    expect(server.recordOf(o.id).members[_alice]!.endsAt, isNull);
    expect(server.recordOf(o.id).members[_alice]!.grants, isEmpty);
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT name FROM orchard_crates'), ['Production']);
  });

  test('ownership moves in one step, and an Orchard always keeps an owner', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);

    // Alone, the owner can neither step down nor leave.
    expect((await owner.service.people(o.id)).soleOwner, isTrue);
    await expectLater(owner.service.stepDown(o.id), throwsA(isA<OrchardRecordRefused>()));
    await expectLater(owner.service.leaveOrchard(o.id), throwsA(isA<OrchardRecordRefused>()));

    server.appends.clear();
    await owner.service.makeOwner(o.id, _alice, stepDown: true);
    expect(server.appends, [
      [RecordTypes.memberSet, RecordTypes.memberSet],
    ], reason: 'both entries in one request, all or nothing');
    final r = server.recordOf(o.id);
    expect((r.members[_alice]!.role, r.members[_owner]!.role), (FixedRoles.owner, FixedRoles.admin));

    // The new owner opens every Crate: Staging came with the change.
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT name, level FROM orchard_crates ORDER BY name'),
        ['Production:manage', 'Staging:manage']);
    await owner.service.refresh();
    expect(await owner.rows(o.id, 'SELECT role FROM orchard_info'), [FixedRoles.admin]);
    final now = await owner.service.people(o.id);
    expect(now.members.firstWhere((p) => p.uid == _alice).actions.any, isFalse,
        reason: 'an admin changes nothing about an owner');
  });

  test('only members this account compared become owners or admins; the record holds the comparison',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await orchard(owner);
    expect(server.recordOf(o.id).format, kRecordFormat, reason: 'a new Orchard is format 2');
    await join(owner, alice, o.id, o.member);
    // Alice was compared as she joined: she becomes an admin, the entry
    // carrying the comparison (the server checks it with the record's rules).
    await owner.service.setMemberRole(o.id, _alice, FixedRoles.admin);
    expect(server.recordOf(o.id).members[_alice]!.role, FixedRoles.admin);

    // Alice adds Bob; the owner never compared him.
    await alice.service.refresh();
    await join(alice, bob, o.id, o.member);
    await owner.service.refresh();
    await expectLater(owner.service.makeOwner(o.id, _bob), throwsA(isA<MemberNotCompared>()));
    await expectLater(owner.service.setMemberRole(o.id, _bob, FixedRoles.admin), throwsA(isA<MemberNotCompared>()));
    expect(server.recordOf(o.id).members[_bob]!.role, o.member, reason: 'nothing was sent');
    // Any lower role needs no comparison.
    await owner.service.setMemberEndsAt(o.id, _bob, null);

    // Compared now: he becomes an owner.
    await owner.service.verifyMember(o.id, _bob);
    await owner.service.makeOwner(o.id, _bob);
    expect(server.recordOf(o.id).members[_bob]!.role, FixedRoles.owner);
  });

  // A server that says no key waits does not keep in use a key someone who
  // left still holds: the record says it waits (found in a client
  // security review).
  test('the keys a suspended member held wait to be replaced though the server hides it', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);

    await owner.service.suspendMember(o.id, _alice);
    server.hideRotationDue(o.id);
    await owner.service.refresh();
    expect(await owner.rows(o.id, 'SELECT rotation_due FROM orchard_info'), ['1']);
    expect(await owner.rows(o.id, 'SELECT name, rotation_due FROM orchard_crates ORDER BY name'),
        ['Production:1', 'Staging:0']);
    expect(await owner.service.keysWaiting(o.id), isTrue);
    expect(await owner.service.rotateDue(o.id), isEmpty);
    expect(server.rotations, unorderedEquals(['orchard:${o.id}', 'crate:${o.production}']));
    await owner.service.refresh();
    expect(await owner.service.keysWaiting(o.id), isFalse, reason: 'replaced, as the record now says');
  });

  test("a member's end date passing after the keys were replaced: they wait, though the server hides it", () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    final ends = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    await owner.service.setMemberEndsAt(o.id, _alice, ends);
    // Replaced while she is still in: the new keys reach her.
    expect(await owner.service.rotateAll(), isEmpty);
    await owner.service.refresh();
    expect(await owner.service.keysWaiting(o.id), isFalse);

    // Her end date passes; this server says nothing of it.
    OrchardService.debugNow = () => DateTime.now().add(const Duration(hours: 2));
    addTearDown(() => OrchardService.debugNow = DateTime.now);
    server.hideRotationDue(o.id);
    await owner.service.refresh();
    expect(await owner.service.keysWaiting(o.id), isTrue);
    expect(await owner.rows(o.id, 'SELECT rotation_due FROM orchard_info'), ['1']);
    expect(await owner.rows(o.id, 'SELECT name, rotation_due FROM orchard_crates ORDER BY name'),
        ['Production:1', 'Staging:0']);
  });

  test('suspended, the keys they held replaced, resumed with every generation, then removed', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);

    await owner.service.suspendMember(o.id, _alice);
    expect(await alice.service.refresh(), isEmpty);
    expect(await alice.rows(o.id, 'SELECT status FROM orchard_info'), ['suspended']);
    expect(await owner.rows(o.id, 'SELECT rotation_due FROM orchard_info'), ['1']);
    expect(await owner.service.rotateDue(o.id), isEmpty);
    expect(server.rotations, unorderedEquals(['orchard:${o.id}', 'crate:${o.production}']));

    await owner.service.resumeMember(o.id, _alice);
    expect(await alice.service.refresh(), [o.id]);
    expect(await alice.rows(o.id, 'SELECT scope, generation FROM space_keys ORDER BY scope, generation'),
        ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);

    await owner.service.removeMember(o.id, _alice);
    expect(await alice.service.refresh(), isEmpty);
    // ZestSSH Cloud lets her device read no record now: nothing checked says
    // she is out, so it stays, held, until she removes it.
    expect(alice.storage.deleted, isEmpty);
    expect(await alice.rows(o.id, 'SELECT status FROM orchard_info'), [kUnlistedStatus]);
    await alice.service.removeUnlistedTeam(o.id);
    expect(alice.storage.deleted, [o.id], reason: 'the Orchard left her device');
    expect(server.recordOf(o.id).members[_alice]!.status, MemberStatus.removed);
  });

  test('a member leaves: the Orchard leaves their device, and its keys wait for new ones', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    final people = await alice.service.people(o.id);
    expect((people.leave, people.stepDown), (true, false));

    await alice.service.leaveOrchard(o.id);
    expect(alice.storage.deleted, [o.id]);
    expect(await alice.service.refresh(), isEmpty);
    expect(server.recordOf(o.id).members[_alice]!.status, MemberStatus.removed);
    await owner.service.refresh();
    expect(await owner.rows(o.id, 'SELECT rotation_due FROM orchard_info'), ['1']);
  });

  test('roles: made below the others, renamed, moved, renumbered when there is no room, and dropped', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    Future<List<String>> order() async => [for (final r in await owner.service.roles(o.id)) '${r.name}'];

    final lead = await owner.service.saveRole(o.id, name: 'Lead', can: const {}, crates: const {});
    final guest = await owner.service.saveRole(o.id,
        name: 'Guest', can: const {}, crates: {o.production: levelSwitches(CrateLevel.connect)});
    expect(await order(), ['Member', 'Lead', 'Guest']);

    // Renamed: a new name under the Orchard's key; unchanged, the same bytes.
    final before = server.recordOf(o.id).roles[lead]!.nameEnc;
    await owner.service.saveRole(o.id, id: lead, name: 'Lead', can: {RoleCan.invite}, crates: const {});
    expect(server.recordOf(o.id).roles[lead]!.nameEnc, before);
    await owner.service.saveRole(o.id, id: lead, name: 'Leads', can: {RoleCan.invite}, crates: const {});
    expect(server.recordOf(o.id).roles[lead]!.nameEnc, isNot(before));

    await owner.service.moveRole(o.id, lead, up: true);
    expect(await order(), ['Leads', 'Member', 'Guest']);
    await owner.service.moveRole(o.id, lead, up: true);
    expect(await order(), ['Leads', 'Member', 'Guest'], reason: 'the top stays the top');

    // No room below: the owners' roles at the lowest ranks there are.
    final r = server.recordOf(o.id);
    await owner.service.changeAll(o.id, [
      for (final (id, rank) in [(lead, 3), (o.member, 2), (guest, 1)])
        (type: RecordTypes.roleSet, body: {..._body(r.roles[id]!), 'rank': rank}),
    ]);
    final newest = await owner.service.saveRole(o.id, name: 'Contractor', can: const {}, crates: const {});
    expect(await order(), ['Leads', 'Member', 'Guest', 'Contractor']);
    final ranks = [for (final id in [lead, o.member, guest, newest]) server.recordOf(o.id).roles[id]!.rank];
    expect(ranks, [4000, 3000, 2000, 1000], reason: 'renumbered with room again');
    await owner.service.moveRole(o.id, newest, up: true);
    expect(await order(), ['Leads', 'Member', 'Contractor', 'Guest']);

    // Dropped: its members move to the role named.
    await owner.service.dropRole(o.id, o.member, guest);
    expect(server.recordOf(o.id).members[_alice]!.role, guest);
    expect(await order(), ['Leads', 'Contractor', 'Guest']);
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT name, level FROM orchard_crates'), ['Production:connect']);
  });

  test("a Crate's settings and names, and the Orchard's", () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);

    await owner.service.setCrateAllow(o.id, o.production, {CrateSwitches.forward, CrateSwitches.agent});
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT switches, allow FROM orchard_crates'),
        ['["connect","forward","reveal"]:["agent","forward"]'],
        reason: 'SFTP is off for everyone in it; agent forwarding is allowed but not in her role');

    await owner.service.renameCrate(o.id, o.production, ' Prod ');
    await owner.service.renameOrchard(o.id, 'Acme Corp');
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT name FROM orchard_crates'), ['Prod']);
    expect(await alice.rows(o.id, 'SELECT name FROM orchard_info'), ['Acme Corp']);
    await expectLater(alice.service.renameCrate(o.id, o.production, 'Mine'),
        throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 403)));
    await expectLater(alice.service.renameOrchard(o.id, 'Mine'),
        throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 403)));

    // An owners-only Crate: only owners have it, until an owner opens it up.
    final vault = await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
    expect(server.recordOf(o.id).crates[vault]!.ownersOnly, isTrue);
    await owner.service.saveRole(o.id,
        id: o.member,
        name: 'Member',
        can: const {},
        crates: {o.production: levelSwitches(CrateLevel.use)});
    await expectLater(
        owner.service.saveRole(o.id,
            id: o.member, name: 'Member', can: const {}, crates: {vault: levelSwitches(CrateLevel.use)}),
        throwsA(isA<OrchardRecordRefused>()),
        reason: 'no role reaches an owners-only Crate');
    await owner.service.openCrateToAll(o.id, vault);
    await owner.service.saveRole(o.id,
        id: o.member, name: 'Member', can: const {}, crates: {vault: levelSwitches(CrateLevel.use)});
    await alice.service.refresh();
    expect(await alice.rows(o.id, 'SELECT name FROM orchard_crates'), ['Vault']);

    // A name made with a key a rotation replaced meanwhile is refused; the
    // device renames again once it has the new key.
    final other = device(_owner);
    await other.service.refresh();
    await owner.service.rotateAll();
    await expectLater(other.service.renameCrate(o.id, vault, 'Old key'),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'generation-moved')));
    await other.service.refresh();
    await other.service.renameCrate(o.id, vault, 'New key');
    final otherDb = await other.service.databases.open(o.id);
    final secret = (await otherDb
            .customSelect("SELECT secret FROM space_keys WHERE scope_id = '$vault' AND generation = 2")
            .getSingle())
        .read<Uint8List>('secret');
    final listed = server.orchardsById[o.id]!.crates.firstWhere((c) => c.id == vault);
    expect(await decryptCrateName(listed.nameEnc, secret, orchardId: o.id, crateId: vault, generation: 2), 'New key');
  });
}

Map<String, Object?> _body(RecordRole r) => {
      'id': r.id,
      'rank': r.rank,
      'name_enc': r.nameEnc,
      'name_gen': r.nameGeneration,
      'can': switchList(r.can),
      'crates': {for (final c in r.crates.entries) c.key: switchList(c.value)},
    };
