import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/key_replacement.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';

import '../../helpers/contract_run.dart';

/// The Orchard's record against the REAL server routes (ZestSSH Cloud's
/// routes/orchards.js, routes/keys.js and lib/orchard_record.js) on a real
/// Postgres (3.0): roles and access change through signed entries
/// both sides check, keys follow access (a role opening a Crate brings its
/// key; a suspension takes keys away and the next rotation leaves the
/// member out; a resume seals every generation again), and a suspended
/// member's key replacement follows a record they cannot read. Start the
/// server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

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

/// An account: its key service, and one device of its.
class _Account {
  _Account(this.uid, this.keys, this.service, this.sync);

  final String uid;
  final AccountKeyService keys;
  final OrchardService service;
  final OrchardSyncCoordinator sync;

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await service.databases.open(orchardId)).customSelect(sql).get())
          r.data.values.join(':'),
      ];
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
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

  /// A new account with published keys, and a device of its.
  Future<_Account> account(String name) async {
    final uid = 'record-$name-$contractRun-${made++}';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid)),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(uid));
    final storage = _MemoryStorage();
    opened.add(storage);
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final service = OrchardService(
      server: server,
      databases: databases,
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    return _Account(uid, keyService, service,
        OrchardSyncCoordinator(service: service, server: server, databases: databases));
  }

  /// [person] joins [orchardId] as its first role: invited by [by],
  /// accepted, compared and confirmed.
  Future<String> join(_Account by, _Account person, String orchardId) async {
    final role = (await by.service.roles(orchardId)).single.id;
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    return role;
  }

  test('roles and access change through the record, and the keys follow', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Record', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = await join(owner, alice, orchardId);
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final production = (await owner.rows(orchardId, "SELECT crate_id FROM orchard_crates WHERE name = 'Production'"))
        .single;

    expect(await alice.service.refresh(), [orchardId]);
    expect(await alice.rows(orchardId, 'SELECT name, switches FROM orchard_crates'),
        ['Production:["connect","forward","reveal","sftp"]'], reason: 'the first role: use of Production');

    // The owner gives the role edit on Staging: its key is sealed to Alice
    // in the same step.
    final named = (await LocalRecord.load(await owner.service.databases.open(orchardId), orchardId))
        .latest
        .roles[role]!;
    await owner.service.change(orchardId, RecordTypes.roleSet, {
      'id': role,
      'rank': kDefaultMemberRank,
      'name_enc': named.nameEnc,
      'name_gen': named.nameGeneration,
      'can': const <String>[],
      'crates': {
        production: switchList(levelSwitches(CrateLevel.use)),
        staging: switchList(levelSwitches(CrateLevel.edit)),
      },
    });
    await alice.service.refresh();
    expect(await alice.rows(orchardId, 'SELECT name, level FROM orchard_crates ORDER BY name'),
        ['Production:use', 'Staging:edit']);
    expect(await alice.rows(orchardId, "SELECT generation FROM space_keys WHERE scope_id = '$staging'"), ['1']);

    // Suspended: Alice's device learns only that, and keeps what it has.
    await owner.service.change(orchardId, RecordTypes.memberSuspend, {'uid': alice.uid});
    expect(await alice.service.refresh(), isEmpty);
    expect(await alice.rows(orchardId, 'SELECT status FROM orchard_info'), ['suspended']);
    expect(await alice.rows(orchardId, 'SELECT COUNT(*) FROM space_keys'), ['3']);

    // The keys she held are due for replacement; the new ones reach the
    // members whose access counts, not her.
    expect(await owner.rows(orchardId, 'SELECT rotation_due FROM orchard_info'), ['1']);
    expect(await owner.rows(orchardId, 'SELECT name, rotation_due FROM orchard_crates ORDER BY name'),
        ['Production:1', 'Staging:1']);
    expect(await owner.service.rotateAll(), isEmpty);
    await owner.service.refresh();
    expect(await owner.rows(orchardId, 'SELECT key_generation, rotation_due FROM orchard_info'), ['2:0'],
        reason: 'the server no longer asks for it either');
    expect(await owner.rows(orchardId, 'SELECT name, key_generation, rotation_due FROM orchard_crates ORDER BY name'),
        ['Production:2:0', 'Staging:2:0']);
    final moved = (await owner.service.server.orchards()).single;
    expect({for (final k in moved.keys) k.generation}, {1, 2});

    // Resumed: every generation of every key she gains, sealed again.
    await owner.service.change(orchardId, RecordTypes.memberResume, {'uid': alice.uid});
    expect(await alice.service.refresh(), [orchardId]);
    expect(await alice.rows(orchardId, 'SELECT status FROM orchard_info'), ['active']);
    expect(
        await alice.rows(orchardId, 'SELECT scope, generation FROM space_keys ORDER BY scope, scope_id, generation'),
        hasLength(6),
        reason: 'the Orchard key and both Crate keys, at generations 1 and 2');

    // What Alice's role cannot do, the rules refuse on her device first.
    await expectLater(
      alice.service.change(orchardId, RecordTypes.memberSuspend, {'uid': owner.uid}),
      throwsA(isA<OrchardRecordRefused>()),
    );
  });

  test("a suspended member's key replacement follows the record the server names", () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Record', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, orchardId);
    await alice.service.refresh();
    await owner.service.change(orchardId, RecordTypes.memberSuspend, {'uid': alice.uid});

    // Alice cannot read the record now; her replacement asks the server
    // where it ends and signs her new keys in after that.
    final replaced = await alice.keys.replaceKeys(
      reseal: alice.service.resealAll,
      records: memberKeysRecords(alice.service),
    );
    expect(replaced.keys.version, 2);
    await owner.service.refresh();
    final entries = await owner.rows(orchardId, 'SELECT type, by_uid, by_key_version FROM orchard_record_entries ORDER BY seq');
    expect(entries.last, '${RecordTypes.memberKeys}:${alice.uid}:2');

    // Resumed, her copies are sealed to the new keys.
    await owner.service.change(orchardId, RecordTypes.memberResume, {'uid': alice.uid});
    final listed = (await alice.service.server.orchards()).single;
    expect(listed.keys.map((k) => k.recipientKeyVersion).toSet(), {2});
  });
}
