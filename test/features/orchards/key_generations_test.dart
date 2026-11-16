import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/orchard_exposure.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'fake_crate_server.dart';

/// Key generations on a device (3.0): a device opens a key only
/// when it is the one the record committed to for its generation, whoever
/// sealed and signed the copy; the current generation is the record's, not
/// the server's; a new generation goes through the record, sealed to
/// exactly who holds the key (end dates counted, deleted accounts aside);
/// and the server may narrow that set, never widen it.

const _owner = 'owner-1';
const _alice = 'alice-1';
const _bob = 'bob-1';

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

/// One device of [uid]'s.
class _Device {
  _Device(FakeCrateServer shared, this.uid, this.accountKeys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: accountKeys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final AccountKeys accountKeys;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  Future<CrateSyncEngine> engine(String orchardId) =>
      coordinator.engineFor(orchardId, author: CrateAuthor(uid: uid, keys: accountKeys));

  Future<void> addHost(String orchardId, String id, {String host = '10.0.0.9', int port = 22, String? key}) async {
    final d = await db(orchardId);
    final at = DateTime(2026, 9, 24);
    await d.into(d.connections).insert(ConnectionsCompanion.insert(
        id: id,
        label: id,
        host: host,
        port: Value(port),
        identityId: Value(key),
        createdAt: at,
        updatedAt: at));
  }

  Future<void> addKey(String orchardId, String id, {required String authMethod, bool usesAgent = false}) async {
    final d = await db(orchardId);
    final at = DateTime(2026, 9, 24);
    await d.into(d.identities).insert(IdentitiesCompanion.insert(
        id: id,
        label: id,
        username: 'user-$id',
        authMethod: authMethod,
        usesAgent: Value(usesAgent),
        createdAt: at,
        updatedAt: Value(at)));
  }

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  /// The key generations this device holds: "orchard:1", "crate:2", ...
  Future<List<String>> keys(String orchardId) async => [
        for (final r in await (await db(orchardId))
            .customSelect('SELECT scope, generation FROM space_keys ORDER BY scope, generation')
            .get())
          '${r.read<String>('scope')}:${r.read<int>('generation')}',
      ];

  Future<Uint8List> key(String orchardId, String scope, String scopeId, int generation) async =>
      (await (await db(orchardId)).customSelect(
        'SELECT secret FROM space_keys WHERE scope = ? AND scope_id = ? AND generation = ?',
        variables: [Variable(scope), Variable(scopeId), Variable(generation)],
      ).getSingle())
          .read<Uint8List>('secret');

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys ownerKeys;
  late AccountKeys aliceKeys;
  late AccountKeys bobKeys;
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    ownerKeys = await AccountKeys.generate();
    aliceKeys = await AccountKeys.generate();
    bobKeys = await AccountKeys.generate();
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    await server.publish(_owner, ownerKeys, email: 'owner@example.com');
    await server.publish(_alice, aliceKeys, email: 'alice@example.com');
    await server.publish(_bob, bobKeys, email: 'bob@example.com');
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid, AccountKeys keys) {
    final d = _Device(server, uid, keys);
    devices.add(d);
    return d;
  }

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// The owner's Orchard with its first Crate, and the role it starts with.
  Future<(String, String, String)> ownersOrchard(_Device owner) async {
    final orchardId =
        await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final crateId = server.recordOf(orchardId).crates.keys.single;
    final role = server.recordOf(orchardId).roles.values.single.id;
    return (orchardId, crateId, role);
  }

  /// [uid] joins as [role]: invited and confirmed by the owner's device.
  Future<void> join(_Device owner, String orchardId, String uid, String role) async {
    await owner.service.invite(orchardId, email: '$uid@example.com', role: role);
    final invite = (await owner.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, uid);
    await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
  }

