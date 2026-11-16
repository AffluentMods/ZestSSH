import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/account/device_sessions.dart';

import 'fake_stream_server.dart' show eventually;

/// The live line against the REAL server (ZestSSH Cloud's lib/stream.js,
/// with the auth middleware, routes/orchards.js and routes/sessions.js) on
/// a real Postgres: the app signs in the way the server expects, hears a
/// write made on another device and a change to its Orchards, and is closed
/// at once when it is signed out from elsewhere. Start the server first:
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

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final storages = <_MemoryStorage>[];
  final lines = <OrchardStream>[];

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

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    DeviceSessionHeader.current = null;
  });

  tearDown(() async {
    for (final line in lines) {
      await line.dispose();
    }
    lines.clear();
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  String skip() => 'app contract server not running at $base';

  var accounts = 0;

  Future<CrateAuthor> account() async {
    final uid = 'stream-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  (OrchardService, OrchardSyncCoordinator) device(CrateAuthor me) {
    final storage = _MemoryStorage();
    storages.add(storage);
    final databases = OrchardDatabasesNotifier(
      OrchardDatabaseKeys(const FlutterSecureStorage()),
      storage: storage,
    );
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid));
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    return (service, OrchardSyncCoordinator(service: service, server: server, databases: databases));
  }

  /// Another device's line, signed in as [uid], its events in [heard].
  OrchardStream line(String uid, List<OrchardStreamEvent> heard, {String? session}) {
    final l = OrchardStream(
      url: OrchardStream.urlFor(base),
      connect: (url) => WebSocket.connect(url.toString()),
      token: ({bool fresh = false}) async => token(uid),
      session: () => session,
      retryDelay: (_, _) => const Duration(seconds: 1),
    );
    l.events.listen(heard.add);
    lines.add(l);
    return l..start();
  }

  test('a write on one device reaches another device\'s line in seconds', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final (service, coordinator) = device(me);
    final orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await coordinator.syncAll();
    final db = await coordinator.databases.open(orchardId);
    final crateId = (await db.customSelect('SELECT crate_id FROM orchard_crates').getSingle())
        .read<String>('crate_id');

    final heard = <OrchardStreamEvent>[];
    line(me.uid, heard);
    await eventually(() => heard.whereType<StreamConnected>().isNotEmpty);

    final at = DateTime(2026, 9, 23);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-1',
          label: 'web',
          host: '10.0.0.1',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
    expect((await coordinator.syncOne(orchardId)).sent, 1);
    await eventually(() => heard.whereType<CrateChanged>().isNotEmpty);
    final changed = heard.whereType<CrateChanged>().first;
    expect(changed.crateId, crateId);
    final revision = (await db
            .customSelect('SELECT server_revision FROM crate_items_meta WHERE item_key = ?',
                variables: [const Variable<String>('h-1')])
            .getSingle())
        .read<int>('server_revision');
    expect(changed.revision, revision, reason: 'the revision the write got');

    // A new Crate changes the account's Orchards.
    await service.createCrate(orchardId, 'Staging');
    await eventually(() => heard.whereType<OrchardsChanged>().isNotEmpty);
  });

  test('another account hears nothing of it', () async {
    if (!serverUp) return markTestSkipped(skip());
    final me = await account();
    final stranger = await account();
    final heard = <OrchardStreamEvent>[];
    line(stranger.uid, heard);
    await eventually(() => heard.whereType<StreamConnected>().isNotEmpty);

    final (service, coordinator) = device(me);
    final orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final db = await coordinator.databases.open(orchardId);
    final at = DateTime(2026, 9, 23);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-1',
          label: 'web',
          host: '10.0.0.1',
          createdAt: at,
          updatedAt: at,
        ));
    await coordinator.syncAll();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(heard.whereType<CrateChanged>(), isEmpty);
    expect(heard.whereType<OrchardsChanged>(), isEmpty);
  });

  test('a sign-in the server does not accept is closed as not signed in', () async {
    if (!serverUp) return markTestSkipped(skip());
    final socket = await WebSocket.connect(OrchardStream.urlFor(base).toString());
    socket.add(jsonEncode({'type': 'auth', 'token': 'not-a-token'}));
    await socket.drain<void>().timeout(const Duration(seconds: 5));
    expect(socket.closeCode, OrchardStream.closeNotSignedIn);
  });

  test('a phone signed out from a desktop has its line closed at once', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = 'stream-${now()}-phone';
    final phoneToken = token(uid);
    final registered = await DeviceSessionsApi(client: client, baseUrl: base, bearer: () async => phoneToken)
        .register(const DeviceLabels(platform: 'android'));

    final heard = <OrchardStreamEvent>[];
    final phone = line(uid, heard, session: registered.token);
    await eventually(() => heard.whereType<StreamConnected>().isNotEmpty);

    final r = await client.post(Uri.parse('$base/auth/session'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'id_token': token(uid)}));
    expect(r.statusCode, 200, reason: r.body);
    final desktopToken = (jsonDecode(r.body) as Map<String, dynamic>)['session_token'] as String;
    await DeviceSessionsApi(client: client, baseUrl: base, bearer: () async => desktopToken)
        .signOut(registered.id);

    await eventually(() => heard.whereType<StreamSignedOut>().isNotEmpty);
    expect(phone.isRunning, isFalse);
  });
}
