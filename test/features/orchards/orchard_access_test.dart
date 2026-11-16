import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';

/// Access on request (3.0), from the devices: a Crate, or more in
/// one, given to a member until a set time; what their device holds while
/// it runs and the moment it ends; ending it early; and the requests members
/// make for it. Every change is an entry the (fake) server checks with the
/// record's rules and holds to its clock, which the tests move together with
/// the devices'.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';
const _lead = 'lead';
const _lead2 = 'lead2';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  /// How often a database was opened.
  var opens = 0;

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    opens++;
    return dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
  }

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

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get()) r.data.values.join(':'),
      ];

  /// The Crates this device holds, with the level it has in each.
  Future<List<String>> crates(String orchardId) =>
      rows(orchardId, 'SELECT name, level FROM orchard_crates ORDER BY name');

  /// How many generations of [crateId]'s key this device holds.
  Future<int> crateKeys(String orchardId, String crateId) async => (await (await db(orchardId)).customSelect(
        "SELECT COUNT(*) AS n FROM space_keys WHERE scope = 'crate' AND scope_id = ?",
        variables: [Variable(crateId)],
      ).getSingle())
          .read<int>('n');

  Future<void> addHost(String orchardId, String id, {required String crateId}) async {
    final d = await db(orchardId);
    await CratePlacement(d).setDefaultCrate(crateId);
    final at = DateTime(2026, 10, 1);
    await d.into(d.connections).insert(
        ConnectionsCompanion.insert(id: id, label: id, host: '192.0.2.10', createdAt: at, updatedAt: at));
  }

  /// A key with a password in [crateId], and a host that signs in with it.
  Future<void> addKeyAndHost(String orchardId, String key, String host, {required String crateId}) async {
    final d = await db(orchardId);
    await CratePlacement(d).setDefaultCrate(crateId);
    final at = DateTime(2026, 10, 1);
    await d.into(d.identities).insert(IdentitiesCompanion.insert(
        id: key, label: key, username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await d.into(d.connections).insert(ConnectionsCompanion.insert(
        id: host, label: host, host: '192.0.2.20', identityId: Value(key), createdAt: at, updatedAt: at));
  }

  Future<List<String>> hosts(String orchardId) => rows(orchardId, 'SELECT id FROM connections ORDER BY id');

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

  /// How far the clocks (the server's, and every device's) have been moved.
  var moved = Duration.zero;
  DateTime clock() => DateTime.now().add(moved);
  int nowSeconds() => clock().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    for (final uid in [_owner, _alice, _bob, _lead, _lead2]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    moved = Duration.zero;
    OrchardService.debugNow = clock;
    server = FakeCrateServer(accountUid: _owner)..clock = clock;
    for (final uid in [_owner, _alice, _bob, _lead, _lead2]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    OrchardService.debugNow = DateTime.now;
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

  /// An Orchard of the owner's: Production (the first role, Member, has use
  /// of it) and Staging, which only the owner opens.
  Future<({String id, String production, String staging, String member})> orchard(_Device owner) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(id, 'Staging');
    final member = server.recordOf(id).roles.values.single;
    return (id: id, production: member.crates.keys.single, staging: staging, member: member.id);
  }

  Future<void> join(_Device by, _Device person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    final invite = (await by.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, person.uid);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    expect(await person.service.refresh(), contains(orchardId));
  }

  test('a Crate given until a set time: its key and its hosts come at once, a change made with it counts, '
      'and when the time comes it leaves the device', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await owner.addHost(o.id, 'staging-db', crateId: o.staging);
    await owner.coordinator.syncOne(o.id);
    expect(await alice.crates(o.id), ['Production:use']);

    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.staging, level: CrateLevel.edit, duration: const Duration(hours: 2));
    final grant = server.recordOf(o.id).members[_alice]!.timed[o.staging]!;
    expect(grant.switches, levelSwitches(CrateLevel.edit));
    expect(grant.until, closeTo(nowSeconds() + 7200, 5));
    expect(server.entriesOf(o.id).last.type, RecordTypes.accessGrant);

    // On her device: the Crate, at the level given, with its key and what is in it.
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:edit']);
    expect(await alice.crateKeys(o.id, o.staging), 1);
    expect(await alice.hosts(o.id), ['staging-db']);
    expect(await alice.service.nextAccessEnd(), grant.until);
    expect(await owner.service.nextAccessEnd(), isNull, reason: 'nothing of the owner ends');

    // What she holds until then, as both devices list it.
    for (final d in [owner, alice]) {
      final listed = (await d.service.timedAccess(o.id)).single;
      expect((listed.uid, listed.crateId, listed.until), (_alice, o.staging, grant.until));
      expect(listed.adds, levelSwitches(CrateLevel.edit));
      expect(listed.wholeCrate, isTrue);
      expect(listed.canEnd, isTrue, reason: 'the owner manages it, and it is hers');
    }

    // A host she adds there reaches the owner, whose device takes it: she
    // could edit when she wrote it.
    await alice.addHost(o.id, 'staging-web', crateId: o.staging);
    final sent = await alice.coordinator.syncOne(o.id);
    expect((sent.sent, sent.rejected), (1, 0));
    final got = await owner.coordinator.syncOne(o.id);
    expect((got.received, got.rejected), (1, 0));
    expect(await owner.hosts(o.id), ['staging-db', 'staging-web']);

    // One second before its time everything is as it was.
    moved = const Duration(hours: 2) - const Duration(seconds: 2);
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:edit']);

    // Its time comes: the Crate, its hosts and its key leave her device.
    moved = const Duration(hours: 2, seconds: 1);
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use']);
    expect(await alice.crateKeys(o.id, o.staging), 0);
    expect(await alice.hosts(o.id), isEmpty);
    expect(await alice.service.timedAccess(o.id), isEmpty);
    expect(await alice.service.nextAccessEnd(), isNull);
    expect(await owner.service.timedAccess(o.id), isEmpty);
    // She is told once that it is over.
    var notices = await alice.service.takeAccessNotices(o.id);
    expect([for (final n in notices) (n.kind, n.crateId)], [(AccessNoticeKind.over, o.staging)]);
    expect(await alice.service.takeAccessNotices(o.id), isEmpty);
    notices = await owner.service.takeAccessNotices(o.id);
    expect(notices, isEmpty, reason: 'nothing of the owner ended');

    // The server asks for a new key, which the owner's device makes, and
    // which goes to the owner alone.
    server.runEndedAccessJob();
    await owner.service.refresh();
    expect(await owner.service.rotateDue(o.id), isEmpty);
    expect(server.recordOf(o.id).generationOf(o.staging), 2);
    expect(server.rotationRequests.last, [_owner]);
    // What the owner writes next is nothing her device could read, had it kept the old key.
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use']);
  });

  test('what someone held until a set time counts among what they could use, while it runs and after', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);
    await owner.addKeyAndHost(o.id, 'staging-key', 'staging-db', crateId: o.staging);
    await owner.coordinator.syncOne(o.id);
    // "could see: ...; could connect with: ...", each key with its Crate.
    Future<String> couldUse(String uid) async {
      final seen = await owner.service.exposure(o.id, uid);
      String keys(List<ExposedKey> list) =>
          [for (final k in list) '${k.id} in ${k.crateId == o.staging ? 'Staging' : 'another Crate'}'].join(', ');
      return 'see: ${keys(seen.reveal)}; connect: ${keys(seen.connect)}';
    }

    expect(await couldUse(_alice), 'see: ; connect: ', reason: 'her role does not open Staging');

    // Given Staging to connect only: its key is one she could connect with.
    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.staging, level: CrateLevel.connect, duration: const Duration(hours: 1));
    expect(await couldUse(_alice), 'see: ; connect: staging-key in Staging');
    // Given it to use: one she could see.
    await owner.service
        .giveAccess(o.id, uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    expect(await couldUse(_alice), 'see: staging-key in Staging; connect: ');
    expect(await couldUse(_bob), 'see: ; connect: ', reason: 'nothing was given to him');

    // Its time comes: she could have copied the password while she had it,
    // so it is still one to change when she goes.
    moved = const Duration(hours: 1, seconds: 5);
    await owner.service.refresh();
    expect(await owner.service.timedAccess(o.id), isEmpty);
    expect(await couldUse(_alice), 'see: staging-key in Staging; connect: ');
    // And it is among what is kept as "change these next" when she is removed.
    final exposure = await owner.service.exposure(o.id, _alice);
    await owner.service.removeMember(o.id, _alice);
    await owner.service.keepChangeNext(o.id, _alice, exposure);
    expect(await owner.rows(o.id, 'SELECT key_id, could_reveal FROM change_next'), ['staging-key:1']);
  });

  test('a device whose clock is behind keeps nothing past the time either: the server stops listing the Crate',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:use']);

    // The server's clock moves on; her device's stays where it was.
    final before = clock();
    moved = const Duration(hours: 1, seconds: 5);
    OrchardService.debugNow = () => before;
    await alice.coordinator.syncAll();
    // Closed on her device at once, as at its time; what is in it is not
    // deleted on the server's word...
    expect((await crateLimitsIn(await alice.db(o.id))).ended.keys, [o.staging]);
    expect(await alice.crateKeys(o.id, o.staging), 1);
    // ...and goes once her own clock passes the record's time.
    OrchardService.debugNow = clock;
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use']);
    expect(await alice.crateKeys(o.id, o.staging), 0);
  });

  test('more in a Crate they open: the level rises for the time given and falls back by itself, and the key stays',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    final copiesBefore = server.appends.length;
    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.production, level: CrateLevel.edit, duration: const Duration(minutes: 30));
    expect(server.appends.length, copiesBefore + 1);
    await alice.service.refresh();
    expect(await alice.crates(o.id), ['Production:edit']);
    final listed = (await owner.service.timedAccess(o.id)).single;
    expect(listed.wholeCrate, isFalse);
    expect(listed.adds, {CrateSwitches.add, CrateSwitches.edit, CrateSwitches.delete});

    moved = const Duration(minutes: 30, seconds: 1);
    await alice.service.refresh();
    expect(await alice.crates(o.id), ['Production:use']);
    expect(await alice.crateKeys(o.id, o.production), 1);
    // Nothing was taken that she holds for good: no new key is asked for.
    server.runEndedAccessJob();
    await owner.service.refresh();
    expect(await owner.rows(o.id, 'SELECT rotation_due FROM orchard_crates ORDER BY name'), ['0', '0']);
    // Nothing more than the level she already has is no access to list.
    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.production, level: CrateLevel.connect, duration: const Duration(hours: 1));
    expect(await owner.service.timedAccess(o.id), isEmpty);
    expect(await alice.service.nextAccessEnd(), isNull);
  });

  test('ended early by the member or by whoever manages the Crate, and by nobody else', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);
    Future<void> give() => owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 4));

    await give();
    await alice.service.refresh();
    await bob.service.refresh();
    expect((await bob.service.timedAccess(o.id)).single.canEnd, isFalse);
    final appends = server.appends.length;
    await expectLater(bob.service.endAccess(o.id, uid: _alice, crateId: o.staging),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'ending access to a Crate needs manage on it')));
    expect(server.appends.length, appends, reason: 'refused before anything was sent');

    // She gives it up herself: it leaves her device at once, and a new key is due.
    await alice.service.endAccess(o.id, uid: _alice, crateId: o.staging);
    expect(await alice.crates(o.id), ['Production:use']);
    expect(await alice.crateKeys(o.id, o.staging), 0);
    expect(server.recordOf(o.id).members[_alice]!.timed, isEmpty);
    await owner.service.refresh();
    expect(await owner.rows(o.id, "SELECT rotation_due FROM orchard_crates WHERE name = 'Staging'"), ['1']);
    await expectLater(alice.service.endAccess(o.id, uid: _alice, crateId: o.staging),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'nothing to end')));

    // Given again, and taken back by the owner.
    expect(await owner.service.rotateDue(o.id), isEmpty);
    await give();
    await alice.service.refresh();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:use']);
    expect(await alice.crateKeys(o.id, o.staging), 2, reason: 'every generation of the key');
    await owner.service.endAccess(o.id, uid: _alice, crateId: o.staging);
    await alice.service.refresh();
    expect(await alice.crates(o.id), ['Production:use']);
    // Nothing of an end made on purpose is told as "your time is over".
    expect(await alice.service.takeAccessNotices(o.id), isEmpty);
  });

  test('what the rules refuse is refused before anything is sent, and the times are held to five minutes and thirty days',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);
    final appends = server.appends.length;
    Future<void> give(_Device by, String uid, String crateId,
            {CrateLevel level = CrateLevel.use, Duration duration = const Duration(hours: 1)}) =>
        by.service.giveAccess(o.id, uid: uid, crateId: crateId, level: level, duration: duration);
    Matcher refused(String reason) =>
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', reason));

    await expectLater(give(owner, _owner, o.staging), refused('nobody gives themselves access'));
    await expectLater(give(alice, _bob, o.production), refused('giving a Crate needs manage on it'));
    await expectLater(give(owner, 'nobody', o.staging), refused('not a member'));
    expect(() => give(owner, _alice, o.staging, level: CrateLevel.manage), throwsArgumentError);
    expect(() => give(owner, _alice, o.staging, duration: const Duration(minutes: 4, seconds: 59)), throwsArgumentError);
    expect(() => give(owner, _alice, o.staging, duration: const Duration(days: 30, seconds: 1)), throwsArgumentError);
    expect(server.appends.length, appends);

    // The shortest and the longest go through.
    await give(owner, _alice, o.staging, duration: kMinAccessDuration);
    await give(owner, _alice, o.staging, duration: kMaxAccessDuration);
    expect(server.recordOf(o.id).members[_alice]!.timed[o.staging]!.until, closeTo(nowSeconds() + 30 * 86400, 5));
  });

  test('the server holds the time to its own clock: a device far behind or far ahead is told so', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    Future<void> give(Duration duration) => owner.service
        .giveAccess(o.id, uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: duration);
    Matcher answered(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));

    // Three hours behind: two hours from its now has already passed.
    OrchardService.debugNow = () => clock().subtract(const Duration(hours: 3));
    await expectLater(give(const Duration(hours: 2)), answered('access-until-passed'));
    // Two days ahead: thirty days from its now is more than the server gives.
    OrchardService.debugNow = () => clock().add(const Duration(days: 2));
    await expectLater(give(const Duration(days: 30)), answered('access-too-long'));
    expect(server.recordOf(o.id).members[_alice]!.timed, isEmpty);
    // A few minutes ahead is taken.
    OrchardService.debugNow = () => clock().add(const Duration(minutes: 4));
    await give(const Duration(days: 30));
    expect(server.recordOf(o.id).members[_alice]!.timed, hasLength(1));
  });

  test('giving needs a recent sign-in; giving it up does not', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    await alice.service.refresh();
    server.requireRecentSignIn = true;
    await expectLater(
        owner.service.giveAccess(o.id,
            uid: _alice, crateId: o.staging, level: CrateLevel.edit, duration: const Duration(hours: 1)),
        throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'recent sign-in', isTrue)));
    await alice.service.endAccess(o.id, uid: _alice, crateId: o.staging);
    expect(await alice.crates(o.id), ['Production:use']);
  });

  test('a member asks for a Crate they cannot name, in words only the members read; whoever manages one gives it, '
      'and the request goes with the answer', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);

    await alice.service.requestAccess(o.id,
        level: CrateLevel.use, duration: const Duration(hours: 2), note: '  Staging, for the release  ');
    final kept = server.requestsOf(o.id).single;
    expect((kept.uid, kept.crateId), (_alice, null));
    // The server holds the note, and cannot read it.
    final listedForOwner = await owner.server.accessRequests(o.id);
    final sealed = listedForOwner.waiting.single.noteEnc!;
    expect(utf8.decode(sealed, allowMalformed: true), isNot(contains('Staging')));
    expect(listedForOwner.waiting.single.uid, _alice);

    // Hers to see as her own; the owner's to answer; not bob's business.
    var hers = await alice.service.accessRequests(o.id);
    expect(hers.waiting, isEmpty);
    expect(hers.mine.single.note, 'Staging, for the release');
    expect((hers.mine.single.uid, hers.mine.single.crateId, hers.mine.single.level, hers.mine.single.duration),
        (null, null, CrateLevel.use, const Duration(hours: 2)));
    final theirs = await bob.service.accessRequests(o.id);
    expect(theirs.mine, isEmpty);
    expect(theirs.waiting, isEmpty);
    final waiting = (await owner.service.accessRequests(o.id)).waiting.single;
    expect((waiting.uid, waiting.note, waiting.noteUnread, waiting.id), (_alice, 'Staging, for the release', false, kept.id));
    expect(waiting.expiresAt, closeTo(nowSeconds() + 7 * 86400, 5));

    // The owner picks the Crate she means and gives it, naming the request.
    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.staging, level: waiting.level, duration: waiting.duration, requestId: waiting.id);
    expect(server.requestsOf(o.id), isEmpty);
    expect(server.entriesOf(o.id).last.body['req'], kept.id);
    await alice.service.refresh();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:use']);
    // Answered: nothing to tell her about the request itself (the record's
    // entry is what she hears of).
    hers = await alice.service.accessRequests(o.id);
    expect(hers.mine, isEmpty);
    expect(await alice.service.takeAccessNotices(o.id, requests: hers), isEmpty);
  });

  test('more in a Crate they open names it, and needs no note', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await alice.service.requestAccess(o.id,
        crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
    final waiting = (await owner.service.accessRequests(o.id)).waiting.single;
    expect((waiting.crateId, waiting.level, waiting.note, waiting.noteUnread), (o.production, CrateLevel.edit, null, false));
    // Asking again for the same Crate changes the request there is.
    await alice.service.requestAccess(o.id,
        crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 3), note: 'the migration');
    final again = (await owner.service.accessRequests(o.id)).waiting.single;
    expect((again.id, again.duration, again.note), (waiting.id, const Duration(hours: 3), 'the migration'));
  });

  test('what a request must say, and who may ask', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    final calls = server.requestCalls;
    Future<void> ask({String? crateId, CrateLevel level = CrateLevel.use, Duration duration = const Duration(hours: 1), String? note}) =>
        alice.service.requestAccess(o.id, crateId: crateId, level: level, duration: duration, note: note);
    await expectLater(ask(), throwsArgumentError, reason: 'neither a Crate nor a word');
    await expectLater(ask(note: '   '), throwsArgumentError);
    await expectLater(ask(crateId: o.production, level: CrateLevel.manage), throwsArgumentError);
    await expectLater(ask(crateId: o.production, duration: const Duration(minutes: 4)), throwsArgumentError);
    await expectLater(ask(crateId: o.production, duration: const Duration(days: 31)), throwsArgumentError);
    await expectLater(ask(note: 'x' * (kMaxAccessNoteLength + 1)), throwsArgumentError);
    expect(server.requestCalls, calls, reason: 'nothing was sent');
    // The longest note goes through, in any script.
    await ask(note: '\u{1F34A}' * kMaxAccessNoteLength);
    expect((await alice.service.accessRequests(o.id)).mine.single.note, '\u{1F34A}' * kMaxAccessNoteLength);

    // An owner opens every Crate one could be given.
    await expectLater(
        owner.service.requestAccess(o.id, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1)),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'access-not-needed')));
    // Five wait at most.
    final extra = [for (var i = 0; i < 5; i++) await owner.service.createCrate(o.id, 'Extra $i')];
    for (final crateId in extra.take(4)) {
      await ask(crateId: crateId);
    }
    await expectLater(ask(crateId: extra[4]),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'request-limit')));
  });

  test('declined, withdrawn or lapsed: nothing is kept of a request, and whoever asked is told which, once',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    Future<List<AccessNoticeKind>> told(_Device d) async => [
          for (final n in await d.service.takeAccessNotices(o.id, requests: await d.service.accessRequests(o.id))) n.kind,
        ];
    Future<void> ask() => alice.service.requestAccess(o.id,
        crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));

    // Declined.
    await ask();
    expect(await told(alice), isEmpty, reason: 'it waits');
    final id = (await owner.service.accessRequests(o.id)).waiting.single.id;
    await owner.service.declineAccessRequest(o.id, id);
    expect(server.requestsOf(o.id), isEmpty);
    expect(await told(alice), [AccessNoticeKind.declined]);
    expect(await told(alice), isEmpty);

    // Withdrawn by herself: nothing to be told.
    await ask();
    await alice.service.withdrawAccessRequest(o.id, (await alice.service.accessRequests(o.id)).mine.single.id);
    expect(server.requestsOf(o.id), isEmpty);
    expect(await told(alice), isEmpty);

    // Lapsed: seven days pass without an answer.
    await ask();
    moved = const Duration(days: 7, seconds: 1);
    expect((await alice.service.accessRequests(o.id)).mine, isEmpty);
    expect((await owner.service.accessRequests(o.id)).waiting, isEmpty);
    expect(await told(alice), [AccessNoticeKind.lapsed]);
    expect(await told(alice), isEmpty);

    // One made on another device of hers is followed from here too.
    final phone = device(_alice);
    await phone.service.refresh();
    await ask();
    expect([for (final n in await phone.service.takeAccessNotices(o.id, requests: await phone.service.accessRequests(o.id))) n.kind],
        isEmpty);
    await owner.service.declineAccessRequest(o.id, (await owner.service.accessRequests(o.id)).waiting.single.id);
    expect([for (final n in await phone.service.takeAccessNotices(o.id, requests: await phone.service.accessRequests(o.id))) n.kind],
        [AccessNoticeKind.declined]);
  });

  test('answered with access before this device read the record: it reads it, and is never told "declined"',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    Future<List<AccessNoticeKind>> told(_Device d) async => [
          for (final n in await d.service.takeAccessNotices(o.id, requests: await d.service.accessRequests(o.id))) n.kind,
        ];
    Future<int> timedOnHerDevice() async =>
        (await LocalRecord.load(await alice.db(o.id), o.id)).latest.members[_alice]!.timed.length;

    await alice.service.requestAccess(o.id, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Staging');
    expect(await told(alice), isEmpty);
    await owner.service.giveAccess(o.id,
        uid: _alice,
        crateId: o.staging,
        level: CrateLevel.use,
        duration: const Duration(hours: 1),
        requestId: (await owner.service.accessRequests(o.id)).waiting.single.id);
    // Word that her request moved reaches her device before its next sync
    // does: its copy of the record has no answer in it yet.
    expect(await timedOnHerDevice(), 0);
    expect(await told(alice), isEmpty, reason: 'answered: the record says so once it is read');
    expect(await timedOnHerDevice(), 1, reason: 'read up to the answer');
    expect(await told(alice), isEmpty);

    // While the record cannot be read, a request that is gone is neither
    // declined nor answered: that is decided at the next look.
    await alice.service
        .requestAccess(o.id, crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
    expect(await told(alice), isEmpty, reason: 'it waits');
    await owner.service.declineAccessRequest(o.id, (await owner.service.accessRequests(o.id)).waiting.single.id);
    server.failRecord = true;
    expect(await told(alice), isEmpty, reason: 'not known yet');
    expect(await told(alice), isEmpty);
    server.failRecord = false;
    expect(await told(alice), [AccessNoticeKind.declined]);
    expect(await told(alice), isEmpty, reason: 'told once');

    // An answer this device already holds needs no reading at all.
    await alice.service
        .requestAccess(o.id, crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
    expect(await told(alice), isEmpty);
    await owner.service.giveAccess(o.id,
        uid: _alice,
        crateId: o.production,
        level: CrateLevel.edit,
        duration: const Duration(hours: 1),
        requestId: (await owner.service.accessRequests(o.id)).waiting.single.id);
    await alice.service.refresh();
    server.failRecord = true;
    expect(await told(alice), isEmpty);
    server.failRecord = false;
    expect(await told(alice), isEmpty, reason: 'it was counted as answered, not kept for later');
  });

  test('new requests are told once to whoever can answer them', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);
    Future<List<AccessNotice>> told(_Device d) async =>
        d.service.takeAccessNotices(o.id, requests: await d.service.accessRequests(o.id));

    expect(await told(owner), isEmpty);
    await alice.service.requestAccess(o.id, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Staging');
    var notices = await told(owner);
    expect([for (final n in notices) (n.kind, n.uid, n.count)], [(AccessNoticeKind.asked, _alice, 1)]);
    expect(await told(owner), isEmpty, reason: 'told once');
    expect(await told(bob), isEmpty, reason: 'not his to answer');

    // Two more, from two people: one notice, naming nobody.
    await alice.service.requestAccess(o.id, crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
    await bob.service.requestAccess(o.id, crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
    notices = await told(owner);
    expect([for (final n in notices) (n.kind, n.uid, n.count)], [(AccessNoticeKind.asked, null, 2)]);
    // One fewer is no news.
    await owner.service.declineAccessRequest(o.id, (await owner.service.accessRequests(o.id)).waiting.first.id);
    expect(await told(owner), isEmpty);
  });

  test('who may answer is the record to say: a request the server lists for someone with no say over it is not shown',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final lead = device(_lead);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);
    // A lead manages Staging, ranked above Member; and a role above the lead's.
    final leads = await owner.service
        .saveRole(o.id, name: 'Lead', can: const {}, crates: {o.staging: levelSwitches(CrateLevel.manage)});
    await owner.service.moveRole(o.id, leads, up: true);
    await join(owner, lead, o.id, leads);
    await alice.service.requestAccess(o.id, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Staging');
    await alice.service.requestAccess(o.id, crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));

    // The lead sees the one that names no Crate (they manage one), not the
    // one for Production, which they do not manage.
    var waiting = (await lead.service.accessRequests(o.id)).waiting;
    expect([for (final r in waiting) r.crateId], [null]);
    expect(OrchardAccess.accessCratesFor(server.recordOf(o.id), _lead), [o.staging]);
    expect(OrchardAccess.accessCratesFor(server.recordOf(o.id), _owner), unorderedEquals([o.production, o.staging]));
    expect(OrchardAccess.accessCratesFor(server.recordOf(o.id), _owner, crateId: o.staging), [o.staging]);
    expect(OrchardAccess.accessCratesFor(server.recordOf(o.id), _bob), isEmpty);

    // A server that lists both requests for bob, who manages nothing, and for
    // the lead: each device shows only what its record lets its account answer.
    final all = await owner.server.accessRequests(o.id);
    server.accessRequestListing = (mine: const [], waiting: all.waiting);
    expect((await bob.service.accessRequests(o.id)).waiting, isEmpty);
    waiting = (await lead.service.accessRequests(o.id)).waiting;
    expect([for (final r in waiting) r.crateId], [null]);
    // One listed as someone else's is read as theirs: a note sealed by alice
    // does not open as bob's.
    server.accessRequestListing = (
      mine: const [],
      waiting: [
        for (final r in all.waiting)
          AccessRequest(
            id: r.id,
            crateId: r.crateId,
            level: r.level,
            seconds: r.seconds,
            noteEnc: r.noteEnc,
            noteGeneration: r.noteGeneration,
            expiresAt: r.expiresAt,
            uid: _bob,
          ),
      ],
    );
    final forged = (await owner.service.accessRequests(o.id)).waiting.where((r) => r.crateId == null).single;
    expect((forged.uid, forged.note, forged.noteUnread), (_bob, null, true));
    // The owner's own request, or one from someone gone, is not one to answer.
    server.accessRequestListing = (
      mine: const [],
      waiting: [
        for (final uid in [_owner, 'nobody'])
          AccessRequest(
              id: all.waiting.first.id,
              crateId: o.staging,
              level: CrateLevel.use,
              seconds: 3600,
              noteEnc: null,
              noteGeneration: null,
              expiresAt: nowSeconds() + 60,
              uid: uid),
      ],
    );
    expect((await owner.service.accessRequests(o.id)).waiting, isEmpty);
  });

  test('who may answer: nobody suspended, no owner or admin, and nobody of the same rank', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final lead = device(_lead);
    final lead2 = device(_lead2);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);
    final leads = await owner.service
        .saveRole(o.id, name: 'Lead', can: const {}, crates: {o.staging: levelSwitches(CrateLevel.manage)});
    await owner.service.moveRole(o.id, leads, up: true);
    await join(owner, lead, o.id, leads);
    await join(owner, lead2, o.id, leads);
    await owner.service.verifyMember(o.id, _bob);
    await owner.service.setMemberRole(o.id, _bob, FixedRoles.admin);
    for (final d in [owner, alice, lead, lead2]) {
      await d.service.refresh();
    }
    AccessRequests from(String uid) => (
          mine: const [],
          waiting: [
            AccessRequest(
                id: '00000000-0000-4000-8000-00000000000a',
                crateId: o.staging,
                level: CrateLevel.use,
                seconds: 3600,
                noteEnc: null,
                noteGeneration: null,
                expiresAt: nowSeconds() + 60,
                uid: uid),
          ],
        );
    Future<List<String?>> shown(_Device d, String asker) async {
      server.accessRequestListing = from(asker);
      return [for (final r in (await d.service.accessRequests(o.id)).waiting) r.uid];
    }

    // A member below them: theirs to answer.
    expect(await shown(lead, _alice), [_alice]);
    expect(await shown(owner, _alice), [_alice]);
    // Another lead ranks the same: not for a lead, but for the owner.
    expect(await shown(lead, _lead2), isEmpty);
    expect(await shown(owner, _lead2), [_lead2]);
    // An admin opens every Crate one could be given: there is nothing to
    // answer, though the owner ranks above them.
    expect(await shown(owner, _bob), isEmpty);
    // Suspended, she is given nothing until she is back.
    server.accessRequestListing = null;
    await owner.service.suspendMember(o.id, _alice);
    await lead.service.refresh();
    expect(await shown(owner, _alice), isEmpty);
    expect(await shown(lead, _alice), isEmpty);
  });

  test('what this device remembers of a request it made, and a note of nothing but spaces', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    Future<List<AccessNoticeKind>> told(_Device d) async => [
          for (final n in await d.service.takeAccessNotices(o.id, requests: await d.service.accessRequests(o.id))) n.kind,
        ];

    // With a Crate named, spaces alone are no note, and no mistake either.
    await alice.service.requestAccess(o.id,
        crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1), note: '   ');
    final kept = (await owner.server.accessRequests(o.id)).waiting.single;
    expect((kept.noteEnc, kept.noteGeneration), (null, null));
    // Declined before her device looked again: it knew of the request from
    // the moment it made it, and says so.
    await owner.service.declineAccessRequest(o.id, kept.id);
    expect(await told(alice), [AccessNoticeKind.declined]);
    expect(await told(alice), isEmpty);

    // She asks again and is made an admin instead: an admin opens every
    // Crate one could be given, so the request goes, and nothing says it was
    // declined.
    await alice.service
        .requestAccess(o.id, crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
    expect(server.requestsOf(o.id), hasLength(1));
    await owner.service.verifyMember(o.id, _alice);
    await owner.service.setMemberRole(o.id, _alice, FixedRoles.admin);
    expect(server.requestsOf(o.id), isEmpty);
    expect(await told(alice), isEmpty);
    await alice.service.refresh();
    expect(await told(alice), isEmpty);
    expect(await alice.crates(o.id), ['Production:manage', 'Staging:manage']);
  });

  test('what can be given: Crates one manages for good, never an owners-only one, and never more than one has there',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final lead = device(_lead);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    final vault = await owner.service.createCrate(o.id, 'Owner keys', ownersOnly: true);
    expect(OrchardAccess.accessCratesFor(server.recordOf(o.id), _owner), unorderedEquals([o.production, o.staging]));
    expect(OrchardAccess.accessCratesFor(server.recordOf(o.id), _owner, crateId: vault), isEmpty);

    // A keeper manages Staging and may connect there, nothing else: asked
    // to give Use, their device hands out what Use and they have in common.
    final keepers = await owner.service.saveRole(o.id,
        name: 'Keeper', can: const {}, crates: {o.staging: {CrateSwitches.connect, CrateSwitches.manage}});
    await owner.service.moveRole(o.id, keepers, up: true);
    await join(owner, lead, o.id, keepers);
    await lead.service
        .giveAccess(o.id, uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    expect(server.recordOf(o.id).members[_alice]!.timed[o.staging]!.switches, {CrateSwitches.connect});
    await alice.service.refresh();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:connect']);
  });

  test('when access next ends: the soonest of what was given and of their time in the Orchard', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    expect(await alice.service.nextAccessEnd(), isNull);
    expect(await alice.service.timeToNextAccessEnd(), isNull);
    await owner.service
        .giveAccess(o.id, uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 2));
    await owner.service.giveAccess(o.id,
        uid: _alice, crateId: o.production, level: CrateLevel.edit, duration: const Duration(minutes: 30));
    await alice.service.refresh();
    expect(await alice.service.nextAccessEnd(), closeTo(nowSeconds() + 1800, 5));
    expect((await alice.service.timeToNextAccessEnd())!.inSeconds, closeTo(1800, 5));
    // Listed soonest to end first.
    expect([for (final t in await owner.service.timedAccess(o.id)) t.crateId], [o.production, o.staging]);
    // Her time in the Orchard ends before either.
    await owner.service.setMemberEndsAt(o.id, _alice, nowSeconds() + 600);
    await alice.service.refresh();
    expect(await alice.service.nextAccessEnd(), closeTo(nowSeconds() + 600, 5));
    // Past the first end, the next is the one that follows.
    await owner.service.setMemberEndsAt(o.id, _alice, null);
    moved = const Duration(minutes: 31);
    await alice.service.refresh();
    expect(await alice.service.nextAccessEnd(), closeTo(nowSeconds() + 7200 - 31 * 60, 5));
  });

  test('an end date further off than a Duration can say is not taken for one that has come', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    // In microseconds, this many seconds come round to a time long past.
    const far = 18446744073710;
    await owner.service.setMemberEndsAt(o.id, _alice, far);
    await alice.service.refresh();
    expect(await alice.service.nextAccessEnd(), far);
    final wait = (await alice.service.timeToNextAccessEnd())!;
    expect(wait.isNegative, isFalse);
    expect(wait, greaterThan(const Duration(days: 365)));
  });

  test('the second it ends is the end, on the device and on the server', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await owner.service
        .giveAccess(o.id, uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    await alice.coordinator.syncAll();
    final until = server.recordOf(o.id).members[_alice]!.timed[o.staging]!.until;
    void setClocks(int seconds) {
      DateTime at() => DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      OrchardService.debugNow = at;
      server.clock = at;
    }

    setClocks(until - 1);
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:use']);
    expect(await alice.service.takeAccessNotices(o.id), isEmpty);
    expect((await alice.service.timedAccess(o.id)).single.until, until);
    expect(await alice.service.timeToNextAccessEnd(), const Duration(seconds: 1));

    setClocks(until);
    expect([for (final n in await alice.service.takeAccessNotices(o.id)) n.kind], [AccessNoticeKind.over],
        reason: 'over, by the record on her device, before it has synced');
    expect(await alice.service.timedAccess(o.id), isEmpty);
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use']);
  });

  test('a device whose clock is past the end keeps nothing of the Crate, whatever the server still lists', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await owner.addHost(o.id, 'staging-db', crateId: o.staging);
    await owner.coordinator.syncOne(o.id);
    await owner.service
        .giveAccess(o.id, uid: _alice, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use', 'Staging:use']);
    expect(await alice.hosts(o.id), ['staging-db']);

    // Her device's clock moves past the end; the server's stays where it is,
    // and goes on listing the Crate and its key for her.
    final here = clock();
    OrchardService.debugNow = () => here.add(const Duration(hours: 1, seconds: 5));
    expect((await alice.server.orchards()).single.crates.map((c) => c.id), contains(o.staging));
    await alice.coordinator.syncAll();
    expect(await alice.crates(o.id), ['Production:use']);
    expect(await alice.crateKeys(o.id, o.staging), 0);
    expect(await alice.hosts(o.id), isEmpty);
  });

  test('an end is told while it is news: not to a device that was away for more than a day', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    await join(owner, bob, o.id, o.member);
    for (final uid in [_alice, _bob]) {
      await owner.service
          .giveAccess(o.id, uid: uid, crateId: o.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    }
    for (final d in [alice, bob]) {
      await d.coordinator.syncAll();
      expect(await d.service.takeAccessNotices(o.id), isEmpty);
    }
    // Hers looks again 23 hours after the end; his, two hours later still.
    moved = const Duration(hours: 24);
    await alice.coordinator.syncAll();
    expect([for (final n in await alice.service.takeAccessNotices(o.id)) (n.kind, n.crateName)],
        [(AccessNoticeKind.over, 'Staging')]);
    moved = const Duration(hours: 26);
    await bob.coordinator.syncAll();
    expect(await bob.crates(o.id), ['Production:use']);
    expect(await bob.service.takeAccessNotices(o.id), isEmpty, reason: 'old news');
    expect(await bob.service.takeAccessNotices(o.id), isEmpty);
  });

  test('the name of a Crate held until a set time is kept for the notice, and forgotten with the Crate', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchard(owner);
    await join(owner, alice, o.id, o.member);
    Future<Map<String, Object?>> namesKept() async =>
        jsonDecode(await LocalStateStore(await alice.db(o.id)).read('access.names') ?? '{}') as Map<String, Object?>;
    Future<void> give(String crateId, CrateLevel level) => owner.service
        .giveAccess(o.id, uid: _alice, crateId: crateId, level: level, duration: const Duration(hours: 1));

    // Staging, which she does not open otherwise, and more in Production,
    // which she does: only the first can leave her device.
    await give(o.staging, CrateLevel.use);
    await give(o.production, CrateLevel.edit);
    await alice.coordinator.syncAll();
    expect(await alice.service.takeAccessNotices(o.id), isEmpty);
    expect(await namesKept(), {o.staging: 'Staging'});
    // Renamed meanwhile: the name it has when it leaves is the one said.
    await owner.service.renameCrate(o.id, o.staging, 'Staging EU');
    await alice.coordinator.syncAll();
    expect(await alice.service.takeAccessNotices(o.id), isEmpty);
    expect(await namesKept(), {o.staging: 'Staging EU'});

    moved = const Duration(hours: 1, seconds: 5);
    await alice.coordinator.syncAll();
    final notices = await alice.service.takeAccessNotices(o.id);
    expect([for (final n in notices) (n.kind, n.crateId, n.crateName)],
        [(AccessNoticeKind.over, o.staging, 'Staging EU')]);
    expect(await namesKept(), isEmpty, reason: 'said once, then nothing of the Crate stays');

    // Ended early: forgotten at the next look, with nothing said.
    await give(o.staging, CrateLevel.use);
    await alice.coordinator.syncAll();
    expect(await alice.service.takeAccessNotices(o.id), isEmpty);
    expect(await namesKept(), {o.staging: 'Staging EU'});
    await owner.service.endAccess(o.id, uid: _alice, crateId: o.staging);
    await alice.coordinator.syncAll();
    expect(await alice.service.takeAccessNotices(o.id), isEmpty);
    expect(await namesKept(), isEmpty);
  });

  group('with ZestSSH Cloud away', () {
    /// Staging given to alice for [time], with a host in it and one in
    /// Production, on her device; and the second it ends.
    Future<({_Device owner, _Device alice, String id, String production, String staging, int until})> given(
        {CrateLevel level = CrateLevel.edit, Duration time = const Duration(hours: 2)}) async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await orchard(owner);
      await join(owner, alice, o.id, o.member);
      await owner.addHost(o.id, 'staging-db', crateId: o.staging);
      await owner.addHost(o.id, 'web-01', crateId: o.production);
      await owner.coordinator.syncOne(o.id);
      await owner.service.giveAccess(o.id, uid: _alice, crateId: o.staging, level: level, duration: time);
      await alice.coordinator.syncAll();
      // (As after every sync: its name is kept for the moment it leaves.)
      expect(await alice.service.takeAccessNotices(o.id), isEmpty);
      return (
        owner: owner,
        alice: alice,
        id: o.id,
        production: o.production,
        staging: o.staging,
        until: server.recordOf(o.id).members[_alice]!.timed[o.staging]!.until,
      );
    }

    /// Every clock, the server's and the devices', at [seconds].
    void setClocks(int seconds) {
      DateTime at() => DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      OrchardService.debugNow = at;
      server.clock = at;
    }

    test('a Crate held until a set time leaves the device when the time comes, by its clock: no sync gets through, '
        'nothing is asked of the server, its person is told, and what they open for good stays', () async {
      final t = await given();
      final alice = t.alice;
      expect(await alice.crates(t.id), ['Production:use', 'Staging:edit']);
      expect(await alice.hosts(t.id), ['staging-db', 'web-01']);

      // A second before its time nothing ends.
      server.down = true;
      setClocks(t.until - 1);
      expect(await alice.service.endAccessByClock(), isEmpty);
      expect(await alice.crates(t.id), ['Production:use', 'Staging:edit']);

      // Its time comes. A sync does not get through, and changes nothing.
      setClocks(t.until);
      await expectLater(alice.coordinator.syncAll(), throwsA(isA<SocketException>()));
      expect(await alice.crates(t.id), ['Production:use', 'Staging:edit']);
      // The device ends it by itself.
      final asked = server.asked;
      expect(await alice.service.endAccessByClock(), {t.id});
      expect(server.asked, asked, reason: 'the server was asked nothing');
      expect(await alice.crates(t.id), ['Production:use']);
      expect(await alice.crateKeys(t.id, t.staging), 0);
      expect(await alice.crateKeys(t.id, t.production), 1);
      expect(await alice.hosts(t.id), ['web-01']);
      expect(await alice.service.nextAccessEnd(), isNull);
      expect(await alice.service.timedAccess(t.id), isEmpty);
      expect([for (final n in await alice.service.takeAccessNotices(t.id)) (n.kind, n.crateId, n.crateName)],
          [(AccessNoticeKind.over, t.staging, 'Staging')]);
      expect(await alice.service.endAccessByClock(), isEmpty, reason: 'once');
      expect(await alice.service.takeAccessNotices(t.id), isEmpty);

      // The server answers again: nothing comes back, and the device syncs.
      server.down = false;
      await alice.coordinator.syncAll();
      expect(await alice.crates(t.id), ['Production:use']);
      expect(await alice.hosts(t.id), ['web-01']);
    });

    test('more in a Crate they open for good: what was added for the time falls away by the clock, and the Crate, '
        'its key and its hosts stay', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final o = await orchard(owner);
      await join(owner, alice, o.id, o.member);
      await owner.addHost(o.id, 'web-01', crateId: o.production);
      await owner.coordinator.syncOne(o.id);
      await owner.service.giveAccess(o.id,
          uid: _alice, crateId: o.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
      await alice.coordinator.syncAll();
      expect(await alice.crates(o.id), ['Production:edit']);
      final until = server.recordOf(o.id).members[_alice]!.timed[o.production]!.until;
      Future<Object?> switchesKept() async => jsonDecode((await (await alice.db(o.id))
              .customSelect('SELECT switches FROM orchard_crates WHERE crate_id = ?', variables: [Variable(o.production)])
              .getSingle())
          .read<String>('switches'));

      server.down = true;
      setClocks(until - 1);
      expect(await alice.service.endAccessByClock(), isEmpty);
      setClocks(until);
      expect(await alice.service.endAccessByClock(), {o.id});
      expect(await alice.crates(o.id), ['Production:use']);
      expect(await switchesKept(), switchList(levelSwitches(CrateLevel.use)));
      expect(await alice.crateKeys(o.id, o.production), 1);
      expect(await alice.hosts(o.id), ['web-01']);
      expect(await alice.service.takeAccessNotices(o.id), isEmpty, reason: 'nothing left her device');
      expect(await alice.service.endAccessByClock(), isEmpty, reason: 'once');
    });

    test('new items go into a Crate they may still add to once the one they went into has left, and nowhere '
        'where there is none', () async {
      final t = await given();
      final db = await t.alice.db(t.id);
      Future<String?> home() async =>
          (await db.customSelect('SELECT default_crate_id FROM orchard_info WHERE id = 1').getSingle())
              .read<String?>('default_crate_id');
      // Production gives her use, which adds nothing: with Staging gone
      // there is nowhere.
      expect(await home(), t.staging);
      server.down = true;
      setClocks(t.until);
      expect(await t.alice.service.endAccessByClock(), {t.id});
      expect(await home(), isNull);

      // With edit in Production for good, that is where new items go next.
      server.down = false;
      final member = server.recordOf(t.id).roles.values.single;
      await t.owner.service.saveRole(t.id,
          id: member.id, name: 'Member', can: const {}, crates: {t.production: levelSwitches(CrateLevel.edit)});
      await t.owner.service
          .giveAccess(t.id, uid: _alice, crateId: t.staging, level: CrateLevel.edit, duration: const Duration(hours: 1));
      await t.alice.coordinator.syncAll();
      await CratePlacement(db).setDefaultCrate(t.staging);
      expect(await home(), t.staging);
      final again = server.recordOf(t.id).members[_alice]!.timed[t.staging]!.until;
      server.down = true;
      setClocks(again);
      expect(await t.alice.service.endAccessByClock(), {t.id});
      expect(await home(), t.production);
    });

    test('their own time in the Orchard comes: the Orchard says so, and what is on the device stays', () async {
      final t = await given();
      final alice = t.alice;
      final ends = t.until + 3600;
      await t.owner.service.setMemberEndsAt(t.id, _alice, ends);
      await alice.coordinator.syncAll();
      Future<String> status() async =>
          (await (await alice.db(t.id)).customSelect('SELECT status FROM orchard_info WHERE id = 1').getSingle())
              .read<String>('status');

      server.down = true;
      setClocks(ends - 1);
      // (What was given until a set time has ended by now, and leaves.)
      expect(await alice.service.endAccessByClock(), {t.id});
      expect(await alice.crates(t.id), ['Production:use']);
      expect(await status(), 'active');
      expect(await alice.service.endAccessByClock(), isEmpty);

      setClocks(ends);
      expect(await alice.service.endAccessByClock(), {t.id});
      expect(await status(), 'ended');
      expect(await alice.crates(t.id), ['Production:use']);
      expect(await alice.hosts(t.id), ['web-01']);
      expect(await alice.crateKeys(t.id, t.production), 1);
      expect(await alice.service.endAccessByClock(), isEmpty, reason: 'said once');
    });

    test('an Orchard whose database is closed is not opened for it, and nothing fails', () async {
      final t = await given();
      server.down = true;
      setClocks(t.until);
      await t.alice.service.databases.close(t.id);
      final opens = t.alice.storage.opens;
      expect(await t.alice.service.endAccessByClock(), isEmpty);
      expect(t.alice.storage.opens, opens);
      // Nor for someone whose keys are not here to say who they are.
      final nobody = OrchardService(
        server: t.alice.server,
        databases: t.owner.service.databases,
        author: () async => null,
      );
      expect(await nobody.endAccessByClock(), isEmpty);
      final unknown = OrchardService(
        server: t.alice.server,
        databases: t.owner.service.databases,
        author: () async => throw StateError('no keys'),
      );
      expect(await unknown.endAccessByClock(), isEmpty);
      // And the owner, of whom nothing ends, loses nothing.
      expect(await t.owner.service.endAccessByClock(), isEmpty);
      expect(await t.owner.crates(t.id), ['Production:manage', 'Staging:manage']);
      // (Closed by this test already.)
      t.alice.storage.dbs.clear();
    });

    test('someone suspended, as far as their device knows, keeps what is on it whatever time has come, as when '
        'the server says so', () async {
      final t = await given(time: const Duration(hours: 1));
      await t.owner.service.suspendMember(t.id, _alice);
      await t.alice.coordinator.syncAll();
      server.down = true;
      setClocks(t.until + 60);
      expect(await t.alice.service.endAccessByClock(), isEmpty);
      expect(await t.alice.crates(t.id), ['Production:use', 'Staging:edit']);
      expect(await t.alice.hosts(t.id), ['staging-db', 'web-01']);
    });

    test('a database nobody told how the device stands closes a Crate whose time has come all the same, by the '
        'system\'s clock, beside a limit it cannot measure', () async {
      final t = await given(time: const Duration(hours: 1));
      await t.owner.service.setCrateOfflineLimit(t.id, t.production, 24);
      await t.alice.coordinator.syncAll();
      final db = await t.alice.db(t.id);
      final real = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await LocalStateStore(db).write(kAccessUntilState, jsonEncode({t.staging: real + 3600}));
      expect(await closedCratesIn(db), {t.production: 24}, reason: 'a limit that cannot be measured counts as reached');
      await LocalStateStore(db).write(kAccessUntilState, jsonEncode({t.staging: real - 1}));
      expect(await closedCratesIn(db), {t.production: 24, t.staging: 0});
      final limits = await crateLimitsIn(db);
      expect(limits.closed, {t.production: 24});
      expect(limits.ended, {t.staging: real - 1});
    });

    test('given again while the device could not hear of it: the Crate left by the clock, and is back with the next '
        'sync that gets through', () async {
      final t = await given();
      server.down = true;
      setClocks(t.until + 60);
      expect(await t.alice.service.endAccessByClock(), {t.id});
      expect(await t.alice.crates(t.id), ['Production:use']);
      server.down = false;
      await t.owner.service
          .giveAccess(t.id, uid: _alice, crateId: t.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
      await t.alice.coordinator.syncAll();
      expect(await t.alice.crates(t.id), ['Production:use', 'Staging:use']);
      expect(await t.alice.hosts(t.id), ['staging-db', 'web-01']);
    });

    test('from the second its time comes the Crate is closed on the device, before anything has taken it off: its '
        'hosts do not connect, nothing in it is shown, and no offline pass is the answer; a clock turned back gives '
        'no time back', () async {
      final t = await given(level: CrateLevel.use, time: const Duration(hours: 1));
      final alice = t.alice;
      final db = await alice.db(t.id);
      final l10n = lookupAppLocalizations(const Locale('en'));
      // How the device stands, as the app gives it to every Orchard
      // database: its clock, and the furthest that clock has read.
      var furthest = 0;
      attachDeviceContact(
          db,
          DeviceContact(
            read: () => OrchardContact(lastContact: t.until - 3600, latest: furthest),
            now: () => OrchardService.debugNow().millisecondsSinceEpoch ~/ 1000,
          ));
      Future<Object?> kept() async => jsonDecode(await LocalStateStore(db).read(kAccessUntilState) ?? 'null');
      expect(await kept(), {t.staging: t.until});

      setClocks(t.until - 1);
      expect(await closedCratesIn(db), isEmpty);
      expect((await crateLimitsIn(db)).ended, isEmpty);
      await requireCratesOpenIn(db, hostId: 'staging-db');
      expect(await itemSwitchesIn(db, 'host', 'staging-db'), isNotEmpty);

      setClocks(t.until);
      expect(await closedCratesIn(db), {t.staging: 0});
      final limits = await crateLimitsIn(db);
      expect(limits.ended, {t.staging: t.until});
      expect(limits.closed, isEmpty);
      expect(limits.closing, isEmpty);
      await expectLater(
          requireCratesOpenIn(db, hostId: 'staging-db'),
          throwsA(isA<CrateClosedOffline>()
              .having((e) => e.accessOver, 'its time is over', isTrue)
              .having((e) => e.hours, 'no limit', 0)
              .having((e) => (e.crateId, e.orchardId), 'which', (t.staging, t.id))
              .having((e) => '$e', 'what is said', l10n.crateAccessOverError('Staging'))));
      expect(await itemSwitchesIn(db, 'host', 'staging-db'), isEmpty);
      expect((await itemClosedIn(db, 'host', 'staging-db'))?.accessOver, isTrue);
      // What she opens for good is as open as it was.
      await requireCratesOpenIn(db, hostId: 'web-01');
      expect(await itemSwitchesIn(db, 'host', 'web-01'), isNotEmpty);
      expect(await itemClosedIn(db, 'host', 'web-01'), isNull);

      // The clock is turned back ten minutes. It had read later than that:
      // still closed. Had it not, the Crate would be open by that clock.
      furthest = t.until + 5;
      setClocks(t.until - 600);
      expect(await closedCratesIn(db), {t.staging: 0});
      furthest = 0;
      expect(await closedCratesIn(db), isEmpty);

      // Off the device: nothing of it is there to close any more.
      setClocks(t.until);
      server.down = true;
      expect(await alice.service.endAccessByClock(), {t.id});
      expect(await closedCratesIn(db), isEmpty);
      expect(await kept(), isNull);
    });

    test('until when a Crate is held is kept for one held only until a set time, and kept up as that changes', () async {
      final t = await given(time: const Duration(hours: 1));
      final db = await t.alice.db(t.id);
      Future<Object?> kept() async => jsonDecode(await LocalStateStore(db).read(kAccessUntilState) ?? 'null');
      expect(await kept(), {t.staging: t.until});
      expect(jsonDecode(await LocalStateStore(await t.owner.db(t.id)).read(kAccessUntilState) ?? 'null'), isNull,
          reason: 'nothing of the owner ends');

      // More in a Crate she opens for good is no Crate that leaves.
      await t.owner.service.giveAccess(t.id,
          uid: _alice, crateId: t.production, level: CrateLevel.edit, duration: const Duration(minutes: 30));
      await t.alice.coordinator.syncAll();
      expect(await kept(), {t.staging: t.until});

      // Given for longer: the new time.
      await t.owner.service
          .giveAccess(t.id, uid: _alice, crateId: t.staging, level: CrateLevel.use, duration: const Duration(hours: 5));
      await t.alice.coordinator.syncAll();
      final longer = server.recordOf(t.id).members[_alice]!.timed[t.staging]!.until;
      expect(longer, greaterThan(t.until));
      expect(await kept(), {t.staging: longer});

      // What was added to Production ends by the clock; Staging is still held.
      server.down = true;
      setClocks(t.until);
      expect(await t.alice.service.endAccessByClock(), {t.id});
      expect(await t.alice.crates(t.id), ['Production:use', 'Staging:use']);
      expect(await kept(), {t.staging: longer});
      server.down = false;

      // More in Production again, for longer than Staging is held: when
      // Staging leaves by the clock, nothing is left that could leave.
      await t.owner.service.giveAccess(t.id,
          uid: _alice, crateId: t.production, level: CrateLevel.edit, duration: const Duration(hours: 6));
      await t.alice.coordinator.syncAll();
      expect(await kept(), {t.staging: longer});
      server.down = true;
      setClocks(longer);
      expect(await t.alice.service.endAccessByClock(), {t.id});
      expect(await t.alice.crates(t.id), ['Production:edit']);
      expect(await kept(), isNull);
      server.down = false;

      // Given again, and ended early by the owner: nothing is kept.
      await t.owner.service
          .giveAccess(t.id, uid: _alice, crateId: t.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
      await t.alice.coordinator.syncAll();
      expect(await kept(), isNotNull);
      await t.owner.service.endAccess(t.id, uid: _alice, crateId: t.staging);
      await t.alice.coordinator.syncAll();
      expect(await kept(), isNull);
      expect(await closedCratesIn(db), isEmpty);
    });

    test('what is kept of until when does not read: nothing is closed for it', () async {
      final t = await given(time: const Duration(hours: 1));
      final db = await t.alice.db(t.id);
      setClocks(t.until + 10);
      for (final unreadable in ['not json', '[1, 2]', jsonEncode({t.staging: 'soon'})]) {
        await LocalStateStore(db).write(kAccessUntilState, unreadable);
        expect(await closedCratesIn(db), isEmpty, reason: unreadable);
      }
      // And in your Tree nothing of the kind is looked for.
      final tree = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(tree.close);
      await LocalStateStore(tree).write(kAccessUntilState, jsonEncode({t.staging: 1}));
      expect(await closedCratesIn(tree), isEmpty);
    });

    test('the words for a Crate whose time is over, in every language: they name it, and say it can be asked for '
        'again', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final words = lookupAppLocalizations(locale);
        final said = words.crateAccessOverError('Staging');
        expect(said, contains('Staging'), reason: '$locale');
        expect(said, isNot(words.crateClosedOfflineError('Staging')), reason: '$locale');
        final again = RegExp(r'[^.。।]+[.。।]\s*$').firstMatch(words.noticeAccessDeclinedBody)!.group(0)!.trim();
        expect(said, endsWith(again), reason: '$locale: the words there are for asking again');
      }
    });
  });
}
