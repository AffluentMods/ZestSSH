// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// ZestSSH Cloud restored from a backup, as the app's own way to it sees it
/// (3.0; see store_rolled_back_test.dart for what was wrong
/// and for the same held against a store of somebody's own).
///
/// The server here is played request by request: how it stands, what it
/// gives, what it takes and what it refuses, as the real one answers. It can
/// be put back to an earlier state, and it can be a server from before 3.0,
/// which does not say when it was written in its answer to a push.

Future<void> _addHost(AppDatabase db, String id) =>
    db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 10, 8)),
      updatedAt: Value(DateTime.utc(2026, 10, 8)),
    ));

/// What the server holds of one account.
class _Held {
  _Held(this.blob, this.salt, this.version, this.updatedAt, this.wrappedDek, this.params);

  final String blob;
  final String salt;
  final int version;
  final DateTime updatedAt;
  final String? wrappedDek;
  final Object? params;
}

/// ZestSSH Cloud's sync routes for one account.
class _Cloud {
  _Held? held;

  /// Whether the answer to a push says when the store was written (3.0).
  bool saysWhenWritten = true;

  /// The server's clock: a minute on at every write, so that no two writes
  /// are of the same moment.
  DateTime clock = DateTime.utc(2026, 10, 8, 9);

  int pushes = 0;
  int pulls = 0;

  http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    final now = held;
    if (path.endsWith('/sync/status')) {
      return _json({
        'has_data': now != null,
        'version': now?.version ?? 0,
        'blob_size': now == null ? 0 : now.blob.length,
        'updated_at': now?.updatedAt.toIso8601String(),
        'last_device': null,
        'has_recovery': false,
      });
    }
    if (path.endsWith('/sync/pull')) {
      if (now == null) return _json({'error': 'No sync data found'}, 404);
      pulls++;
      return _json({
        'encrypted_data': now.blob,
        'salt': now.salt,
        'version': now.version,
        'updated_at': now.updatedAt.toIso8601String(),
        'wrapped_dek_password': now.wrappedDek,
        'wrapped_dek_recovery': null,
        'recovery_salt': null,
        'argon2_params': now.params,
      });
    }
    if (path.endsWith('/sync/push')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final expected = body['expected_version'] as int?;
      if (now != null && (body['create_only'] == true || (expected != null && expected != now.version))) {
        return _json({'error': 'Version conflict', 'server_version': now.version, 'expected_version': expected ?? 0}, 409);
      }
      pushes++;
      clock = clock.add(const Duration(minutes: 1));
      final next = _Held(
        body['encrypted_data'] as String,
        now?.salt ?? body['salt'] as String,
        (now?.version ?? 0) + 1,
        clock,
        (body['wrapped_dek_password'] as String?) ?? now?.wrappedDek,
        now?.params ?? body['argon2_params'],
      );
      held = next;
      return _json({
        'success': true,
        'version': next.version,
        if (saysWhenWritten) 'updated_at': next.updatedAt.toIso8601String(),
      });
    }
    return _json({'error': 'not here'}, 404);
  }
}

class _Device {
  _Device(this.db, this.settings, this.sync);

  final AppDatabase db;
  final SettingsService settings;
  final AutoSyncService sync;

  Future<Set<String>> hosts() async => (await db.connectionsDao.getAll()).map((c) => c.id).toSet();

  Future<void> add(String id) async {
    await _addHost(db, id);
    await settings.setSyncDirty(true);
  }

  /// One sync as the app runs it by itself: what stopped it, or null.
  Future<String?> syncNow() async {
    await sync.triggerSync();
    return sync.activity.value.failure;
  }

  int get version => settings.syncServerVersion;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late _Cloud cloud;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  final devices = <_Device>[];

  setUpAll(() async {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    cloud = _Cloud();
    ZestServerBackend.debugHttpClient = MockClient(cloud.answer);
    devices.clear();
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
  });

  tearDown(() async {
    ZestServerBackend.debugHttpClient = null;
    for (final d in devices) {
      d.sync.dispose();
      await d.db.close();
    }
  });

  ZestServerBackend way() => ZestServerBackend(
        baseUrl: 'https://sync.northwind.example/v1',
        staticToken: 'demo-token',
        requiresEntitlement: false,
        kind: SyncBackendKind.custom,
      );

