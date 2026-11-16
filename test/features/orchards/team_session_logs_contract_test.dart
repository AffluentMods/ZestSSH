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
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Team session logs (3.0) against the REAL server routes on a real
/// Postgres: an owner's crate.set session_logs goes into the record the
/// server checks, a member's device logs a session in sealed chunks the
/// server takes in order, the owner reads it back whole and redacted, a
/// member who only uses the Crate reads nothing, the owner deletes one, and
/// turning session logs off deletes the rest and stops the writer.
/// Start the server:
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

/// The line to the server, as a test cuts it: [down], no request leaves, as
/// when the server cannot be reached; [lose], one entry for each request
/// from now on, true where the request goes through and its answer is
/// lost on the way back.
class _Line extends http.BaseClient {
  _Line(this._inner);

  final http.Client _inner;
  var down = false;
  final lose = <bool>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (down) throw const SocketException('Connection refused');
    final response = await _inner.send(request);
    if (lose.isNotEmpty && lose.removeAt(0)) {
      await response.stream.drain<void>();
      throw const SocketException('Connection closed before the answer arrived');
    }
    return response;
  }
}

class _Device {
  _Device(this.storage, this.service, this.coordinator);

  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;
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
    final uid = 'slog-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  _Device device(CrateAuthor me, {http.Client? line}) {
    final storage = _MemoryStorage();
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server = OrchardsApi(client: line ?? client, baseUrl: base, bearer: () async => token(me.uid));
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    final d = _Device(storage, service, OrchardSyncCoordinator(service: service, server: server, databases: databases));
    devices.add(d);
    return d;
  }


  test('session logs through the real routes: sealed, in order, read back redacted, deleted, stopped when off', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final o = device(owner);
    final id = await o.service.createOrchard('Logs', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = (await o.service.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final role = (await o.service.roles(id)).single.id;
    await o.service.invite(id, email: '${alice.uid}@example.com', role: role);
    final a = device(alice);
    await a.service.acceptInvite((await a.service.myInvites()).single.id);
    await o.service.confirmInvite(id, (await o.service.invites(id)).single);
    await a.coordinator.syncAll();

    // Off: none is started.
    expect(await a.service.startTeamSessionLog(id, crate, label: 'Web 1', host: 'web1.example.com', port: 22), isNull);

    await o.service.setCrateSessionLogs(id, crate, true);
    await a.coordinator.syncAll();
    final writer = (await a.service.startTeamSessionLog(id, crate,
        label: 'Web 1', host: 'web1.example.com', port: 22, user: 'deploy',
        flushEvery: const Duration(hours: 1), flushAtBytes: 1 << 20))!;
    writer.addSecret('pa55word-typed');
    writer.append('\x1b[32m\$\x1b[0m mysql -ppa55word-typed\r\n');
    await writer.flush();
    writer.append('Welcome\r\nAKIAABCDEFGHIJKLMNOP\r\n');
    await writer.close();
    expect(writer.waiting, 0, reason: 'everything was taken');

    final page = await o.service.teamSessionLogs(id, crate);
    final entry = page.entries.single;
    expect((entry.header.uid, entry.header.label, entry.header.user, entry.closed), (alice.uid, 'Web 1', 'deploy', true));
    final text = await o.service.teamSessionLogText(id, crate, entry);
    expect(text.complete, isTrue);
    expect(text.text, '\$ mysql -p[redacted]\nWelcome\n[redacted]\n');
    await expectLater(a.service.teamSessionLogs(id, crate),
        throwsA(isA<OrchardServerException>().having((e) => e.need, 'need', 'manage')));

    // The owner deletes it.
    await o.service.deleteTeamSessionLog(crate, entry.id);
    expect((await o.service.teamSessionLogs(id, crate)).entries, isEmpty);

    // Off while a session runs: the writer stops, and the logs are gone.
    final second = (await a.service.startTeamSessionLog(id, crate,
        label: 'Web 1', host: 'web1.example.com', port: 22,
        flushEvery: const Duration(hours: 1), flushAtBytes: 1 << 20))!;
    second.append('one\n');
    await second.flush();
    await o.service.setCrateSessionLogs(id, crate, false);
    second.append('two\n');
    await second.flush();
    expect(second.stopped, isTrue);
    await expectLater(o.service.teamSessionLogs(id, crate), completion(isA<TeamSessionLogPage>()));
    expect((await o.service.teamSessionLogs(id, crate)).entries, isEmpty);
  });

  test('kept on the device while the server cannot be reached, then through the real routes: whole and in order, '
      'nothing doubled where an answer was lost, and under the key the session was sealed with', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final o = device(owner);
    final id = await o.service.createOrchard('Logs', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = (await o.service.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final role = (await o.service.roles(id)).single.id;
    await o.service.invite(id, email: '${alice.uid}@example.com', role: role);
    final line = _Line(client);
    final a = device(alice, line: line);
    await a.service.acceptInvite((await a.service.myInvites()).single.id);
    await o.service.confirmInvite(id, (await o.service.invites(id)).single);
    await o.service.setCrateSessionLogs(id, crate, true);
    await a.coordinator.syncAll();
    Future<TeamSessionLogEntry> onServer(String logId) async =>
        (await o.service.teamSessionLogs(id, crate)).entries.firstWhere((e) => e.id == logId);

    // The server cannot be reached as the session starts, while it runs
    // and as it ends.
    line.down = true;
    final writer = (await a.service.startTeamSessionLog(id, crate,
        label: 'Web 1', host: 'web1.example.com', port: 22, user: 'deploy',
        flushEvery: const Duration(hours: 1), flushAtBytes: 1 << 20))!;
    writer.append('first\n');
    await writer.flush();
    writer.append('second\n');
    await writer.close();
    expect((writer.waiting, writer.stopped, await a.service.sessionLogsWaiting(id)), (3, false, 1));
    expect((await o.service.teamSessionLogs(id, crate)).entries, isEmpty);

    // Meanwhile the Crate's key moves on: the log is sealed with the one
    // before it.
    expect(await o.service.rotateAll(), isEmpty);
    line.down = false;

    // The server takes the log's start, and its answer never arrives.
    line.lose.add(true);
    expect(await a.service.sessionLogRound(id), 0);
    expect(((await onServer(writer.logId)).chunks, await a.service.sessionLogsWaiting(id)), (0, 1));
    // The start again (answered as taken), then the first chunk, whose
    // answer never arrives either.
    line.lose.addAll([false, true]);
    expect(await a.service.sessionLogRound(id), 0);
    expect((await onServer(writer.logId)).chunks, 1);

    // The sync that brings the new key sends the rest (in a round it
    // starts and does not wait for): the first chunk is answered as taken
    // and is there once.
    await a.coordinator.syncAll();
    await a.service.debugSessionLogRound(id);
    final entry = await onServer(writer.logId);
    expect((entry.chunks, entry.closed, entry.keyGeneration, entry.header.label), (3, true, 1, 'Web 1'));
    final text = await o.service.teamSessionLogText(id, crate, entry);
    expect((text.text, text.complete), ('first\nsecond\n', true));
    expect(await a.service.sessionLogsWaiting(id), 0);
    expect((await o.service.teamSessionLogs(id, crate)).entries, hasLength(1));

    // A session after that is sealed with the key the Crate has now.
    final next = (await a.service.startTeamSessionLog(id, crate, label: 'Web 1', host: 'web1.example.com', port: 22))!;
    await next.close();
    expect((await onServer(next.logId)).keyGeneration, 2);
  });
}