  /// [key] sealed to [to] as generation [generation] of the Orchard's key
  /// (null [crateId]) or a Crate's, and signed by [signer] ([sealer]).
  Future<SealedSpaceKey> copyOf(Uint8List key, String orchardId,
      {String? crateId, required int generation, required String to, required AccountKeys toKeys,
      required String sealer, required AccountKeys signer}) async {
    final sealed = crateId == null
        ? await sealOrchardKey(toKeys.encryption.publicKey, key, orchardId: orchardId, generation: generation)
        : await sealCrateKey(toKeys.encryption.publicKey, key,
            orchardId: orchardId, crateId: crateId, generation: generation);
    return SealedSpaceKey(generation, sealed,
        recipientKeyVersion: toKeys.version,
        sealedBy: sealer,
        sealerKeyVersion: signer.version,
        signature: await signKeyCopy(
          signer,
          KeyCopyPlace(
            orchardId: orchardId,
            crateId: crateId,
            generation: generation,
            recipient: to,
            recipientKeyVersion: toKeys.version,
            sealer: sealer,
            sealerKeyVersion: signer.version,
          ),
          sealed,
        ));
  }

  test('a copy signed by a trusted account opens only when the key inside is the one the record committed to',
      () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateId, role) = await ownersOrchard(owner);
    await join(owner, orchardId, _alice, role);
    final alice = device(_alice, aliceKeys);
    await alice.service.refresh();
    expect(await alice.keys(orchardId), ['crate:1', 'orchard:1']);

    // The owner (whom Alice's record trusts) seals and signs keys of its own
    // as generation 1: correct signatures, the wrong keys inside. (What a
    // modified app, or a member working with a hacked server, could send.)
    server.accountUid = _alice;
    final honest = server.orchardsById[orchardId]!;
    server.serveKeys(orchardId, [
      await copyOf(newSpaceKey(), orchardId, generation: 1, to: _alice, toKeys: aliceKeys, sealer: _owner, signer: ownerKeys),
    ]);
    server.serveKeys(orchardId, [
      await copyOf(newSpaceKey(), orchardId,
          crateId: crateId, generation: 1, to: _alice, toKeys: aliceKeys, sealer: _owner, signer: ownerKeys),
    ], crateId: crateId);
    server.accountUid = _owner;

    // A new device of Alice's takes neither.
    final aliceNew = device(_alice, aliceKeys);
    await aliceNew.service.refresh();
    expect(await aliceNew.keys(orchardId), isEmpty, reason: 'no key but the committed one opens');
    final info = await (await aliceNew.db(orchardId)).customSelect('SELECT name FROM orchard_info').getSingle();
    expect(info.read<String?>('name'), isNull, reason: 'the name stays closed without the real key');

