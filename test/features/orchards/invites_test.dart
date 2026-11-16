import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../helpers/record_statements.dart';

import 'fake_crate_server.dart';

/// Invitations on a device (3.0): someone who may invite confirms a
/// person who accepted with a member.add entry naming the keys they compared
/// and exactly the offer, and every generation of every key the person
/// gains, sealed to those keys and signed; and the new member's device opens
/// copies only when a member its record trusts signed them.

const _owner = 'owner-1';
const _newcomer = 'new-1';
const _admin = 'admin-1';

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

/// One device of [uid]'s: the shared server seen as that account, its
/// databases and its Orchard service.
class _Device {
  _Device(FakeCrateServer shared, this.uid, AccountKeys keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
  }

  final String uid;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;

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

  late AccountKeys ownerKeys;
  late AccountKeys newKeys;
  late AccountKeys adminKeys;
  late PublishedAccountKeys ownerPublished;
  late PublishedAccountKeys newPublished;
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    ownerKeys = await AccountKeys.generate();
    newKeys = await AccountKeys.generate(version: 2);
    adminKeys = await AccountKeys.generate();
    ownerPublished = await ownerKeys.publish(_owner);
    newPublished = await newKeys.publish(_newcomer);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    await server.publish(_owner, ownerKeys, email: 'owner@example.com');
    await server.publish(_newcomer, newKeys, email: 'new@example.com');
    await server.publish(_admin, adminKeys, email: 'admin@example.com');
    server.keyVersions[_newcomer] = 2;
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

  /// The owner's Orchard: its key and first Crate's key at generation 2 (a
  /// replacement moved them on), a second Crate at 1. Returns the ids and
  /// the role it starts with (use of the first Crate).
  Future<(String, String, String, String)> ownersOrchard(_Device owner) async {
    final orchardId =
        await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    expect(await owner.service.rotateAll(), isEmpty);
    final crateB = await owner.service.createCrate(orchardId, 'Staging');
    final crateA = server.recordOf(orchardId).roles.values.single.crates.keys.single;
    final role = server.recordOf(orchardId).roles.values.single.id;
    await owner.service.refresh();
    return (orchardId, crateA, crateB, role);
  }

  /// [by] invites the newcomer as [role] (with [grants]), and the newcomer
  /// accepts. Returns the invitation as [by]'s device reads it.
  Future<OrchardInvite> accepted(_Device by, String orchardId, String role,
      {Map<String, Set<String>> grants = const {}}) async {
    await by.service.invite(orchardId, email: 'new@example.com', role: role, grants: grants);
    final invite = (await by.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, _newcomer);
    return (await by.service.invites(orchardId)).single;
  }

  Future<Uint8List> spaceKey(_Device d, String orchardId, String scope, String scopeId, int generation) async {
    final row = await (await d.db(orchardId)).customSelect(
      'SELECT secret FROM space_keys WHERE scope = ? AND scope_id = ? AND generation = ?',
      variables: [Variable(scope), Variable(scopeId), Variable(generation)],
    ).getSingle();
    return row.read<Uint8List>('secret');
  }

  test('confirming adds the person with a member.add entry and seals every key they gain to the compared keys, signed',
      () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateA, crateB, role) = await ownersOrchard(owner);

    await owner.service.confirmInvite(orchardId, await accepted(owner, orchardId, role));

    final sent = server.confirmations.single;
    expect(sent.entry.type, RecordTypes.memberAdd);
    expect(sent.entry.by, _owner);
    expect(sent.entry.byKeyVersion, 1);
    final body = sent.entry.body;
    expect(body['uid'], _newcomer);
    expect(body['role'], role);
    expect(body['key_version'], 2);
    expect(body['ed25519_pub'], base64Encode(newPublished.signingKey));
    expect(server.recordOf(orchardId).members[_newcomer]!.role, role);

    final places = {for (final c in sent.copies) '${c.crateId ?? 'orchard'}:${c.generation}'};
    expect(places, {'orchard:1', 'orchard:2', '$crateA:1', '$crateA:2'},
        reason: 'every generation of the Orchard and of the one Crate the role opens, nothing of the other');
    expect(places.any((p) => p.startsWith(crateB)), isFalse);
    for (final c in sent.copies) {
      expect(c.uid, _newcomer);
      final crateId = c.crateId;
      final opened = crateId == null
          ? await openOrchardKey(newKeys.encryption, c.sealed, orchardId: orchardId, generation: c.generation)
          : await openCrateKey(newKeys.encryption, c.sealed,
              orchardId: orchardId, crateId: crateId, generation: c.generation);
      expect(opened,
          await spaceKey(owner, orchardId, crateId == null ? 'orchard' : 'crate', crateId ?? orchardId, c.generation),
          reason: 'the copy opens with the newcomer key to the very key');
      expect(
        await verifyKeyCopy(
          ownerKeys.signingPublicKey,
          KeyCopyPlace(
            orchardId: orchardId,
            crateId: crateId,
            generation: c.generation,
            recipient: _newcomer,
            recipientKeyVersion: 2,
            sealer: _owner,
            sealerKeyVersion: 1,
          ),
          c.sealed,
          c.signature,
        ),
        isTrue,
        reason: 'signed by the owner, naming the newcomer and both key versions',
      );
    }

