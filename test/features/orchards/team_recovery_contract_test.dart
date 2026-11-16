import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Team recovery (3.0) against the REAL server routes on a real
/// Postgres: a member who lost every device starts over with new keys
/// (POST /v1/keys/reset), one owner approves the new keys, a second owner
/// completes the recovery (the record's member.recover entry and every key
/// sealed to the new keys), and the member's new device reads and writes
/// the team's hosts again. Start the server:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running.

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
  _Device(this.storage, this.service, this.coordinator);

  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get())
          r.data.values.map((v) => '$v').join(':'),
      ];
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // Signed in just now: recovery and starting over need a recent sign-in.
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
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  var accounts = 0;

  Future<CrateAuthor> account(String name) async {
    final uid = 'rec-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  _Device device(CrateAuthor me) {
    final storage = _MemoryStorage();
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid));
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    final d = _Device(storage, service,
        OrchardSyncCoordinator(service: service, server: server, databases: databases));
    devices.add(d);
    return d;
  }

  Future<void> addHost(AppDatabase db, String id) async {
    final at = DateTime(2026, 9, 25);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: '10.0.0.9', port: const Value(22), createdAt: at, updatedAt: at));
  }

  test('lost every key: started over, approved by one owner, completed by another, and back in the team', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final owner2 = await account('owner2');
    // Alice's first device makes and publishes their keys through the key
    // service, as the app does.
    final aliceUid = 'rec-alice-${now()}-${accounts++}';
    final aliceStore = AccountKeyStore(const FlutterSecureStorage());
    final aliceKeys = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(aliceUid)),
      store: aliceStore,
      onKeysChanged: () {},
    );
    expect(await aliceKeys.ensureKeys(), AccountKeyStatus.ready);
    final alice = CrateAuthor(uid: aliceUid, keys: (await aliceKeys.readyKeys())!.keys);

    final o = device(owner);
    final orchardId = await o.service.createOrchard('Recovery', firstCrateName: 'Production', memberRoleName: 'Member');
    // A second generation of every key: all of them come back.
    expect(await o.service.rotateAll(), isEmpty);
    final production = (await o.service.server.orchards()).firstWhere((x) => x.id == orchardId).crates.single.id;
    final role = (await o.service.roles(orchardId)).single.id;
    Future<void> join(CrateAuthor person, String role, {Map<String, Set<String>> grants = const {}}) async {
      await o.service.invite(orchardId, email: '${person.uid}@example.com', role: role, grants: grants);
      final p = device(person);
      await p.service.acceptInvite((await p.service.myInvites()).single.id);
      await o.service.confirmInvite(orchardId, (await o.service.invites(orchardId)).single);
    }

    await join(owner2, FixedRoles.owner);
    await join(alice, role, grants: {production: levelSwitches(CrateLevel.edit)});
    await addHost(await o.db(orchardId), 'h-owner');
    expect((await o.coordinator.syncAll())[orchardId]!.sent, 1);
    await o.service.setTeamRecovery(orchardId, true);

    // Every device alice had is gone, with the keys: a new one starts over.
    await aliceStore.delete(aliceUid);
    expect(await aliceKeys.ensureKeys(), AccountKeyStatus.waitingForAnotherDevice);
    final started = await aliceKeys.startOver();
    expect(started.keys.version, 2);
    final a = device(CrateAuthor(uid: aliceUid, keys: started.keys));
    expect(await a.service.refresh(), isEmpty, reason: 'nothing opens yet');
    expect(await a.rows(orchardId, 'SELECT status FROM orchard_info'), [kRecoveryWaitStatus]);
    expect((await a.service.teamRecovery(orchardId)).waiting.single.approvals, isEmpty);

    // owner2 compares alice's new words and approves.
    final o2 = device(owner2);
    final wait = (await o2.service.teamRecovery(orchardId)).waiting.single;
    expect(wait.keys.fingerprint, (await started.keys.publish(aliceUid)).fingerprint);
    expect(wait.recordKeyVersion, 1);
    expect(wait.email, '$aliceUid@example.com');
    await o2.service.approveRecovery(orchardId, wait);
    expect((await a.service.teamRecovery(orchardId)).waiting.single.approvals.single.uid, owner2.uid);

    // The first owner compares too, and completes.
    final approved = (await o.service.teamRecovery(orchardId)).waiting.single;
    expect(approved.approvals.single.signature, isNotNull);
    await o.service.completeRecovery(orchardId, approved);
    expect((await o.service.teamRecovery(orchardId)).waiting, isEmpty);

    // Alice's new device opens every generation again and reads the team's
    // host, its signature checked against the owner's pinned key.
    final reports = await a.coordinator.syncAll();
    expect(reports.keys, [orchardId]);
    expect(reports[orchardId]!.rejected, 0);
    expect(await a.rows(orchardId, 'SELECT scope, generation FROM space_keys ORDER BY scope, generation'),
        ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);
    expect(await a.rows(orchardId, 'SELECT id FROM connections'), ['h-owner']);
    expect((await a.rows(orchardId, 'SELECT type FROM orchard_record_entries ORDER BY seq')).last, 'member.recover');

    // What alice writes with the new keys, the owners' devices accept.
    await addHost(await a.db(orchardId), 'h-alice');
    expect((await a.coordinator.syncAll())[orchardId]!.sent, 1);
    final back = await o.coordinator.syncAll();
    expect(back[orchardId]!.rejected, 0);
    expect(await o.rows(orchardId, 'SELECT id FROM connections ORDER BY id'), ['h-alice', 'h-owner']);
    expect(await o.rows(orchardId, "SELECT key_version, verified_by_me FROM member_keys WHERE uid = '$aliceUid'"),
        ['2:1']);
  });
}
