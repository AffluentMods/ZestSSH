import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../helpers/contract_run.dart';

/// Orchards and Crate sync against the REAL server routes
/// (ZestSSH Cloud's routes/orchards.js, routes/keys.js, the auth middleware)
/// on a real Postgres, so the app and the server agree on paths, fields,
/// limits and codes. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1). A Firebase ID token there is
/// `fb:<uid>:<authTime>:<iat>`.

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
  _Device(this.storage, this.service, this.coordinator, this.author);

  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;
  final CrateAuthor author;

  Future<AppDatabase> db(String orchardId) => coordinator.databases.open(orchardId);

  Future<CrateSyncEngine> engine(String orchardId) =>
      coordinator.engineFor(orchardId, author: author);

  Future<Object?> value(String orchardId, String sql) async =>
      (await (await db(orchardId)).customSelect(sql).getSingleOrNull())?.data.values.first;
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String token(String uid) => 'fb:$uid:${now()}:${now()}';

  setUpAll(() async {
    try {
      final r = await client
          .get(Uri.parse('$base/orchards'))
          .timeout(const Duration(seconds: 2));
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

  String skip() => 'app contract server not running at $base';

  var accounts = 0;

  /// A new account with published keys.
  Future<CrateAuthor> account() async {
    final uid = 'orchards-$contractRun-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  OrchardsApi api(CrateAuthor me) =>
      OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid));

  _Device device(CrateAuthor me) {
    final storage = _MemoryStorage();
    final databases = OrchardDatabasesNotifier(
      OrchardDatabaseKeys(const FlutterSecureStorage()),
      storage: storage,
    );
    final server = api(me);
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    final d = _Device(
      storage,
      service,
      OrchardSyncCoordinator(service: service, server: server, databases: databases),
      me,
    );
    devices.add(d);
    return d;
  }

  Future<void> addHost(AppDatabase db, String id, {String? icon}) async {
    final at = DateTime(2026, 9, 23);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: '10.0.0.1',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
          customIcon: Value(icon),
        ));
    await db.customStatement(
        "INSERT INTO connection_tags (connection_id, tag, created_at) VALUES (?, 'prod', 0)", [id]);
  }

  test('an Orchard made on one device syncs its items to the next', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final a = device(me);
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await addHost(await a.db(id), 'h-1');
    final sent = await a.coordinator.syncAll();
    expect(sent[id]!.sent, 1);
    expect(sent[id]!.rejected, 0);

    final b = device(me);
    final got = await b.coordinator.syncAll();
    expect(got[id]!.received, 1);
    expect(await b.value(id, 'SELECT name FROM orchard_info'), 'Acme');
    expect(await b.value(id, "SELECT tag FROM connection_tags WHERE connection_id = 'h-1'"),
        'prod');
    expect(await b.value(id, 'SELECT COUNT(*) FROM crate_outbox'), 0);
  });

  test('two edits: the newer wins on both devices, the other is kept in history', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final a = device(me);
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await addHost(await a.db(id), 'h-1');
    await a.coordinator.syncAll();
    final b = device(me);
    await b.coordinator.syncAll();

    final later = DateTime.now().millisecondsSinceEpoch + 600000;
    final aDb = await a.db(id);
    final bDb = await b.db(id);
    await aDb.customStatement("UPDATE connections SET label = 'from-a' WHERE id = 'h-1'");
    await aDb.customStatement('UPDATE crate_outbox SET edited_at = ?', [later]);
    await bDb.customStatement("UPDATE connections SET label = 'from-b' WHERE id = 'h-1'");
    await bDb.customStatement('UPDATE crate_outbox SET edited_at = ?', [later + 1000]);

    await a.coordinator.syncAll();
    final report = (await b.coordinator.syncAll())[id]!;
    expect(report.conflictsWon, 1);
    expect(report.historyFailed, 0);
    await a.coordinator.syncAll();
    expect(await a.value(id, "SELECT label FROM connections WHERE id = 'h-1'"), 'from-b');
    expect(await b.value(id, "SELECT label FROM connections WHERE id = 'h-1'"), 'from-b');

    // And the older, arriving second, goes to the history through the route.
    await aDb.customStatement("UPDATE connections SET label = 'late-a' WHERE id = 'h-1'");
    await aDb.customStatement('UPDATE crate_outbox SET edited_at = ?', [later + 5000]);
    await bDb.customStatement("UPDATE connections SET label = 'late-b' WHERE id = 'h-1'");
    await bDb.customStatement('UPDATE crate_outbox SET edited_at = ?', [later + 3000]);
    await a.coordinator.syncAll();
    final lost = (await b.coordinator.syncAll())[id]!;
    expect(lost.conflictsLost, 1);
    expect(lost.historyFailed, 0);
    expect(await b.value(id, "SELECT label FROM connections WHERE id = 'h-1'"), 'late-a');
  });

  test('a move to another Crate reaches the other device', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final a = device(me);
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await addHost(await a.db(id), 'h-1');
    await a.coordinator.syncAll();
    final b = device(me);
    await b.coordinator.syncAll();

    final staging = await a.service.createCrate(id, 'Staging');
    await (await a.engine(id)).moveItem('host', 'h-1', staging);
    await a.coordinator.syncAll();
    await b.coordinator.syncAll();
    expect(
        await b.value(id, "SELECT crate_id FROM crate_items_meta WHERE item_key = 'h-1'"), staging);
    expect(await b.value(id, "SELECT label FROM connections WHERE id = 'h-1'"), 'h-1');
  });

  test('a large item goes through the Crate write limit, not the 16 KB one', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final a = device(me);
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await addHost(await a.db(id), 'h-icon', icon: 'A' * (96 * 1024));
    final report = (await a.coordinator.syncAll())[id]!;
    expect(report.sent, 1);

    final b = device(me);
    await b.coordinator.syncAll();
    expect(
        (await b.value(id, "SELECT length(custom_icon) FROM connections WHERE id = 'h-icon'")),
        96 * 1024);
  });

  test('creating an Orchard again (the answer was lost) is a success', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final server = api(me);
    // Fresh ids: the contract server keeps its database between runs.
    final orchardId = const Uuid().v4();
    final crateId = const Uuid().v4();
    final orchardKey = newSpaceKey();
    final crateKey = newSpaceKey();
    final orchardSealed = await sealOrchardKey(me.keys.encryption.publicKey, orchardKey,
        orchardId: orchardId, generation: 1);
    final crateSealed = await sealCrateKey(me.keys.encryption.publicKey, crateKey,
        orchardId: orchardId, crateId: crateId, generation: 1);
    KeyCopyPlace own({String? crate}) => KeyCopyPlace(
          orchardId: orchardId,
          crateId: crate,
          generation: 1,
          recipient: me.uid,
          recipientKeyVersion: me.keys.version,
          sealer: me.uid,
          sealerKeyVersion: me.keys.version,
        );
    final body = NewOrchard(
      id: orchardId,
      nameEnc: await encryptOrchardName('Acme', orchardKey, orchardId: orchardId, generation: 1),
      keySealed: orchardSealed,
      keyVersion: me.keys.version,
      keySignature: await signKeyCopy(me.keys, own(), orchardSealed),
      firstCrate: FirstCrate(
        id: crateId,
        nameEnc: await encryptCrateName('Production', crateKey,
            orchardId: orchardId, crateId: crateId, generation: 1),
        keySealed: crateSealed,
        keySignature: await signKeyCopy(me.keys, own(crate: crateId), crateSealed),
      ),
      record: await signRecordEntry(me.keys,
          orchardId: orchardId,
          seq: 1,
          prev: const [],
          type: RecordTypes.create,
          by: me.uid,
          body: {
            'owner': {...recordKeysBody(await me.keys.publish(me.uid)), 'uid': me.uid},
            'key_commit': base64Encode(await keyCommitment(orchardKey, orchardId: orchardId, generation: 1)),
            'crate': {
              'id': crateId,
              'owners_only': false,
              'allow': ['forward', 'sftp'],
              'key_commit':
                  base64Encode(await keyCommitment(crateKey, orchardId: orchardId, crateId: crateId, generation: 1)),
            },
            'roles': const <Object?>[],
          }),
    );
    await server.createOrchard(body);
    await server.createOrchard(body);
    expect((await server.orchards()).map((o) => o.id), [orchardId]);
  });

  test('another account cannot see or write a Crate it is not in', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final a = device(me);
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final crateId = (await (await a.db(id))
            .customSelect('SELECT crate_id FROM orchard_crates')
            .getSingle())
        .read<String>('crate_id');

    final stranger = api(await account());
    expect(await stranger.orchards(), isEmpty);
    await expectLater(
      stranger.changes(crateId, since: 0),
      throwsA(isA<OrchardServerException>().having((e) => e.notFound, 'notFound', isTrue)),
    );
  });
}
