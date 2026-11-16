import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/hostkeys/host_key_notices.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/ssh_service.dart';

import 'fake_crate_server.dart';

/// Team-pinned host keys travel and are told of (3.0): a pin an
/// owner's device makes reaches a member's device with the Crate's sync; when
/// it is replaced or removed, the member's device tells its person (who, for
/// a replacement); nobody is told of their own change, and the first look on
/// a device only notes where things stand.

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
  final l10n = lookupAppLocalizations(const Locale('en'));

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

  SSHHostKey key(int seed) =>
      SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => (seed + i) & 0xff)));

  test("a pin reaches a member's device; its replacement and removal are told, never one's own", () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = server.recordOf(id).roles.values.single.crates.keys.single;
    await owner.service.invite(id, email: 'alice@example.com', role: server.recordOf(id).roles.values.single.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);

    final ownerPins = TeamHostKeys(await owner.db(id));
    await ownerPins.pin('web1.example.com', 22, key(1), crateId: production);
    expect((await owner.coordinator.syncAll())[id]!.sent, 1);
    await alice.coordinator.syncAll();
    final aliceDb = await alice.db(id);
    expect((await TeamHostKeys(aliceDb).pinFor('web1.example.com', 22, crateId: production))!.matches(key(1)), isTrue);
    expect(await takeHostKeyNotices(aliceDb, me: _alice), isEmpty, reason: 'the first look only notes it');
    expect(await takeHostKeyNotices(await owner.db(id), me: _owner), isEmpty);

    // The owner replaces it: alice is told, by whom; the owner is not.
    await ownerPins.pin('web1.example.com', 22, key(2), crateId: production);
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect((await TeamHostKeys(aliceDb).pinFor('web1.example.com', 22, crateId: production))!.matches(key(2)), isTrue);
    final replaced = await takeTeamNotifications({id: aliceDb},
        me: _alice, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
    expect(replaced.map((n) => n.title), [l10n.noticeHostKeyReplacedTitle('web1.example.com:22', 'The Acme Orchard')]);
    expect(replaced.single.body, l10n.noticeHostKeyReplacedBody('owner-1@example.com'));
    expect(await takeHostKeyNotices(aliceDb, me: _alice), isEmpty, reason: 'told once');
    expect(await takeHostKeyNotices(await owner.db(id), me: _owner), isEmpty, reason: 'its own change');

    // The owner removes it: alice is told.
    await ownerPins.unpin(teamHostKeyId('web1.example.com', 22, null, crateId: production));
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect(await TeamHostKeys(aliceDb).pinFor('web1.example.com', 22, crateId: production), isNull);
    final removed = await takeHostKeyNotices(aliceDb, me: _alice);
    expect(removed.single.kind, HostKeyNoticeKind.removed);
    expect(removed.single.host, 'web1.example.com');
    expect(await takeHostKeyNotices(await owner.db(id), me: _owner), isEmpty);
    // The owner's other device pins it again: that is the owner's own
    // change, so the first device says nothing; alice is told.
    final ownerLaptop = device(_owner);
    await ownerLaptop.service.refresh();
    await ownerLaptop.coordinator.syncAll();
    await TeamHostKeys(await ownerLaptop.db(id)).pin('web1.example.com', 22, key(4), crateId: production);
    await ownerLaptop.coordinator.syncAll();
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect((await TeamHostKeys(await owner.db(id)).pinFor('web1.example.com', 22, crateId: production))!.matches(key(4)),
        isTrue);
    expect(await takeHostKeyNotices(await owner.db(id), me: _owner), isEmpty, reason: 'written from its own other device');
    // (New to alice's device: pinned again after the removal, not replaced.)
    expect(await takeHostKeyNotices(aliceDb, me: _alice), isEmpty);
    await TeamHostKeys(await ownerLaptop.db(id)).pin('web1.example.com', 22, key(5), crateId: production);
    await ownerLaptop.coordinator.syncAll();
    await owner.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect(await takeHostKeyNotices(await owner.db(id), me: _owner), isEmpty, reason: 'its own other device replaced it');
    expect((await takeHostKeyNotices(aliceDb, me: _alice)).single.by, _owner);
    // A member who may only use Production cannot pin.
    await expectLater(TeamHostKeys(aliceDb).pin('web2.example.com', 22, key(3), crateId: production),
        throwsA(predicate((e) => '$e'.contains('orchard-access'))));
  });
}
