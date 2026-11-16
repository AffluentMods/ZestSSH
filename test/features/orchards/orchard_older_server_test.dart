import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';

/// The team pages' refresh against a server a deploy behind this app and
/// against one that is not (in a test build the Members
/// page said only "The members could not be loaded."). Mixed versions are
/// normal during a deploy, and a new app must never break against a server
/// one deploy behind: there the restore routes are not (a "Not found"
/// with no code), the record comes with no receipt, and a Crate with no head.
/// The same against the real routes of both: run the Orchard contract tests
/// with ZESTSSH_TEST_API naming a stand-in server of each.

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

class _Device {
  _Device(this.storage, this.databases, this.service, this.coordinator);

  final _MemoryStorage storage;
  final OrchardDatabasesNotifier databases;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => databases.open(orchardId);

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get()) r.data.values.join(':'),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys keys;
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    keys = await AccountKeys.generate();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer();
  });

  tearDown(() async {
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  _Device device() {
    final storage = _MemoryStorage();
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final service =
        OrchardService(server: server, databases: databases, author: () async => CrateAuthor(uid: 'owner-1', keys: keys));
    final d = _Device(storage, databases, service, OrchardSyncCoordinator(service: service, server: server, databases: databases));
    devices.add(d);
    return d;
  }

  test('a server a deploy behind: the refresh, the sync and the members work as before the restore work', () async {
    server.olderServer = true;
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    expect(await a.service.refresh(), [o]);
    await a.coordinator.syncAll();
    final people = await a.service.people(o);
    expect(people.members.map((m) => m.uid), ['owner-1']);
    expect(await LocalStateStore(await a.db(o)).read(kRecordReceiptState), isNull, reason: 'it gives none');
    expect(await a.rows(o, "SELECT COALESCE(record_problem, '') FROM orchard_info"), ['']);
    expect(server.holdsAsked, 0, reason: 'nothing asked of a route it does not have while the team is listed');
  });

  test('a server a deploy behind no longer lists a team: it stays, held, as nothing checked says this account is out',
      () async {
    server.olderServer = true;
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final b = device();
    expect(await b.service.refresh(), [o]);

    server.hidden.add(o);
    expect(await b.service.refresh(), isEmpty);
    expect(server.holdsAsked, 1, reason: 'asked once, and the server has no such question');
    // The server's word alone: its person is asked.
    expect(b.storage.deleted, isEmpty);
    expect(await b.rows(o, 'SELECT status FROM orchard_info'), [kUnlistedStatus]);
  });

  test('a server that is not behind no longer lists a team: it stays, held, too', () async {
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final b = device();
    await b.service.refresh();
    server.hidden.add(o);
    expect(await b.service.refresh(), isEmpty);
    expect(b.storage.deleted, isEmpty);
    expect(await b.rows(o, 'SELECT status FROM orchard_info'), [kUnlistedStatus]);
  });

  test('a question the server could not answer takes nothing off the device', () async {
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final b = device();
    await b.service.refresh();
    server.hidden.add(o);
    for (final fail in [
      const OrchardServerException(503, null),
      // The route is there and found nothing it could say about.
      const OrchardServerException(404, 'not-found'),
    ]) {
      server.holdsFail = fail;
      expect(await b.service.refresh(), isEmpty);
      expect(b.storage.deleted, isEmpty, reason: '$fail: asked again at the next refresh');
    }
    server.holdsFail = null;
    await b.service.refresh();
    expect(b.storage.deleted, isEmpty);
    expect(await b.rows(o, 'SELECT status FROM orchard_info'), [kUnlistedStatus]);
  });

  test('refreshes at once (the Members page and the sync) never take a listed team off the device', () async {
    final a = device();
    final ids = [
      for (var i = 0; i < 3; i++)
        await a.service.createOrchard('Team $i', firstCrateName: 'Production', memberRoleName: 'Member'),
    ];
    await a.service.refresh();
    // The second reads the list once the first has asked for the last
    // team's record, so that it starts over (clearing what it knows of the
    // list) while the first goes through the teams on the device: where the
    // first took what the second had cleared for teams no longer listed, it
    // took two listed teams off the device under the second.
    final firstAtLast = Completer<void>();
    final start = server.recordReads;
    server.onRecordRead = (reads) {
      if (reads == start + ids.length && !firstAtLast.isCompleted) firstAtLast.complete();
    };
    var lists = 0;
    server.beforeOrchards = () async {
      if (++lists == 2) await firstAtLast.future;
    };
    final results = await Future.wait([a.service.refresh(), a.service.refresh()]);
    for (final r in results) {
      expect(r.toSet(), ids.toSet());
    }
    expect(a.storage.deleted, isEmpty);
    for (final id in ids) {
      expect((await a.service.people(id)).members, hasLength(1));
    }
  });

  test('a call while a refresh runs waits for it and is then brought up to date once more', () async {
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await a.service.refresh();
    final before = server.recordReads;
    final first = a.service.refresh();
    final second = a.service.refresh();
    final third = a.service.refresh();
    expect(await Future.wait([first, second, third]), [
      [o],
      [o],
      [o],
    ]);
    expect(server.recordReads - before, 2, reason: 'the one running, and one after it for both that came meanwhile');
  });

  test('entries a server a deploy behind cannot take back: the team stops as before, the refresh does not fail',
      () async {
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await a.coordinator.syncAll();
    final backupSeq = server.entriesOf(o).length;
    await a.service.createCrate(o, 'Staging');
    await a.coordinator.syncAll();
    expect(await LocalStateStore(await a.db(o)).read(kRecordReceiptState), isNotNull);

    // Behind this device, and (one host of a deploy not yet done) without
    // the route to send the entries back to.
    await server.rollBackRecord(o, backupSeq);
    server.olderServer = true;
    expect(await a.service.refresh(), isEmpty);
    expect(server.mends, 1);
    final problem = (await a.rows(o, 'SELECT record_problem FROM orchard_info')).single;
    expect(problem, contains(ErrorCodes.teamRecordParted.code));
    expect(problem, contains('the server holds $backupSeq entries'));
    expect(await a.rows(o, 'SELECT COUNT(*) FROM orchard_record_entries'), ['${backupSeq + 1}'],
        reason: 'what the device holds stays');
    expect((await a.service.people(o)).members, hasLength(1), reason: 'the Members page reads it');
  });
}
