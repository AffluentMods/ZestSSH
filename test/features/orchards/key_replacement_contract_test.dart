import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/key_replacement.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';

/// Replacing account keys against the REAL server routes (ZestSSH Cloud's
/// routes/keys.js PUT, routes/orchards.js rotations and item writes) on a
/// real Postgres: the keys and every copy change in one statement, the
/// Orchard and Crate keys move on, every item is written again, and the old
/// keys can no longer write. Start the server first:
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

class _MemoryProgress implements KeyReplacementProgressStore {
  KeyReplacementProgress? value;

  @override
  Future<KeyReplacementProgress?> read() async => value;

  @override
  Future<void> write(KeyReplacementProgress progress) async => value = progress;

  @override
  Future<void> clear() async => value = null;
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // Signed in just now: replacing keys needs a recent sign-in.
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

  test('a key replacement end to end, with the real routes', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final uid = 'replace-${now()}';
    final keysApi = AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid));
    final keyService = AccountKeyService(
      api: keysApi,
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final crateApi = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(uid));

    (OrchardService, OrchardSyncCoordinator) device(Future<CrateAuthor?> Function() author) {
      final storage = _MemoryStorage();
      opened.add(storage);
      final databases = OrchardDatabasesNotifier(
          OrchardDatabaseKeys(const FlutterSecureStorage()),
          storage: storage);
      final service = OrchardService(server: crateApi, databases: databases, author: author);
      return (service, OrchardSyncCoordinator(service: service, server: crateApi, databases: databases));
    }

    Future<CrateAuthor?> current() async {
      final ready = await keyService.readyKeys();
      return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
    }

    final (aService, aSync) = device(current);
    final orchardId = await aService.createOrchard('Contract', firstCrateName: 'Production', memberRoleName: 'Member');
    await aService.createCrate(orchardId, 'Staging');
    final aDb = await aService.databases.open(orchardId);
    final at = DateTime(2026, 9, 24);
    await aDb.into(aDb.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'prod-web', host: '10.0.0.1', port: const Value(22), createdAt: at, updatedAt: at));
    expect((await aSync.syncAll())[orchardId]!.sent, 1);

    final old = (await keyService.readyKeys())!.keys;
    final (lostService, lostSync) = device(() async => CrateAuthor(uid: uid, keys: old));
    await lostSync.syncAll();

    final report = await KeyReplacement(
      keys: keyService,
      orchards: aService,
      sync: aSync,
      progress: _MemoryProgress(),
      forgetAuthor: () {},
    ).run();
    expect(report.keyVersion, 2);
    expect(report.copiesResealed, 3);
    expect(report.complete, isTrue, reason: '${report.left}');

    // The server publishes the new keys with the old key's endorsement.
    final mine = (await keysApi.mine())!.published!;
    expect(mine.version, 2);
    expect(await mine.endorsedBy(await old.publish(uid)), isTrue);

    // It lists new Orchard and Crate keys, every copy sealed to version 2.
    final listed = (await crateApi.orchards()).single;
    expect(listed.keyGeneration, 2);
    for (final c in listed.crates) {
      expect(c.keyGeneration, 2);
    }
    for (final k in [...listed.keys, for (final c in listed.crates) ...c.keys]) {
      expect(k.recipientKeyVersion, 2);
      expect(k.sealerKeyVersion, 2);
      expect(k.sealedBy, uid);
    }

    // A new device with the new keys reads everything, all generations.
    final (bService, bSync) = device(current);
    final got = (await bSync.syncAll())[orchardId]!;
    expect(got.rejected, 0);
    final bDb = await bService.databases.open(orchardId);
    expect((await bDb.customSelect('SELECT label FROM connections').getSingle()).read<String>('label'),
        'prod-web');
    expect((await bDb.customSelect('SELECT COUNT(*) AS n FROM space_keys').getSingle()).read<int>('n'), 6);

    // The lost device can no longer write.
    final lostDb = await lostService.databases.open(orchardId);
    await lostDb.customStatement("UPDATE connections SET label = 'evil' WHERE id = 'h-1'");
    final refused = (await lostSync.syncAll())[orchardId]!;
    expect(refused.sent, 0);
    expect(refused.needsKeys || refused.staleAccountKeys, isTrue);
    await bSync.syncAll();
    expect((await bDb.customSelect('SELECT label FROM connections').getSingle()).read<String>('label'),
        'prod-web');
  });

  test('a device on the old keys gets stale-account-keys from the real item route', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final uid = 'replace-stale-${now()}';
    final keysApi = AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid));
    final keyService = AccountKeyService(
        api: keysApi, store: AccountKeyStore(const FlutterSecureStorage()), onKeysChanged: () {});
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final crateApi = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(uid));
    final storage = _MemoryStorage();
    opened.add(storage);
    final databases = OrchardDatabasesNotifier(
        OrchardDatabaseKeys(const FlutterSecureStorage()),
        storage: storage);
    final old = (await keyService.readyKeys())!.keys;
    final service = OrchardService(
        server: crateApi, databases: databases, author: () async => CrateAuthor(uid: uid, keys: old));
    final sync = OrchardSyncCoordinator(service: service, server: crateApi, databases: databases);
    final orchardId = await service.createOrchard('Stale', firstCrateName: 'Production', memberRoleName: 'Member');

    // Only the keys change (no rotation yet), from another "device".
    final otherStorage = _MemoryStorage();
    opened.add(otherStorage);
    final other = OrchardService(
      server: crateApi,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()),
          storage: otherStorage),
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    await keyService.replaceKeys(reseal: other.resealAll, records: memberKeysRecords(other));

    final db = await databases.open(orchardId);
    final at = DateTime(2026, 9, 24);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-2', label: 'late', host: '10.0.0.2', port: const Value(22), createdAt: at, updatedAt: at));
    final report = (await sync.syncOne(orchardId))..toString();
    expect(report.staleAccountKeys, isTrue);
    expect(report.sent, 0);
  });
}
