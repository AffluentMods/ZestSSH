import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';

/// A server that went back in time (restored from an older
/// backup), on the in-memory server: a device that
/// holds the record the server lost sends it back with the names it can
/// seal, and only with the server's receipt; a server whose last entry is
/// not the device's is not followed, whatever its length; and a Crate that
/// lost the newest version a device holds is read again and sent what it
/// lacks, whether the server answers the device's question about that
/// version or only says how far the Crate goes. The same against the real
/// routes: orchard_restore_contract_test.dart.

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

  Future<void> addHost(_Device d, String orchardId, String id) async {
    final db = await d.db(orchardId);
    final at = DateTime(2026, 10, 23);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: '10.0.0.1', port: const Value(22), createdAt: at, updatedAt: at));
  }

  test('entries the server lost go back with the names this device can seal, and it follows again', () async {
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await a.coordinator.syncAll();
    final backupSeq = server.entriesOf(o).length;
    final staging = await a.service.createCrate(o, 'Staging');
    await a.coordinator.syncAll();
    expect(server.entriesOf(o).length, backupSeq + 1);

    await server.rollBackRecord(o, backupSeq);
    await a.coordinator.syncAll();
    expect(server.mends, 1);
    expect(server.entriesOf(o).length, backupSeq + 1, reason: 'the server has the lost entry again');
    expect(await a.rows(o, "SELECT COALESCE(record_problem, '') FROM orchard_info"), ['']);
    // The vault's name, sealed under its key, so the server shows it again.
    final name = server.lastMendNames.singleWhere((n) => n.crateId == staging);
    final key = (await (await a.db(o))
            .customSelect("SELECT secret FROM space_keys WHERE scope = 'crate' AND scope_id = ? AND generation = 1",
                variables: [Variable(staging)])
            .getSingle())
        .read<Uint8List>('secret');
    expect(await decryptCrateName(name.nameEnc, key, orchardId: o, crateId: staging, generation: 1), 'Staging');
    // Another device of the account reads the record as the server has it.
    final b = device();
    await b.coordinator.syncAll();
    expect(await b.rows(o, 'SELECT COUNT(*) FROM orchard_record_entries'), ['${backupSeq + 1}']);
  });

  test('without the server\'s receipt for them, nothing goes back, and the device says why with a code', () async {
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await a.coordinator.syncAll();
    final backupSeq = server.entriesOf(o).length;
    await a.service.createCrate(o, 'Staging');
    await a.coordinator.syncAll();
    await LocalStateStore(await a.db(o)).remove(kRecordReceiptState);
    await server.rollBackRecord(o, backupSeq);

    await a.coordinator.syncAll();
    expect(server.mends, 0);
    final problem = (await a.rows(o, 'SELECT record_problem FROM orchard_info')).single;
    expect(problem, contains(ErrorCodes.teamRecordParted.code));
    expect(problem, contains('receipt'));
    expect(await a.rows(o, 'SELECT COUNT(*) FROM orchard_record_entries'), ['${backupSeq + 1}'],
        reason: 'what the device holds stays');
  });

  test('a server whose last entry is another one than the device\'s, at the same length, is not followed', () async {
    final a = device();
    final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await a.coordinator.syncAll();
    final b = device();
    await b.coordinator.syncAll();
    final backupSeq = server.entriesOf(o).length;
    final production = (await a.rows(o, 'SELECT crate_id FROM orchard_crates')).single;
    await a.service.change(o, RecordTypes.crateSet, {'id': production, 'confirm_reveal': true});
    await a.coordinator.syncAll();
    await server.rollBackRecord(o, backupSeq);
    // In its place, the other device's change.
    await b.service.change(o, RecordTypes.crateSet, {'id': production, 'session_logs': true});
    expect(server.entriesOf(o).length, backupSeq + 1);

    await a.coordinator.syncAll();
    final problem = (await a.rows(o, 'SELECT record_problem FROM orchard_info')).single;
    expect(problem, contains(ErrorCodes.teamRecordParted.code));
    expect(problem, contains('another entry'));
  });

  for (final answers in [true, false]) {
    test('a Crate that lost the newest version this device holds is read again and sent it '
        '(${answers ? 'the server answers the check' : 'an older server: the Crate\'s head tells'})', () async {
      server.answersChecks = answers;
      final a = device();
      final o = await a.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final crate = (await a.rows(o, 'SELECT crate_id FROM orchard_crates')).single;
      await addHost(a, o, 'h-1');
      await a.coordinator.syncAll();
      await addHost(a, o, 'h-2');
      await a.coordinator.syncAll();
      expect(server.items[crate], hasLength(2));
      // The restore lost h-2, the newest write.
      final newest = server.items[crate]!.entries.reduce((x, y) => x.value.revision > y.value.revision ? x : y);
      server.items[crate]!.remove(newest.key);
      if (answers) {
        // And another device wrote after the restore, past what this one
        // read: only the question about h-2 tells.
        final b = device();
        await b.coordinator.syncAll();
        await addHost(b, o, 'h-3');
        await b.coordinator.syncAll();
      }

      await a.coordinator.syncAll();
      expect(server.items[crate], hasLength(answers ? 3 : 2), reason: 'h-2 is on the server again');
      expect(await a.rows(o, 'SELECT id FROM connections ORDER BY id'), answers ? ['h-1', 'h-2', 'h-3'] : ['h-1', 'h-2']);
      expect(await a.rows(o, 'SELECT COUNT(*) FROM crate_outbox'), ['0']);
      expect(await LocalStateStore(await a.db(o)).read(kServerWentBackState), isNull);
      // Read again only once: the next sync reads on as usual.
      final calls = server.changesCalls;
      await a.coordinator.syncAll();
      expect(server.changesCalls - calls, 1);
    });
  }
}
