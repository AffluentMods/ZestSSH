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
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../helpers/record_statements.dart';

import 'fake_crate_server.dart';

/// Other members' keys on a device (3.0): a teammate the
/// Orchard's record brings in is pinned when first seen and their edits
/// count; keys the record took through member.keys (vouched for by the ones
/// before) are followed; keys it took any other way (removed and added again)
/// stop their edits until someone compares and checks them; "verified by"
/// counts only statements this device can check; and the member list is
/// read again only when the server's tag for it moves.

const _me = 'owner-1';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys myKeys;
  late FakeCrateServer server;
  late _MemoryStorage storage;
  late OrchardService service;
  late OrchardSyncCoordinator sync;

  setUpAll(() async => myKeys = await AccountKeys.generate());

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _me);
    storage = _MemoryStorage();
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    service = OrchardService(
        server: server,
        databases: databases,
        author: () async => CrateAuthor(uid: _me, keys: myKeys));
    sync = OrchardSyncCoordinator(service: service, server: server, databases: databases);
  });

  tearDown(() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  });

  /// An Orchard with one host synced; returns its id and its Crate.
  Future<(String, String)> orchardWithHost() async {
    final id = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final db = await service.databases.open(id);
    final at = DateTime(2026, 9, 24);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'mine', host: '10.0.0.1', port: const Value(22), createdAt: at, updatedAt: at));
    await sync.syncAll();
    final crate = server.orchardsById[id]!.crates.single.id;
    return (id, crate);
  }

  /// [by] (signing with [keys]) appends one entry to the record, as their
  /// device would.
  Future<void> append(String orchardId, String by, AccountKeys keys, String type, Map<String, Object?> body) async {
    final r = server.recordOf(orchardId);
    final entry = await signRecordEntry(keys,
        orchardId: orchardId, seq: r.seq + 1, prev: r.head, type: type, body: body, by: by);
    await server.appendAs(by, orchardId, [entry], checkCopies: false);
  }

  /// [uid] added by this account with [keys], in the Orchard's first role
  /// (or [role]), with edit access to [crate] on top of it.
  Future<void> addMember(String orchardId, String uid, AccountKeys keys,
      {String? crate, String? role, String? email}) async {
    await server.publish(uid, keys, email: email);
    await append(orchardId, _me, myKeys, RecordTypes.memberAdd, {
      ...recordKeysBody(await keys.publish(uid)),
      'uid': uid,
      'role': role ?? server.recordOf(orchardId).roles.values.single.id,
      if (crate != null) 'grants': {crate: switchList(levelSwitches(CrateLevel.edit))},
      // Owners and admins join with the statement that they were compared.
      if (role == FixedRoles.admin || role == FixedRoles.owner)
        'verified': await comparedStatement(myKeys, _me, orchardId, await keys.publish(uid)),
    });
  }

  /// [uid] replaces their keys [from] with [to], vouched for by [from].
  Future<void> newKeys(String orchardId, String uid, AccountKeys from, AccountKeys to) async {
    final published = await to.publish(uid);
    await append(orchardId, uid, to, RecordTypes.memberKeys, {
      ...recordKeysBody(published),
      'endorsement': base64Encode(await from.endorse(published)),
    });
    server.published[uid] = published;
  }

  /// Another member's edit of host h-1, signed with [keys] as [uid], put on
  /// the server as the item's newest version, naming the record's last
  /// entry as the one it was written after.
  Future<void> editAs(String uid, AccountKeys keys, String orchardId, String crateId, String label) async {
    final db = await service.databases.open(orchardId);
    final data = (await OrchardItemStore(db).read('host', 'h-1'))!;
    final rows = (data['connections']! as List).cast<Map<String, Object?>>();
    final record = server.recordOf(orchardId);
    final item = ItemRecord(
      kind: 'host',
      key: 'h-1',
      author: uid,
      authorKeyVersion: keys.version,
      editedAt: DateTime.now().millisecondsSinceEpoch,
      data: {
        ...data,
        'connections': [
          {...rows.single, 'label': label},
        ],
      },
      recordSeq: record.seq,
      recordHead: record.head,
    );
    final generation = server.crateGenerations[crateId]!;
    final key = (await db.customSelect(
      "SELECT secret FROM space_keys WHERE scope = 'crate' AND scope_id = ? AND generation = ?",
      variables: [Variable(crateId), Variable(generation)],
    ).getSingle())
        .read<Uint8List>('secret');
    final itemId = server.items[crateId]!.keys.single;
    server.forceItem(
      crateId,
      await sealItem(item,
          place: ItemPlace(orchardId: orchardId, crateId: crateId, itemId: itemId, generation: generation),
          crateKey: key,
          signer: keys),
    );
  }

  Future<String> label(String orchardId) async => (await (await service.databases.open(orchardId))
          .customSelect("SELECT label FROM connections WHERE id = 'h-1'")
          .getSingle())
      .read<String>('label');

  test('a teammate is pinned when first seen, and then their edits count', () async {
    final (id, crate) = await orchardWithHost();
    final alice = await AccountKeys.generate();

    // Not a member: refused.
    await editAs('alice', alice, id, crate, 'alice-1');
    expect((await sync.syncAll())[id]!.rejected, 1);
    expect(await label(id), 'mine');

    await addMember(id, 'alice', alice, crate: crate, email: 'alice@example.com');
    await sync.syncAll();
    await editAs('alice', alice, id, crate, 'alice-2');
    final report = (await sync.syncAll())[id]!;
    expect(report.rejected, 0);
    expect(await label(id), 'alice-2');

    final view = await MemberDirectory(await service.databases.open(id)).view(_me);
    expect(view.map((m) => m.uid), [_me, 'alice'], reason: 'this account first');
    expect(view.first.isMe, isTrue);
    expect(view[1].email, 'alice@example.com');
    expect(view[1].keyVersion, 1);
    expect(view[1].verifiedByMe, isFalse);
    expect(view[1].hardStop, isFalse);
  });

  test('keys the record took through member.keys are followed; keys it took any other way stop edits until checked',
      () async {
    final (id, crate) = await orchardWithHost();
    final v1 = await AccountKeys.generate(version: 1);
    final v2 = await AccountKeys.generate(version: 2);
    final v3 = await AccountKeys.generate(version: 3);

    await addMember(id, 'alice', v1, crate: crate);
    await sync.syncAll();

    // Replaced on a device that had version 1: followed.
    await newKeys(id, 'alice', v1, v2);
    await sync.syncAll();
    await editAs('alice', v2, id, crate, 'from-v2');
    expect((await sync.syncAll())[id]!.rejected, 0);
    expect(await label(id), 'from-v2');

    // Removed and added again with keys version 2 never vouched for: a hard
    // stop, her new key counts for nothing.
    await append(id, _me, myKeys, RecordTypes.memberRemove, {'uid': 'alice'});
    await addMember(id, 'alice', v3, crate: crate);
    await sync.syncAll();
    await editAs('alice', v3, id, crate, 'from-v3');
    expect((await sync.syncAll())[id]!.rejected, 1);
    expect(await label(id), 'from-v2');
    final stopped = (await MemberDirectory(await service.databases.open(id)).view(_me))[1];
    expect(stopped.hardStop, isTrue);
    expect(stopped.keyVersion, 2);
    expect(stopped.pending!.version, 3);
    // No key is sealed to keys this device stops on: a Crate she would gain
    // is refused here, before anything is sent.
    final staging = await service.createCrate(id, 'Staging');
    await expectLater(
      service.change(id, RecordTypes.memberSet, {
        'uid': 'alice',
        'grants': {
          crate: switchList(levelSwitches(CrateLevel.edit)),
          staging: switchList(levelSwitches(CrateLevel.use)),
        },
      }),
      throwsA(isA<MemberKeysNotTrusted>()),
    );
    expect(server.recordOf(id).switchesOf('alice', staging), isEmpty);

    // Someone compared the new fingerprint with her: checked and trusted.
    await service.verifyMember(id, 'alice');
    final statement = server.verifications.single;
    expect(statement.subjectUid, 'alice');
    expect(statement.subjectKeyVersion, 3);
    expect(
      await verifyMemberVerification(myKeys.signingPublicKey, statement.signature,
          orchardId: id,
          subjectUid: 'alice',
          subjectKeyVersion: 3,
          fingerprint: (await v3.publish('alice')).fingerprint,
          verifierUid: _me,
          verifierKeyVersion: myKeys.version),
      isTrue,
    );
    final checked = (await MemberDirectory(await service.databases.open(id)).view(_me))[1];
    expect(checked.hardStop, isFalse);
    expect(checked.keyVersion, 3);
    expect(checked.verifiedByMe, isTrue);
    await editAs('alice', v3, id, crate, 'from-v3-again');
    expect((await sync.syncAll())[id]!.rejected, 0);
    expect(await label(id), 'from-v3-again');
  });

  test('after a replacement their old keys vouched for, "verified by you" turns amber until compared again',
      () async {
    final (id, crate) = await orchardWithHost();
    final v1 = await AccountKeys.generate(version: 1);
    final v2 = await AccountKeys.generate(version: 2);
    await addMember(id, 'alice', v1, crate: crate);
    await sync.syncAll();
    await service.verifyMember(id, 'alice');
    Future<MemberView> alice() async =>
        (await MemberDirectory(await service.databases.open(id)).view(_me)).firstWhere((m) => m.uid == 'alice');
    expect(((await alice()).verifiedByMe, (await alice()).replacedSinceCompared), (true, false));

    // She replaces her keys, version 1 vouching for version 2: followed
    // without a stop, but what was compared were the old keys.
    await newKeys(id, 'alice', v1, v2);
    await sync.syncAll();
    final replaced = await alice();
    expect(replaced.keyVersion, 2);
    expect(replaced.hardStop, isFalse);
    expect(replaced.verifiedByMe, isFalse);
    expect(replaced.replacedSinceCompared, isTrue);
    expect(replaced.verifiedBy, isEmpty, reason: 'statements cover the keys they were made for');

    // Compared again: verified, no longer amber, and stored so.
    await service.verifyMember(id, 'alice');
    final again = await alice();
    expect((again.verifiedByMe, again.replacedSinceCompared), (true, false));
    final stored = await (await service.databases.open(id))
        .customSelect("SELECT verified_by_me, replaced_since_compared FROM member_keys WHERE uid = 'alice'")
        .getSingle();
    expect(stored.data, {'verified_by_me': 1, 'replaced_since_compared': 0});
    // A later sync keeps it so.
    await sync.syncAll();
    expect(((await alice()).verifiedByMe, (await alice()).replacedSinceCompared), (true, false));
  });

  test('verified by counts checkable statements only; the list is read again only when its tag moves',
      () async {
    final (id, _) = await orchardWithHost();
    final aliceKeys = await AccountKeys.generate();
    final bobKeys = await AccountKeys.generate();
    final carolKeys = await AccountKeys.generate();
    await addMember(id, 'alice', aliceKeys);
    await addMember(id, 'bob', bobKeys, role: FixedRoles.admin);
    final alice = await aliceKeys.publish('alice');
    Future<void> check(String by, AccountKeys keys) async => server.addVerification(id,
        by: by,
        subjectUid: 'alice',
        subjectKeyVersion: alice.version,
        keyVersion: keys.version,
        signature: await signMemberVerification(keys, verifierUid: by, orchardId: id, subject: alice));
    await check('bob', bobKeys);
    await check('carol', carolKeys); // carol is not a member
    final reads = server.memberReads.length;
    await sync.syncAll();
    expect(server.memberReads, hasLength(reads + 1));
    final view = await MemberDirectory(await service.databases.open(id)).view(_me);
    expect(view.firstWhere((m) => m.uid == 'alice').verifiedBy, ['bob']);

    await sync.syncAll();
    expect(server.memberReads, hasLength(reads + 1), reason: 'the tag did not move');
    await append(id, _me, myKeys, RecordTypes.memberRemove, {'uid': 'alice'});
    await append(id, _me, myKeys, RecordTypes.memberRemove, {'uid': 'bob'});
    await sync.syncAll();
    expect(server.memberReads, hasLength(reads + 2));
    expect((await MemberDirectory(await service.databases.open(id)).view(_me)).map((m) => m.uid), [_me],
        reason: 'members who left are not shown');
  });

  // To-do 59: the members page shows a name first with the address under it,
  // and a picture, from what the server lists.
  test('names and pictures from the list are kept on the device and shown; a later list without them drops them',
      () async {
    final (id, _) = await orchardWithHost();
    final aliceKeys = await AccountKeys.generate();
    server.names['alice'] = 'Alice Example';
    server.pictures['alice'] = 'https://lh3.googleusercontent.com/a/alice';
    await addMember(id, 'alice', aliceKeys, email: 'alice@example.com');
    await sync.syncAll();
    Future<MemberView> alice() async =>
        (await MemberDirectory(await service.databases.open(id)).view(_me)).firstWhere((m) => m.uid == 'alice');
    expect(((await alice()).name, (await alice()).picture, (await alice()).email),
        ('Alice Example', 'https://lh3.googleusercontent.com/a/alice', 'alice@example.com'));

    await sync.syncAll();
    expect((await alice()).name, 'Alice Example', reason: 'the list was not read again: what was kept stays');

    server.names.clear();
    server.pictures.clear();
    await addMember(id, 'bob', await AccountKeys.generate());
    await sync.syncAll();
    expect(((await alice()).name, (await alice()).picture), (null, null));
  });

  test('a check this account signed on another of its devices shows as verified by you', () async {
    final (id, _) = await orchardWithHost();
    final aliceKeys = await AccountKeys.generate();
    final bobKeys = await AccountKeys.generate();
    await addMember(id, 'alice', aliceKeys);
    await addMember(id, 'bob', bobKeys, role: FixedRoles.admin);
    final alice = await aliceKeys.publish('alice');
    Future<void> check(String by, AccountKeys keys) async => server.addVerification(id,
        by: by,
        subjectUid: 'alice',
        subjectKeyVersion: alice.version,
        keyVersion: keys.version,
        signature: await signMemberVerification(keys, verifierUid: by, orchardId: id, subject: alice));
    await check(_me, myKeys);
    await check('bob', bobKeys);
    await sync.syncAll();
    final view = await MemberDirectory(await service.databases.open(id)).view(_me);
    final row = view.firstWhere((m) => m.uid == 'alice');
    expect(row.verifiedByMe, isTrue);
    expect(row.verifiedBy, ['bob'], reason: 'the others who checked, without this account');
  });
}