    // The real copies, served again, open.
    server.accountUid = _alice;
    server.serveKeys(orchardId, honest.keys);
    server.serveKeys(orchardId, honest.crates.single.keys, crateId: crateId);
    server.accountUid = _owner;
    await aliceNew.service.refresh();
    expect(await aliceNew.keys(orchardId), ['crate:1', 'orchard:1']);
    expect(await aliceNew.key(orchardId, 'crate', crateId, 1), await alice.key(orchardId, 'crate', crateId, 1));
  });

  test("the current generation is the record's, not the server's word for it", () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateId, _) = await ownersOrchard(owner);
    // The server says generation 5 for both keys, with the honest copies.
    final listed = server.orchardsById[orchardId]!;
    server.serveKeys(orchardId, listed.keys, generation: 5);
    server.serveKeys(orchardId, listed.crates.single.keys, crateId: crateId, generation: 5);

    final other = device(_owner, ownerKeys);
    await other.service.refresh();
    Future<(int, int)> generations(_Device d) async {
      final db = await d.db(orchardId);
      final o = await db.customSelect('SELECT key_generation FROM orchard_info').getSingle();
      final c = await db.customSelect('SELECT key_generation FROM orchard_crates').getSingle();
      return (o.read<int>('key_generation'), c.read<int>('key_generation'));
    }

    expect(await generations(other), (1, 1));
    // A real new generation, through the record, moves it.
    server.serveKeys(orchardId, listed.keys, generation: 1);
    server.serveKeys(orchardId, listed.crates.single.keys, crateId: crateId, generation: 1);
    expect(await owner.service.rotateAll(), isEmpty);
    await other.service.refresh();
    expect(await generations(other), (2, 2));
  });

  test('a new generation is a key.rotate entry committing to the new key, sealed to exactly who holds it', () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateId, role) = await ownersOrchard(owner);
    await join(owner, orchardId, _alice, role);
    await owner.service.refresh();
    final before = server.entriesOf(orchardId).length;

    expect(await owner.service.rotateAll(), isEmpty);
    final added = server.entriesOf(orchardId).skip(before).toList();
    expect([for (final e in added) (e.type, e.body['crate'], e.body['generation'])],
        unorderedEquals([(RecordTypes.keyRotate, null, 2), (RecordTypes.keyRotate, crateId, 2)]));
    final record = server.recordOf(orchardId);
    expect(
        await keyMatchesCommitment(await owner.key(orchardId, 'orchard', orchardId, 2),
            record.keyCommitOf(kOrchardScope, 2), orchardId: orchardId, generation: 2),
        isTrue);
    expect(
        await keyMatchesCommitment(await owner.key(orchardId, 'crate', crateId, 2), record.keyCommitOf(crateId, 2),
            orchardId: orchardId, crateId: crateId, generation: 2),
        isTrue);

    // Alice holds both keys: she opens the new generations, which are the
    // owner's.
    final alice = device(_alice, aliceKeys);
    await alice.service.refresh();
    expect(await alice.keys(orchardId), ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);
    expect(await alice.key(orchardId, 'crate', crateId, 2), await owner.key(orchardId, 'crate', crateId, 2));
  });

  test('a key someone else moved on meanwhile counts as moved, and is not moved twice', () async {
    final a = device(_owner, ownerKeys);
    final (orchardId, crateId, _) = await ownersOrchard(a);
    final b = device(_owner, ownerKeys);
    await b.service.refresh();

    // As the first device's new key goes out, the other device moves both
    // keys on first: the first device's entry no longer follows the record,
    // and once it reads the record again it finds its work done.
    server.beforeRotate = () async => expect(await b.service.rotateAll(), isEmpty);
    expect(await a.service.rotateAll(), isEmpty);
    expect(server.rotations, unorderedEquals(['orchard:$orchardId', 'crate:$crateId']),
        reason: "the other device's two, and no more");
    final record = server.recordOf(orchardId);
    expect((record.generationOf(kOrchardScope), record.generationOf(crateId)), (2, 2));
  });

  test('a server counting fewer holders gets copies for the ones it names; never more than the device counts',
      () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateId, role) = await ownersOrchard(owner);
    await join(owner, orchardId, _alice, role);
    await join(owner, orchardId, _bob, role);
    await owner.service.refresh();

    // Bob's account goes after this device last read the members: the
    // server leaves him out, and the device seals to the two it names.
    server.deletedAccounts.add(_bob);
    final left = await owner.service.rotateAll();
    expect(left, isEmpty);
    expect(server.recordOf(orchardId).generationOf(kOrchardScope), 2);
    server.accountUid = _bob;
    expect([for (final k in server.orchardsById[orchardId]!.keys) k.generation], [1], reason: 'nothing new for Bob');
    server.accountUid = _alice;
    expect([for (final k in server.orchardsById[orchardId]!.keys) k.generation], [1, 2]);
    server.accountUid = _owner;

    // Now the device counts Alice out (it was told her account went) while
    // the server wants a copy for her: the device seals to no one it counts
    // out, and the key waits.
    await owner.service.refresh();
    await (await owner.db(orchardId))
        .customStatement("UPDATE member_keys SET account_deleted = 1 WHERE uid = '$_alice'");
    final stuck = await owner.service.rotateAll();
    expect(stuck, unorderedEquals(['orchard:$orchardId', 'crate:$crateId']));
    expect(server.recordOf(orchardId).generationOf(kOrchardScope), 2, reason: 'nothing moved');
  });

  test('an ended member is sealed nothing new; a later end date brings every generation back', () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateId, role) = await ownersOrchard(owner);
    await join(owner, orchardId, _alice, role);
    await owner.service.refresh();

    await owner.service.setMemberEndsAt(orchardId, _alice, now() - 60);
    expect(await owner.service.rotateAll(), isEmpty);
    expect(server.rotationRequests, [
      [_owner],
      [_owner],
    ], reason: 'the device leaves her out itself, not because the server said so');
    server.accountUid = _alice;
    expect(server.orchardsById[orchardId]!.status, 'ended');
    server.accountUid = _owner;
    expect(server.recordOf(orchardId).holdersAt(kOrchardScope, now()), [_owner]);

    // More time: every generation of every key her access gives, again.
    await owner.service.setMemberEndsAt(orchardId, _alice, now() + 3600);
    final alice = device(_alice, aliceKeys);
    await alice.service.refresh();
    expect(await alice.keys(orchardId), ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);
    expect(await alice.key(orchardId, 'orchard', orchardId, 2), await owner.key(orchardId, 'orchard', orchardId, 2));
  });

  test('after a key replacement an account signs again only what it wrote last, and counts what it no longer may',
      () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateId, role) = await ownersOrchard(owner);
    await join(owner, orchardId, _bob, role);
    await owner.service.setMemberGrants(orchardId, _bob, {crateId: levelSwitches(CrateLevel.edit)});
    final bob = device(_bob, bobKeys);
    await bob.coordinator.syncAll();
    await bob.addHost(orchardId, 'h-bob');
    expect((await bob.coordinator.syncAll())[orchardId]!.sent, 1);
    await owner.addHost(orchardId, 'h-owner');
    await owner.coordinator.syncAll();

    // Each device knows who wrote the version it holds.
    Future<List<String>> authors(_Device d) async => [
          for (final r in await (await d.db(orchardId))
              .customSelect('SELECT item_key, author FROM crate_items_meta ORDER BY item_key')
              .get())
            '${r.read<String>('item_key')}:${r.read<String?>('author')}',
        ];
    expect(await authors(owner), ['h-bob:$_bob', 'h-owner:$_owner']);

    // The owner signs again its own, not Bob's.
    expect(await (await owner.engine(orchardId)).queueRewrite(), (queued: 1, stranded: 0));
    final queued = await (await owner.db(orchardId)).customSelect('SELECT item_key FROM crate_outbox').get();
    expect([for (final r in queued) r.read<String>('item_key')], ['h-owner']);

    // Bob loses Edit: his item stays his, and he can no longer sign it again.
    await owner.service.setMemberGrants(orchardId, _bob, {});
    await bob.coordinator.syncAll();
    expect(await (await bob.engine(orchardId)).queueRewrite(), (queued: 0, stranded: 1));
  });

  test('what someone could use: keys they could see, then ones they only connected with, and the hosts each opens',
      () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateA, role) = await ownersOrchard(owner);
    final crateB = await owner.service.createCrate(orchardId, 'Backups');
    await join(owner, orchardId, _alice, role);
    await join(owner, orchardId, _bob, role);
    // Alice: Use on A (her role) and Connect on B.
    await owner.service.setMemberGrants(orchardId, _alice, {crateB: levelSwitches(CrateLevel.connect)});

    // Keys in A: two with a secret, one in an agent and one on a hardware
    // token (nothing of theirs is in the Orchard); hosts that use them.
    await owner.addKey(orchardId, 'deploy', authMethod: 'password');
    await owner.addKey(orchardId, 'ci', authMethod: 'publicKey');
    await owner.addKey(orchardId, 'agent-held', authMethod: 'publicKey', usesAgent: true);
    await owner.addKey(orchardId, 'yubikey', authMethod: 'hardwareToken');
    await owner.addHost(orchardId, 'web1', host: '10.0.0.1', key: 'deploy');
    await owner.addHost(orchardId, 'web2', host: '10.0.0.2', port: 2222, key: 'deploy');
    // A key in B, and its host.
    await CratePlacement(await owner.db(orchardId)).setDefaultCrate(crateB);
    await owner.addKey(orchardId, 'backup', authMethod: 'password');
    await owner.addHost(orchardId, 'nas', host: '10.0.0.3', key: 'backup');
    await owner.coordinator.syncAll();

    final seen = await owner.service.exposure(orchardId, _alice);
    expect([for (final k in seen.reveal) (k.id, k.crateId, k.authMethod)],
        [('ci', crateA, 'publicKey'), ('deploy', crateA, 'password')]);
    expect([for (final k in seen.connect) (k.id, k.crateId)], [('backup', crateB)]);
    expect(seen.closed, isEmpty, reason: 'the owner opens every Crate');
    final deploy = seen.reveal.last;
    expect([for (final h in deploy.hosts) exposedHost(h)], ['web1 (10.0.0.1)', 'web2 (10.0.0.2:2222)']);
    expect(seen.reveal.first.hosts, isEmpty);

    // Removed, the list is the same as the record stood before; and from
    // the record now, what their role and extra Crates gave them.
    final before = server.recordOf(orchardId).copy();
    await owner.service.removeMember(orchardId, _alice);
    for (final exposure in [
      await owner.service.exposure(orchardId, _alice, asOf: before),
      await owner.service.exposure(orchardId, _alice),
    ]) {
      expect([for (final k in exposure.reveal) k.id], ['ci', 'deploy']);
      expect([for (final k in exposure.connect) k.id], ['backup']);
    }

    // On Bob's device (Use on A only), B cannot be opened: counted, with who
    // manages it.
    final bob = device(_bob, bobKeys);
    await bob.coordinator.syncAll();
    final fromBob = await bob.service.exposure(orchardId, _alice, asOf: before);
    expect([for (final k in fromBob.reveal) k.id], ['ci', 'deploy']);
    expect(fromBob.connect, isEmpty);
    expect(fromBob.closed, {crateB: [_owner]});

    // The same list as plain text, for working through it.
    final l10n = lookupAppLocalizations(const Locale('en'));
    final text = exposureText(l10n,
        name: 'Alice', exposure: seen, crateName: (id) => id == crateA ? 'Production' : 'Backups', nameOf: (u) => u);
    expect(text.split('\n'), [
      'What Alice could use',
      l10n.orchardExposureIntro,
      '',
      '2 keys they could see or copy',
      '- ci (user-ci), Private key, Production',
      '  No saved host here uses it',
      '- deploy (user-deploy), Password, Production',
      '  Opens web1 (10.0.0.1), web2 (10.0.0.2:2222)',
      '',
      '1 key they could connect with, never shown to them',
      '- backup (user-backup), Password, Backups',
      '  Opens nas (10.0.0.3)',
    ]);
  });

  test('the member list names deleted accounts; the device shows them so and seals them nothing', () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, _, role) = await ownersOrchard(owner);
    await join(owner, orchardId, _alice, role);
    await join(owner, orchardId, _bob, role);
    server.deletedAccounts.add(_bob);
    await owner.service.refresh();

    final directory = MemberDirectory(await owner.db(orchardId));
    expect(await directory.deletedAccounts(), {_bob});
    final view = await directory.view(_owner);
    expect(view.firstWhere((m) => m.uid == _bob).accountDeleted, isTrue);
    expect(view.firstWhere((m) => m.uid == _alice).accountDeleted, isFalse);
    // A new key reaches the others, the device leaving Bob out itself.
    server.rotations.clear();
    expect(await owner.service.rotateAll(), isEmpty);
    expect(server.rotations, hasLength(2));
    expect(server.rotationRequests, [
      [_alice, _owner],
      [_alice, _owner],
    ]);
  });
}
