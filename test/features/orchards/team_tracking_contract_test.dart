import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// What the team records (3.0) against the REAL server routes on a
/// real Postgres: an owner's tracking.set goes into the record the server
/// checks, an invitation says what the Orchard records before anyone joins,
/// the trash hands back what was deleted and a second device brings it back,
/// version history serves only what changed after it was turned on, and
/// activity sealed on a member's device reaches the owner and nobody else.
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
    final uid = 'track-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  _Device device(CrateAuthor me) {
    final storage = _MemoryStorage();
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid));
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    final d = _Device(storage, service, OrchardSyncCoordinator(service: service, server: server, databases: databases));
    devices.add(d);
    return d;
  }

  Future<String?> labelOf(AppDatabase db, String id) async =>
      (await db.customSelect('SELECT label FROM connections WHERE id = ?', variables: [Variable(id)]).getSingleOrNull())
          ?.read<String>('label');

  test('tracking, the trash, version history and activity through the real routes', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final dave = await account('dave');
    final o = device(owner);
    final id = await o.service.createOrchard('Tracking', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = (await o.service.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final role = (await o.service.roles(id)).single.id;
    await o.service.invite(id, email: '${alice.uid}@example.com', role: role);
    final a = device(alice);
    await a.service.acceptInvite((await a.service.myInvites()).single.id);
    await o.service.confirmInvite(id, (await o.service.invites(id)).single);
    await a.coordinator.syncAll();
    final db = await o.service.databases.open(id);

    // The trash, before anything is recorded.
    await db.customStatement(
        "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('web1', 'Web 1', 'web1.example.com', 22, 0, 0)");
    await o.coordinator.syncAll();
    await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
    expect((await o.coordinator.syncAll())[id]!.sent, 1);
    final trashed = (await o.service.trashOf(id, crate)).single;
    expect((trashed.kind, trashed.key, trashed.name, trashed.deletedBy), ('host', 'web1', 'Web 1', owner.uid));
    await expectLater(a.service.trashOf(id, crate),
        throwsA(isA<OrchardServerException>().having((e) => e.need, 'need', CrateSwitches.add)));
    final laptop = device(owner);
    await laptop.service.refresh();
    await laptop.coordinator.syncAll();
    await laptop.service.restoreFromTrash(id, (await laptop.service.trashOf(id, crate)).single);
    expect((await laptop.coordinator.syncAll())[id]!.sent, 1, reason: 'the server took it back as an add');
    await o.coordinator.syncAll();
    expect(await labelOf(db, 'web1'), 'Web 1');
    expect(await o.service.trashOf(id, crate), isEmpty);

    // Version history: off, then on from now.
    await expectLater(o.service.itemVersions(id, crate, kind: 'host', key: 'web1'),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'history-off')));
    await o.service.setTracking(id, const RecordTracking(history: true, activity: true));
    await o.coordinator.syncAll();
    await db.customStatement("UPDATE connections SET label = 'Second' WHERE id = 'web1'");
    await o.coordinator.syncAll();
    await db.customStatement("UPDATE connections SET label = 'Third' WHERE id = 'web1'");
    await o.coordinator.syncAll();
    final versions = await o.service.itemVersions(id, crate, kind: 'host', key: 'web1');
    expect([for (final v in versions) v.name], ['Third', 'Second', 'Web 1'],
        reason: 'the version brought back was replaced after history was turned on; earlier ones are not served');
    final changes = await o.service.crateChanges(id, crate);
    expect([for (final c in changes.changes) (c.previous.name, c.version.name)], [('Second', 'Third'), ('Web 1', 'Second')]);
    await expectLater(a.service.itemVersions(id, crate, kind: 'host', key: 'web1'),
        throwsA(isA<OrchardServerException>().having((e) => e.need, 'need', CrateSwitches.manage)));

    // Activity: noted on alice's device, sealed, read by the owner only.
    await a.coordinator.syncAll();
    await a.service.recordActivity(id, ActivityKind.connect, crateId: crate, itemKind: 'host', itemKey: 'web1', name: 'Third');
    await a.coordinator.syncAll();
    final page = await o.service.teamActivity(id);
    expect([for (final e in page.entries) (e.event.uid, e.event.kind, e.event.name)], [(alice.uid, ActivityKind.connect, 'Third')]);
    await expectLater(a.service.teamActivity(id),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'owners-only')));

    // An invitation says what the Orchard records before anyone joins.
    await o.service.invite(id, email: '${dave.uid}@example.com', role: role);
    final d = device(dave);
    expect((await d.service.myInvites()).single.tracking, const RecordTracking(history: true, activity: true));

    // Off: the server stops serving history and drops the activity.
    await o.service.setTracking(id, RecordTracking.none);
    await expectLater(o.service.teamActivity(id),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'activity-off')));
    await expectLater(o.service.crateChanges(id, crate),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'history-off')));
  });
}
