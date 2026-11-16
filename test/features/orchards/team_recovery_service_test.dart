import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'fake_crate_server.dart';

/// Team recovery from the devices' side (3.0): a member who lost
/// every device starts over with new keys and waits in the Orchard; one
/// owner approves the new keys, a second owner completes, and the member's
/// new device opens everything it held again. What the rules would refuse
/// is refused before anything is sent, and the status keeps only what a
/// device can check. The (fake) server holds to the same rules as
/// ZestSSH Cloud's routes.

const _owner = 'owner-1';
const _owner2 = 'owner-2';
const _alice = 'alice';
const _bob = 'bob';

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
  }

  final String uid;
  final AccountKeys keys;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await service.databases.open(orchardId)).customSelect(sql).get())
          r.data.values.join(':'),
      ];

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
  late AccountKeys alice2;
  late AccountKeys alice3;
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    for (final uid in [_owner, _owner2, _alice, _bob]) {
      keys[uid] = await AccountKeys.generate();
    }
    alice2 = await AccountKeys.generate(version: 2);
    alice3 = await AccountKeys.generate(version: 3);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _owner2, _alice, _bob]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid, [AccountKeys? with_]) {
    final d = _Device(server, uid, with_ ?? keys[uid]!);
    devices.add(d);
    return d;
  }

  Future<void> join(_Device by, _Device person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    final invite = (await by.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, person.uid);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    expect(await person.service.refresh(), contains(orchardId));
  }

  /// An Orchard with two owners, alice and bob in the first role (use of
  /// Production), and Staging (owners only by the roles), team recovery on
  /// unless [on] is false.
  Future<({String id, String production, String staging, _Device owner, _Device owner2, _Device alice, _Device bob})>
      team({bool on = true}) async {
    final owner = device(_owner);
    final owner2 = device(_owner2);
    final alice = device(_alice);
    final bob = device(_bob);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(id, 'Staging');
    final member = server.recordOf(id).roles.values.single;
    await join(owner, owner2, id, FixedRoles.owner);
    await join(owner, alice, id, member.id);
    await join(owner, bob, id, member.id);
    if (on) await owner.service.setTeamRecovery(id, true);
    return (
      id: id,
      production: member.crates.keys.single,
      staging: staging,
      owner: owner,
      owner2: owner2,
      alice: alice,
      bob: bob,
    );
  }

  test('a member who lost every key waits; one owner approves, a second completes, and their new device opens all again',
      () async {
    final t = await team();
    expect(server.recordOf(t.id).teamRecovery, isTrue);
    // The keys moved on once: both generations come back.
    expect(await t.owner.service.rotateAll(), isEmpty);

    // Every device alice had is gone, with the keys; they start over.
    await server.resetKeys(_alice, alice2);
    final aliceNew = device(_alice, alice2);
    expect(await aliceNew.service.refresh(), isEmpty, reason: 'nothing to sync while waiting');
    expect(await aliceNew.rows(t.id, 'SELECT status FROM orchard_info'), [kRecoveryWaitStatus]);
    expect(await aliceNew.rows(t.id, 'SELECT scope FROM space_keys'), isEmpty);

    // The owners see alice waiting with the new keys; alice sees their own wait; bob, nobody.
    var status = await t.owner.service.teamRecovery(t.id);
    expect(status.on, isTrue);
    expect(status.owners, 2);
    final wait = status.waiting.single;
    expect(wait.uid, _alice);
    expect(wait.email, 'alice@example.com');
    expect(wait.keys.version, 2);
    expect(wait.keys.fingerprint, (await alice2.publish(_alice)).fingerprint);
    expect(wait.recordKeyVersion, 1);
    expect(wait.approvals, isEmpty);
    expect((await aliceNew.service.teamRecovery(t.id)).waiting.single.uid, _alice);
    expect((await t.bob.service.teamRecovery(t.id)).waiting, isEmpty);

    // owner2 compares alice's new words, then approves.
    await t.owner2.service.approveRecovery(t.id, (await t.owner2.service.teamRecovery(t.id)).waiting.single);
    status = await t.owner.service.teamRecovery(t.id);
    expect(status.waiting.single.approvals.map((a) => a.uid), [_owner2]);
    expect((await aliceNew.service.teamRecovery(t.id)).waiting.single.approvals.single.signature, isNull,
        reason: 'the member learns it was given, not its bytes');

    // The first owner compares too, and completes.
    await t.owner.service.completeRecovery(t.id, status.waiting.single);
    final recovered = server.recordOf(t.id).members[_alice]!;
    expect(recovered.currentKeys.version, 2);
    expect(server.recoveries.single.copies.map((c) => '${c.crateId ?? 'orchard'}:${c.generation}').toList()..sort(),
        ['orchard:1', 'orchard:2', '${t.production}:1', '${t.production}:2']..sort());
    expect((await t.owner.service.teamRecovery(t.id)).waiting, isEmpty);
    // Her old keys, and every key opened with them, may be in other hands
    // (a lost device): every key she may hold waits to be replaced, as the
    // record says, though this server does not.
    await t.owner.service.refresh();
    expect(await t.owner.service.keysWaiting(t.id), isTrue);
    expect(await t.owner.rows(t.id, 'SELECT rotation_due FROM orchard_info'), ['1']);

    // Alice's new device opens the Orchard and Production again, every generation.
    expect(await aliceNew.service.refresh(), contains(t.id));
    expect(await aliceNew.rows(t.id, 'SELECT status FROM orchard_info'), ['active']);
    expect(await aliceNew.rows(t.id, 'SELECT name, level FROM orchard_crates'), ['Production:use']);
    expect(await aliceNew.rows(t.id, 'SELECT scope, generation FROM space_keys ORDER BY scope, generation'),
        ['crate:1', 'crate:2', 'orchard:1', 'orchard:2']);

    // The owner who completed compared the new keys: verified by them, and
    // the others see it; bob follows the new keys without a hard stop.
    expect(await t.owner.rows(t.id, "SELECT key_version, verified_by_me FROM member_keys WHERE uid = '$_alice'"),
        ['2:1']);
    expect(server.verifications.where((v) => v.subjectUid == _alice && v.subjectKeyVersion == 2).map((v) => v.by),
        [_owner]);
    await t.bob.service.refresh();
    expect(
        await t.bob.rows(t.id, "SELECT key_version, pending_keys IS NULL, verified_by FROM member_keys WHERE uid = '$_alice'"),
        ['2:1:["$_owner"]']);
  });

  test('refused before anything is sent: off, one owner, a member approving, no second owner', () async {
    final t = await team(on: false);
    await server.resetKeys(_alice, alice2);
    final wait = (await t.owner.service.teamRecovery(t.id)).waiting.single;

    await expectLater(t.owner2.service.approveRecovery(t.id, wait),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'team recovery is off')));
    await t.owner.service.setTeamRecovery(t.id, true);
    await expectLater(t.bob.service.approveRecovery(t.id, wait),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'only owners recover a member')));
    // An owner's own approval is not a second owner's.
    await t.owner.service.approveRecovery(t.id, wait);
    final mine = (await t.owner.service.teamRecovery(t.id)).waiting.single;
    expect(mine.approvals.map((a) => a.uid), [_owner]);
    await expectLater(t.owner.service.completeRecovery(t.id, mine),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'two different owners')));
    expect(server.recoveries, isEmpty);
    // Taken back, it is gone.
    await t.owner.service.withdrawRecoveryApproval(t.id, _alice);
    expect((await t.owner.service.teamRecovery(t.id)).waiting.single.approvals, isEmpty);

    // One owner alone cannot turn it on: refused here, not sent.
    final soloKeys = await AccountKeys.generate();
    await server.publish('solo', soloKeys);
    final solo = device('solo', soloKeys);
    final soloOrchard = await solo.service.createOrchard('Solo', firstCrateName: 'Main', memberRoleName: 'Member');
    server.appends.clear();
    await expectLater(solo.service.setTeamRecovery(soloOrchard, true),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'team recovery needs two owners')));
    expect(server.appends, isEmpty);
  });

  test('the status keeps only what this device can check', () async {
    final t = await team();
    await server.resetKeys(_alice, alice2);
    await t.owner2.service.approveRecovery(t.id, (await t.owner2.service.teamRecovery(t.id)).waiting.single);
    final given = server.recoveryApprovals[t.id]![_alice]!;

    // An approval whose signature does not check out.
    final real = given[_owner2]!;
    given[_owner2] = (keyVersion: real.keyVersion, approverKeyVersion: real.approverKeyVersion, signature: Uint8List(64));
    expect((await t.owner.service.teamRecovery(t.id)).waiting.single.approvals, isEmpty);
    // One from someone who is no owner (with a real signature of theirs).
    given.remove(_owner2);
    given[_bob] = (
      keyVersion: 2,
      approverKeyVersion: 1,
      signature: await signTeamRecovery(keys[_bob]!, approverUid: _bob, orchardId: t.id, subject: await alice2.publish(_alice)),
    );
    expect((await t.owner.service.teamRecovery(t.id)).waiting.single.approvals, isEmpty);

    // Keys that are not signed for the account they name are no wait at all.
    server.published[_alice] = await alice2.publish(_bob);
    expect((await t.owner.service.teamRecovery(t.id)).waiting, isEmpty);
  });

  test('a server that lies about team recovery: each device keeps only what it can check', () async {
    final t = await team(on: false);
    await server.resetKeys(_alice, alice2);
    final real = await alice2.publish(_alice);
    final approved = await signTeamRecovery(keys[_owner2]!, approverUid: _owner2, orchardId: t.id, subject: real);
    // Signed with owner-2's keys, but naming a version of them the record
    // does not hold.
    final otherVersion = await keys[_owner2]!.sign(teamRecoveryMessage(
      orchardId: t.id,
      subjectUid: _alice,
      subjectKeyVersion: 2,
      fingerprint: real.fingerprint,
      approverUid: _owner2,
      approverKeyVersion: 2,
    ));
    // Owner-2 starting over too, approving their own new keys.
    final owner2New = await (await AccountKeys.generate(version: 2)).publish(_owner2);
    final own = await signTeamRecovery(keys[_owner2]!, approverUid: _owner2, orchardId: t.id, subject: owner2New);
    final unsigned = PublishedAccountKeys(
      uid: _alice,
      version: 2,
      createdAt: real.createdAt,
      encryptionKey: real.encryptionKey,
      signingKey: real.signingKey,
      signature: Uint8List(64),
    );
    // Bob, a member, signing an approval with his real keys; and removed.
    final byBob = await signTeamRecovery(keys[_bob]!, approverUid: _bob, orchardId: t.id, subject: real);
    await t.owner.service.removeMember(t.id, _bob);
    final bob2 = await (await AccountKeys.generate(version: 2)).publish(_bob);
    server.recoveryListing = TeamRecoveryStatus(on: true, owners: 5, waiting: [
      RecoveryWait(uid: _alice, keys: real, recordKeyVersion: 1, approvals: [
        RecoveryApproval(uid: _owner2, keyVersion: 2, signature: otherVersion),
        RecoveryApproval(uid: _bob, keyVersion: 1, signature: byBob),
        RecoveryApproval(uid: _owner2, keyVersion: 1, signature: approved),
      ]),
      // Someone removed, with later keys signed for them.
      RecoveryWait(uid: _bob, keys: bob2, recordKeyVersion: 1),
      RecoveryWait(uid: _owner2, keys: owner2New, recordKeyVersion: 1, approvals: [
        RecoveryApproval(uid: _owner2, keyVersion: 1, signature: own),
      ]),
      // Not past the keys the record holds, not signed, not a member.
      RecoveryWait(uid: _alice, keys: await keys[_alice]!.publish(_alice), recordKeyVersion: 1),
      RecoveryWait(uid: _alice, keys: unsigned, recordKeyVersion: 1),
      RecoveryWait(
          uid: 'nobody', keys: await (await AccountKeys.generate(version: 2)).publish('nobody'), recordKeyVersion: 1),
    ]);
    final status = await t.owner.service.teamRecovery(t.id);
    expect(status.on, isFalse, reason: "the record's word, not the server's");
    expect(status.owners, 2);
    expect(status.waiting.map((w) => w.uid), [_alice, _owner2]);
    expect(status.waiting.first.approvals.map((a) => (a.uid, a.keyVersion)), [(_owner2, 1)]);
    expect(status.waiting.last.approvals, isEmpty, reason: 'nobody approves their own keys');
  });

  test('approving refuses, before anything is signed, what the record would', () async {
    final t = await team();
    await server.resetKeys(_alice, alice2);
    final real = await alice2.publish(_alice);
    Matcher refused(String reason) => throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', reason));
    // Keys at the version the record already holds.
    await expectLater(
        t.owner2.service.approveRecovery(
            t.id, RecoveryWait(uid: _alice, keys: await keys[_alice]!.publish(_alice), recordKeyVersion: 1)),
        refused('keys must be a later version'));
    // Keys that are not signed for the account.
    final unsigned = PublishedAccountKeys(
      uid: _alice,
      version: 2,
      createdAt: real.createdAt,
      encryptionKey: real.encryptionKey,
      signingKey: real.signingKey,
      signature: Uint8List(64),
    );
    await expectLater(t.owner2.service.approveRecovery(t.id, RecoveryWait(uid: _alice, keys: unsigned, recordKeyVersion: 1)),
        refused('the keys are not signed for this account'));
    // An owner approving their own new keys.
    final ownerNew = await (await AccountKeys.generate(version: 2)).publish(_owner);
    await expectLater(t.owner.service.approveRecovery(t.id, RecoveryWait(uid: _owner, keys: ownerNew, recordKeyVersion: 1)),
        refused('nobody recovers themselves'));
    // Someone removed meanwhile.
    final wait = (await t.owner2.service.teamRecovery(t.id)).waiting.single;
    await t.owner.service.removeMember(t.id, _alice);
    await expectLater(t.owner2.service.approveRecovery(t.id, wait), refused('not a member'));
    expect(server.recoveryApprovals[t.id]?[_alice] ?? const {}, isEmpty, reason: 'nothing was sent');
  });

  test("both owners approved: either completes with the other's; an approval without its bytes is none", () async {
    final t = await team();
    await server.resetKeys(_alice, alice2);
    await t.owner.service.approveRecovery(t.id, (await t.owner.service.teamRecovery(t.id)).waiting.single);
    await t.owner2.service.approveRecovery(t.id, (await t.owner2.service.teamRecovery(t.id)).waiting.single);
    final both = (await t.owner.service.teamRecovery(t.id)).waiting.single;
    expect(both.approvals.map((a) => a.uid), [_owner, _owner2]);

    // As a member sees them: no bytes to carry into the record.
    final bare = RecoveryWait(uid: _alice, keys: both.keys, recordKeyVersion: 1, approvals: [
      for (final a in both.approvals) RecoveryApproval(uid: a.uid, keyVersion: a.keyVersion),
    ]);
    await expectLater(t.owner.service.completeRecovery(t.id, bare),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'two different owners')));
    expect(server.recoveries, isEmpty);

    await t.owner.service.completeRecovery(t.id, both);
    expect(server.recoveries.single.entry.body['approver'], _owner2);
    expect(server.recordOf(t.id).members[_alice]!.currentKeys.version, 2);
  });

  test('a member who started over twice is recovered straight to the latest keys', () async {
    final t = await team();
    await server.resetKeys(_alice, alice2);
    await server.resetKeys(_alice, alice3);
    final wait = (await t.owner2.service.teamRecovery(t.id)).waiting.single;
    expect(wait.keys.version, 3);
    await t.owner2.service.approveRecovery(t.id, wait);
    await t.owner.service.completeRecovery(t.id, (await t.owner.service.teamRecovery(t.id)).waiting.single);
    expect(server.recordOf(t.id).members[_alice]!.currentKeys.version, 3);
    final aliceNew = device(_alice, alice3);
    expect(await aliceNew.service.refresh(), contains(t.id));
    expect(await aliceNew.rows(t.id, 'SELECT scope FROM space_keys ORDER BY scope'), ['crate', 'orchard']);
  });

  test('every member is told: team recovery turned on, and each recovery, the member in their own words', () async {
    final t = await team(on: false);
    final l10n = lookupAppLocalizations(const Locale('en'));
    final bobDb = await t.bob.service.databases.open(t.id);
    expect(await takeTeamNotices(bobDb, t.id), isEmpty, reason: 'the first look only marks where the device stands');

    await t.owner.service.setTeamRecovery(t.id, true);
    await t.bob.service.refresh();
    final on = await takeTeamNotices(bobDb, t.id);
    expect(on.map((n) => (n.kind, n.by)), [(TeamNoticeKind.recoveryOn, _owner)]);
    expect(await takeTeamNotices(bobDb, t.id), isEmpty, reason: 'told once');

    await server.resetKeys(_alice, alice2);
    final aliceNew = device(_alice, alice2);
    await aliceNew.service.refresh();
    final aliceDb = await aliceNew.service.databases.open(t.id);
    expect(await takeTeamNotices(aliceDb, t.id), isEmpty);
    await t.owner2.service.approveRecovery(t.id, (await t.owner2.service.teamRecovery(t.id)).waiting.single);
    await t.owner.service.completeRecovery(t.id, (await t.owner.service.teamRecovery(t.id)).waiting.single);

    await t.bob.service.refresh();
    final recovered = (await takeTeamNotices(bobDb, t.id)).single;
    expect((recovered.kind, recovered.member, recovered.by, recovered.approver),
        (TeamNoticeKind.memberRecovered, _alice, _owner, _owner2));
    String nameOf(String? uid) => '$uid@example.com';
    final toBob = teamNoticeNotification(recovered,
        orchardId: t.id, orchard: 'Acme Orchard', nameOf: nameOf, me: _bob, l10n: l10n);
    expect(toBob.title, l10n.noticeMemberRecoveredTitle('alice@example.com', 'Acme Orchard'));
    expect(toBob.body, l10n.noticeMemberRecoveredBody('owner-1@example.com', 'owner-2@example.com'));
    expect(toBob.severity, NotificationSeverity.warning, reason: 'stays in the bell until read');
    expect(toBob.id, 'orchard-notice-${t.id}-${recovered.seq}', reason: 'the same change is never shown twice');

    await aliceNew.service.refresh();
    final toAlice = teamNoticeNotification((await takeTeamNotices(aliceDb, t.id)).single,
        orchardId: t.id, orchard: 'Acme Orchard', nameOf: nameOf, me: _alice, l10n: l10n);
    expect(toAlice.title, l10n.noticeYouRecoveredTitle('Acme Orchard'));
    expect(toAlice.body, l10n.noticeYouRecoveredBody('owner-1@example.com', 'owner-2@example.com'));

    // Turned off again: everyone hears of that too.
    await t.owner2.service.setTeamRecovery(t.id, false);
    await t.bob.service.refresh();
    final off = (await takeTeamNotices(bobDb, t.id)).single;
    expect((off.kind, off.by), (TeamNoticeKind.recoveryOff, _owner2));
    expect(teamNoticeNotification(off, orchardId: t.id, orchard: 'Acme Orchard', nameOf: nameOf, me: _bob, l10n: l10n).title,
        l10n.noticeRecoveryOffTitle('Acme Orchard'));
  });

  test('what each device shows: named people and Orchard, and nothing about its own changes', () async {
    final t = await team(on: false);
    final l10n = lookupAppLocalizations(const Locale('en'));
    final bobDb = await t.bob.service.databases.open(t.id);
    final ownerDb = await t.owner.service.databases.open(t.id);
    String orchardName(String? name) => 'The ${name ?? '?'} Orchard';
    Future<List<AppNotification>> take(String me, AppDatabase db) =>
        takeTeamNotifications({t.id: db}, me: me, l10n: l10n, orchardName: orchardName);
    expect(await take(_bob, bobDb), isEmpty);
    expect(await take(_owner, ownerDb), isEmpty);

    await t.owner.service.setTeamRecovery(t.id, true);
    await t.bob.service.refresh();
    await t.owner.service.refresh();
    final toBob = await take(_bob, bobDb);
    expect(toBob.map((n) => n.title), [l10n.noticeRecoveryOnTitle('The Acme Orchard')]);
    expect(await take(_owner, ownerDb), isEmpty, reason: 'the owner who turned it on just saw it happen');
    expect(await take(_owner, ownerDb), isEmpty, reason: 'and it is not saved up for later');

    // A recovery: people named by their addresses on this device.
    await server.resetKeys(_alice, alice2);
    await t.owner2.service.approveRecovery(t.id, (await t.owner2.service.teamRecovery(t.id)).waiting.single);
    await t.owner.service.completeRecovery(t.id, (await t.owner.service.teamRecovery(t.id)).waiting.single);
    await t.bob.service.refresh();
    final recovered = (await take(_bob, bobDb)).single;
    expect(recovered.title, l10n.noticeMemberRecoveredTitle('alice@example.com', 'The Acme Orchard'));
    expect(recovered.body, l10n.noticeMemberRecoveredBody('owner-1@example.com', 'owner-2@example.com'));

    // An Orchard that cannot be read keeps nothing from the others.
    await t.owner2.service.setTeamRecovery(t.id, false);
    await t.bob.service.refresh();
    final broken = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    addTearDown(broken.close);
    await broken.customStatement('DROP TABLE orchard_record_entries');
    await expectLater(takeTeamNotices(broken, 'broken'), throwsA(anything), reason: 'truly unreadable');
    final both = await takeTeamNotifications({'broken': broken, t.id: bobDb},
        me: _bob, l10n: l10n, orchardName: orchardName);
    expect(both.map((n) => n.title), [l10n.noticeRecoveryOffTitle('The Acme Orchard')]);
  });

  test('another entry getting in first: the recovery goes in on top of it', () async {
    final t = await team();
    await server.resetKeys(_alice, alice2);
    await t.owner2.service.approveRecovery(t.id, (await t.owner2.service.teamRecovery(t.id)).waiting.single);
    final wait = (await t.owner.service.teamRecovery(t.id)).waiting.single;
    server.beforeRecover = () => t.owner2.service.setCrateAllow(t.id, t.staging, {CrateSwitches.sftp});
    await t.owner.service.completeRecovery(t.id, wait);
    expect(server.recoveries, hasLength(2), reason: 'refused once as out of order, then taken');
    final record = server.recordOf(t.id);
    expect(record.members[_alice]!.currentKeys.version, 2);
    expect(record.crates[t.staging]!.allow, {CrateSwitches.sftp});
  });
}
