import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Invitations (3.0) against the REAL server routes on a real
/// Postgres: an owner invites an address, the person accepts on their own
/// device, the owner's device confirms them with every key generation
/// sealed to the keys they published, and from then on each device opens
/// what the other writes. Start the server:
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

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get())
          r.data.values.map((v) => '$v').join(':'),
      ];
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
    final uid = 'inv-$name-${now()}-${accounts++}';
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
    final d = _Device(storage, service,
        OrchardSyncCoordinator(service: service, server: server, databases: databases));
    devices.add(d);
    return d;
  }

  Future<void> addHost(AppDatabase db, String id) async {
    final at = DateTime(2026, 9, 24);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: '10.0.0.9', port: const Value(22), createdAt: at, updatedAt: at));
  }

  test('invite, accept, compare and confirm: the new member opens every generation, and edits flow both ways',
      () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final newcomer = await account('new');
    final o = device(owner);
    final orchardId = await o.service.createOrchard('Invites', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await o.service.createCrate(orchardId, 'Staging');
    // A second generation of every key, so "every generation" means two.
    expect(await o.service.rotateAll(), isEmpty);
    final production = (await o.service.server.orchards())
        .firstWhere((x) => x.id == orchardId)
        .crates
        .firstWhere((c) => c.id != staging)
        .id;
    await addHost(await o.db(orchardId), 'h-owner');
    await o.coordinator.syncAll();

    // The owner invites the newcomer's address into the Orchard's first role
    // (use of Production), with edit on Production on top.
    final role = (await o.service.roles(orchardId)).single.id;
    final emailed = await o.service.invite(orchardId,
        email: '${newcomer.uid}@EXAMPLE.com', role: role, grants: {production: levelSwitches(CrateLevel.edit)});
    expect(emailed, isFalse, reason: 'no email service on the test server');

    // The newcomer sees it and accepts.
    final n = device(newcomer);
    final mine = await n.service.myInvites();
    expect(mine, hasLength(1));
    expect(mine.single.orchardId, orchardId);
    expect(mine.single.crates, 1);
    expect(mine.single.invitedBy, '${owner.uid}@example.com');
    expect(mine.single.accepted, isFalse);
    await n.service.acceptInvite(mine.single.id);
    expect((await n.service.myInvites()).single.accepted, isTrue);

    // The owner is told someone waits, and sees the keys they published.
    await o.service.refresh();
    expect(o.service.invitesWaiting[orchardId], 1);
    final invite = (await o.service.invites(orchardId)).single;
    expect(invite.email, '${newcomer.uid}@example.com');
    expect(invite.acceptedUid, newcomer.uid);
    final own = await newcomer.keys.publish(newcomer.uid);
    expect(invite.acceptedKeys!.fingerprint, own.fingerprint,
        reason: 'the fingerprint the owner compares is the one the newcomer reads out');

    // They compare; the owner's device adds them.
    await o.service.confirmInvite(orchardId, invite);
    expect(await o.service.invites(orchardId), isEmpty);
    expect(await n.service.myInvites(), isEmpty);
    expect(o.service.invitesWaiting[orchardId], 0);

    // The newcomer's device opens both generations of the Orchard key and
    // of Production, sealed by the owner; Staging was not offered.
    final reports = await n.coordinator.syncAll();
    expect(reports.keys, [orchardId]);
    expect(await n.rows(orchardId, 'SELECT name, role FROM orchard_info'), ['Invites:$role']);
    // The record, as the newcomer checked it: the second generation of each
    // of the three keys is an entry too, and every key the newcomer
    // opened is the one its entry committed to.
    expect(await n.rows(orchardId, 'SELECT type FROM orchard_record_entries ORDER BY seq'),
        ['create', 'crate.add', 'key.rotate', 'key.rotate', 'key.rotate', 'member.add'],
        reason: 'the record, as the newcomer checked it');
    expect(await n.rows(orchardId, 'SELECT scope, generation FROM space_keys ORDER BY scope, generation'),
        ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);
    expect(await n.rows(orchardId, 'SELECT crate_id, name, level FROM orchard_crates'),
        ['$production:Production:edit']);
    expect(await n.rows(orchardId, 'SELECT id FROM connections'), ['h-owner'],
        reason: "the owner's host, its signature checked against the owner's pinned key");
    expect(reports[orchardId]!.rejected, 0);

    // The newcomer sees the owner's check of their keys.
    final nDb = await n.db(orchardId);
    final view = await MemberDirectory(nDb).view(newcomer.uid);
    expect(view.firstWhere((m) => m.isMe).verifiedBy, [owner.uid]);
    expect(view.firstWhere((m) => m.uid == owner.uid).role, 'owner');

    // What the newcomer writes, the owner's device opens: it pinned the
    // newcomer's keys when it confirmed them.
    await addHost(nDb, 'h-new');
    expect((await n.coordinator.syncAll())[orchardId]!.sent, 1);
    final back = await o.coordinator.syncAll();
    expect(back[orchardId]!.rejected, 0);
    expect(await o.rows(orchardId, 'SELECT id FROM connections ORDER BY id'), ['h-new', 'h-owner']);
    final oView = await MemberDirectory(await o.db(orchardId)).view(owner.uid);
    expect(oView.firstWhere((m) => m.uid == newcomer.uid).verifiedByMe, isTrue);
  });

  test('keys that changed after the comparison add no one; comparing the new ones does', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    var newcomer = await account('new');
    final o = device(owner);
    final orchardId = await o.service.createOrchard('Invites', firstCrateName: 'Production', memberRoleName: 'Member');
    await o.service.invite(orchardId,
        email: '${newcomer.uid}@example.com', role: (await o.service.roles(orchardId)).single.id);
    final n = device(newcomer);
    await n.service.acceptInvite((await n.service.myInvites()).single.id);
    final compared = (await o.service.invites(orchardId)).single;

    // Meanwhile the newcomer replaces their keys (a lost device, say).
    final next = await AccountKeys.generate(version: 2);
    final nextPublished = await next.publish(newcomer.uid);
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(newcomer.uid))
        .replace(nextPublished, endorsement: await newcomer.keys.endorse(nextPublished), copies: const []);
    newcomer = CrateAuthor(uid: newcomer.uid, keys: next);

    // What was compared no longer holds: nobody is added, nothing pinned.
    await expectLater(
      o.service.confirmInvite(orchardId, compared),
      throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'recipient-keys-changed')),
    );
    expect(await MemberDirectory(await o.db(orchardId)).pin(newcomer.uid), isNull);

    // Read again, the list shows the new keys: those are compared and added.
    final fresh = (await o.service.invites(orchardId)).single;
    expect(fresh.acceptedKeys!.version, 2);
    expect(fresh.acceptedKeys!.fingerprint, nextPublished.fingerprint);
    await o.service.confirmInvite(orchardId, fresh);
    final pin = await MemberDirectory(await o.db(orchardId)).pin(newcomer.uid);
    expect(pin?.keyVersion, 2);
    expect(pin?.verifiedByMe, isTrue);
  });

  test('an invite code: made on the owner\'s device, checked on both sides, used once, '
      'then let in without comparing; the real routes never see the code', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('code-owner');
    final newcomer = await account('code-new');
    final other = await account('code-other');
    final o = device(owner);
    final orchardId = await o.service.createOrchard('Codes', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = (await o.service.roles(orchardId)).single.id;
    final made = await o.service.makeInviteCode(orchardId,
        role: role,
        expiresIn: 3600,
        shown: const JoinOffer(team: 'Codes', role: 'Member', vaults: [JoinOfferVault('Production', 'use')]));
    expect(made.expiresAt.difference(DateTime.now()).inMinutes, inInclusiveRange(58, 60));

    // The newcomer types it, checks it and accepts.
    final n = device(newcomer);
    final preview = await n.service.previewInviteCode(writtenJoinCode(made.code).toLowerCase());
    expect(preview.shown.team, 'Codes');
    expect(preview.offer.invite.invitedBy, '${owner.uid}@example.com');
    expect(await n.service.acceptInviteCode(preview), made.inviteId);
    expect((await n.service.myInvites()).single.byCode, isTrue);

    // Used up: anyone else gets what an unknown code gets.
    final x = device(other);
    await expectLater(x.service.previewInviteCode(made.code),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'join-code-invalid')));

    // The owner's device checks the newcomer's keys with the code, and lets
    // them in.
    final invite = (await o.service.invites(orchardId)).single;
    expect(invite.byCode, isTrue);
    expect(invite.email, '${newcomer.uid}@example.com');
    final check = await o.service.checkInviteCode(orchardId, invite);
    expect(check.checked, isTrue);
    await o.service.confirmInvite(orchardId, invite);
    expect(await o.service.invites(orchardId), isEmpty);
    expect((await n.coordinator.syncAll()).keys, [orchardId]);
  });
}
