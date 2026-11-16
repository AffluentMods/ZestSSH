import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A port forward in sync (3.0; a reported bug: a forward's
/// "Start automatically" kept switching itself off, though the forward
/// worked). Whether a forward starts by itself when its host
/// connects, whether other devices on the network may use it, and an address
/// that is not the device's own are each device's to decide: they do not
/// travel, a forward a device has keeps its own through every sync, and one
/// new on a device starts by hand only, on loopback, shared with nobody.
/// Every restore set those for every forward, also one the device had, and
/// the next push carried that to the others: "Start automatically" switched
/// itself off with each sync, on every device.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const storage = FlutterSecureStorage();
  late SettingsService settings;
  final dbs = <AppDatabase>[];
  final key = List<int>.filled(32, 7);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
  });

  tearDown(() async {
    for (final db in dbs) {
      await db.close();
    }
    dbs.clear();
  });

  /// A device with the host web-01, and on it the forward f1 to its
  /// database (5432), named "db".
  Future<AppDatabase> device() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    dbs.add(db);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'web',
          label: 'web-01',
          host: 'web-01.example.com',
          createdAt: DateTime.utc(2026, 10, 15),
          updatedAt: DateTime.utc(2026, 10, 15),
        ));
    return db;
  }

  Future<void> forward(AppDatabase db, {bool autoStart = false, bool lan = false, String bind = '127.0.0.1'}) =>
      db.portForwardRulesDao.upsertRule(PortForwardRulesCompanion.insert(
        id: 'f1',
        connectionId: 'web',
        type: 'local',
        bindAddress: Value(bind),
        bindPort: 15432,
        remoteHost: 'localhost',
        remotePort: 5432,
        autoStart: Value(autoStart),
        gatewayPorts: Value(lan),
        label: const Value('db'),
        createdAt: DateTime.utc(2026, 10, 15),
        updatedAt: Value(DateTime.utc(2026, 10, 15)),
      ));

  /// The forward f1 on [db], as this device has it.
  Future<PortForwardRule> f1(AppDatabase db) async => (await db.portForwardRulesDao.getAll()).single;

  SyncDataService sync(AppDatabase db) => memoryDataService(db, storage, settings);

  test('what each device decides for itself does not travel; the rest of the forward does', () async {
    final a = await device();
    await forward(a, autoStart: true, lan: true, bind: '0.0.0.0');
    final sent = ((await sync(a).gatherAll())['port_forward_rules'] as List).single as Map;
    expect(sent.containsKey('autoStart'), isFalse);
    expect(sent.containsKey('gatewayPorts'), isFalse);
    expect(sent['bindAddress'], '127.0.0.1', reason: "an address not the device's own does not travel");
    expect((sent['bindPort'], sent['remotePort'], sent['label']), (15432, 5432, 'db'));
  });

  test('a forward new to a device starts by hand only, on loopback, shared with nobody', () async {
    final a = await device();
    await forward(a, autoStart: true, lan: true, bind: '0.0.0.0');
    final b = await device();
    expect((await sync(b).restoreAll(await sync(a).gatherAll())).success, isTrue);
    final mine = await f1(b);
    expect((mine.autoStart, mine.gatewayPorts, mine.bindAddress), (false, false, '127.0.0.1'));
    expect(mine.label, 'db');
  });

  test('switched on here, it stays on through a sync from another device, and the rest of the change is taken',
      () async {
    final a = await device();
    await forward(a);
    final b = await device();
    await sync(b).restoreAll(await sync(a).gatherAll());
    // On B: start it by itself, and let the network use it.
    await (b.update(b.portForwardRules)..where((r) => r.id.equals('f1'))).write(
        const PortForwardRulesCompanion(autoStart: Value(true), gatewayPorts: Value(true), bindAddress: Value('0.0.0.0')));

    // A renames it, and syncs; B takes that, and keeps its own.
    await (a.update(a.portForwardRules)..where((r) => r.id.equals('f1')))
        .write(const PortForwardRulesCompanion(label: Value('postgres')));
    await sync(b).restoreAll(await sync(a).gatherAll());
    final mine = await f1(b);
    expect((mine.autoStart, mine.gatewayPorts, mine.bindAddress), (true, true, '0.0.0.0'));
    expect(mine.label, 'postgres');

    // And A's own stay as they were, when it takes B's.
    await sync(a).restoreAll(await sync(b).gatherAll());
    final theirs = await f1(a);
    expect((theirs.autoStart, theirs.gatewayPorts, theirs.bindAddress), (false, false, '127.0.0.1'));
  });

  test('two devices that decide differently send the same: no push back and forth', () async {
    final a = await device();
    await forward(a, autoStart: true, lan: true, bind: '0.0.0.0');
    final b = await device();
    final fromA = await sync(a).gatherAll();
    await sync(b).restoreAll(fromA);
    expect(SyncDataService.contentFingerprint(await sync(b).gatherAll(), key),
        SyncDataService.contentFingerprint(fromA, key));
  });

  test('a blob of an older build, that carries them: a forward new here as safe as ever; one here keeps its own',
      () async {
    final older = {
      'schema_version': 21,
      'port_forward_rules': [
        {
          'id': 'f1',
          'connectionId': 'web',
          'type': 'local',
          'bindAddress': '0.0.0.0',
          'bindPort': 15432,
          'remoteHost': 'localhost',
          'remotePort': 5432,
          'autoStart': true,
          'gatewayPorts': true,
          'label': 'db',
          'createdAt': DateTime.utc(2026, 10, 15).millisecondsSinceEpoch ~/ 1000,
        },
      ],
    };
    Map<String, dynamic> blob() => jsonDecode(jsonEncode(older)) as Map<String, dynamic>;

    final fresh = await device();
    await sync(fresh).restoreAll(blob());
    final added = await f1(fresh);
    expect((added.autoStart, added.gatewayPorts, added.bindAddress), (false, false, '127.0.0.1'));

    final onLoopback = await device();
    await forward(onLoopback, autoStart: true);
    await sync(onLoopback).restoreAll(blob());
    final kept = await f1(onLoopback);
    expect((kept.autoStart, kept.gatewayPorts, kept.bindAddress), (true, false, '127.0.0.1'));

    final onTheNetwork = await device();
    await forward(onTheNetwork, lan: true, bind: '192.168.10.5');
    await sync(onTheNetwork).restoreAll(blob());
    final own = await f1(onTheNetwork);
    expect((own.autoStart, own.gatewayPorts, own.bindAddress), (false, true, '192.168.10.5'));
  });

  test("another of the device's own addresses travels, and is taken", () async {
    final a = await device();
    await forward(a, bind: '::1');
    final b = await device();
    await forward(b);
    await sync(b).restoreAll(await sync(a).gatherAll());
    expect((await f1(b)).bindAddress, '::1');
  });
}
