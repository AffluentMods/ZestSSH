import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_reader.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'setup_world.dart';

// Reading an Orchard for a setup file (3.0): what a device knows
// of it, as a file is compared with it.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;

  String email(String uid) => SetupWorld.emailOf(uid);

  setUpAll(SetupWorld.makeKeys);

  setUp(() async {
    world = SetupWorld();
    await world.start();
    owner = world.device(SetupWorld.owner);
    o = await world.orchard(owner);
  });

  tearDown(() => world.stop());

  Future<SetupDevice> joined(String uid, String role, {Map<String, Set<String>> grants = const {}}) async {
    final d = world.device(uid);
    await world.join(owner, d, o.id, role, grants: grants);
    return d;
  }

  test('an owner reads all of it: Crates and roles by name, members by address, what waits, and the hosts',
      () async {
    final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
    await owner.service.orderRoles(o.id, [ops, o.members]);
    await joined(SetupWorld.ada, o.members);
    await owner.service.invite(o.id,
        email: email(SetupWorld.sam),
        role: ops,
        grants: {o.staging: levelSwitches(CrateLevel.use)},
        endsAt: secondsOf(kLater));
    await owner.service.invite(o.id, email: email(SetupWorld.lin), role: FixedRoles.admin);
    final invites = await owner.service.invites(o.id);
    world.server.acceptAs(o.id, invites.firstWhere((i) => i.email == email(SetupWorld.lin)).id, SetupWorld.lin);
    final deploy = await owner.addKey(o.id, 'deploy', crateId: o.staging);
    final web = await owner.addGroup(o.id, 'Web', crateId: o.staging);
    final placed = await owner.addHost(o.id, 'stage-1',
        crateId: o.staging, address: '10.30.0.11', port: 2222, protocol: 'mosh', keyId: deploy, groupId: web, tags: {'b', 'a'});
    // One written without a word on its Crate is in the Crate new items go to.
    final db = await owner.db(o.id);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'unplaced', label: 'web-1', host: '10.50.0.11', createdAt: kSetupNow, updatedAt: kSetupNow));
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'unplaced-key', label: 'backup', username: 'ops', authMethod: 'password', createdAt: kSetupNow,
        updatedAt: Value(kSetupNow)));
    await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion(
        id: const Value('unplaced-group'), name: const Value('Edge'), isExpanded: const Value(true), createdAt: Value(kSetupNow)));

    final now = await owner.snapshot(o.id, lock: (on: true, minutes: 5));
    expect(now.orchardId, o.id);
    expect(now.name, 'Northwind Ops');
    expect(now.me, SetupWorld.owner);
    expect(now.myEmail, email(SetupWorld.owner));
    expect(now.now, kSetupNow.millisecondsSinceEpoch ~/ 1000);
    expect(now.reached, isTrue);
    expect(now.lockOn, isTrue);
    expect(now.lockMinutes, 5);
    expect(now.record.seq, world.server.recordOf(o.id).seq);

    expect({for (final c in now.crates) c.id: c.name}, {o.production: 'Production', o.staging: 'Staging'});
    expect(now.crates.every((c) => c.open), isTrue);
    expect(now.crate(o.staging)!.name, 'Staging');
    expect(now.crate('nowhere'), isNull);
    expect([for (final r in now.roles) '${r.id == ops ? 'ops' : 'members'} ${r.name}'],
        ['ops Operators', 'members Members'], reason: 'highest first');
    expect(now.role(ops)!.name, 'Operators');
    expect(now.role('nobody'), isNull);

    expect({for (final m in now.members) m.uid: m.email},
        {SetupWorld.owner: email(SetupWorld.owner), SetupWorld.ada: email(SetupWorld.ada)});
    expect(now.member(SetupWorld.ada)!.compared, isTrue, reason: 'the owner compared her keys to add her');
    expect(now.member(SetupWorld.ada)!.keysTrusted, isTrue);
    expect(now.member(SetupWorld.owner)!.keysTrusted, isTrue);
    expect(now.member('stranger'), isNull);

    final waiting = {for (final i in now.invites!) i.email: i};
    expect(waiting.keys, unorderedEquals([email(SetupWorld.sam), email(SetupWorld.lin)]));
    final sam = waiting[email(SetupWorld.sam)]!;
    expect(sam.role, ops);
    expect(sam.grants, {o.staging: levelSwitches(CrateLevel.use)});
    expect(sam.endsAt, secondsOf(kLater));
    expect(sam.expired, isFalse);
    expect(sam.accepted, isFalse);
    final lin = waiting[email(SetupWorld.lin)]!;
    expect(lin.role, FixedRoles.admin);
    expect(lin.grants, isEmpty);
    expect(lin.endsAt, isNull);
    expect(lin.accepted, isTrue);
    world.server.lapse(o.id, invites.firstWhere((i) => i.email == email(SetupWorld.sam)).id);
    expect((await owner.snapshot(o.id)).invites!.firstWhere((i) => i.email == email(SetupWorld.sam)).expired, isTrue);

    final hosts = {for (final h in now.hosts) h.id: h};
    expect(hosts.keys, unorderedEquals([placed, 'unplaced']));
    final stage = hosts[placed]!;
    expect(stage.crateId, o.staging);
    expect(stage.name, 'stage-1');
    expect(stage.address, '10.30.0.11');
    expect(stage.port, 2222);
    expect(stage.protocol, 'mosh');
    expect(stage.keyId, deploy);
    expect(stage.groupId, web);
    expect(stage.tags, {'a', 'b'});
    final plain = hosts['unplaced']!;
    expect(plain.crateId, o.production, reason: 'where new items go on this device');
    expect(plain.port, 22);
    expect(plain.protocol, 'ssh');
    expect(plain.keyId, isNull);
    expect(plain.groupId, isNull);
    expect(plain.tags, isEmpty);
    expect({for (final k in now.keys) k.name: k.crateId}, {'deploy': o.staging, 'backup': o.production});
    expect(now.keys.firstWhere((k) => k.name == 'deploy').id, deploy);
    expect({for (final g in now.groups) g.name: g.crateId}, {'Web': o.staging, 'Edge': o.production});
    expect(now.groups.firstWhere((g) => g.name == 'Web').id, web);
  });

  test('a member reads what is open to them: a closed Crate has no name, and who is invited is not theirs to see',
      () async {
    await owner.service.invite(o.id, email: email(SetupWorld.sam), role: o.members);
    await owner.addHost(o.id, 'web-1', crateId: o.production);
    await owner.addHost(o.id, 'stage-1', crateId: o.staging);
    await owner.sync(o.id);
    final lin = await joined(SetupWorld.lin, o.members);
    final now = await lin.snapshot(o.id);
    expect(now.me, SetupWorld.lin);
    expect(now.myEmail, email(SetupWorld.lin));
    expect({for (final c in now.crates) c.id: c.name}, {o.production: 'Production', o.staging: null});
    expect(now.crate(o.staging)!.open, isFalse);
    expect(now.roles.map((r) => r.name), ['Members']);
    expect(now.invites, isNull);
    expect(now.hosts.map((h) => h.name), ['web-1']);
    expect(now.lockOn, isNull);
    expect(now.lockMinutes, isNull);
    // Members hear each other's addresses; nobody here was compared by Lin.
    expect({for (final m in now.members) m.uid: m.email},
        {SetupWorld.owner: email(SetupWorld.owner), SetupWorld.lin: email(SetupWorld.lin)});
    expect(now.member(SetupWorld.owner)!.compared, isFalse);
    expect(now.member(SetupWorld.owner)!.keysTrusted, isTrue, reason: 'the record\'s keys for them, kept on first sight');
    expect(now.member(SetupWorld.lin)!.keysTrusted, isTrue);
  });

  test('comparing someone\'s keys is what makes them compared here; a change of keys nobody here saw stops both',
      () async {
    final second = await joined(SetupWorld.second, FixedRoles.owner);
    await joined(SetupWorld.ada, o.members);
    expect((await second.snapshot(o.id)).member(SetupWorld.ada)!.compared, isFalse);
    expect((await second.snapshot(o.id)).member(SetupWorld.ada)!.keysTrusted, isTrue);
    await second.service.verifyMember(o.id, SetupWorld.ada);
    expect((await second.snapshot(o.id)).member(SetupWorld.ada)!.compared, isTrue);

    // Ada is taken out and comes back with other keys, added by the second
    // owner: the first owner's device holds the keys it compared, and these
    // are not them.
    await owner.service.removeMember(o.id, SetupWorld.ada);
    final other = await AccountKeys.generate();
    await world.server.publish(SetupWorld.ada, other, email: email(SetupWorld.ada));
    await world.join(second, world.device(SetupWorld.ada, keys: other), o.id, o.members);
    final now = await owner.snapshot(o.id);
    expect(now.member(SetupWorld.ada)!.compared, isFalse);
    expect(now.member(SetupWorld.ada)!.keysTrusted, isFalse);
    expect((await second.snapshot(o.id)).member(SetupWorld.ada)!.keysTrusted, isTrue);
    expect((await second.snapshot(o.id)).member(SetupWorld.ada)!.compared, isTrue);

    // So a plan made here gives her nothing new, as the service itself would not.
    final plan = await planSetup(
        setupFile({
          'roles': [
            {
              'name': 'Members',
              'crates': {'Production': 'use', 'Staging': 'use'},
            },
          ],
        }),
        now);
    expect(texts(plan.problems), [
      'keysNotTrusted ${email(SetupWorld.ada)} <role Members: Production="use" Staging="use">',
    ]);
    await expectLater(
        owner.service.setRoleParts(o.id, o.members, crates: {
          o.production: levelSwitches(CrateLevel.use),
          o.staging: levelSwitches(CrateLevel.use),
        }),
        throwsA(isA<MemberKeysNotTrusted>().having((e) => e.uid, 'uid', SetupWorld.ada)));
  });

  test('keys are trusted here as the service trusts them: this version, these very keys, and no change waiting',
      () async {
    await joined(SetupWorld.ada, o.members);
    final db = await owner.db(o.id);
    final kept = (await db
            .customSelect('SELECT * FROM member_keys WHERE uid = ?', variables: const [Variable(SetupWorld.ada)])
            .getSingle())
        .data;
    // What this device holds for Ada, with [changed] put over it.
    Future<void> holding(Map<String, Object?> changed) async {
      final next = {...kept, ...changed};
      await db.customStatement(
          'UPDATE member_keys SET key_version = ?, signing_key = ?, encryption_key = ?, pending_keys = ? '
          'WHERE uid = ?',
          [next['key_version'], next['signing_key'], next['encryption_key'], next['pending_keys'], SetupWorld.ada]);
    }

    // From here on ZestSSH Cloud is out of reach: nothing puts this device's
    // list of members right again, and a snapshot is of what it holds.
    world.server.failOrchards = true;
    Future<SnapshotMember> ada() async => (await owner.snapshot(o.id)).member(SetupWorld.ada)!;
    expect((await ada()).keysTrusted, isTrue);
    expect((await ada()).compared, isTrue);

    // Another version of the same keys.
    await holding({'key_version': (kept['key_version']! as int) + 1});
    expect((await ada()).keysTrusted, isFalse);
    expect((await ada()).compared, isFalse, reason: 'what was compared were other keys');

    // Other keys under the same version: one set whose fingerprint differs
    // from its first byte on, and one whose fingerprint begins the same.
    final signing = kept['signing_key']! as Uint8List;
    final encryption = kept['encryption_key']! as Uint8List;
    final right = accountKeysFingerprint(signingKey: signing, encryptionKey: encryption);
    Uint8List? near, far;
    for (var i = 1; i < 65536 && (near == null || far == null); i++) {
      final other = Uint8List.fromList(signing);
      other[0] ^= i & 0xff;
      other[1] ^= i >> 8;
      final print = accountKeysFingerprint(signingKey: other, encryptionKey: encryption);
      expect(print, hasLength(right.length));
      if (print[0] == right[0]) {
        near ??= other;
      } else {
        far ??= other;
      }
    }
    for (final other in [far!, near!]) {
      await holding({'signing_key': other});
      expect((await ada()).keysTrusted, isFalse);
    }

    // The right keys, with a change of them waiting to be looked at.
    final waiting = await (await AccountKeys.generate()).publish(SetupWorld.ada);
    await holding({
      'pending_keys': jsonEncode({...waiting.toJson(), 'endorsement': null}),
    });
    expect((await MemberDirectory(db).pin(SetupWorld.ada))!.hardStop, isTrue);
    expect((await ada()).keysTrusted, isFalse);

    // As it was, they are trusted again.
    await holding(const {});
    expect((await ada()).keysTrusted, isTrue);
    expect((await ada()).compared, isTrue);
  });

  test('this account\'s own keys need no such check, and addresses are read in small letters', () async {
    await joined(SetupWorld.ada, o.members);
    final db = await owner.db(o.id);
    world.server.failOrchards = true;
    await db.customStatement(
        'UPDATE member_keys SET email = ? WHERE uid = ?', [' Ada@Northwind.EXAMPLE ', SetupWorld.ada]);
    await db.customStatement(
        'UPDATE member_keys SET email = ? WHERE uid = ?', ['Owner-1@NORTHWIND.example', SetupWorld.owner]);
    final loud = await owner.snapshot(o.id);
    expect(loud.member(SetupWorld.ada)!.email, email(SetupWorld.ada));
    expect(loud.member(SetupWorld.owner)!.email, email(SetupWorld.owner));
    expect(loud.myEmail, email(SetupWorld.owner));
    // Nothing held for this account itself: it holds its own keys all the same.
    await db.customStatement('DELETE FROM member_keys WHERE uid = ?', [SetupWorld.owner]);
    final bare = await owner.snapshot(o.id);
    expect(bare.member(SetupWorld.owner)!.keysTrusted, isTrue);
    expect(bare.member(SetupWorld.owner)!.compared, isFalse);
    expect(bare.myEmail, isNull);
  });

  test('an Orchard whose record stopped on this device is not read', () async {
    await owner.snapshot(o.id);
    final db = await owner.db(o.id);
    await db.customStatement("UPDATE orchard_info SET record_problem = 'An entry does not follow the one before' "
        'WHERE id = 1');
    // (Out of reach, so that the reading does not look at the record again
    // first: it is the look at the record that notes a problem, or clears it.)
    world.server.failOrchards = true;
    await expectLater(
        owner.snapshot(o.id), throwsA(isA<SetupNotOpen>().having((e) => e.status, 'status', 'record')));
  });

  test('the invitations are asked for only by an account that may see them', () async {
    final lin = await joined(SetupWorld.lin, o.members);
    final before = world.server.inviteLists;
    expect((await lin.snapshot(o.id)).invites, isNull);
    expect(world.server.inviteLists, before, reason: 'a role that cannot invite does not ask');
    expect((await owner.snapshot(o.id)).invites, isEmpty);
    expect(world.server.inviteLists, before + 1);
  });

  test('a host, a key and a group nothing has placed yet are in the Crate new items go to', () async {
    final db = await owner.db(o.id);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'unplaced', label: 'web-1', host: '10.50.0.11', createdAt: kSetupNow, updatedAt: kSetupNow));
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'unplaced-key', label: 'backup', username: 'ops', authMethod: 'password', createdAt: kSetupNow,
        updatedAt: Value(kSetupNow)));
    await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion(
        id: const Value('unplaced-group'), name: const Value('Edge'), isExpanded: const Value(true), createdAt: Value(kSetupNow)));
    // No sync has run: nothing says where they are.
    final now = await readSetupSnapshot(owner.service, o.id);
    expect(
        await db.customSelect("SELECT item_key FROM crate_items_meta WHERE item_key LIKE 'unplaced%'").get(), isEmpty);
    expect({for (final h in now.hosts) h.name: h.crateId}, {'web-1': o.production});
    expect({for (final k in now.keys) k.name: k.crateId}, {'backup': o.production});
    expect({for (final g in now.groups) g.name: g.crateId}, {'Edge': o.production});
  });

  test('when ZestSSH Cloud cannot be reached, it is the Orchard as this device last saw it, and says so',
      () async {
    await owner.service.invite(o.id, email: email(SetupWorld.sam), role: o.members);
    await owner.addHost(o.id, 'web-1', crateId: o.production);
    final before = await owner.snapshot(o.id);
    expect(before.reached, isTrue);
    expect(before.invites, hasLength(1));
    final syncs = owner.syncs;
    world.server.failOrchards = true;
    final now = await owner.snapshot(o.id);
    expect(now.reached, isFalse);
    expect(now.invites, isNull, reason: 'who is invited is on the server alone');
    expect(owner.syncs, syncs, reason: 'nothing to sync with');
    expect(now.name, 'Northwind Ops');
    expect(now.record.seq, before.record.seq);
    expect(now.crates.map((c) => c.name), ['Production', 'Staging']);
    expect(now.hosts.map((h) => h.name), ['web-1']);
    expect(now.members.map((m) => m.email), [email(SetupWorld.owner)]);
  });

  test('a sync that fails first does not stop the reading; invitations that cannot be read are not known',
      () async {
    await owner.service.invite(o.id, email: email(SetupWorld.sam), role: o.members);
    final now = await readSetupSnapshot(owner.service, o.id, sync: () async => throw StateError('no sync'));
    expect(now.reached, isTrue);
    expect(now.name, 'Northwind Ops');
    expect(now.invites, hasLength(1));
    // With no sync given at all, it reads what the device has; and the
    // time is the device's own where none is given.
    final plain = await readSetupSnapshot(owner.service, o.id);
    expect(plain.crates, hasLength(2));
    expect(plain.now, closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000, 5));
    world.server.failOrchardInvites = true;
    final blind = await owner.snapshot(o.id);
    expect(blind.reached, isTrue);
    expect(blind.invites, isNull);
    expect(blind.members, hasLength(1));
  });

  test('the sync it is given runs once, and only after the Orchard itself was brought up to date', () async {
    final seen = <int>[];
    final before = world.server.recordReads;
    await readSetupSnapshot(owner.service, o.id, sync: () async => seen.add(world.server.recordReads));
    expect(seen, hasLength(1));
    expect(seen.single, greaterThan(before), reason: 'the record was read from ZestSSH Cloud first');
  });

  test('an Orchard this account is not in good standing in is not read as if it were', () async {
    final ada = await joined(SetupWorld.ada, o.members);
    await ada.snapshot(o.id);
    await owner.service.suspendMember(o.id, SetupWorld.ada);
    await expectLater(ada.snapshot(o.id),
        throwsA(isA<SetupNotOpen>().having((e) => e.status, 'status', 'suspended')));
    expect('${const SetupNotOpen('suspended')}', contains('suspended'));
    // An Orchard this device never held: said, and no database is made for it.
    const stranger = '00000000-0000-4000-8000-00000000ffff';
    await expectLater(
        owner.snapshot(stranger), throwsA(isA<SetupNotOpen>().having((e) => e.status, 'status', 'unknown')));
    expect(await owner.service.databases.onDevice(), [o.id]);
    // An account whose keys are not ready reads nothing.
    final none = OrchardService(server: world.server.as(SetupWorld.sam), databases: owner.service.databases, author: () async => null);
    await expectLater(readSetupSnapshot(none, o.id), throwsA(isA<AccountKeysNotReady>()));
  });
}
