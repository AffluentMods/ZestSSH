import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show readOrchardSummary;
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'fake_crate_server.dart';

/// ZestSSH Cloud alone takes nothing of a team off a device (found in a
/// security review). A team the server stops listing, saying it holds
/// the device's last entry (or having no such question), leaves the device
/// only where a record the device checks has the account out of it;
/// otherwise it stays, held back, changes not yet sent included, until its
/// person removes it. A vault leaves only once the record no longer opens it
/// by the device's clock; one the list alone leaves out stays, held.

const _owner = 'owner-1';
const _alice = 'alice';

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

  CrateAuthor get me => CrateAuthor(uid: uid, keys: keys);

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get()) r.data.values.join(':'),
      ];

  Future<String> status(String orchardId) async => (await rows(orchardId, 'SELECT status FROM orchard_info')).single;

  Future<bool> holds(String orchardId) async => (await service.databases.onDevice()).contains(orchardId);

  /// A host added here, not sent yet, placed in [crateId] where given.
  Future<void> unsentHost(String orchardId, String id, {String? crateId}) async {
    final d = await db(orchardId);
    final now = DateTime(2026, 11, 5);
    await d.into(d.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: '10.0.0.9', port: const Value(22), createdAt: now, updatedAt: now));
    if (crateId != null) await (await coordinator.engineFor(orchardId, author: me)).place('host', id, crateId);
  }

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

  /// The owner's team, Acme, with Production (the role Member has use of it),
  /// and each of [people] in it as a Member.
  Future<String> team(_Device owner, List<_Device> people) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single.id;
    for (final p in people) {
      await owner.service.invite(id, email: '${p.uid}@example.com', role: member);
      final invite = (await owner.service.invites(id)).single;
      server.acceptAs(id, invite.id, p.uid);
      await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
      expect(await p.service.refresh(), contains(id));
      await p.coordinator.syncAll();
    }
    return id;
  }

  group('a team the server stops listing', () {
    test("on the server's word alone, an only owner's team stays, held back, unsent changes and key included",
        () async {
      final owner = device(_owner);
      final o = await team(owner, []);
      await owner.coordinator.syncAll();
      await owner.unsentHost(o, 'h-unsent');
      expect((await LocalRecord.load(await owner.db(o), o)).latest.isOwner(_owner), isTrue);

      server.hidden.add(o);
      expect(await owner.service.refresh(), isEmpty);

      expect(owner.storage.deleted, isEmpty, reason: 'nothing left the device');
      expect(await owner.holds(o), isTrue);
      expect(await const FlutterSecureStorage().read(key: OrchardDatabaseKeys.storageKey(o)), isNotNull);
      expect(await owner.rows(o, "SELECT id FROM connections WHERE id = 'h-unsent'"), ['h-unsent']);
      expect(await owner.status(o), kUnlistedStatus);
      expect(owner.service.standing[o], kUnlistedStatus);
      expect((await readOrchardSummary(await owner.db(o), o)).status, kUnlistedStatus);

      final reads = server.changesCalls;
      final report = await owner.coordinator.syncOne(o);
      expect(report.held, isTrue, reason: 'nothing syncs while it is not listed');
      expect(server.changesCalls, reads);

      // Asked again at each refresh: still nothing goes.
      await owner.service.refresh();
      expect(owner.storage.deleted, isEmpty);
    });

    test('a server with no such question (a 404 with no code) takes nothing off either', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await team(owner, [alice]);
      final keysBefore = await alice.rows(o, 'SELECT scope, scope_id, generation FROM space_keys ORDER BY 1, 2, 3');
      expect(keysBefore, isNotEmpty);

      server.olderServer = true;
      server.hidden.add(o);
      expect(await alice.service.refresh(), isEmpty);
      expect(alice.storage.deleted, isEmpty);
      expect(await alice.status(o), kUnlistedStatus);
      expect(await alice.rows(o, 'SELECT scope, scope_id, generation FROM space_keys ORDER BY 1, 2, 3'), keysBefore);
    });

    test('listed again, it syncs again as before', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await team(owner, [alice]);
      server.hidden.add(o);
      await alice.service.refresh();
      expect(await alice.status(o), kUnlistedStatus);

      server.hidden.remove(o);
      expect(await alice.service.refresh(), [o]);
      expect(await alice.status(o), 'active');
      expect((await alice.coordinator.syncOne(o)).held, isFalse);
    });

    test('its person removes it from the device; a team that is listed is never removed so', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await team(owner, [alice]);
      await expectLater(alice.service.removeUnlistedTeam(o), throwsA(isA<StateError>()));
      expect(await alice.holds(o), isTrue);

      server.hidden.add(o);
      await alice.service.refresh();
      await alice.service.removeUnlistedTeam(o);
      expect(alice.storage.deleted, [o]);
      expect(await const FlutterSecureStorage().read(key: OrchardDatabaseKeys.storageKey(o)), isNull);
    });

    test('removed by a signed member.remove that the server lets the device read: it leaves the device', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await team(owner, [alice]);
      await owner.service.removeMember(o, _alice);
      expect(server.recordOf(o).members[_alice]!.status, MemberStatus.removed);

      // ZestSSH Cloud lets no former member read the record: the device asks.
      expect(await alice.service.refresh(), isEmpty);
      expect(alice.storage.deleted, isEmpty);
      expect(await alice.status(o), kUnlistedStatus);

      // A server that lets it read the record: the signed removal decides.
      server.formerMembersRead = true;
      await alice.service.refresh();
      expect(alice.storage.deleted, [o]);
    });

    test('the record here already has the account out: it leaves the device, as before', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await team(owner, [alice]);
      await owner.service.removeMember(o, _alice);
      // Alice's device read the record with her removal in it (it was listed
      // a moment longer), then the list left the team out.
      server.formerMembersRead = true;
      await pullRecord(await alice.db(o), o, alice.server);
      server.formerMembersRead = false;
      await alice.service.refresh();
      expect(alice.storage.deleted, [o]);
    });
  });

  group('a vault', () {
    test('the list alone leaves it out: it stays, held, with its items, keys and unsent changes', () async {
      final owner = device(_owner);
      final o = await team(owner, []);
      final staging = await owner.service.createCrate(o, 'Staging');
      await owner.coordinator.syncAll();
      await owner.unsentHost(o, 'h-unsent', crateId: staging);
      expect(await owner.rows(o, 'SELECT COUNT(*) FROM crate_outbox'), isNot(['0']));

      server.dropCrate(o, staging);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(server.recordOf(o).switchesAt(_owner, staging, now), isNotEmpty);
      await owner.service.refresh();

      expect(await owner.rows(o, "SELECT scope_id FROM space_keys WHERE scope_id = '$staging'"), isNotEmpty,
          reason: "the vault's keys stay");
      expect(await owner.rows(o, "SELECT id FROM connections WHERE id = 'h-unsent'"), ['h-unsent']);
      expect(await owner.rows(o, 'SELECT COUNT(*) FROM crate_outbox'), isNot(['0']), reason: 'the unsent change waits');
      expect(await owner.rows(o, "SELECT name FROM orchard_crates WHERE crate_id = '$staging'"), ['Staging']);
    });

    test('the record no longer opens it to this account: it leaves, whatever the list says', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await team(owner, [alice]);
      final production = server.recordOf(o).crates.keys.single;
      expect(await alice.rows(o, 'SELECT crate_id FROM orchard_crates'), [production]);

      // An owner holds Alice to nothing in Production (member.limit): the
      // record no longer opens it to her.
      await owner.service.setMemberLimit(o, _alice, production, const {});
      await alice.service.refresh();
      expect(await alice.rows(o, 'SELECT crate_id FROM orchard_crates'), isEmpty);
      expect(await alice.rows(o, "SELECT scope_id FROM space_keys WHERE scope = 'crate'"), isEmpty);
    });
  });
}
