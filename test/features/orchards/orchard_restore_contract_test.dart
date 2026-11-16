import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

/// A team after ZestSSH Cloud is restored from an older backup,
/// against the REAL server routes on a real
/// Postgres: the server's database is taken back to a snapshot made a moment
/// before (in production, a backup some 30 seconds or a night old) while the
/// devices hold the newer record (a new vault, a new member, a role change)
/// and newer items. The devices send back what the server lost, nothing is
/// lost or written twice, and what was written after the restore by a device
/// that never saw the newer state is kept too. A server whose record parts
/// ways with a device's is not followed. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1); the server's test routes
/// (/test/db/snapshot, /test/db/restore) are beside /v1, and take back only
/// the rows of the team under test.

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
  _Device(this.name, this.storage, this.service, this.coordinator, this.author);

  final String name;
  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;
  final CrateAuthor author;

  Future<AppDatabase> db(String orchardId) => coordinator.databases.open(orchardId);

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get()) r.data.values.join(':'),
      ];

  Future<Map<String, CrateSyncReport>> sync() => coordinator.syncAll();
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1$'), '');
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String token(String uid) => 'fb:$uid:${now()}:${now()}';

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/orchards')).timeout(const Duration(seconds: 2));
      final snap = await client
          .post(Uri.parse('$root/test/db/snapshot'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'orchards': <String>[]}))
          .timeout(const Duration(seconds: 30));
      serverUp = r.statusCode == 401 && snap.statusCode == 200;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  String skip() => 'app contract server (with /test/db/snapshot) not running at $base';

  /// What the server's database holds of [orchardId] now, to go back to:
  /// its id. (Only that team's rows: the other contract tests run at the
  /// same time against the same server.)
  Future<String> backup(String orchardId) async {
    final r = await client.post(Uri.parse('$root/test/db/snapshot'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'orchards': [orchardId]
        }));
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map)['id'] as String;
  }

  /// The server's database restored from [id], whatever was written since.
  Future<void> restore(String id) async {
    final r = await client.post(Uri.parse('$root/test/db/restore/$id'));
    expect(r.statusCode, 200, reason: r.body);
  }

  var accounts = 0;

  Future<CrateAuthor> account(String name) async {
    final uid = 'restore-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid)).publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  _Device device(String name, CrateAuthor me) {
    final storage = _MemoryStorage();
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid));
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    final d = _Device(name, storage, service, OrchardSyncCoordinator(service: service, server: server, databases: databases), me);
    devices.add(d);
    return d;
  }

  Future<void> addHost(_Device d, String orchardId, String id, {String? crateId}) async {
    final db = await d.db(orchardId);
    final at = DateTime(2026, 10, 23);
    if (crateId != null) await db.customStatement('UPDATE orchard_info SET default_crate_id = ? WHERE id = 1', [crateId]);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: '10.0.0.${id.hashCode % 200 + 1}',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
  }

  /// [person] joins as the first role, invited and confirmed by [by].
  Future<void> join(_Device by, _Device person, String orchardId) async {
    final role = (await by.service.roles(orchardId)).single.id;
    await by.service.invite(orchardId, email: '${person.author.uid}@example.com', role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
  }

  /// The first role gets edit in [crateId] (to write items there).
  Future<void> roleEdits(_Device owner, String orchardId, String crateId) async {
    final record = (await LocalRecord.load(await owner.db(orchardId), orchardId)).latest;
    final id = record.roles.keys.single;
    final role = record.roles[id]!;
    await owner.service.change(orchardId, RecordTypes.roleSet, {
      'id': id,
      'rank': kDefaultMemberRank,
      'name_enc': role.nameEnc,
      'name_gen': role.nameGeneration,
      'can': const <String>[],
      'crates': {crateId: switchList(levelSwitches(CrateLevel.edit))},
    });
  }

  Future<List<String>> hosts(_Device d, String orchardId) =>
      d.rows(orchardId, 'SELECT id, label FROM connections ORDER BY id');

  test('restored to a backup made before a new vault, a new member, a role change and new items: '
      'the devices send it all back and every device ends up with all of it', () async {
    if (!serverUp) return markTestSkipped(skip());
    final ownerId = await account('owner');
    final aliceId = await account('alice');
    final bobId = await account('bob');
    final owner = device('owner', ownerId);
    final alice = device('alice', aliceId);
    final alice2 = device('alice-2', aliceId);
    final bob = device('bob', bobId);

    final o = await owner.service.createOrchard('Restore', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = (await owner.rows(o, "SELECT crate_id FROM orchard_crates WHERE name = 'Production'")).single;
    await join(owner, alice, o);
    await roleEdits(owner, o, production);
    await addHost(owner, o, 'h-1');
    await owner.sync();
    await alice.sync();
    await alice2.sync();
    expect(await hosts(alice2, o), ['h-1:h-1']);
    final seqAtBackup = (await owner.rows(o, 'SELECT MAX(seq) FROM orchard_record_entries')).single;

    // ── The backup. Then, in the 30 seconds before the restore: ──
    final snapshot = await backup(o);
    final staging = await owner.service.createCrate(o, 'Staging');
    await join(owner, bob, o);
    await addHost(owner, o, 'h-2', crateId: production);
    await (await owner.db(o)).customStatement("UPDATE connections SET label = 'edited-after-backup' WHERE id = 'h-1'");
    await owner.sync();
    await addHost(owner, o, 'h-4', crateId: staging);
    await owner.sync();
    await alice.sync();
    await addHost(alice, o, 'h-3');
    await alice.sync();
    await owner.sync();
    await bob.sync();
    expect(await hosts(bob, o), ['h-1:edited-after-backup', 'h-2:h-2', 'h-3:h-3']);
    final seqBeforeRestore = (await owner.rows(o, 'SELECT MAX(seq) FROM orchard_record_entries')).single;
    expect(int.parse(seqBeforeRestore), greaterThan(int.parse(seqAtBackup)));

    // ── The restore. ──
    await restore(snapshot);

    // Alice's other device saw none of the newer state: it writes as usual,
    // on the restored server. What it writes must reach everyone.
    await addHost(alice2, o, 'h-5');
    final second = await alice2.sync();
    expect(second[o]!.sent, 1);

    // Bob, whom the server no longer has in the team: what his device holds
    // stays, and it says why nothing syncs.
    expect(await bob.service.refresh(), isEmpty);
    expect(await bob.rows(o, 'SELECT status FROM orchard_info'), [kServerBehindStatus]);
    expect(await hosts(bob, o), hasLength(3), reason: 'nothing on his device is deleted');

    // Alice's device holds the record the server lost (much of it the
    // owner's entries) and its receipt: it sends it back, and the items too.
    final aliceRound = await alice.sync();
    expect(aliceRound[o]!.rejected, 0);
    expect(await alice.rows(o, "SELECT COALESCE(record_problem, '') FROM orchard_info"), ['']);
    final serverSeq = (await alice.service.server.record(o, after: 0)).seq;
    expect('$serverSeq', seqBeforeRestore, reason: 'the server has the whole record again');
    // In the same round, the key copies Alice's device holds the keys of
    // went back to the server: Bob's of the team's key among them.
    final stillMissing = await alice.service.server.missingCopies(o);
    expect(stillMissing.where((m) => m.uid == bobId.uid && m.crateId == null), isEmpty);
    expect(stillMissing.where((m) => m.crateId == production), isEmpty);

    // The owner's device: the record is back, its Crates are read again, the
    // vault the owner added (whose name Alice could not seal) is named again,
    // its items go back, and the key copies the server lost are sealed again.
    final ownerRound = await owner.sync();
    expect(ownerRound[o]!.rejected, 0);
    await owner.sync();
    final listed = (await owner.service.server.orchards()).single;
    expect(listed.copiesMissing, isFalse, reason: 'every copy the server lost is sealed again');

    // Everyone follows by themselves.
    for (final d in [alice, alice2, bob, owner]) {
      await d.sync();
    }
    for (final d in [alice, alice2, bob, owner]) {
      await d.sync();
    }
    const production4 = ['h-1:edited-after-backup', 'h-2:h-2', 'h-3:h-3', 'h-5:h-5'];
    for (final d in [alice, alice2, bob]) {
      expect(await hosts(d, o), production4, reason: d.name);
    }
    expect(await hosts(owner, o), [...production4.sublist(0, 3), 'h-4:h-4', 'h-5:h-5']);
    for (final d in [alice, alice2, bob, owner]) {
      expect(await d.rows(o, "SELECT status, COALESCE(record_problem, '') FROM orchard_info"), ['active:'], reason: d.name);
      expect((await d.rows(o, 'SELECT MAX(seq) FROM orchard_record_entries')).single, seqBeforeRestore, reason: d.name);
      expect(await d.rows(o, 'SELECT COUNT(*) FROM crate_outbox'), ['0'], reason: '${d.name}: nothing left to send');
      expect(await LocalStateStore(await d.db(o)).read(kServerWentBackState), isNull, reason: d.name);
    }
    expect(await owner.rows(o, "SELECT name FROM orchard_crates WHERE crate_id = '$staging'"), ['Staging']);
    // The server holds each item once, at its newest version.
    final page = await owner.service.server.changes(production, since: 0);
    expect(page.items, hasLength(4));
    final stagingPage = await owner.service.server.changes(staging, since: 0);
    expect(stagingPage.items, hasLength(1));
    // And a fresh device of Bob's reads it all from the server alone.
    final bob2 = device('bob-2', bobId);
    await bob2.sync();
    expect(await hosts(bob2, o), production4);
    // A fresh device of the owner's opens the vault's name, sealed again,
    // from the server alone.
    final owner3 = device('owner-3', ownerId);
    await owner3.sync();
    expect(await owner3.rows(o, 'SELECT name FROM orchard_crates ORDER BY name'), ['Production', 'Staging']);
    expect(await hosts(owner3, o), await hosts(owner, o));
  });

  test('a record that parts ways with the server after a restore is not followed, and nothing on the device is lost',
      () async {
    if (!serverUp) return markTestSkipped(skip());
    final ownerId = await account('owner');
    final owner = device('owner', ownerId);
    final owner2 = device('owner-2', ownerId);
    final o = await owner.service.createOrchard('Fork', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = (await owner.rows(o, "SELECT crate_id FROM orchard_crates WHERE name = 'Production'")).single;
    await addHost(owner, o, 'h-1');
    await owner.sync();
    await owner2.sync();
    final snapshot = await backup(o);
    // Two changes the owner's first device makes, then the restore.
    await owner.service.createCrate(o, 'Staging');
    await owner.service.createCrate(o, 'Later');
    await owner.sync();
    await restore(snapshot);
    // The owner's second device, at the backup's record, changes the team in
    // place of what was lost: the server's record now parts ways.
    await owner2.service.createCrate(o, 'Elsewhere');
    await owner.sync();
    final problem = (await owner.rows(o, 'SELECT record_problem FROM orchard_info')).single;
    expect(problem, contains(ErrorCodes.teamRecordParted.code));
    expect(problem, contains('parts ways'));
    // Nothing on the device is lost, and nothing it holds went to the server.
    expect(await hosts(owner, o), ['h-1:h-1']);
    expect((await owner2.service.server.changes(production, since: 0)).items, hasLength(1));
  });
}
