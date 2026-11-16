import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';

import '../../helpers/contract_run.dart';

/// Running an Orchard against the REAL server routes (ZestSSH Cloud's
/// routes/orchards.js with lib/orchard_record.js and
/// lib/orchard_record_store.js) on a real database (3.0): a
/// member's role, extra Crates and end date; an ownership transfer in one
/// request; roles made, ordered, renumbered and dropped; leaving; Crate
/// settings; renames checked against the key generation; and the keys a
/// revocation leaves waiting, replaced. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

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

class _Account {
  _Account(this.uid, this.service, this.storage);

  final String uid;
  final OrchardService service;
  final _MemoryStorage storage;

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await service.databases.open(orchardId)).customSelect(sql).get())
          r.data.values.join(':'),
      ];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String token(String uid) => 'fb:$uid:${now()}:${now()}';

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/orchards')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in opened) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    opened.clear();
  });

  var made = 0;

  /// A new account with published keys; [device] another device of it.
  Future<_Account> account(String name, {String? uid}) async {
    final id = uid ?? 'manage-$name-$contractRun-${made++}';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(id)),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final storage = _MemoryStorage();
    opened.add(storage);
    final service = OrchardService(
      server: OrchardsApi(client: client, baseUrl: base, bearer: () async => token(id)),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    return _Account(id, service, storage);
  }

  Future<void> join(_Account by, _Account person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    expect(await person.service.refresh(), contains(orchardId));
  }

  test("a member's role, extra Crates and end date, with the keys each hands out and the ones it leaves waiting",
      () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Manage', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final member = (await owner.service.roles(orchardId)).single.id;
    final ops = await owner.service.saveRole(orchardId,
        name: 'Ops', can: {RoleCan.invite}, crates: {staging: levelSwitches(CrateLevel.edit)});
    await join(owner, alice, orchardId, member);
    expect((await owner.service.roles(orchardId)).map((r) => r.name), ['Member', 'Ops']);

    // A new role: Staging with its key, Production taken away.
    await owner.service.setMemberRole(orchardId, alice.uid, ops);
    await alice.service.refresh();
    expect(await alice.rows(orchardId, 'SELECT name, level FROM orchard_crates'), ['Staging:edit']);
    expect(await owner.service.keysWaiting(orchardId), isTrue, reason: 'she held the Production key');
    expect(await owner.service.rotateDue(orchardId), isEmpty);
    expect(await owner.service.keysWaiting(orchardId), isFalse);
    expect(await owner.rows(orchardId, 'SELECT name, key_generation FROM orchard_crates ORDER BY name'),
        ['Production:2', 'Staging:1']);

    // Production again as an extra Crate, at Connect: every generation.
    await owner.service.setMemberGrants(orchardId, alice.uid, {
      (await owner.rows(orchardId, "SELECT crate_id FROM orchard_crates WHERE name = 'Production'")).single:
          levelSwitches(CrateLevel.connect),
    });
    await alice.service.refresh();
    expect(await alice.rows(orchardId, 'SELECT name, level FROM orchard_crates ORDER BY name'),
        ['Production:connect', 'Staging:edit']);
    final prod = (await alice.rows(orchardId, "SELECT crate_id FROM orchard_crates WHERE name = 'Production'")).single;
    expect(await alice.rows(orchardId, "SELECT generation FROM space_keys WHERE scope_id = '$prod' ORDER BY generation"),
        ['1', '2']);

    final ends = now() + 86400 * 14;
    await owner.service.setMemberEndsAt(orchardId, alice.uid, ends);
    final her = (await owner.service.people(orchardId)).members.firstWhere((p) => p.uid == alice.uid);
    expect(her.endsAt, ends);
    await owner.service.setMemberEndsAt(orchardId, alice.uid, null);
    expect((await owner.service.people(orchardId)).members.firstWhere((p) => p.uid == alice.uid).endsAt, isNull);

    // What her role does not allow, the rules refuse on her device first.
    await expectLater(alice.service.setMemberRole(orchardId, owner.uid, ops), throwsA(isA<OrchardRecordRefused>()));
  });

  test('ownership moves in one request; roles are made, ordered, renumbered and dropped; a member leaves',
      () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final bob = await account('bob');
    final orchardId =
        await owner.service.createOrchard('Handover', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = (await owner.service.roles(orchardId)).single.id;
    await join(owner, alice, orchardId, member);
    await join(owner, bob, orchardId, member);

    // Alone, an owner neither steps down nor leaves; with Alice an owner and
    // this account an admin, in one step, it is Alice's Orchard.
    await expectLater(owner.service.stepDown(orchardId), throwsA(isA<OrchardRecordRefused>()));
    await owner.service.makeOwner(orchardId, alice.uid, stepDown: true);
    await alice.service.refresh();
    expect(await alice.rows(orchardId, 'SELECT role FROM orchard_info'), [FixedRoles.owner]);
    expect(await owner.rows(orchardId, 'SELECT role FROM orchard_info'), [FixedRoles.admin]);
    expect(await alice.rows(orchardId, 'SELECT level FROM orchard_crates'), ['manage'],
        reason: 'an owner opens every Crate, with its keys');

    // Alice's roles: two made below Member, one moved up.
    final lead = await alice.service.saveRole(orchardId, name: 'Lead', can: const {}, crates: const {});
    final guest = await alice.service.saveRole(orchardId, name: 'Guest', can: const {}, crates: const {});
    await alice.service.moveRole(orchardId, lead, up: true);
    Future<List<String?>> order() async => [for (final r in await alice.service.roles(orchardId)) r.name];
    expect(await order(), ['Lead', 'Member', 'Guest']);

    // No room left below: renumbered, every entry in one request.
    final r = (await LocalRecord.load(await alice.service.databases.open(orchardId), orchardId)).latest;
    await alice.service.changeAll(orchardId, [
      for (final (id, rank) in [(lead, 3), (member, 2), (guest, 1)])
        (type: RecordTypes.roleSet, body: roleBody(r.roles[id]!, rank: rank)),
    ]);
    final contractors = await alice.service.saveRole(orchardId, name: 'Contractors', can: const {}, crates: const {});
    expect(await order(), ['Lead', 'Member', 'Guest', 'Contractors']);
    final ranks = [for (final x in await alice.service.roles(orchardId)) x.rank];
    expect(ranks, [4000, 3000, 2000, 1000]);

    // Member dropped: Bob moves to Guest, and his device follows.
    await alice.service.dropRole(orchardId, member, guest);
    await bob.service.refresh();
    expect(await bob.rows(orchardId, 'SELECT role FROM orchard_info'), [guest]);
    expect(await order(), ['Lead', 'Guest', 'Contractors']);
    expect(contractors, isNotEmpty);

    // Bob leaves: the Orchard leaves his device, and the server no longer
    // lists it for him.
    await bob.service.leaveOrchard(orchardId);
    expect(bob.storage.deleted, [orchardId]);
    expect(await bob.service.refresh(), isEmpty);
    await alice.service.refresh();
    expect((await alice.service.people(orchardId)).members.map((p) => p.uid), isNot(contains(bob.uid)));
  });

  test("a Crate's settings and names, and the Orchard's, checked against the key they were made with", () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Names', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = (await owner.service.roles(orchardId)).single.id;
    await join(owner, alice, orchardId, member);
    final prod = (await owner.rows(orchardId, 'SELECT crate_id FROM orchard_crates')).single;

    await owner.service.setCrateAllow(orchardId, prod, {CrateSwitches.forward});
    await owner.service.renameCrate(orchardId, prod, 'Prod');
    await owner.service.renameOrchard(orchardId, 'Names Inc');
    await alice.service.refresh();
    expect(await alice.rows(orchardId, 'SELECT name, switches, allow FROM orchard_crates'),
        ['Prod:["connect","forward","reveal"]:["forward"]']);
    expect(await alice.rows(orchardId, 'SELECT name FROM orchard_info'), ['Names Inc']);
    await expectLater(alice.service.renameCrate(orchardId, prod, 'Mine'),
        throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 403)));
    await expectLater(alice.service.renameOrchard(orchardId, 'Mine'),
        throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 403)));

    // A second device of the owner's, a key replacement behind: its rename
    // is refused until it has the new key.
    final other = await account('owner', uid: owner.uid);
    await other.service.refresh();
    expect(await owner.service.rotateAll(), isEmpty);
    await expectLater(other.service.renameCrate(orchardId, prod, 'Stale'),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'generation-moved')));
    await expectLater(other.service.renameOrchard(orchardId, 'Stale'),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'generation-moved')));
    await other.service.refresh();
    await other.service.renameCrate(orchardId, prod, 'Production');
    await alice.service.refresh();
    expect(await alice.rows(orchardId, 'SELECT name FROM orchard_crates'), ['Production']);

    // An owners-only Crate reaches owners alone until an owner opens it up.
    final vault = await owner.service.createCrate(orchardId, 'Vault', ownersOnly: true);
    await expectLater(
      owner.service.saveRole(orchardId,
          id: member, name: 'Member', can: const {}, crates: {vault: levelSwitches(CrateLevel.use)}),
      throwsA(isA<OrchardRecordRefused>()),
    );
    await owner.service.openCrateToAll(orchardId, vault);
    await owner.service.saveRole(orchardId,
        id: member,
        name: 'Member',
        can: const {},
        crates: {prod: levelSwitches(CrateLevel.use), vault: levelSwitches(CrateLevel.use)});
    await alice.service.refresh();
    expect(await alice.rows(orchardId, 'SELECT name FROM orchard_crates ORDER BY name'), ['Production', 'Vault']);
  });
}