  Future<_Device> device() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final backend = way();
    final sync = AutoSyncService(
      syncDataService: memoryDataService(db, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
    );
    await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);
    final d = _Device(db, settings, sync);
    devices.add(d);
    return d;
  }

  Future<Set<String>> cloudHosts() async {
    final data = await SyncService.decrypt(base64Decode(cloud.held!.blob), dek);
    return (data['connections'] as List).map((c) => (c as Map)['id'] as String).toSet();
  }

  /// Device A with a1, a2 and a3 synced one after the other (the server at
  /// version 3), and what the server held when it had a1 alone.
  Future<(_Device, _Held)> threeVersions() async {
    final a = await device();
    await _addHost(a.db, 'a1');
    final v1 = await way().push(
      data: await memoryDataService(a.db, storage, a.settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    );
    await a.settings.setSyncServerVersion(v1.version, storeUpdatedAt: v1.updatedAt);
    expect(await a.syncNow(), isNull);
    final backup = cloud.held!;
    await a.add('a2');
    expect(await a.syncNow(), isNull);
    await a.add('a3');
    expect(await a.syncNow(), isNull);
    expect(cloud.held!.version, 3);
    expect(a.version, 3);
    expect(await cloudHosts(), {'a1', 'a2', 'a3'});
    return (a, backup);
  }

  /// Another device that had only what the backup held writes [hosts] to the
  /// restored server, one sync for each.
  Future<_Device> otherDeviceWrites(List<String> hosts) async {
    final c = await device();
    expect(await c.syncNow(), isNull);
    for (final host in hosts) {
      await c.add(host);
      expect(await c.syncNow(), isNull);
    }
    return c;
  }

  group('ZestSSH Cloud restored from a backup, behind a device', () {
    test('gets back what it lost at the next sync, with nothing changed on the device', () async {
      final (a, backup) = await threeVersions();
      cloud.held = backup;
      expect(await cloudHosts(), {'a1'});

      expect(await a.syncNow(), isNull);
      expect(await cloudHosts(), {'a1', 'a2', 'a3'});
      expect(cloud.held!.version, 2, reason: 'it counts on from where the backup was');
      expect(a.version, 2);
      expect(a.settings.syncStoreUpdatedAt, cloud.held!.updatedAt, reason: 'and the device knows the store it left');
      expect(a.settings.syncDirty, isFalse);
    });

    test('takes a change made on the device afterwards: the device is not left refused for ever', () async {
      final (a, backup) = await threeVersions();
      cloud.held = backup;
      await a.add('a4');
      expect(await a.syncNow(), isNull);
      expect(await cloudHosts(), {'a1', 'a2', 'a3', 'a4'});
      await a.add('a5');
      expect(await a.syncNow(), isNull);
      expect(await cloudHosts(), {'a1', 'a2', 'a3', 'a4', 'a5'});
      expect(a.version, cloud.held!.version);
    });

    test('what another device wrote to it since is merged, both ways', () async {
      final (a, backup) = await threeVersions();
      cloud.held = backup;
      final c = await otherDeviceWrites(['c1']);
      expect(cloud.held!.version, 2);

      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'c1'});
      expect(await cloudHosts(), {'a1', 'a2', 'a3', 'c1'});
      expect(await c.syncNow(), isNull);
      expect(await c.hosts(), {'a1', 'a2', 'a3', 'c1'});
    });
  });

  group('ZestSSH Cloud restored from a backup, back at a device\'s own count', () {
    test('is told from the store the device left by when it was written', () async {
      final (a, backup) = await threeVersions();
      final left = a.settings.syncStoreUpdatedAt;
      expect(left, cloud.held!.updatedAt, reason: 'the server said when, in its answer to the push');
      cloud.held = backup;
      await otherDeviceWrites(['c1', 'c2']);
      expect(cloud.held!.version, 3, reason: 'the very number device A is at');
      expect(cloud.held!.updatedAt, isNot(left));

      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'c1', 'c2'});
      expect(await cloudHosts(), {'a1', 'a2', 'a3', 'c1', 'c2'});
    });

    test('and is not written over by a device that has something to send', () async {
      final (a, backup) = await threeVersions();
      cloud.held = backup;
      await otherDeviceWrites(['c1', 'c2']);
      await a.add('a4');
      expect(await a.syncNow(), isNull);
      expect(await cloudHosts(), {'a1', 'a2', 'a3', 'a4', 'c1', 'c2'});
    });

    test('a server from before 3.0 does not say when it was written: the device learns it at its next look', () async {
      cloud.saysWhenWritten = false;
      final (a, backup) = await threeVersions();
      expect(a.settings.syncStoreUpdatedAt, isNull, reason: 'it sent last, and was not told when that was');

      // The next look finds the store level, and notes when it was written.
      final pulled = cloud.pulls;
      final pushed = cloud.pushes;
      expect(await a.syncNow(), isNull);
      expect(a.settings.syncStoreUpdatedAt, cloud.held!.updatedAt);
      expect(cloud.pulls, pulled, reason: 'nothing is fetched for it');
      expect(cloud.pushes, pushed, reason: 'and nothing sent');

      // From then on a store that comes back under the same count is told.
      cloud.held = backup;
      await otherDeviceWrites(['c1', 'c2']);
      expect(cloud.held!.version, 3);
      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'c1', 'c2'});
      expect(await cloudHosts(), {'a1', 'a2', 'a3', 'c1', 'c2'});
    });
  });

  group('ZestSSH Cloud where the device left it', () {
    test('is not fetched from and not written to, however often it is synced', () async {
      final (a, _) = await threeVersions();
      final pulled = cloud.pulls;
      final pushed = cloud.pushes;
      for (var i = 0; i < 3; i++) {
        expect(await a.syncNow(), isNull);
      }
      expect(cloud.pulls, pulled);
      expect(cloud.pushes, pushed);
      expect(a.version, 3);
    });

    test('the same goes for a server that does not say when it was written', () async {
      cloud.saysWhenWritten = false;
      final (a, _) = await threeVersions();
      final pulled = cloud.pulls;
      final pushed = cloud.pushes;
      for (var i = 0; i < 3; i++) {
        expect(await a.syncNow(), isNull);
      }
      expect(cloud.pulls, pulled);
      expect(cloud.pushes, pushed);
    });

    test('another device\'s work is fetched as before, and nothing is sent back', () async {
      final (a, _) = await threeVersions();
      final b = await device();
      expect(await b.syncNow(), isNull);
      await b.add('b1');
      expect(await b.syncNow(), isNull);
      final pushed = cloud.pushes;

      expect(await a.syncNow(), isNull);
      expect(await a.hosts(), {'a1', 'a2', 'a3', 'b1'});
      expect(cloud.pushes, pushed);
      expect(a.version, 4);
      expect(a.settings.syncStoreUpdatedAt, cloud.held!.updatedAt);
    });
  });
}