    // Pinned here as verified (and still so after the record and the member
    // list were read again), and the check signed for the others.
    final pin = await MemberDirectory(await owner.db(orchardId)).pin(_newcomer);
    expect(pin?.keyVersion, 2);
    expect(pin?.verifiedByMe, isTrue);
    expect(pin?.signingKey, newPublished.signingKey);
    final check = server.verifications.single;
    expect(check.subjectUid, _newcomer);
    expect(check.subjectKeyVersion, 2);
    expect(
      await verifyMemberVerification(ownerKeys.signingPublicKey, check.signature,
          orchardId: orchardId,
          subjectUid: _newcomer,
          subjectKeyVersion: 2,
          fingerprint: newPublished.fingerprint,
          verifierUid: _owner,
          verifierKeyVersion: 1),
      isTrue,
    );
  });

  test('extra Crates and an end date go into the entry as offered', () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateA, crateB, role) = await ownersOrchard(owner);
    final endsAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    await owner.service.invite(orchardId,
        email: 'new@example.com', role: role, grants: {crateB: levelSwitches(CrateLevel.edit)}, endsAt: endsAt);
    final invite = (await owner.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, _newcomer);
    await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);

    final m = server.recordOf(orchardId).members[_newcomer]!;
    expect(m.grants, {crateB: levelSwitches(CrateLevel.edit)});
    expect(m.endsAt, endsAt);
    final places = {for (final c in server.confirmations.single.copies) '${c.crateId ?? 'orchard'}:${c.generation}'};
    expect(places, {'orchard:1', 'orchard:2', '$crateA:1', '$crateA:2', '$crateB:1'});
  });

  test('another entry or a new key first: confirmed once more on top of it; any other refusal adds nothing', () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, _, _, role) = await ownersOrchard(owner);

    server.failConfirmOnce = 'copies-changed';
    await owner.service.confirmInvite(orchardId, await accepted(owner, orchardId, role));
    expect(server.confirmations, hasLength(1));
    expect(server.recordOf(orchardId).members.containsKey(_newcomer), isTrue);

    final (otherOrchard, _, _, otherRole) = await ownersOrchard(owner);
    server.failConfirmOnce = 'recipient-keys-changed';
    await expectLater(
      owner.service.confirmInvite(otherOrchard, await accepted(owner, otherOrchard, otherRole)),
      throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'recipient-keys-changed')),
    );
    expect(server.recordOf(otherOrchard).members.containsKey(_newcomer), isFalse);
    expect(await MemberDirectory(await owner.db(otherOrchard)).pin(_newcomer), isNull, reason: 'nothing pinned');
  });

  test('not accepted, keys that do not sign for the account, an offer the rules refuse, or a key not on this device: nothing sent',
      () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateA, _, role) = await ownersOrchard(owner);
    OrchardInvite invite({String? uid, PublishedAccountKeys? keys, Map<String, Set<String>> grants = const {}}) =>
        OrchardInvite(
          id: 'invite-x',
          email: 'new@example.com',
          role: role,
          grants: grants,
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          expired: false,
          acceptedUid: uid,
          acceptedKeys: keys,
        );
    Future<void> refused(OrchardInvite i, OrchardInviteProblem problem) => expectLater(
          owner.service.confirmInvite(orchardId, i),
          throwsA(isA<OrchardInviteError>().having((e) => e.problem, 'problem', problem)),
        );

    await refused(invite(), OrchardInviteProblem.notAccepted);
    // The server names one account and shows keys that sign for another.
    await refused(invite(uid: 'someone-else', keys: newPublished), OrchardInviteProblem.badKeys);
    // Keys whose self-signature does not hold.
    final forged = PublishedAccountKeys(
      uid: _newcomer,
      version: 2,
      createdAt: newPublished.createdAt,
      encryptionKey: ownerPublished.encryptionKey,
      signingKey: newPublished.signingKey,
      signature: newPublished.signature,
    );
    await refused(invite(uid: _newcomer, keys: forged), OrchardInviteProblem.badKeys);
    // A Crate the record does not have: the rules refuse it here.
    await expectLater(
      owner.service.confirmInvite(orchardId,
          invite(uid: _newcomer, keys: newPublished, grants: {'not-a-crate-here': levelSwitches(CrateLevel.use)})),
      throwsA(isA<OrchardRecordRefused>()),
    );
    // A key the person would gain that is not on this device (nor any copy
    // of it this account holds on the server).
    final held = server.orchardsById[orchardId]!.crates.firstWhere((c) => c.id == crateA).keys;
    server.serveKeys(orchardId, [for (final k in held) if (k.generation != 1) k], crateId: crateA);
    await (await owner.db(orchardId))
        .customStatement("DELETE FROM space_keys WHERE scope = 'crate' AND scope_id = ? AND generation = 1", [crateA]);
    await refused(invite(uid: _newcomer, keys: newPublished), OrchardInviteProblem.missingKeys);
    expect(server.confirmations, isEmpty);
    expect(server.verifications, isEmpty);
  });

  test("the new member's device follows the record, and opens the copies a member it trusts signed", () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateA, _, role) = await ownersOrchard(owner);
    await owner.service.confirmInvite(orchardId, await accepted(owner, orchardId, role));

    final joined = device(_newcomer, newKeys);
    expect(await joined.service.refresh(), [orchardId]);
    Future<List<String>> keysOn(_Device d) async => [
          for (final r in await (await d.db(orchardId))
              .customSelect('SELECT scope, generation FROM space_keys ORDER BY scope, generation')
              .get())
            '${r.read<String>('scope')}:${r.read<int>('generation')}',
        ];
    expect(await keysOn(joined), ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);
    final info = (await (await joined.db(orchardId))
            .customSelect('SELECT name, role, can FROM orchard_info WHERE id = 1')
            .getSingle())
        .data;
    expect(info, {'name': 'Acme', 'role': role, 'can': '[]'});
    for (final g in [1, 2]) {
      expect(await spaceKey(joined, orchardId, 'orchard', orchardId, g),
          await spaceKey(owner, orchardId, 'orchard', orchardId, g));
    }
    final entries = await (await joined.db(orchardId))
        .customSelect('SELECT seq, type FROM orchard_record_entries ORDER BY seq')
        .get();
    expect(entries.map((r) => r.read<String>('type')).last, RecordTypes.memberAdd,
        reason: 'the record, as checked, is kept on the device');
    expect((await MemberDirectory(await joined.db(orchardId)).pin(_owner))?.signingKey, ownerPublished.signingKey,
        reason: 'the owner pinned from the record');

    // Copies no member signed, or said to be sealed by someone who is not
    // in the record, or by the owner with other keys: none opens on a device
    // that has not held the key.
    final copies = server.confirmations.single.copies;
    SealedSpaceKey listed(GrantCopy c, {String sealedBy = _owner, int sealerVersion = 1, Uint8List? signature}) =>
        SealedSpaceKey(c.generation, c.sealed,
            recipientKeyVersion: 2, sealedBy: sealedBy, sealerKeyVersion: sealerVersion, signature: signature ?? c.signature);
    for (final served in [
      [for (final c in copies.where((c) => c.crateId == crateA)) listed(c, sealedBy: 'stranger-9')],
      [for (final c in copies.where((c) => c.crateId == crateA)) listed(c, sealerVersion: 2)],
      [for (final c in copies.where((c) => c.crateId == crateA)) listed(c, signature: Uint8List(64))],
    ]) {
      server.accountUid = _newcomer;
      server.serveKeys(orchardId, served, crateId: crateA);
      server.accountUid = _owner;
      final fresh = device(_newcomer, newKeys);
      await fresh.service.refresh();
      expect(await keysOn(fresh), ['orchard:1', 'orchard:2'], reason: 'the Crate key does not open');
    }
  });

  test('a member added again with keys the old ones never vouched for seals nothing this device opens', () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, _, _, role) = await ownersOrchard(owner);
    // The owner adds an admin, and the admin adds the newcomer: the
    // newcomer's copies are sealed by the admin.
    await owner.service.invite(orchardId, email: 'admin@example.com', role: FixedRoles.admin);
    server.acceptAs(orchardId, (await owner.service.invites(orchardId)).single.id, _admin);
    await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
    final admin = device(_admin, adminKeys);
    await admin.service.refresh();
    await admin.service.confirmInvite(orchardId, await accepted(admin, orchardId, role));
    final joined = device(_newcomer, newKeys);
    await joined.service.refresh();
    final directory = MemberDirectory(await joined.db(orchardId));
    expect((await directory.pin(_admin))?.hardStop, isFalse);

    // The owner takes the admin out and adds the account again with other
    // keys, which the old ones never vouched for.
    final otherKeys = await AccountKeys.generate();
    await server.publish(_admin, otherKeys);
    final r = server.recordOf(orchardId);
    final out = await signRecordEntry(ownerKeys,
        orchardId: orchardId, seq: r.seq + 1, prev: r.head, type: RecordTypes.memberRemove, by: _owner,
        body: {'uid': _admin});
    final hash = RecordEntry.fromJson(out.toJson()).hash(orchardId);
    final back = await signRecordEntry(ownerKeys,
        orchardId: orchardId, seq: r.seq + 2, prev: hash, type: RecordTypes.memberAdd, by: _owner,
        body: {
          ...recordKeysBody(await otherKeys.publish(_admin)),
          'uid': _admin,
          'role': FixedRoles.admin,
          'verified': await comparedStatement(ownerKeys, _owner, orchardId, await otherKeys.publish(_admin)),
        });
    await server.appendAs(_owner, orchardId, [out, back], checkCopies: false);

    // The admin, back with the new keys, makes generation 3 of the Orchard
    // key through the record, sealing it to everyone who holds it.
    final generation3 = newSpaceKey();
    final r2 = server.recordOf(orchardId);
    final rotate = await signRecordEntry(otherKeys,
        orchardId: orchardId, seq: r2.seq + 1, prev: r2.head, type: RecordTypes.keyRotate, by: _admin,
        body: {
          'generation': 3,
          'key_commit': base64Encode(await keyCommitment(generation3, orchardId: orchardId, generation: 3)),
        });
    Future<GrantCopy> copyFor(String uid) async {
      final keys = r2.members[uid]!.currentKeys;
      final sealed = await sealOrchardKey(uid == _admin ? otherKeys.encryption.publicKey : keys.encryptionKey, generation3,
          orchardId: orchardId, generation: 3);
      final version = uid == _admin ? otherKeys.version : keys.version;
      return GrantCopy(
        uid: uid,
        generation: 3,
        sealed: sealed,
        signature: await signKeyCopy(
          otherKeys,
          KeyCopyPlace(
            orchardId: orchardId,
            generation: 3,
            recipient: uid,
            recipientKeyVersion: version,
            sealer: _admin,
            sealerKeyVersion: otherKeys.version,
          ),
          sealed,
        ),
      );
    }

    await server.rotateAs(_admin, orchardId, rotate,
        nameEnc: await encryptOrchardName('Acme', generation3, orchardId: orchardId, generation: 3),
        copies: [for (final uid in [_owner, _admin, _newcomer]) await copyFor(uid)]);

    await joined.service.refresh();
    expect((await directory.pin(_admin))?.hardStop, isTrue, reason: 'keys the record took by adding them again');
    Future<List<int>> generations() async => [
          for (final row in await (await joined.db(orchardId))
              .customSelect("SELECT generation FROM space_keys WHERE scope = 'orchard' ORDER BY generation")
              .get())
            row.read<int>('generation'),
        ];
    expect(await generations(), [1, 2], reason: 'what the stopped keys sealed does not open');

    // Someone compared the new fingerprint: trusted, and it opens.
    await joined.service.verifyMember(orchardId, _admin);
    await joined.service.refresh();
    expect(await generations(), [1, 2, 3]);
  });

  test('inviting passes the address in lower case; the lists and answers go to the server', () async {
    final owner = device(_owner, ownerKeys);
    final (orchardId, crateA, _, role) = await ownersOrchard(owner);
    final emailed = await owner.service.invite(orchardId,
        email: '  New@Example.COM ', role: role, grants: {crateA: levelSwitches(CrateLevel.edit)});
    expect(emailed, isTrue);
    final sent = server.sentInvites.single;
    expect(sent.email, 'new@example.com');
    expect(sent.role, role);
    expect(sent.grants, {crateA: levelSwitches(CrateLevel.edit)});
    final invite = (await owner.service.invites(orchardId)).single;
    expect(invite.email, 'new@example.com');

    // Accepted: the owner is told someone waits.
    server.acceptAs(orchardId, invite.id, _newcomer);
    await owner.service.refresh();
    expect(owner.service.invitesWaiting, {orchardId: 1});
    await owner.service.withdrawInvite(orchardId, invite.id);
    expect(server.withdrawn, [invite.id]);

    final invitee = device(_newcomer, newKeys);
    server.mine.add(MyInvite(
      id: 'invite-7',
      orchardId: orchardId,
      role: role,
      crates: 1,
      expiresAt: DateTime.now().add(const Duration(days: 3)),
      accepted: false,
      invitedBy: 'owner@example.com',
    ));
    expect((await invitee.service.myInvites()).single.invitedBy, 'owner@example.com');
    await invitee.service.acceptInvite('invite-7');
    expect(server.accepted, ['invite-7']);
    await invitee.service.declineInvite('invite-7');
    expect(server.declined, ['invite-7']);
  });

  test('accepting needs the account keys on this device', () async {
    final storage = _MemoryStorage();
    final service = OrchardService(
      server: server.as(_newcomer),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => null,
    );
    await expectLater(service.acceptInvite('invite-1'), throwsA(isA<AccountKeysNotReady>()));
    expect(server.accepted, isEmpty);
  });
}
