import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Members and member checks (3.0) against the REAL server routes
/// (GET /v1/orchards/:id/members, POST /v1/orchards/:id/verifications, the
/// members tag on the Orchard list) on a real Postgres. Start the server:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. A second member is added through
/// the test server's test-only route until invitations exist.

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
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];

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
    for (final s in opened) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    opened.clear();
  });

  Future<CrateAuthor> account(String uid) async {
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  OrchardService device(CrateAuthor me) {
    final storage = _MemoryStorage();
    opened.add(storage);
    return OrchardService(
      server: OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid)),
      databases:
          OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => me,
    );
  }

  test('members see each other, and a check is signed, stored and counted', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('m-owner-${now()}');
    final alice = await account('m-alice-${now()}');
    final ownerDevice = device(owner);
    final orchardId = await ownerDevice.createOrchard('Members', firstCrateName: 'Production', memberRoleName: 'Member');
    // Alice joins the way anyone does: invited, accepted, compared, added.
    await ownerDevice.invite(orchardId,
        email: '${alice.uid}@example.com', role: (await ownerDevice.roles(orchardId)).single.id);
    final aliceDevice = device(alice);
    await aliceDevice.acceptInvite((await aliceDevice.myInvites()).single.id);
    await ownerDevice.confirmInvite(orchardId, (await ownerDevice.invites(orchardId)).single);

    await ownerDevice.refresh();
    final ownerDb = await ownerDevice.databases.open(orchardId);
    var view = await MemberDirectory(ownerDb).view(owner.uid);
    expect(view.map((m) => m.uid).toSet(), {owner.uid, alice.uid});
    final aliceRow = view.firstWhere((m) => m.uid == alice.uid);
    expect(aliceRow.keyVersion, 1);
    expect(aliceRow.fingerprint, (await alice.keys.publish(alice.uid)).fingerprint,
        reason: 'the same fingerprint Alice sees for herself');
    expect(aliceRow.email, '${alice.uid}@example.com');

    // The owner compares Alice's fingerprint with her and checks it.
    await ownerDevice.verifyMember(orchardId, alice.uid);

    // Alice's device sees the owner's statement for her keys and counts it.
    await aliceDevice.refresh();
    final aliceDb = await aliceDevice.databases.open(orchardId);
    view = await MemberDirectory(aliceDb).view(alice.uid);
    expect(view.firstWhere((m) => m.isMe).verifiedBy, [owner.uid]);

    // The owner's own refresh, with nothing new: the tag keeps it from
    // reading the list again, and its row stays "verified by you".
    await ownerDevice.refresh();
    view = await MemberDirectory(ownerDb).view(owner.uid);
    expect(view.firstWhere((m) => m.uid == alice.uid).verifiedByMe, isTrue);
  });
}
