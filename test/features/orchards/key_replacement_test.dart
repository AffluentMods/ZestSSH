import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/key_replacement.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'fake_crate_server.dart';

/// Replacing the account's keys after a device was lost (3.0):
/// the keys and every key copy change together, the Orchard and Crate keys
/// move on, every item is written again with the new keys, a device still on
/// the old keys can no longer write, and anything the old key signs from
/// then on is refused. Interruptions are carried on, never half-applied.

const _uid = 'owner-1';

/// /v1/keys with the rules of ZestSSH Cloud's routes/keys.js: self-signed
/// keys, exactly the next version, a valid endorsement when one is sent,
/// every copy signed by the new keys, and the copies replaced (by the Crate
/// server) together with the keys or not at all.
class _KeyServer {
  _KeyServer(this.crates);

  final FakeCrateServer crates;
  PublishedAccountKeys? published;
  bool needsRecentSignIn = false;

  /// Runs before a replacement is applied (something changing meanwhile).
  Future<void> Function()? beforeReplace;

  /// Applies the replacement, then fails as a lost answer would.
  bool loseReplaceAnswer = false;

  late final client = MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/keys/me')) {
      final p = published;
      if (p == null) return _json(404, {'code': 'no-keys', 'uid': _uid});
      return _json(200, {'uid': _uid, ...p.toJson(), 'endorsement': _b64(p.endorsement)});
    }
    if (request.method == 'POST' && path.endsWith('/keys')) {
      final keys = PublishedAccountKeys.fromJson(_uid, jsonDecode(request.body));
      if (!await keys.verify() || keys.version != 1) return _json(400, {'code': 'invalid-keys'});
      published ??= keys;
      return _json(201, {'published': true});
    }
    if (request.method == 'PUT' && path.endsWith('/keys')) return _replace(request);
    return _json(404, {});
  });

  Future<http.Response> _replace(http.Request request) async {
    if (needsRecentSignIn) return _json(403, {'code': 'recent-sign-in-required'});
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final next = PublishedAccountKeys.fromJson(_uid, body);
    final current = published!;
    if (!await next.verify()) return _json(400, {'code': 'bad-signature'});
    if (next.version != current.version + 1) return _json(409, {'code': 'version-conflict'});
    if (next.endorsement != null && !await next.endorsedBy(current)) {
      return _json(400, {'code': 'bad-endorsement'});
    }
    final copies = <ResealedKeyCopy>[
      for (final c in (body['copies']['orchards'] as List).cast<Map<String, dynamic>>())
        ResealedKeyCopy(
            orchardId: c['orchard_id'] as String,
            generation: c['generation'] as int,
            sealed: base64Decode(c['sealed'] as String),
            signature: base64Decode(c['signature'] as String)),
      for (final c in (body['copies']['crates'] as List).cast<Map<String, dynamic>>())
        ResealedKeyCopy(
            orchardId: crates.orchardsById.values
                .firstWhere((o) => o.crates.any((k) => k.id == c['crate_id']))
                .id,
            crateId: c['crate_id'] as String,
            generation: c['generation'] as int,
            sealed: base64Decode(c['sealed'] as String),
            signature: base64Decode(c['signature'] as String)),
    ];
    for (final c in copies) {
      final place = KeyCopyPlace(
        orchardId: c.orchardId,
        crateId: c.crateId,
        generation: c.generation,
        recipient: _uid,
        recipientKeyVersion: next.version,
        sealer: _uid,
        sealerKeyVersion: next.version,
      );
      if (!await verifyKeyCopy(next.signingKey, place, c.sealed, c.signature)) {
        return _json(400, {'code': 'bad-signature'});
      }
    }
    final hook = beforeReplace;
    beforeReplace = null;
    if (hook != null) await hook();
    final records = <String, Map<String, dynamic>>{
      if (body['records'] is Map)
        for (final e in (body['records'] as Map).entries) e.key as String: (e.value as Map).cast<String, dynamic>(),
    };
    try {
      await crates.replaceOwnCopies(next.version, copies, records: records);
    } on AccountKeysReplaceConflict catch (e) {
      return _json(409, {'code': e.code});
    } on AccountKeysRecordsNeeded catch (e) {
      return _json(409, {
        'code': 'records-changed',
        'heads': [
          for (final h in e.heads.entries) {'orchard_id': h.key, 'seq': h.value.seq, 'head': base64Encode(h.value.hash)},
        ],
      });
    }
    published = next;
    if (loseReplaceAnswer) {
      loseReplaceAnswer = false;
      throw http.ClientException('connection reset');
    }
    return _json(200, {'published': true});
  }

  static String? _b64(Uint8List? bytes) => bytes == null ? null : base64Encode(bytes);

  static http.Response _json(int status, Object body) => http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json'});
}

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
  _Device(this.storage, this.service, this.sync);

  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator sync;

  Future<AppDatabase> db(String id) => service.databases.open(id);

  Future<List<Map<String, Object?>>> rows(String id, String sql) async =>
      [for (final r in await (await db(id)).customSelect(sql).get()) r.data];
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
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeCrateServer crates;
  late _KeyServer keyServer;
  late AccountKeyService keyService;
  late AccountKeyStore store;
  late _MemoryProgress progress;
  final devices = <_Device>[];
  var keysChanged = 0;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    crates = FakeCrateServer(accountUid: _uid);
    keyServer = _KeyServer(crates);
    store = AccountKeyStore(const FlutterSecureStorage());
    keyService = AccountKeyService(
      api: AccountKeysApi(
          client: keyServer.client, baseUrl: 'https://keys.test/v1', bearer: () async => 't'),
      store: store,
      onKeysChanged: () => keysChanged++,
    );
    progress = _MemoryProgress();
    keysChanged = 0;
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
  });

  tearDown(() async {
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  /// A device of this account. [author] defaults to whatever keys this
  /// account holds now (asked each time, as after the cache is forgotten).
  _Device device({Future<CrateAuthor?> Function()? author}) {
    final storage = _MemoryStorage();
    final databases = OrchardDatabasesNotifier(
      OrchardDatabaseKeys(const FlutterSecureStorage()),
      storage: storage,
    );
    final service = OrchardService(
      server: crates,
      databases: databases,
      author: author ??
          () async {
            final ready = await keyService.readyKeys();
            return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
          },
    );
    final d = _Device(storage, service,
        OrchardSyncCoordinator(service: service, server: crates, databases: databases));
    devices.add(d);
    return d;
  }

  KeyReplacement replacement(_Device d) => KeyReplacement(
        keys: keyService,
        orchards: d.service,
        sync: d.sync,
        progress: progress,
        forgetAuthor: () {},
      );

  Future<void> addHost(_Device d, String orchardId, String id, String label) async {
    final db = await d.db(orchardId);
    final now = DateTime(2026, 9, 24);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: '10.0.0.1',
          port: const Value(22),
          createdAt: now,
          updatedAt: now,
        ));
  }

  /// An Orchard with two Crates and a host synced, on device [a].
  Future<(String orchardId, String prod, String staging)> orchard(_Device a) async {
    final id = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await a.service.createCrate(id, 'Staging');
    final prod = (await a.rows(id, "SELECT crate_id FROM orchard_crates WHERE name = 'Production'"))
        .single['crate_id'] as String;
    await addHost(a, id, 'h-1', 'prod-web');
    final report = (await a.sync.syncAll())[id]!;
    expect(report.sent, 1);
    return (id, prod, staging);
  }

  test('keys, copies, Orchard and Crate keys and every item move to the new keys', () async {
    final a = device();
    final (id, prod, staging) = await orchard(a);
    final old = (await keyService.readyKeys())!.keys;

    final report = await replacement(a).run();
    expect(report.keyVersion, 2);
    expect(report.copiesResealed, 3, reason: 'the Orchard key and two Crate keys, generation 1');
    expect(report.complete, isTrue, reason: '${report.left}');
    expect(progress.value, isNull, reason: 'nothing left to carry on');

    // Published with the old key's endorsement; this device switched over.
    final published = keyServer.published!;
    expect(published.version, 2);
    expect(await published.endorsedBy(await old.publish(_uid)), isTrue);
    expect((await store.read(_uid))!.state, StoredKeyState.confirmed);
    expect((await store.read(_uid))!.version, 2);
    expect((await store.readPrevious(_uid))!.version, 1);
    expect((await store.readPrevious(_uid))!.state, StoredKeyState.superseded);
    expect(await store.readNext(_uid), isNull);
    expect(keysChanged, greaterThan(0), reason: 'sync carries the new keys to other devices');

    // New Orchard and Crate keys, every copy sealed to version 2.
    expect(crates.rotations.toSet(), {'orchard:$id', 'crate:$prod', 'crate:$staging'});
    final o = crates.orchardsById[id]!;
    expect(o.keyGeneration, 2);
    for (final k in [...o.keys, for (final c in o.crates) ...c.keys]) {
      expect(k.recipientKeyVersion, 2);
      expect(k.sealerKeyVersion, 2);
    }
    expect(await a.rows(id, 'SELECT key_generation FROM orchard_crates'),
        everyElement(containsPair('key_generation', 2)));

    // The host was written again under the new Crate key.
    final hostItem = crates.items[prod]!.values.single;
    expect(hostItem.item!.keyGeneration, 2);

    // A fresh device with the new keys reads everything.
    final b = device();
    final got = (await b.sync.syncAll())[id]!;
    expect(got.rejected, 0);
    expect((await b.rows(id, 'SELECT label FROM connections')).single['label'], 'prod-web');
    expect((await b.rows(id, 'SELECT name FROM orchard_info')).single['name'], 'Acme');
    // Every generation of every key still opens with the new keys: older
    // items, the history and item ids need them.
    final keysOnB = await b.rows(id, 'SELECT scope, scope_id, generation FROM space_keys');
    expect(
      {for (final k in keysOnB) '${k['scope']}:${k['scope_id']}:${k['generation']}'},
      {
        for (final g in [1, 2]) ...{
          'orchard:$id:$g',
          'crate:$prod:$g',
          'crate:$staging:$g',
        },
      },
    );
  });

  test('a device still on the old keys cannot write, and what the old key signs is refused',
      () async {
    final a = device();
    final (id, prod, _) = await orchard(a);
    final old = (await keyService.readyKeys())!.keys;
    // The lost device: it has the Orchard and signs with the old keys.
    final lost = device(author: () async => CrateAuthor(uid: _uid, keys: old));
    await lost.sync.syncAll();
    final before = crates.items[prod]!.values.single.revision;

    // Step 1 only: the keys and copies change, the Crate keys have not moved
    // yet. The lost device's write is refused by the server all the same.
    await keyService.replaceKeys(reseal: a.service.resealAll, records: memberKeysRecords(a.service));
    await (await lost.db(id))
        .customStatement("UPDATE connections SET label = 'evil' WHERE id = 'h-1'");
    final refused = (await lost.sync.syncAll())[id]!;
    expect(refused.staleAccountKeys, isTrue);
    expect(crates.items[prod]!.values.single.revision, before, reason: 'nothing reached the server');
    final forged = crates.writeCalls.last.single.item; // signed with the old key

    // Steps 2 and 3. Now it cannot even open the Crate's new key.
    await progress.write(const KeyReplacementProgress(uid: _uid, version: 2));
    expect(await replacement(a).finish(), isEmpty);
    final afterRotation = (await lost.sync.syncAll())[id]!;
    expect(afterRotation.needsKeys, isTrue);
    expect(crates.items[prod]!.values.single.item!.keyGeneration, 2);

    // A server that stores the old key's version anyway: every device with
    // the new keys refuses it.
    crates.forceItem(prod, forged);
    final b = device();
    final got = (await b.sync.syncAll())[id]!;
    expect(got.rejected, 1);
    expect(await b.rows(id, 'SELECT label FROM connections'), isEmpty,
        reason: 'the forged version was refused (it had replaced the good one on the server)');
    final onA = (await a.sync.syncAll())[id]!;
    expect(onA.rejected, 1);
    expect((await a.rows(id, 'SELECT label FROM connections')).single['label'], 'prod-web');
  });

  test('a sign-in that is not recent stops it before anything changes, and the retry uses the same new keys',
      () async {
    final a = device();
    await orchard(a);
    keyServer.needsRecentSignIn = true;
    await expectLater(replacement(a).run(), throwsA(isA<AccountKeysNeedRecentSignIn>()));
    expect(keyServer.published!.version, 1);
    expect((await store.read(_uid))!.version, 1);
    expect(crates.accountKeyVersion, 1);
    final pending = await store.readNext(_uid);
    expect(pending!.state, StoredKeyState.pending);

    keyServer.needsRecentSignIn = false;
    final report = await replacement(a).run();
    expect(report.keyVersion, 2);
    final next = await AccountKeys.fromSecretJson(pending.secret);
    expect(keyServer.published!.signingKey, next.signingPublicKey,
        reason: 'the keys made the first time, which may already have reached the server');
  });

  test('keys the server took but whose answer was lost are switched to on the next check',
      () async {
    final a = device();
    await orchard(a);
    keyServer.loseReplaceAnswer = true;
    await expectLater(replacement(a).run(), throwsA(isA<http.ClientException>()));
    expect(keyServer.published!.version, 2, reason: 'the server took them');
    expect((await store.read(_uid))!.version, 1, reason: 'this device never heard');
    expect(await store.readNext(_uid), isNotNull);

    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    expect((await store.read(_uid))!.version, 2);
    expect((await store.read(_uid))!.state, StoredKeyState.confirmed);
    expect((await store.readPrevious(_uid))!.version, 1);
    expect(await store.readNext(_uid), isNull);
  });

  test('pressing it again after a lost answer finishes that replacement, not a second one',
      () async {
    final a = device();
    await orchard(a);
    keyServer.loseReplaceAnswer = true;
    await expectLater(replacement(a).run(), throwsA(isA<http.ClientException>()));

    final report = await replacement(a).run();
    expect(report.keyVersion, 2);
    expect(keyServer.published!.version, 2, reason: 'no version 3');
    expect(report.complete, isTrue, reason: '${report.left}');
    expect(crates.rotations, hasLength(3), reason: 'the follow-up ran');
  });

  test('copies that changed meanwhile fail the replacement whole; the retry takes them in',
      () async {
    final a = device();
    final (id, _, _) = await orchard(a);
    keyServer.beforeReplace = () => a.service.createCrate(id, 'Added meanwhile');
    await expectLater(replacement(a).run(),
        throwsA(isA<AccountKeysReplaceConflict>().having((e) => e.copiesChanged, 'copies', isTrue)));
    expect(keyServer.published!.version, 1);
    expect(crates.accountKeyVersion, 1);
    expect(crates.orchardsById[id]!.crates.expand((c) => c.keys),
        everyElement(predicate<dynamic>((k) => k.recipientKeyVersion == 1)));

    final report = await replacement(a).run();
    expect(report.copiesResealed, 4);
    expect(report.complete, isTrue);
  });

  test('an interrupted follow-up carries on where it stopped, without moving a key twice',
      () async {
    final a = device();
    final (id, prod, staging) = await orchard(a);
    crates.failRotationOnce.add('crate:$staging');
    final report = await replacement(a).run();
    expect(report.left, contains('crate:$staging'));
    expect(progress.value!.done, containsAll(['orchard:$id', 'crate:$prod']));

    expect(await replacement(a).finish(), isEmpty);
    expect(progress.value, isNull);
    expect(crates.rotations, ['orchard:$id', 'crate:$prod', 'crate:$staging'],
        reason: 'each key moved once');
  });
}
