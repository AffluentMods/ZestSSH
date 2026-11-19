import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/activity/activity_notes.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';

/// Activity (3.0): while an owner has it on, a
/// member's device notes what its person does with the Crates' items and
/// sends it sealed with the Orchard's key; owners read it, each event kept
/// only when it names who the server says sent it. While it is off nothing
/// is noted, and what was waiting is dropped.

const _owner = 'owner-1';
const _alice = 'alice';

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
  _Device(FakeCrateServer shared, this.uid, this.keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final AccountKeys keys;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    for (final uid in [_owner, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _alice]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid) {
    final d = _Device(server, uid, keys[uid]!);
    devices.add(d);
    return d;
  }

  Future<(String, String)> team(_Device owner, _Device alice) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = server.recordOf(id).roles.values.single.crates.keys.single;
    await owner.service.invite(id, email: 'alice@example.com', role: server.recordOf(id).roles.values.single.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    await alice.coordinator.syncAll();
    return (id, crate);
  }

  Future<String?> queued(_Device d, String id) async => LocalStateStore(await d.db(id)).read('activity.queue');

  test('nothing is noted while off; on, what a member did reaches the owners, sealed, newest first', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);

    await alice.service.recordActivity(id, ActivityKind.connect, crateId: crate, itemKind: 'host', itemKey: 'web1');
    expect(await queued(alice, id), isNull, reason: 'the team records no activity');
    await alice.coordinator.syncAll();
    expect(server.activityRows[id], isNull);

    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await alice.coordinator.syncAll();
    await alice.service.recordActivity(id, ActivityKind.reveal,
        crateId: crate, itemKind: 'key', itemKey: 'k1', name: '  Deploy key  ');
    await alice.service.recordActivity(id, ActivityKind.connect,
        crateId: crate, itemKind: 'host', itemKey: 'web1', name: 'Web 1');
    expect(jsonDecode((await queued(alice, id))!) as List, hasLength(2));
    await alice.coordinator.syncAll();
    expect(await queued(alice, id), isNull, reason: 'sent with the sync');
    expect(server.activityRows[id], hasLength(2));
    // The server holds nothing readable.
    for (final e in server.activityRows[id]!) {
      expect(utf8.decode(e.sealed, allowMalformed: true), isNot(contains('Deploy key')));
    }

    final page = await owner.service.teamActivity(id);
    expect([for (final e in page.entries) (e.event.uid, e.event.kind, e.event.itemKey, e.event.name)], [
      (_alice, ActivityKind.connect, 'web1', 'Web 1'),
      (_alice, ActivityKind.reveal, 'k1', 'Deploy key'),
    ]);
    expect(page.entries.first.event.crateId, crate);
    expect(page.unreadable, 0);

    // Only owners read it.
    await expectLater(alice.service.teamActivity(id),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'owners-only')));
  });

  test('an event that does not open, or names someone other than who sent it, is left out', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, _) = await team(owner, alice);
    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await alice.coordinator.syncAll();

    // Alice holds the Orchard's key: she can seal an event naming the owner,
    // but the server says she sent it.
    final key = (await (await alice.db(id)).customSelect(
      "SELECT secret FROM space_keys WHERE scope = 'orchard' AND scope_id = ? AND generation = 1",
      variables: [Variable(id)],
    ).getSingle())
        .read<Uint8List>('secret');
    final framed = await sealActivity(
        ActivityEvent(uid: _owner, kind: ActivityKind.export, at: DateTime.now()).toJson(), key,
        orchardId: id, generation: 1);
    await alice.server.sendActivity(id, [SealedActivity(keyGeneration: 1, sealed: framed)]);
    await alice.server.sendActivity(id, [SealedActivity(keyGeneration: 1, sealed: Uint8List.fromList(List.filled(60, 7)))]);
    // Under another Orchard's name.
    final elsewhere = await sealActivity(
        ActivityEvent(uid: _alice, kind: ActivityKind.copy, at: DateTime.now()).toJson(), key,
        orchardId: 'another-orchard', generation: 1);
    await alice.server.sendActivity(id, [SealedActivity(keyGeneration: 1, sealed: elsewhere)]);
    await alice.service.recordActivity(id, ActivityKind.copy, itemKind: 'key', itemKey: 'k1');
    await alice.coordinator.syncAll();

    final page = await owner.service.teamActivity(id);
    expect([for (final e in page.entries) (e.event.uid, e.event.kind)], [(_alice, ActivityKind.copy)]);
    expect(page.unreadable, 3);
  });

  test('turned off: what waited is dropped and nothing more is noted; the queue keeps the newest 500', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, _) = await team(owner, alice);
    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await alice.coordinator.syncAll();

    for (var i = 0; i < 505; i++) {
      await alice.service.recordActivity(id, ActivityKind.connect, itemKind: 'host', itemKey: 'h$i');
    }
    final waiting = jsonDecode((await queued(alice, id))!) as List;
    expect(waiting, hasLength(500));
    expect((waiting.first as Map)['item'], 'h5', reason: 'the oldest went first');

    // Off before alice's device sends it: the record says so, and it goes
    // without a word to the server.
    await owner.service.setTracking(id, RecordTracking.none);
    await alice.coordinator.syncAll();
    expect(await queued(alice, id), isNull);
    expect(server.activityCalls, 0);
    expect(server.activityRows[id], isNull);
    await alice.service.recordActivity(id, ActivityKind.connect, itemKind: 'host', itemKey: 'late');
    expect(await queued(alice, id), isNull);

    // The server says off while this device's record still says on: dropped.
    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await alice.coordinator.syncAll();
    await alice.service.recordActivity(id, ActivityKind.connect, itemKind: 'host', itemKey: 'x');
    await owner.service.setTracking(id, RecordTracking.none);
    expect(await alice.service.activityRound(id), 0);
    expect(await queued(alice, id), isNull);
  });

  test("notes from the app: a key's secrets opened count once in ten minutes, each connection counts, nothing while off",
      () async {
    resetRevealNotes();
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    final db = await alice.db(id);
    final start = DateTime.utc(2026, 9, 25, 12);
    Future<void> note(ActivityKind kind, String key, {Duration after = Duration.zero}) =>
        noteActivityIn(alice.service, db, kind, itemKind: kind == ActivityKind.connect ? 'host' : 'key', itemKey: key,
            name: key, now: start.add(after));

    // Off: nothing kept, and nothing counted as seen either.
    await note(ActivityKind.reveal, 'k1');
    expect(await queued(alice, id), isNull);

    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await (await owner.db(id)).customStatement(
        "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('web1', 'Web 1', 'web1.example.com', 22, 0, 0)");
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    await note(ActivityKind.reveal, 'k1');
    await note(ActivityKind.reveal, 'k1', after: const Duration(minutes: 9));
    await note(ActivityKind.reveal, 'k2', after: const Duration(minutes: 9));
    await note(ActivityKind.reveal, 'k1', after: const Duration(minutes: 11));
    await note(ActivityKind.connect, 'web1');
    await note(ActivityKind.connect, 'web1');
    final waiting = [for (final e in jsonDecode((await queued(alice, id))!) as List) ((e as Map)['kind'], e['item'])];
    expect(waiting, [('reveal', 'k1'), ('reveal', 'k2'), ('reveal', 'k1'), ('connect', 'web1'), ('connect', 'web1')]);
    // A connection names the Crate its host is in.
    expect([for (final e in jsonDecode((await queued(alice, id))!) as List) if ((e as Map)['kind'] == 'connect') e['crate']],
        [crate, crate]);

    // Your Tree's items are never noted.
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    await noteActivityIn(alice.service, tree, ActivityKind.connect, itemKind: 'host', itemKey: 'mine');
    expect(jsonDecode((await queued(alice, id))!) as List, hasLength(5));

    // A key that has left the team is in no vault to look up: the vault it was in is given.
    await noteActivityIn(alice.service, db, ActivityKind.export, itemKind: 'key', itemKey: 'gone', name: 'gone', crateId: crate);
    final last = (jsonDecode((await queued(alice, id))!) as List).last as Map;
    expect((last['kind'], last['item'], last['crate']), ('export', 'gone', crate));
  });
}

