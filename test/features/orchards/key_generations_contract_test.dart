import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../helpers/contract_run.dart';

/// Key generations and removal against the REAL server routes (ZestSSH Cloud's
/// routes/orchards.js and lib/orchard_record.js) on a real Postgres (3.0
/// release): a new generation goes through the record and every holder opens
/// it as the key the record committed to; a copy holding another key is
/// refused by the device that gets it, whoever signed it; someone removed
/// makes no new generation; suspending someone wants a recent sign-in; and
/// an end date that passed leaves the member out of the next key. Start the
/// server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

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

/// An account: its key service, and one device of its.
class _Account {
  _Account(this.uid, this.keys, this.service, this.server);

  final String uid;
  final AccountKeyService keys;
  final OrchardService service;
  final OrchardsApi server;

  Future<AccountKeys> accountKeys() async => (await keys.readyKeys())!.keys;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  /// The key generations this device holds: "orchard:1", "crate:2", ...
  Future<List<String>> held(String orchardId) async => [
        for (final r in await (await db(orchardId))
            .customSelect('SELECT scope, generation FROM space_keys ORDER BY scope, generation')
            .get())
          '${r.read<String>('scope')}:${r.read<int>('generation')}',
      ];
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// When each account last signed in; now unless a test says otherwise.
  final signedInAt = <String, int>{};
  String token(String uid) => 'fb:$uid:${signedInAt[uid] ?? now()}:${now()}';

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
    for (final s in opened) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    opened.clear();
    signedInAt.clear();
  });

  var made = 0;

  Future<_Account> account(String name) async {
    final uid = 'keygen-$name-$contractRun-${made++}';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid)),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(uid));
    final storage = _MemoryStorage();
    opened.add(storage);
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final service = OrchardService(
      server: server,
      databases: databases,
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    return _Account(uid, keyService, service, server);
  }

  Future<void> join(_Account by, _Account person, String orchardId) async {
    final role = (await by.service.roles(orchardId)).single.id;
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
  }

  /// The record as the server holds it, checked entry by entry.
  Future<OrchardRecord> serverRecord(_Account reader, String orchardId) async {
    final page = await reader.server.record(orchardId, after: 0);
    return OrchardRecord.replay(orchardId, page.entries);
  }

  test('a new generation goes through the record, and every holder opens it as the key it committed to', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Keys', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, orchardId);

    expect(await owner.service.rotateAll(), isEmpty);
    final record = await serverRecord(owner, orchardId);
    expect((record.generationOf(kOrchardScope), record.generationOf(record.crates.keys.single)), (2, 2));
    final page = await owner.server.record(orchardId, after: 0);
    expect([for (final e in page.entries.skip(page.entries.length - 2)) e.type], [RecordTypes.keyRotate, RecordTypes.keyRotate]);

    await alice.service.refresh();
    expect(await alice.held(orchardId), ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);
    final mine = (await LocalRecord.load(await alice.db(orchardId), orchardId)).latest;
    final crateId = mine.crates.keys.single;
    for (final r in await (await alice.db(orchardId))
        .customSelect('SELECT scope, scope_id, generation, secret FROM space_keys')
        .get()) {
      final scope = r.read<String>('scope') == 'orchard' ? kOrchardScope : r.read<String>('scope_id');
      final g = r.read<int>('generation');
      expect(
          await keyMatchesCommitment(r.read<Uint8List>('secret'), mine.keyCommitOf(scope, g),
              orchardId: orchardId, crateId: scope == kOrchardScope ? null : crateId, generation: g),
          isTrue,
          reason: '$scope $g');
    }
  });

  test('a copy holding another key than the committed one is refused by the device that gets it', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Forged', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, orchardId);
    await alice.service.refresh();

    // A modified app of the owner's: it commits to one key and seals another
    // to Alice, each copy correctly signed. The server cannot tell.
    final ownerKeys = await owner.accountKeys();
    final record = await serverRecord(owner, orchardId);
    final committed = newSpaceKey();
    final other = newSpaceKey();
    final entry = await signRecordEntry(ownerKeys,
        orchardId: orchardId,
        seq: record.seq + 1,
        prev: record.head,
        type: RecordTypes.keyRotate,
        by: owner.uid,
        body: {
          'generation': 2,
          'key_commit': base64Encode(await keyCommitment(committed, orchardId: orchardId, generation: 2)),
        });
    Future<GrantCopy> copy(String uid, Uint8List key) async {
      final keys = record.members[uid]!.currentKeys;
      final sealed = await sealOrchardKey(keys.encryptionKey, key, orchardId: orchardId, generation: 2);
      return GrantCopy(
        uid: uid,
        generation: 2,
        sealed: sealed,
        signature: await signKeyCopy(
            ownerKeys,
            KeyCopyPlace(
              orchardId: orchardId,
              generation: 2,
              recipient: uid,
              recipientKeyVersion: keys.version,
              sealer: owner.uid,
              sealerKeyVersion: ownerKeys.version,
            ),
            sealed),
      );
    }

    final generation = await owner.server.rotateKey(orchardId, entry,
        nameEnc: await encryptOrchardName('Forged', committed, orchardId: orchardId, generation: 2),
        copies: [await copy(owner.uid, committed), await copy(alice.uid, other)]);
    expect(generation, 2, reason: 'the server took it: it cannot open a copy');

    await alice.service.refresh();
    expect(await alice.held(orchardId), isNot(contains('orchard:2')),
        reason: "the key in Alice's copy is not the one the record committed to");
    await owner.service.refresh();
    expect(await owner.held(orchardId), contains('orchard:2'), reason: "the owner's copy is the committed key");
  });

  test('someone removed makes no new generation: the server refuses it, and so would every device', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Leavers', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, orchardId);
    await owner.service.setMemberRole(orchardId, alice.uid, FixedRoles.admin);
    await owner.service.removeMember(orchardId, alice.uid);

    final record = await serverRecord(owner, orchardId);
    final aliceKeys = await alice.accountKeys();
    final theirs = newSpaceKey();
    final entry = await signRecordEntry(aliceKeys,
        orchardId: orchardId,
        seq: record.seq + 1,
        prev: record.head,
        type: RecordTypes.keyRotate,
        by: alice.uid,
        body: {
          'generation': record.orchardGeneration + 1,
          'key_commit': base64Encode(
              await keyCommitment(theirs, orchardId: orchardId, generation: record.orchardGeneration + 1)),
        });
    await expectLater(
        alice.server.rotateKey(orchardId, entry,
            nameEnc: await encryptOrchardName('x', theirs, orchardId: orchardId, generation: 2), copies: const []),
        throwsA(isA<OrchardServerException>().having((e) => e.notFound, 'not found', isTrue)));
    // Served by a hacked server, a device refuses it by the record's rules.
    await expectLater(record.copy().append(entry),
        throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'not an active member')));
  });

  test('suspending someone wants a sign-in from the last few minutes', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Recent', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, orchardId);

    signedInAt[owner.uid] = now() - 3 * 3600;
    await expectLater(owner.service.suspendMember(orchardId, alice.uid),
        throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'recent sign-in', isTrue)));
    expect((await serverRecord(owner, orchardId)).members[alice.uid]!.status, MemberStatus.active);

    signedInAt[owner.uid] = now();
    await owner.service.suspendMember(orchardId, alice.uid);
    expect((await serverRecord(owner, orchardId)).members[alice.uid]!.status, MemberStatus.suspended);
  });

  test('an end date that passed leaves the member out of the next generation, as the server agrees', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchardId =
        await owner.service.createOrchard('Ends', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, orchardId);
    await owner.service.setMemberEndsAt(orchardId, alice.uid, now() - 60);

    expect(await owner.service.rotateAll(), isEmpty);
    expect((await serverRecord(owner, orchardId)).generationOf(kOrchardScope), 2);
    final listed = await alice.server.orchards();
    expect(listed.single.status, 'ended');

    // More time: every generation comes back to her.
    await owner.service.setMemberEndsAt(orchardId, alice.uid, now() + 3600);
    await alice.service.refresh();
    expect(await alice.held(orchardId), ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);
  });
}
