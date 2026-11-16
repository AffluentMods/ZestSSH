import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import '../fake_crate_server.dart';

/// Trusted devices (3.0), from the devices: an owner's first device
/// approves itself, every other one asks and is approved from a device that
/// already is, after two people (or one person with two devices) compared
/// three words; the rule goes on once the owners have two; a device nobody
/// approved is then held back, and one whose approval was taken back drops
/// what it holds. The (fake) server checks every entry with the record's
/// rules, holds the rule for each sign-in's device, and passes the requests
/// along, as ZestSSH Cloud does.

const _owner = 'owner-1';
const _admin = 'admin-1';
const _alice = 'alice';
const _bob = 'bob';
const _carol = 'carol';

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

/// One device's secure storage: every device in a test has its own.
class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Device {
  _Device(this.shared, this.uid, this.keys, this.name, {_Device? restartOf})
      : keychain = restartOf?.keychain ?? _Keychain(),
        storage = restartOf?.storage ?? _MemoryStorage() {
    server = shared.as(uid, signIn: () => name);
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: name == null ? null : DeviceIdentityStore(keychain),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;

  /// What the device is called in the test, which is also its sign-in (a
  /// device that signs in again takes another); null for a device with no
  /// session and nowhere to keep a key.
  String? name;
  late final CrateServer server;
  final _Keychain keychain;
  final _MemoryStorage storage;
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  String get session => FakeCrateServer.sessionOf(uid, name!);

  /// This device's key, as the record writes it.
  Future<String> get key async => (await DeviceIdentityStore(keychain).forAccount(uid)).key;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<void> addHost(String orchardId, String id, {required String crateId}) async {
    final d = await db(orchardId);
    await CratePlacement(d).setDefaultCrate(crateId);
    final at = DateTime(2026, 10, 1);
    await d.into(d.connections).insert(
        ConnectionsCompanion.insert(id: id, label: id, host: '192.0.2.10', createdAt: at, updatedAt: at));
  }

  Future<List<String>> hosts(String orchardId) async => [
        for (final r in await (await db(orchardId)).customSelect('SELECT id FROM connections ORDER BY id').get())
          r.read<String>('id'),
      ];

  /// How many entries of the Orchard's record this device holds.
  Future<int> recordEntries(String orchardId) async =>
      (await (await db(orchardId)).customSelect('SELECT COUNT(*) AS n FROM orchard_record_entries').getSingle())
          .read<int>('n');

  /// What the Orchard's own database says of where this device stands:
  /// its status, and what holds it back.
  Future<(String?, Object?)> standing(String orchardId) async {
    final row =
        await (await db(orchardId)).customSelect('SELECT status, held FROM orchard_info WHERE id = 1').getSingleOrNull();
    final held = row?.read<String?>('held');
    return (row?.read<String>('status'), held == null ? null : jsonDecode(held));
  }

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

Matcher _refused(String reason) => isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', reason);

Matcher _server(int status, String code) => isA<OrchardServerException>()
    .having((e) => e.status, 'status', status)
    .having((e) => e.code, 'code', code);

const _rule = RecordRules(trustedDevices: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    for (final uid in [_owner, _admin, _alice, _bob, _carol]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _admin, _alice, _bob, _carol]) {
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

  _Device device(String uid, String? name, {_Device? restartOf}) {
    final d = _Device(server, uid, keys[uid]!, name, restartOf: restartOf);
    if (restartOf == null) devices.add(d);
    return d;
  }

  /// An Orchard of the owner's with one Crate, which the first role
  /// (Member) uses.
  Future<({String id, String crate, String member})> orchard(_Device owner) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single;
    return (id: id, crate: member.crates.keys.single, member: member.id);
  }

  Future<void> join(_Device by, _Device person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    final invite = (await by.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, person.uid);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    await person.service.refresh();
  }

  /// [asking] asks, [approver] answers, both have the words, and
  /// [approver]'s person, having compared them, approves. Returns the words.
  Future<List<String>> approve(_Device asking, _Device approver, String orchardId) async {
    final asked = await asking.service.askDeviceApproval(orchardId);
    expect(asked.words, isNull, reason: 'nobody answered yet');
    final waiting = (await approver.service.deviceRequests(orchardId)).singleWhere((r) => r.id == asked.id);
    expect(waiting.stage, DeviceRequestStage.asks);
    await approver.service.answerDeviceRequest(orchardId, asked.id);
    final answered = (await asking.service.deviceAsk(orchardId))!;
    final shown = (await approver.service.deviceRequests(orchardId)).singleWhere((r) => r.id == asked.id);
    expect(shown.stage, DeviceRequestStage.compare);
    expect(shown.words, answered.words);
    await approver.service.approveDevice(orchardId, asked.id);
    return answered.words!;
  }

  /// The owner's laptop and phone approved, and the rule on.
  Future<({String id, String crate, String member, _Device laptop, _Device phone})> guarded() async {
    final laptop = device(_owner, 'laptop');
    final phone = device(_owner, 'phone');
    final o = await orchard(laptop);
    await laptop.service.approveThisDevice(o.id);
    await phone.service.refresh();
    await approve(phone, laptop, o.id);
    await laptop.service.setRules(o.id, _rule);
    // (The phone reads its own approval, and the rule.)
    await phone.service.refresh();
    return (id: o.id, crate: o.crate, member: o.member, laptop: laptop, phone: phone);
  }

  test("an owner's first device approves itself, the second asks and is approved once the words were compared, "
      'and the rule goes on', () async {
    final laptop = device(_owner, 'laptop');
    final o = await orchard(laptop);
    var here = await laptop.service.deviceStanding(o.id);
    expect((here.ruleOn, here.approved, here.mine, here.ownerDevices, here.isOwner), (false, false, 0, 0, true));
    expect((here.canApproveItself, here.canTurnOn), (true, false));
    expect(here.thisKey, await laptop.key);
    expect(here.thisCode, deviceCode(await laptop.key));
    expect(here.without, [_owner]);
    await expectLater(laptop.service.setRules(o.id, _rule), throwsA(_refused('two approved devices among the owners first')));

    await laptop.service.approveThisDevice(o.id);
    here = await laptop.service.deviceStanding(o.id);
    expect((here.approved, here.mine, here.ownerDevices), (true, 1, 1));
    expect((here.canApproveItself, here.canTurnOn), (false, false));
    expect(here.without, isEmpty);
    expect(server.recordOf(o.id).devicesOf(_owner), {await laptop.key});
    expect(server.namedDevices[laptop.session], await laptop.key, reason: 'the sign-in said which device it is');
    // The entry: this device, approved through itself, and signed by it.
    var entry = server.entriesOf(o.id).last;
    expect(entry.type, RecordTypes.deviceTrust);
    expect((entry.body['uid'], entry.body['device'], entry.body['via']), (_owner, await laptop.key, await laptop.key));
    // One device is not two: still not.
    await expectLater(laptop.service.setRules(o.id, _rule), throwsA(_refused('two approved devices among the owners first')));

    // The owner's phone: in the Orchard (the rule is off), not approved, and
    // no longer a first device that could approve itself.
    final phone = device(_owner, 'phone');
    expect(await phone.service.refresh(), [o.id]);
    var there = await phone.service.deviceStanding(o.id);
    expect((there.approved, there.mine, there.canApproveItself), (false, 1, false));
    await expectLater(phone.service.approveThisDevice(o.id), throwsA(_refused('not from an approved device')));
    expect(await phone.service.deviceRequests(o.id), isEmpty, reason: 'only an approved device answers');
    // It sees the owner's approved device, which is not this one, and may
    // not remove it from here.
    expect([for (final d in await phone.service.memberDevices(o.id, _owner)) (d.key, d.isThis, d.canRemove)],
        [(await laptop.key, false, false)]);

    final asked = await phone.service.askDeviceApproval(o.id);
    expect(asked.words, isNull);
    // Its own request is not one it answers, even from a server that lists
    // it there: its copy of the record says it is not approved, and it does
    // not so much as ask.
    final lists = server.deviceLists;
    server.listsDeviceRequestsToAll = true;
    expect(await phone.service.deviceRequests(o.id), isEmpty);
    expect(server.deviceLists, lists);
    server.listsDeviceRequestsToAll = false;
    expect(asked.expiresAt, closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600, 5));
    var waiting = (await laptop.service.deviceRequests(o.id)).single;
    expect((waiting.id, waiting.uid, waiting.stage), (asked.id, _owner, DeviceRequestStage.asks));
    expect((waiting.words, waiting.deviceKey, waiting.code), (null, null, null),
        reason: 'nothing of the device before it showed its key');

    await laptop.service.answerDeviceRequest(o.id, asked.id);
    expect((await laptop.service.deviceRequests(o.id)).single.stage, DeviceRequestStage.answered);
    // The phone sees the answer, shows what it committed to, and has words.
    final answered = (await phone.service.deviceAsk(o.id))!;
    expect(answered.words, hasLength(kDeviceTrustWordCount));
    expect(answered.sameAccount, isTrue);
    expect((await phone.service.deviceAsk(o.id))!.words, answered.words, reason: 'asked again, the same');
    waiting = (await laptop.service.deviceRequests(o.id)).single;
    expect(waiting.stage, DeviceRequestStage.compare);
    expect(waiting.words, answered.words);
    expect(waiting.deviceKey, await phone.key);
    expect(waiting.code, deviceCode(await phone.key));
    expect(server.recordOf(o.id).devicesOf(_owner), {await laptop.key}, reason: 'nothing is approved by showing words');

    await laptop.service.approveDevice(o.id, asked.id);
    expect(server.recordOf(o.id).devicesOf(_owner), {await laptop.key, await phone.key});
    entry = server.entriesOf(o.id).last;
    expect((entry.body['uid'], entry.body['device'], entry.body['via']), (_owner, await phone.key, await laptop.key));
    expect(server.deviceRequestsOf(o.id), isEmpty);
    expect(await phone.service.deviceAsk(o.id), isNull);
    expect(await laptop.service.deviceRequests(o.id), isEmpty);
    await expectLater(laptop.service.approveDevice(o.id, asked.id), throwsA(isA<DeviceRequestGone>()));

    // Two approved devices among the owners: the rule goes on, from one of
    // them. Both get in.
    await phone.service.refresh();
    there = await phone.service.deviceStanding(o.id);
    expect((there.approved, there.mine, there.ownerDevices, there.canTurnOn), (true, 2, 2, true));
    await phone.service.setRules(o.id, _rule);
    expect(server.recordOf(o.id).rules.trustedDevices, isTrue);
    expect(await laptop.service.refresh(), [o.id]);
    expect(await phone.service.refresh(), [o.id]);
    expect((await laptop.service.deviceStanding(o.id)).ruleOn, isTrue);
  });

  test('with the rule on, a device nobody approved is held back, an owner on one cannot change the rules, '
      'and it gets in once it asked and was approved', () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await join(g.laptop, alice, g.id, g.member);
    await g.laptop.addHost(g.id, 'web-1', crateId: g.crate);
    await g.laptop.coordinator.syncOne(g.id);

    // Alice: in the Orchard, and held back as a device nobody approved.
    expect(await alice.service.refresh(), isEmpty);
    var (status, held) = await alice.standing(g.id);
    expect(status, 'rules');
    expect((held as Map)['unmet'], ['trusted_device']);
    expect(held.containsKey('device_removed'), isFalse);
    expect(await alice.hosts(g.id), isEmpty);
    expect(server.namedDevices[alice.session], await alice.key, reason: 'it said which device it is all the same');
    await expectLater(alice.server.record(g.id, after: 0), throwsA(_server(403, 'rules-unmet')));

    // The owner's third device is held back like anyone's: no rules from it.
    final tablet = device(_owner, 'tablet');
    final reads = server.recordReads;
    expect(await tablet.service.refresh(), isEmpty);
    expect(server.recordReads, reads, reason: 'the record is closed to it, and it does not ask for it');
    (status, held) = await tablet.standing(g.id);
    expect(status, 'rules');
    expect((held as Map)['unmet'], ['trusted_device']);
    await expectLater(
      tablet.service.setRules(g.id, RecordRules.none),
      throwsA(isA<OrchardServerException>().having((e) => e.deviceNotApproved, 'only the device', isTrue)),
    );
    expect(server.recordOf(g.id).rules.trustedDevices, isTrue);
    expect(await tablet.service.deviceRequests(g.id), isEmpty);

    // Alice asks; the owner answers on the phone; the words match; approved.
    final words = await approve(alice, g.phone, g.id);
    expect(words, hasLength(3));
    expect(server.recordOf(g.id).devicesOf(_alice), {await alice.key});
    final entry = server.entriesOf(g.id).last;
    expect((entry.by, entry.body['uid'], entry.body['via']), (_owner, _alice, await g.phone.key));
    expect(await alice.service.refresh(), [g.id]);
    await alice.coordinator.syncAll();
    expect(await alice.hosts(g.id), ['web-1']);
    expect((await alice.standing(g.id)).$1, 'active');
    final hers = (await alice.service.deviceStanding(g.id));
    expect((hers.ruleOn, hers.approved, hers.mine, hers.isOwner, hers.canApproveItself), (true, true, 1, false, false));
    expect(hers.ownerDevices, 2, reason: "the owners', not her own");
  });

  test('who sees a request and who approves: the member, an owner, an admin for those below; '
      'the record decides, not what the server lists', () async {
    final g = await guarded();
    final admin = device(_admin, 'admin-desk');
    final alice = device(_alice, 'alice-laptop');
    final bob = device(_bob, 'bob-laptop');
    // Everyone joins and is approved while the rule is off.
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, admin, g.id, FixedRoles.admin);
    await join(g.laptop, alice, g.id, g.member);
    await join(g.laptop, bob, g.id, g.member);
    for (final d in [admin, alice, bob]) {
      await approve(d, g.laptop, g.id);
      await d.service.refresh();
    }
    await g.laptop.service.setRules(g.id, _rule);
    for (final d in [admin, alice, bob]) {
      expect(await d.service.refresh(), [g.id]);
    }

    // Alice's second device asks: her first one, the owner and the admin see
    // it; bob does not, though his device is approved.
    final second = device(_alice, 'alice-phone');
    await second.service.refresh();
    final asked = await second.service.askDeviceApproval(g.id);
    for (final d in [alice, g.laptop, g.phone, admin]) {
      expect([for (final r in await d.service.deviceRequests(g.id)) (r.id, r.uid, r.stage)],
          [(asked.id, _alice, DeviceRequestStage.asks)], reason: d.name);
    }
    expect(await bob.service.deviceRequests(g.id), isEmpty);
    // A server that lists it to him anyway: his device still shows nothing
    // and answers nothing.
    server.listsDeviceRequestsToAll = true;
    expect((await bob.server.deviceRequests(g.id)).waiting, hasLength(1));
    expect(await bob.service.deviceRequests(g.id), isEmpty);
    await expectLater(bob.service.answerDeviceRequest(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));
    server.listsDeviceRequestsToAll = false;

    // An owner's new device: the owner's own to approve, not the admin's.
    final tablet = device(_owner, 'tablet');
    await tablet.service.refresh();
    final owners = await tablet.service.askDeviceApproval(g.id);
    expect([for (final r in await admin.service.deviceRequests(g.id)) r.id], [asked.id]);
    expect([for (final r in await g.laptop.service.deviceRequests(g.id)) r.id]..sort(), [asked.id, owners.id]..sort());
    server.listsDeviceRequestsToAll = true;
    expect([for (final r in await admin.service.deviceRequests(g.id)) r.id], [asked.id],
        reason: 'listed or not, an admin approves no owner');
    server.listsDeviceRequestsToAll = false;

    // The admin answers alice's: answered once, it is the admin's to finish.
    await admin.service.answerDeviceRequest(g.id, asked.id);
    await expectLater(g.laptop.service.answerDeviceRequest(g.id, asked.id), throwsA(isA<DeviceRequestGone>()),
        reason: 'the server no longer lists it to anyone else');
    expect([for (final r in await g.laptop.service.deviceRequests(g.id)) r.id], [owners.id]);
    final answered = (await second.service.deviceAsk(g.id))!;
    expect(answered.sameAccount, isFalse);
    final shown = (await admin.service.deviceRequests(g.id)).single;
    expect(shown.stage, DeviceRequestStage.compare);
    expect(shown.words, answered.words);
    await admin.service.approveDevice(g.id, asked.id);
    expect(server.recordOf(g.id).devicesOf(_alice), {await alice.key, await second.key});
    expect(server.entriesOf(g.id).last.by, _admin);

    // The devices as each member's panel lists them, once every device
    // read the record: this one first; who may remove which.
    for (final d in [alice, bob, g.laptop]) {
      await d.service.refresh();
    }
    var listed = await alice.service.memberDevices(g.id, _alice);
    expect([for (final d in listed) (d.key, d.isThis, d.canRemove)], [
      (await alice.key, true, true),
      (await second.key, false, true),
    ]);
    expect(listed.first.code, deviceCode(await alice.key));
    expect(await second.service.memberDevices(g.id, _alice), isEmpty,
        reason: 'held back until now, it holds no record yet');
    await second.service.refresh();
    listed = await second.service.memberDevices(g.id, _alice);
    expect((listed.first.key, listed.first.isThis), (await second.key, true));
    // Bob sees hers and may remove none; the admin may remove hers, and not
    // the owner's; the owner may remove anyone's.
    expect([for (final d in await bob.service.memberDevices(g.id, _alice)) (d.isThis, d.canRemove)],
        [(false, false), (false, false)]);
    expect([for (final d in await admin.service.memberDevices(g.id, _alice)) d.canRemove], [true, true]);
    expect([for (final d in await admin.service.memberDevices(g.id, _owner)) d.canRemove], [false, false]);
    expect([for (final d in await g.laptop.service.memberDevices(g.id, _admin)) (d.isThis, d.canRemove)], [(false, true)]);
    expect(await g.laptop.service.memberDevices(g.id, 'nobody'), isEmpty);
    // The tablet, which nobody approved, may remove nothing, its owner's
    // other devices neither. (It holds no record, the rule is on.)
    expect(await tablet.service.memberDevices(g.id, _owner), isEmpty);
  });

  test('a device removed drops what it holds and says so; approved again it syncs again; '
      'the owners keep one approved device', () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, alice, g.id, g.member);
    await approve(alice, g.laptop, g.id);
    await g.laptop.service.setRules(g.id, _rule);
    await g.laptop.addHost(g.id, 'web-1', crateId: g.crate);
    await g.laptop.coordinator.syncOne(g.id);
    await alice.coordinator.syncAll();
    expect(await alice.hosts(g.id), ['web-1']);
    expect(await alice.recordEntries(g.id), greaterThan(0));

    // The owner removes her device.
    await g.phone.service.refresh();
    await g.phone.service.removeDevice(g.id, uid: _alice, deviceKey: await alice.key);
    expect(server.recordOf(g.id).devicesOf(_alice), isEmpty);
    final entry = server.entriesOf(g.id).last;
    expect((entry.type, entry.body['uid'], entry.body['device'], entry.body['via']),
        (RecordTypes.deviceRevoke, _alice, await alice.key, await g.phone.key));

    // Her device, the next time it reaches the server: held, told so, and
    // nothing of the Orchard left on it.
    final before = alice.storage.dbs[g.id];
    expect(await alice.coordinator.syncAll(), isEmpty);
    var (status, held) = await alice.standing(g.id);
    expect(status, 'rules');
    expect((held as Map)['unmet'], ['trusted_device']);
    expect(held['device_removed'], isTrue);
    expect(await alice.hosts(g.id), isEmpty);
    expect(await alice.recordEntries(g.id), 0);
    expect(identical(alice.storage.dbs[g.id], before), isFalse, reason: 'the database itself was deleted');
    // Once: the next look leaves the (empty) database where it is.
    final emptied = alice.storage.dbs[g.id];
    await alice.service.refresh();
    expect(identical(alice.storage.dbs[g.id], emptied), isTrue);
    expect((await alice.service.deviceStanding(g.id)).approved, isFalse);

    // She asks again and is approved: everything comes back.
    await approve(alice, g.laptop, g.id);
    await alice.coordinator.syncAll();
    (status, held) = await alice.standing(g.id);
    expect(status, 'active');
    expect(await alice.hosts(g.id), ['web-1']);

    // A device takes back its own approval, and then holds nothing either.
    await alice.service.removeDevice(g.id, uid: _alice, deviceKey: await alice.key);
    expect(server.recordOf(g.id).devicesOf(_alice), isEmpty);
    expect((await alice.standing(g.id)).$1, 'rules');
    expect(await alice.hosts(g.id), isEmpty);

    // What the record refuses: a key that is no approved device, someone
    // else's device from a member, and the owners' last one while the rule
    // is on.
    await expectLater(g.laptop.service.removeDevice(g.id, uid: _alice, deviceKey: await alice.key),
        throwsA(_refused('not an approved device')));
    await expectLater(g.laptop.service.removeDevice(g.id, uid: _alice, deviceKey: 'not a key'),
        throwsA(_refused('not an approved device')));
    await g.laptop.service.removeDevice(g.id, uid: _owner, deviceKey: await g.phone.key);
    await expectLater(g.laptop.service.removeDevice(g.id, uid: _owner, deviceKey: await g.laptop.key),
        throwsA(_refused('would leave no owner with an approved device')));
    expect(server.recordOf(g.id).devicesOf(_owner), {await g.laptop.key});
    var standing = await g.laptop.service.deviceStanding(g.id);
    expect((standing.ownerDevices, standing.canTurnOn), (1, false));
    expect(standing.without, [_alice]);
    // Someone suspended is nobody the rule would shut out: not counted.
    await g.laptop.service.suspendMember(g.id, _alice);
    standing = await g.laptop.service.deviceStanding(g.id);
    expect(standing.without, isEmpty);
  });

  // Found in a security review: the server alone made
  // a device wipe a team's data, changes not yet sent included.
  test("ZestSSH Cloud says this device was removed and the team's signed record does not: what is here stays", () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, alice, g.id, g.member);
    await approve(alice, g.laptop, g.id);
    await g.laptop.service.setRules(g.id, _rule);
    await g.laptop.addHost(g.id, 'web-1', crateId: g.crate);
    await g.laptop.coordinator.syncOne(g.id);
    await alice.coordinator.syncAll();
    expect(await alice.hosts(g.id), ['web-1']);

    // The server says her device is held and was removed; the record says it is approved.
    server.held[_alice] = ['trusted_device'];
    server.sayDeviceRemoved(g.id, _alice, await alice.key);
    expect(server.recordOf(g.id).devicesOf(_alice), contains(await alice.key));
    final before = alice.storage.dbs[g.id];
    await alice.coordinator.syncAll();
    final (status, held) = await alice.standing(g.id);
    expect(status, 'rules');
    expect((held as Map).containsKey('device_removed'), isFalse, reason: 'not removed here');
    expect(await alice.hosts(g.id), ['web-1'], reason: 'nothing of the team went');
    expect(identical(alice.storage.dbs[g.id], before), isTrue, reason: 'the database is the same');
  });

  test('an admin decides about members below and not about another admin; a member about nobody else',
      () async {
    final g = await guarded();
    final admin = device(_admin, 'admin-desk');
    final bob = device(_bob, 'bob-desk');
    final carol = device(_carol, 'carol-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, admin, g.id, FixedRoles.admin);
    await join(g.laptop, bob, g.id, FixedRoles.admin);
    await join(g.laptop, carol, g.id, g.member);
    for (final d in [admin, bob, carol]) {
      await approve(d, g.laptop, g.id);
    }
    await g.laptop.service.setRules(g.id, _rule);
    for (final d in [admin, bob, carol, g.laptop]) {
      expect(await d.service.refresh(), [g.id]);
    }

    // Another device of bob's (an admin) asks: his own approved device and
    // the owner see it. The other admin does not, nor does carol, whatever
    // the server lists to them.
    final second = device(_bob, 'bob-phone');
    await second.service.refresh();
    final asked = await second.service.askDeviceApproval(g.id);
    server.listsDeviceRequestsToAll = true;
    expect([for (final r in await bob.service.deviceRequests(g.id)) r.id], [asked.id]);
    expect([for (final r in await g.laptop.service.deviceRequests(g.id)) r.id], [asked.id]);
    expect(await admin.service.deviceRequests(g.id), isEmpty, reason: 'an admin approves no other admin');
    expect(await carol.service.deviceRequests(g.id), isEmpty);
    await expectLater(admin.service.answerDeviceRequest(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));
    server.listsDeviceRequestsToAll = false;

    // What each may remove: an admin a member's and not another admin's; a
    // member their own and nobody else's.
    expect([for (final d in await admin.service.memberDevices(g.id, _bob)) d.canRemove], [false]);
    expect([for (final d in await admin.service.memberDevices(g.id, _carol)) d.canRemove], [true]);
    expect([for (final d in await admin.service.memberDevices(g.id, _admin)) (d.isThis, d.canRemove)], [(true, true)]);
    expect([for (final d in await carol.service.memberDevices(g.id, _admin)) d.canRemove], [false]);
    expect([for (final d in await carol.service.memberDevices(g.id, _carol)) (d.isThis, d.canRemove)], [(true, true)]);
  });

  test("a member's devices are listed this one first, the rest by what they are called", () async {
    final laptop = device(_owner, 'laptop');
    final o = await orchard(laptop);
    await laptop.service.approveThisDevice(o.id);
    // Three more, approved in the opposite order of their codes: the list is
    // not in the order the record came to hold them.
    final more = [for (final n in ['a', 'b', 'c']) device(_owner, 'device-$n')];
    final codes = {for (final d in more) d: deviceCode(await d.key)};
    more.sort((x, y) => codes[y]!.compareTo(codes[x]!));
    for (final d in more) {
      await d.service.refresh();
      await approve(d, laptop, o.id);
    }
    final all = [laptop, ...more];
    for (final viewer in all) {
      await viewer.service.refresh();
      final listed = await viewer.service.memberDevices(o.id, _owner);
      final others = [
        for (final d in all)
          if (d != viewer) deviceCode(await d.key),
      ]..sort();
      expect([for (final d in listed) d.code], [deviceCode(await viewer.key), ...others], reason: viewer.name);
      expect([for (final d in listed) d.isThis], [true, false, false, false], reason: viewer.name);
    }
  });

  test('a device that learns it is no longer approved while it reads the record lists nothing', () async {
    final g = await guarded();
    await g.laptop.service.setRules(g.id, RecordRules.none);
    final alice = device(_alice, 'alice-laptop');
    await join(g.laptop, alice, g.id, g.member);
    await approve(alice, g.laptop, g.id);
    await alice.service.refresh();
    expect((await alice.service.deviceStanding(g.id)).approved, isTrue);

    // Removed without her device hearing of it. Then carol joins, whom her
    // device has not heard of either, and carol's device and alice's other
    // one both ask.
    await g.laptop.service.removeDevice(g.id, uid: _alice, deviceKey: await alice.key);
    final carol = device(_carol, 'carol-laptop');
    await join(g.laptop, carol, g.id, g.member);
    await carol.service.askDeviceApproval(g.id);
    final second = device(_alice, 'alice-phone');
    await second.service.refresh();
    await second.service.askDeviceApproval(g.id);

    // A server that lists them to her removed device all the same: it reads
    // the record up to now for carol's sake, learns that it is not approved
    // any more, and lists nothing, her own other device's request neither.
    server.listsDeviceRequestsToAll = true;
    expect(await alice.service.deviceRequests(g.id), isEmpty);
    expect((await alice.service.deviceStanding(g.id)).approved, isFalse, reason: 'it read the record on the way');
    // The same with the rule on, where being removed costs it its copy of
    // the Orchard while it reads.
    server.listsDeviceRequestsToAll = false;
    await approve(alice, g.laptop, g.id);
    await g.laptop.service.setRules(g.id, _rule);
    await alice.service.refresh();
    await g.laptop.service.removeDevice(g.id, uid: _alice, deviceKey: await alice.key);
    final bob = device(_bob, 'bob-laptop');
    await join(g.laptop, bob, g.id, g.member);
    await bob.service.askDeviceApproval(g.id);
    server.listsDeviceRequestsToAll = true;
    expect(await alice.service.deviceRequests(g.id), isEmpty);
    expect((await alice.standing(g.id)).$1, 'rules');
    expect(await alice.recordEntries(g.id), 0);
  });

  test('someone in between: another key, another answer, another commitment or another member never passes '
      'as approved', () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, alice, g.id, g.member);
    await g.laptop.service.setRules(g.id, _rule);
    await alice.service.refresh();
    final hers = await DeviceIdentityStore(alice.keychain).forAccount(_alice);
    final stranger = await DeviceIdentity.generate();
    final strangerNonce = Uint8List.fromList(List.filled(32, 7));

    // 1. Both sides showed, and the approving device has its words. Then
    // what the asking device showed is swapped for another key: it is not
    // what was committed to, and the request ends on the approving device,
    // which approves nothing it had words for either.
    var asked = await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    final honest = (await alice.service.deviceAsk(g.id))!;
    var shown = (await g.laptop.service.deviceRequests(g.id)).single;
    expect(shown.stage, DeviceRequestStage.compare);
    expect(shown.words, honest.words);
    server.spoilDeviceRequest(g.id, asked.id, deviceKey: stranger.publicKey, nonce: strangerNonce);
    shown = (await g.laptop.service.deviceRequests(g.id)).single;
    expect((shown.stage, shown.words, shown.deviceKey), (DeviceRequestStage.changed, null, null));
    expect(server.deviceRequestsOf(g.id), isEmpty, reason: 'ended');
    await expectLater(g.laptop.service.approveDevice(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));
    expect(await g.laptop.service.deviceRequests(g.id), isEmpty);
    expect(await alice.service.deviceAsk(g.id), isNull);
    expect(server.recordOf(g.id).devicesOf(_alice), isEmpty);
    // The same swap before the approving device ever had words.
    asked = await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    await alice.service.deviceAsk(g.id);
    server.spoilDeviceRequest(g.id, asked.id, deviceKey: stranger.publicKey, nonce: strangerNonce);
    expect((await g.laptop.service.deviceRequests(g.id)).single.stage, DeviceRequestStage.changed);
    await expectLater(g.laptop.service.approveDevice(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));

    // 2. The commitment is swapped before anyone answers, and the stranger's
    // key shown for it: all of it fits together on the approving device,
    // whose words are made from what IT was shown and what IT answered
    // with, and are not the ones on alice's screen.
    asked = await alice.service.askDeviceApproval(g.id);
    final committed = server.deviceRequestsOf(g.id).single.commitment;
    final swapped = deviceTrustCommitment(stranger.publicKey, strangerNonce);
    server.spoilDeviceRequest(g.id, asked.id, commitment: swapped);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    final answer = server.deviceRequestsOf(g.id).single.responderNonce!;
    // Alice's device is passed the answer and shows its own key, which the
    // one in between keeps to itself, showing the stranger's instead.
    server.spoilDeviceRequest(g.id, asked.id, commitment: committed);
    final onHers = (await alice.service.deviceAsk(g.id))!;
    final herNonce = server.deviceRequestsOf(g.id).single.nonce!;
    expect(
      onHers.words,
      deviceTrustWords(
          orchardId: g.id, uid: _alice, commitment: committed, approverNonce: answer, deviceKey: hers.publicKey, nonce: herNonce),
    );
    server.spoilDeviceRequest(g.id, asked.id, deviceKey: stranger.publicKey, nonce: strangerNonce);
    shown = (await g.laptop.service.deviceRequests(g.id)).single;
    expect((shown.stage, shown.deviceKey), (DeviceRequestStage.compare, stranger.key));
    expect(
      shown.words,
      deviceTrustWords(
          orchardId: g.id,
          uid: _alice,
          commitment: swapped,
          approverNonce: answer,
          deviceKey: stranger.publicKey,
          nonce: strangerNonce),
      reason: 'from what the approving device kept, not from what the server says was committed to',
    );
    expect(shown.words, isNot(onHers.words), reason: 'the two screens differ, and the person declines');
    expect(onHers.words, isNot(honest.words), reason: 'every request has words of its own');
    await g.laptop.service.declineDeviceRequest(g.id, asked.id);

    // The same swap, left in place: what alice's device shows is not what
    // the server holds as committed to. Her request is over, and nothing
    // more is said of it than that.
    asked = await alice.service.askDeviceApproval(g.id);
    server.spoilDeviceRequest(g.id, asked.id, commitment: swapped);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    expect(await alice.service.deviceAsk(g.id), isNull);
    expect(server.deviceRequestsOf(g.id), isEmpty);
    final lists = server.deviceLists;
    expect(await alice.service.deviceAsk(g.id), isNull);
    expect(server.deviceLists, lists, reason: 'over on her device too: it asks nothing more about it');
    expect(await g.laptop.service.deviceRequests(g.id), isEmpty);

    // 3. The answer is swapped on its way to the asking device, and stays
    // swapped: the approving device's words are made from the answer it
    // gave, the asking device's from the one it was passed.
    asked = await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    var listed = server.deviceRequestsOf(g.id).single;
    final real = listed.responderNonce!;
    final passed = Uint8List.fromList(List.filled(32, 9));
    server.spoilDeviceRequest(g.id, asked.id, responderNonce: passed);
    final misled = (await alice.service.deviceAsk(g.id))!;
    listed = server.deviceRequestsOf(g.id).single;
    expect(
      misled.words,
      deviceTrustWords(
          orchardId: g.id,
          uid: _alice,
          commitment: listed.commitment,
          approverNonce: passed,
          deviceKey: hers.publicKey,
          nonce: listed.nonce!),
    );
    shown = (await g.laptop.service.deviceRequests(g.id)).single;
    expect(shown.stage, DeviceRequestStage.compare);
    expect(
      shown.words,
      deviceTrustWords(
          orchardId: g.id,
          uid: _alice,
          commitment: listed.commitment,
          approverNonce: real,
          deviceKey: hers.publicKey,
          nonce: listed.nonce!),
    );
    expect(shown.words, isNot(misled.words));
    // An answer that changes later changes nothing on the asking device.
    server.spoilDeviceRequest(g.id, asked.id, responderNonce: real);
    expect((await alice.service.deviceAsk(g.id))!.words, misled.words);
    await g.laptop.service.declineDeviceRequest(g.id, asked.id);
    expect(await alice.service.deviceAsk(g.id), isNull);

    // 4. After the approving device answered for alice's device, the request
    // says it is someone else's (the owner's own): not one to go on with.
    asked = await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    await alice.service.deviceAsk(g.id);
    server.spoilDeviceRequest(g.id, asked.id, uid: _owner);
    shown = (await g.laptop.service.deviceRequests(g.id)).single;
    expect((shown.stage, shown.uid, shown.words), (DeviceRequestStage.cutOff, _owner, null));
    await expectLater(g.laptop.service.approveDevice(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));
    expect(server.recordOf(g.id).devicesOf(_alice), isEmpty);
    expect(server.recordOf(g.id).devicesOf(_owner), hasLength(2));
  });

  test('a request is taken back, declined, replaced by asking again, and gone when it lapsed', () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, alice, g.id, g.member);
    await g.laptop.service.setRules(g.id, _rule);
    await alice.service.refresh();
    expect(await alice.service.deviceAsk(g.id), isNull, reason: 'never asked');
    await alice.service.withdrawDeviceAsk(g.id);

    // Taken back.
    var asked = await alice.service.askDeviceApproval(g.id);
    expect((await g.laptop.service.deviceRequests(g.id)).single.id, asked.id);
    await alice.service.withdrawDeviceAsk(g.id);
    expect(server.deviceRequestsOf(g.id), isEmpty);
    expect(await alice.service.deviceAsk(g.id), isNull);
    expect(await g.laptop.service.deviceRequests(g.id), isEmpty);

    // Asked twice: one request, the later one.
    final first = await alice.service.askDeviceApproval(g.id);
    final second = await alice.service.askDeviceApproval(g.id);
    expect(second.id, isNot(first.id));
    expect([for (final r in await g.laptop.service.deviceRequests(g.id)) r.id], [second.id]);
    await expectLater(g.laptop.service.answerDeviceRequest(g.id, first.id), throwsA(isA<DeviceRequestGone>()));

    // Declined: gone on both sides. Declined again: nothing.
    await g.laptop.service.declineDeviceRequest(g.id, second.id);
    await g.laptop.service.declineDeviceRequest(g.id, second.id);
    expect(await alice.service.deviceAsk(g.id), isNull);

    // Lapsed while it waited, and while it was being compared.
    asked = await alice.service.askDeviceApproval(g.id);
    server.lapseDeviceRequests(g.id);
    expect(await g.laptop.service.deviceRequests(g.id), isEmpty);
    expect(await alice.service.deviceAsk(g.id), isNull);
    asked = await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    server.lapseDeviceRequests(g.id);
    expect(await alice.service.deviceAsk(g.id), isNull);
    expect(await g.laptop.service.deviceRequests(g.id), isEmpty);
    await expectLater(g.laptop.service.approveDevice(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));

    // An approved device has nothing to ask for.
    await expectLater(g.laptop.service.askDeviceApproval(g.id), throwsA(_server(409, 'device-approved')));

    // Declined while this device was not looking: taking it back then is
    // no error.
    asked = await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.declineDeviceRequest(g.id, asked.id);
    await alice.service.withdrawDeviceAsk(g.id);
    // Taken back twice: the server hears of it once.
    await alice.service.askDeviceApproval(g.id);
    var drops = server.deviceDrops;
    await alice.service.withdrawDeviceAsk(g.id);
    await alice.service.withdrawDeviceAsk(g.id);
    expect(server.deviceDrops, drops + 1);
    // Seen to be gone, it is forgotten: nothing is taken back afterwards.
    await alice.service.askDeviceApproval(g.id);
    server.lapseDeviceRequests(g.id);
    expect(await alice.service.deviceAsk(g.id), isNull);
    drops = server.deviceDrops;
    await alice.service.withdrawDeviceAsk(g.id);
    expect(server.deviceDrops, drops);
    // Removed from the Orchard while her device asks: it is told there is
    // no such Orchard for it, and forgets the request.
    await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.removeMember(g.id, _alice);
    await expectLater(alice.service.deviceAsk(g.id), throwsA(_server(404, 'not-found')));
    drops = server.deviceDrops;
    await alice.service.withdrawDeviceAsk(g.id);
    expect(server.deviceDrops, drops);
  });

  test('what a device tells its person about devices: each request once, and that it was removed', () async {
    var ahead = Duration.zero;
    DateTime clock() => DateTime.now().add(ahead);
    OrchardService.debugNow = clock;
    server.clock = clock;
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    final bob = device(_bob, 'bob-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, alice, g.id, g.member);
    await join(g.laptop, bob, g.id, g.member);
    await g.laptop.service.refresh();
    await g.phone.service.refresh();
    Future<List<(DeviceNoticeKind, String?, bool, int)>> told(_Device d) async => [
          for (final n in await d.service.takeDeviceNotices(g.id, requests: await d.service.deviceRequests(g.id)))
            (n.kind, n.uid, n.own, n.count),
        ];
    Future<Object?> kept(_Device d) async {
      final raw = await LocalStateStore(await d.db(g.id)).read('device.seen');
      return raw == null ? null : jsonDecode(raw);
    }

    expect(await told(g.laptop), isEmpty);
    expect(await kept(g.laptop), isNull, reason: 'nothing to keep yet');
    final first = await alice.service.askDeviceApproval(g.id);
    expect(await told(g.laptop), [(DeviceNoticeKind.asked, _alice, false, 1)]);
    expect(await told(g.laptop), isEmpty, reason: 'once');
    expect((await kept(g.laptop) as Map).keys, [first.id]);
    // Kept on the device, not in the service: started again, it still knows.
    expect(await told(device(_owner, 'laptop', restartOf: g.laptop)), isEmpty);
    // Without the list just read, nothing is said of requests, and what
    // was told stays told.
    expect(await g.phone.service.takeDeviceNotices(g.id), isEmpty);
    expect(await g.laptop.service.takeDeviceNotices(g.id), isEmpty);
    expect((await kept(g.laptop) as Map).keys, [first.id]);
    expect(await told(g.laptop), isEmpty);
    // One this device answered before its person was told is not news, and
    // is not told later either.
    await g.phone.service.answerDeviceRequest(g.id, first.id);
    expect(await told(g.phone), isEmpty);
    await g.phone.service.declineDeviceRequest(g.id, first.id);

    // Another device of this account's own asks: said as its own.
    final tablet = device(_owner, 'tablet');
    await tablet.service.refresh();
    final own = await tablet.service.askDeviceApproval(g.id);
    expect(await told(g.laptop), [(DeviceNoticeKind.asked, _owner, true, 1)]);
    // Two new ones at once: one notice, with how many.
    final again = await alice.service.askDeviceApproval(g.id);
    final his = await bob.service.askDeviceApproval(g.id);
    expect(await told(g.laptop), [(DeviceNoticeKind.asked, null, false, 2)]);
    expect((await kept(g.laptop) as Map).keys.toSet(), {first.id, own.id, again.id, his.id});

    // What lapsed is forgotten, each when its own ten minutes are over.
    ahead = const Duration(minutes: 11);
    expect(await told(g.laptop), isEmpty);
    expect(await kept(g.laptop), isEmpty);
    // What is kept is not what this device wrote: told again, once.
    final fresh = await alice.service.askDeviceApproval(g.id);
    expect(await told(g.laptop), [(DeviceNoticeKind.asked, _alice, false, 1)]);
    await LocalStateStore(await g.laptop.db(g.id)).write('device.seen', 'not what it wrote');
    expect(await told(g.laptop), [(DeviceNoticeKind.asked, _alice, false, 1)]);
    expect(await told(g.laptop), isEmpty);
    await LocalStateStore(await g.laptop.db(g.id)).write('device.seen', jsonEncode({fresh.id: 'soon', 'other': 1}));
    expect(await told(g.laptop), [(DeviceNoticeKind.asked, _alice, false, 1)], reason: 'only a time counts');
    expect((await kept(g.laptop) as Map).keys, [fresh.id], reason: 'and what is over goes');

    // Removed: told once, with the name the Orchard had on the device.
    await approve(alice, g.laptop, g.id);
    await g.laptop.service.setRules(g.id, _rule);
    await alice.coordinator.syncAll();
    expect(await alice.service.takeDeviceNotices(g.id), isEmpty);
    await g.laptop.service.removeDevice(g.id, uid: _alice, deviceKey: await alice.key);
    await alice.coordinator.syncAll();
    final notices = await alice.service.takeDeviceNotices(g.id);
    expect([for (final n in notices) (n.kind, n.orchardName)], [(DeviceNoticeKind.removed, 'Acme')]);
    expect(await alice.service.takeDeviceNotices(g.id), isEmpty);
    await alice.coordinator.syncAll();
    expect(await alice.service.takeDeviceNotices(g.id), isEmpty, reason: 'removed once, told once');
    // The name stays with it, to say which Orchard this was.
    final info = await (await alice.db(g.id)).customSelect('SELECT name FROM orchard_info WHERE id = 1').getSingle();
    expect(info.read<String?>('name'), 'Acme');
  });

  test('the app was restarted in the middle: an answer from before can only be declined, and a request '
      'from before is asked again', () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, alice, g.id, g.member);
    await g.laptop.service.setRules(g.id, _rule);
    await alice.service.refresh();

    final asked = await alice.service.askDeviceApproval(g.id);
    await g.laptop.service.answerDeviceRequest(g.id, asked.id);
    await alice.service.deviceAsk(g.id);
    // The approving device starts again: the same sign-in, the same key,
    // and nothing of what it answered with.
    final again = device(_owner, 'laptop', restartOf: g.laptop);
    var listed = (await again.service.deviceRequests(g.id)).single;
    expect((listed.id, listed.stage, listed.words), (asked.id, DeviceRequestStage.cutOff, null));
    await expectLater(again.service.approveDevice(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));
    await again.service.declineDeviceRequest(g.id, asked.id);
    expect(await alice.service.deviceAsk(g.id), isNull);

    // The asking device starts again while its request waits: it knows of
    // none, and asking again replaces the one that was left.
    final left = await alice.service.askDeviceApproval(g.id);
    final restarted = device(_alice, 'alice-laptop', restartOf: alice);
    expect(await restarted.service.deviceAsk(g.id), isNull);
    expect(server.deviceRequestsOf(g.id).single.id, left.id);
    final fresh = await restarted.service.askDeviceApproval(g.id);
    expect(server.deviceRequestsOf(g.id).single.id, fresh.id);
    await again.service.answerDeviceRequest(g.id, fresh.id);
    final words = (await restarted.service.deviceAsk(g.id))!.words;
    listed = (await again.service.deviceRequests(g.id)).single;
    expect(listed.stage, DeviceRequestStage.compare);
    expect(listed.words, words);
    await again.service.approveDevice(g.id, fresh.id);
    expect(server.recordOf(g.id).devicesOf(_alice), {await alice.key});
  });

  test('signing in again brings a new sign-in, which says which device it is before the change is tried',
      () async {
    final g = await guarded();
    // The laptop signs in again, as for a change that needs a recent
    // sign-in: the same app, the same key, another sign-in. Told of it, the
    // service says at once which device this is.
    var named = server.nameDeviceCalls;
    g.laptop.name = 'laptop, signed in again';
    await g.laptop.service.signedInAgain();
    expect(server.nameDeviceCalls, named + 1);
    expect(server.namedDevices[g.laptop.session], await g.laptop.key);
    await g.laptop.service.setRules(g.id, RecordRules.none);
    expect(server.recordOf(g.id).rules.trustedDevices, isFalse);
    expect(server.nameDeviceCalls, named + 1, reason: 'nothing more to say');
    await g.laptop.service.setRules(g.id, _rule);

    // Not told of it: the change is held back as from a device nobody
    // approved, the sign-in says which device it is, and the change is
    // tried again and goes through.
    named = server.nameDeviceCalls;
    g.laptop.name = 'laptop, signed in once more';
    await expectLater(g.laptop.server.record(g.id, after: 0), throwsA(_server(403, 'rules-unmet')));
    await g.laptop.service.setRules(g.id, RecordRules.none);
    expect(server.recordOf(g.id).rules.trustedDevices, isFalse);
    expect(server.nameDeviceCalls, named + 1);
    expect(server.namedDevices[g.laptop.session], await g.laptop.key);
    await g.laptop.service.setRules(g.id, _rule);

    // A device nobody approved gains nothing by saying which it is again:
    // refused once, and not tried a second time.
    final tablet = device(_owner, 'tablet');
    await tablet.service.refresh();
    named = server.nameDeviceCalls;
    var reads = server.recordReads;
    await expectLater(
      tablet.service.setRules(g.id, RecordRules.none),
      throwsA(isA<OrchardServerException>().having((e) => e.deviceNotApproved, 'only the device', isTrue)),
    );
    expect(server.nameDeviceCalls, named);
    expect(server.recordReads, reads + 1);
    expect(server.recordOf(g.id).rules.trustedDevices, isTrue);
    // A refusal for any other reason is passed on as it is, and nothing is
    // asked about the sign-in.
    server.requireRecentSignIn = true;
    final sessionAsks = server.sessionAsks;
    reads = server.recordReads;
    await expectLater(
      g.laptop.service.setRules(g.id, RecordRules.none),
      throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'a recent sign-in', isTrue)),
    );
    expect(server.sessionAsks, sessionAsks);
    expect(server.recordReads, reads + 1);
    server.requireRecentSignIn = false;
    // Reading the record for something else than a change is helped the
    // same way (team recovery, certificates): the new sign-in says which
    // device it is, and the reading goes through.
    g.laptop.name = 'laptop, a fourth sign-in';
    named = server.nameDeviceCalls;
    expect((await g.laptop.service.teamRecovery(g.id)).on, isFalse);
    expect(server.nameDeviceCalls, named + 1);

    // A new sign-in that asks for its Orchards first: the list holds it
    // back as a device nobody approved, it says which device it is, reads
    // the list again and is in, all in that one look.
    g.laptop.name = 'laptop, a fifth sign-in';
    expect(await g.laptop.service.refresh(), [g.id]);
    expect((await g.laptop.standing(g.id)).$1, 'active');
    // Saying which device it is does not get through just now: the look
    // goes on with the list it has (held back), and the next one gets in.
    g.phone.name = 'phone, signed in again';
    server.failDeviceCalls.add('name');
    expect(await g.phone.service.refresh(), isEmpty);
    expect((await g.phone.standing(g.id)).$1, 'rules');
    server.failDeviceCalls.clear();
    expect(await g.phone.service.refresh(), [g.id]);
    expect((await g.phone.standing(g.id)).$1, 'active');

    // An account in no Orchard says nothing when it signs in again.
    final alice = device(_alice, 'alice-laptop');
    await alice.service.refresh();
    final asks = server.sessionAsks;
    named = server.nameDeviceCalls;
    alice.name = 'alice-laptop, signed in again';
    await alice.service.signedInAgain();
    expect((server.sessionAsks, server.nameDeviceCalls), (asks, named));
  });

  test('a device held back keeps what it holds, whatever holds it back; only one that was removed drops it, '
      'also while something else holds it back', () async {
    final laptop = device(_owner, 'laptop');
    final phone = device(_owner, 'phone');
    final o = await orchard(laptop);
    await laptop.service.approveThisDevice(o.id);
    await phone.service.refresh();
    await approve(phone, laptop, o.id);
    final alice = device(_alice, 'alice-laptop');
    final bob = device(_bob, 'bob-laptop');
    await join(laptop, alice, o.id, o.member);
    await join(laptop, bob, o.id, o.member);
    await approve(bob, laptop, o.id);
    await laptop.addHost(o.id, 'web-1', crateId: o.crate);
    await laptop.coordinator.syncOne(o.id);
    await alice.coordinator.syncAll();
    await bob.coordinator.syncAll();
    expect(await alice.hosts(o.id), ['web-1']);
    expect(await bob.hosts(o.id), ['web-1']);

    // The rule goes on. Alice's device was never approved: held back, and
    // what it synced before stays where it is.
    await laptop.service.setRules(o.id, _rule);
    final hers = alice.storage.dbs[o.id];
    expect(await alice.coordinator.syncAll(), isEmpty);
    var (status, held) = await alice.standing(o.id);
    expect(status, 'rules');
    expect((held as Map)['unmet'], ['trusted_device']);
    expect(held.containsKey('device_removed'), isFalse);
    expect(await alice.hosts(o.id), ['web-1']);
    expect(await alice.recordEntries(o.id), greaterThan(0));
    expect(identical(alice.storage.dbs[o.id], hers), isTrue);

    // Bob's device is approved, and held back for something else (his
    // second step): it keeps what it holds as well.
    server.held[_bob] = ['second_factor'];
    final his = bob.storage.dbs[o.id];
    expect(await bob.coordinator.syncAll(), isEmpty);
    (status, held) = await bob.standing(o.id);
    expect(status, 'rules');
    expect((held as Map)['unmet'], ['second_factor']);
    expect(held.containsKey('device_removed'), isFalse);
    expect(await bob.hosts(o.id), ['web-1']);
    expect(identical(bob.storage.dbs[o.id], his), isTrue);
    // Removed while it is held back for that: it drops what it holds all
    // the same, and says so.
    await laptop.service.removeDevice(o.id, uid: _bob, deviceKey: await bob.key);
    expect(await bob.coordinator.syncAll(), isEmpty);
    (status, held) = await bob.standing(o.id);
    expect(status, 'rules');
    expect((held as Map)['unmet'], ['second_factor', 'trusted_device']);
    expect(held['device_removed'], isTrue);
    expect(await bob.hosts(o.id), isEmpty);
    expect(await bob.recordEntries(o.id), 0);
    expect(identical(bob.storage.dbs[o.id], his), isFalse, reason: 'the database itself was deleted');
    expect([for (final n in await bob.service.takeDeviceNotices(o.id)) n.kind], [DeviceNoticeKind.removed]);
  });

  test('a step that does not get through, or is refused: each device remembers of a request what really '
      'happened to it', () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await join(g.laptop, alice, g.id, g.member);
    await g.phone.service.refresh();
    final unreachable = throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 503));

    // ZestSSH Cloud cannot be reached while her device looks at its
    // request: the request is still there when it can be again.
    final asked = await alice.service.askDeviceApproval(g.id);
    server.failDeviceCalls.add('list');
    await expectLater(alice.service.deviceAsk(g.id), unreachable);
    server.failDeviceCalls.clear();
    expect((await alice.service.deviceAsk(g.id))!.id, asked.id);

    // Everyone who asks is known on the owner's laptop: listing the
    // requests does not read the record again.
    final reads = server.recordReads;
    expect((await g.laptop.service.deviceRequests(g.id)).single.stage, DeviceRequestStage.asks);
    expect(server.recordReads, reads);

    // The laptop's answer does not get through: it keeps none. The phone
    // answers. A server that lists the request to the laptop all the same
    // finds it one the laptop did not answer, before and after her device
    // showed its key.
    server.failDeviceCalls.add('answer');
    await expectLater(g.laptop.service.answerDeviceRequest(g.id, asked.id), unreachable);
    server.failDeviceCalls.clear();
    await g.phone.service.answerDeviceRequest(g.id, asked.id);
    server.listsDeviceRequestsToAll = true;
    expect((await g.laptop.service.deviceRequests(g.id)).single.stage, DeviceRequestStage.cutOff);
    final onHers = (await alice.service.deviceAsk(g.id))!;
    expect((await g.laptop.service.deviceRequests(g.id)).single.stage, DeviceRequestStage.cutOff);
    await expectLater(g.laptop.service.approveDevice(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));
    server.listsDeviceRequestsToAll = false;

    // Answering a second time is told that it was answered, and what the
    // phone answered with first is kept: its words are still hers.
    await expectLater(g.phone.service.answerDeviceRequest(g.id, asked.id), throwsA(_server(409, 'answered')));
    var shown = (await g.phone.service.deviceRequests(g.id)).single;
    expect(shown.stage, DeviceRequestStage.compare);
    expect(shown.words, onHers.words);

    // Declining does not get through: the phone keeps nothing of its
    // answer all the same, and the request, still listed, is one it can
    // only decline.
    server.failDeviceCalls.add('drop');
    await expectLater(g.phone.service.declineDeviceRequest(g.id, asked.id), unreachable);
    server.failDeviceCalls.clear();
    shown = (await g.phone.service.deviceRequests(g.id)).single;
    expect((shown.stage, shown.words), (DeviceRequestStage.cutOff, null));
    await expectLater(g.phone.service.approveDevice(g.id, asked.id), throwsA(isA<DeviceRequestGone>()));
    await g.phone.service.declineDeviceRequest(g.id, asked.id);
    expect(await g.phone.service.deviceRequests(g.id), isEmpty);
    expect(server.recordOf(g.id).devicesOf(_alice), isEmpty);
  });

  test('a certificate goes to an approved device only: the request names its device, which signs it', () async {
    final g = await guarded();
    final alice = device(_alice, 'alice-laptop');
    await g.laptop.service.setRules(g.id, RecordRules.none);
    await join(g.laptop, alice, g.id, g.member);
    await approve(alice, g.laptop, g.id);
    final vault = await g.laptop.service.createCrate(g.id, 'Owner keys', ownersOnly: true);
    await g.laptop.service.setAuthorityKey(g.id, g.crate,
        keyCrate: vault,
        ttlMinutes: 60,
        principals: {
          g.member: ['deploy'],
          FixedRoles.owner: ['root'],
        },
        keyLabel: 'Production authority');
    await g.laptop.service.setRules(g.id, _rule);
    await alice.service.refresh();

    // Her device asks: the request names the device, and carries its
    // signature over the request itself, under the device's own label.
    await alice.service.askForCertificate(g.id, g.crate);
    final asked = server.certRequests.values.single.request;
    expect(deviceKeyText(asked.deviceKey!), await alice.key);
    final message = asked.message(orchardId: g.id, crateId: g.crate);
    expect(await verifyDeviceSignature(asked.deviceKey!, certDeviceMessage(message), asked.deviceSignature!), isTrue);
    expect(await verifyDeviceSignature(asked.deviceKey!, message, asked.deviceSignature!), isFalse);
    expect(await g.laptop.service.signWaitingCertificates(g.id), 1);
    expect(await alice.service.collectCertificates(g.id), {g.crate});

    // What a server could pass off as her requests, each signed with her
    // account's keys (which reach any device that has her vault password):
    // from a device nobody approved, from no device at all, and naming her
    // approved device without its signature. The owner's device signs none.
    final hers = await DeviceIdentityStore(alice.keychain).forAccount(_alice);
    final stranger = await DeviceIdentity.generate();
    Future<CertRequest> planted({DeviceIdentity? named, DeviceIdentity? signer}) async {
      final unsigned = CertRequest(
        id: const Uuid().v4(),
        uid: _alice,
        keyVersion: 1,
        sshPublicKey: (await DeviceIdentity.generate()).publicKey,
        requestedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        signature: Uint8List(64),
      );
      final signed = unsigned.message(orchardId: g.id, crateId: g.crate);
      final request = CertRequest(
        id: unsigned.id,
        uid: _alice,
        keyVersion: 1,
        sshPublicKey: unsigned.sshPublicKey,
        requestedAt: unsigned.requestedAt,
        signature: await keys[_alice]!.sign(signed),
        deviceKey: named?.publicKey,
        deviceSignature: signer == null ? null : await signer.sign(certDeviceMessage(signed)),
      );
      server.certRequests[request.id] =
          (crateId: g.crate, uid: _alice, request: request, certificate: null, validBefore: null);
      return request;
    }

    // (It does not get as far as sending one for the server to refuse: the
    // rule is its own, held by its own copy of the record.)
    final sent = server.signAttempts.length;
    await planted(named: stranger, signer: stranger);
    expect(await g.laptop.service.signWaitingCertificates(g.id), 0, reason: 'a device nobody approved');
    await planted();
    expect(await g.laptop.service.signWaitingCertificates(g.id), 0, reason: 'no device named');
    await planted(named: hers, signer: stranger);
    expect(await g.laptop.service.signWaitingCertificates(g.id), 0, reason: 'not signed by the device it names');
    expect(server.signAttempts, hasLength(sent), reason: 'none of the three was signed, not even to be refused');
    // One made on her approved device is signed.
    final good = await planted(named: hers, signer: hers);
    expect(await g.laptop.service.signWaitingCertificates(g.id), 1);
    expect(server.certRequests[good.id]!.certificate, isNotNull);

    // Her device is removed before the owner's device gets to her next
    // request: no certificate for it.
    final late = await planted(named: hers, signer: hers);
    await g.laptop.service.removeDevice(g.id, uid: _alice, deviceKey: hers.key);
    expect(await g.laptop.service.signWaitingCertificates(g.id), 0, reason: 'removed since it asked');
    expect(server.certRequests[late.id]!.certificate, isNull);
    expect(server.signAttempts, isNot(contains(late.id)));

    // With the rule off a device is not asked for: every request of a
    // member is signed, as before there were approved devices.
    await g.laptop.service.setRules(g.id, RecordRules.none);
    expect(await g.laptop.service.signWaitingCertificates(g.id), 4);
  });

  test("an owner's device signs its own certificate under the rule only while it is an approved one", () async {
    final g = await guarded();
    // A third device of the owner's, from before the rule: it has the
    // Orchard, and with it the key the Crate's authority signs with.
    await g.laptop.service.setRules(g.id, RecordRules.none);
    final tablet = device(_owner, 'tablet');
    expect(await tablet.service.refresh(), contains(g.id));
    final vault = await g.laptop.service.createCrate(g.id, 'Owner keys', ownersOnly: true);
    await g.laptop.service.setAuthorityKey(g.id, g.crate,
        keyCrate: vault,
        ttlMinutes: 60,
        principals: {
          FixedRoles.owner: ['root'],
        },
        keyLabel: 'Production authority');
    await g.laptop.coordinator.syncOne(g.id);
    await tablet.coordinator.syncAll();
    expect(await tablet.service.authorityKey(g.id, g.crate), isNotNull);
    Future<LocalStateStore> state() async => LocalStateStore(await tablet.db(g.id));
    Future<String?> held() async => (await state()).read('certs.crate.${g.crate}');
    Future<Object?> connect({bool ask = true}) =>
        tablet.service.teamCertificateKey(g.id, g.crate, userName: 'root', ask: ask, wait: Duration.zero);
    // While any device is let in, an owner's signs for itself.
    await connect();
    expect(await held(), isNotNull);
    await (await state()).remove('certs.crate.${g.crate}');

    // The rule goes on. Nobody approved the tablet, so the server refuses
    // it the record: its own copy still has the rule off, and it still
    // holds the key. It signs nothing for itself, and is given nothing.
    await g.laptop.service.setRules(g.id, _rule);
    final asked = server.certRequests.length;
    await expectLater(connect(), throwsA(anything));
    expect(await held(), isNull);
    expect(server.certRequests, hasLength(asked), reason: 'the server took no request from it either');
    final (status, heldBy) = await tablet.standing(g.id);
    expect(status, 'rules', reason: 'what the server said is kept');
    expect(heldBy, containsPair('unmet', ['trusted_device']));
    // Nor where nobody is asked a thing (the monitor, an automation).
    await expectLater(connect(ask: false), throwsA(isA<TeamCertificateUnavailable>()));
    expect(await held(), isNull);

    // Approved, it signs for itself again, under the rule: the request it
    // checks names this device, which signed it.
    await approve(tablet, g.laptop, g.id);
    await tablet.service.refresh();
    await connect();
    expect(await held(), isNotNull);
    expect(server.certRequests, hasLength(asked), reason: 'by itself: nothing was asked of anybody');

    // With its own key gone from the system's keychain it is a device
    // nobody approved, whatever its copy of the Orchard says of where it
    // stands: the request it would sign names a key the record does not
    // list. The key back, it is the approved device again.
    final entry = DeviceIdentityStore.storageKey(_owner);
    final kept = tablet.keychain.values[entry]!;
    await (await state()).remove('certs.crate.${g.crate}');
    tablet.keychain.values.remove(entry);
    await expectLater(connect(ask: false), throwsA(isA<TeamCertificateUnavailable>()));
    expect(await held(), isNull);
    tablet.keychain.values[entry] = kept;
    await connect(ask: false);
    expect(await held(), isNotNull);

    // Taken out again, it signs nothing from the moment the server says so.
    await (await state()).remove('certs.crate.${g.crate}');
    await g.laptop.service.removeDevice(g.id, uid: _owner, deviceKey: await tablet.key);
    await expectLater(connect(), throwsA(anything));
    expect(await held(), isNull);
    await expectLater(connect(ask: false), throwsA(isA<TeamCertificateUnavailable>()));
    expect(await held(), isNull);
  });

  test('a certificate handed over goes to an approved device only: the request names its device, which signed it',
      () async {
    final g = await guarded();
    // Alice joins with a laptop the team approves, and a phone it does not.
    await g.laptop.service.setRules(g.id, RecordRules.none);
    final alice = device(_alice, 'alice-laptop');
    await join(g.laptop, alice, g.id, g.member);
    await approve(alice, g.laptop, g.id);
    final phone = device(_alice, 'alice-phone');
    expect(await phone.service.refresh(), contains(g.id));
    final vault = await g.laptop.service.createCrate(g.id, 'Owner keys', ownersOnly: true);
    await g.laptop.service.setAuthorityKey(g.id, g.crate,
        keyCrate: vault,
        ttlMinutes: 60,
        principals: {
          g.member: ['deploy'],
          FixedRoles.owner: ['root'],
        },
        keyLabel: 'Production authority');
    await alice.service.refresh();
    await phone.service.refresh();
    await g.laptop.service.setRules(g.id, _rule);
    await alice.service.refresh();

    // The server goes away. Her laptop's request names the laptop, and
    // carries the laptop's own signature under its own label.
    server.down = true;
    final ask = await alice.service.handRequest(g.id, g.crate);
    expect(deviceKeyText(ask.request.deviceKey!), await alice.key);
    final message = ask.request.message(orchardId: g.id, crateId: g.crate);
    expect(
        await verifyDeviceSignature(ask.request.deviceKey!, certDeviceMessage(message), ask.request.deviceSignature!),
        isTrue);
    // It reads the same after the journey as a text.
    final review = await g.laptop.service.reviewHandedRequest(ask.toText());
    expect(review.uid, _alice);
    expect(review.userNames, ['deploy']);
    final kept = await alice.service.takeHandedCertificate((await g.laptop.service.signHandedRequest(review)).toText());
    expect(kept.certificate.principals, ['deploy']);

    // Her phone has the Orchard from before the rule, and nobody approved
    // it: its request is made (its own copy still has the rule off), and
    // the owner's device, which has the rule, signs nothing for it.
    final fromPhone = (await phone.service.handRequest(g.id, g.crate)).toText();
    await expectLater(
      g.laptop.service.reviewHandedRequest(fromPhone),
      throwsA(isA<HandedRequestRefused>()
          .having((e) => e.problem, 'problem', HandedRequestProblem.refused)
          .having((e) => e.refusal, 'refusal', CertRequestRefusal.deviceNotApproved)),
    );
    // Once the phone has heard that it is held back, it asks for nothing.
    server.down = false;
    await phone.service.refresh();
    server.down = true;
    await expectLater(
      phone.service.handRequest(g.id, g.crate),
      throwsA(isA<TeamCertificateUnavailable>().having((e) => e.problem, 'problem', TeamCertificateProblem.heldBack)),
    );
    // The laptop's certificate is of no use on the phone.
    await expectLater(
      phone.service.takeHandedCertificate((await g.laptop.service.signHandedRequest(review)).toText()),
      throwsA(isA<HandedCertificateRefused>()
          .having((e) => e.problem, 'problem', HandedCertificateProblem.notForThisDevice)),
    );
    // A request that names the laptop and was signed by another device.
    final stranger = await DeviceIdentity.generate();
    final r = ask.request;
    final swapped = HandedRequest(
      orchardId: g.id,
      crateId: g.crate,
      request: CertRequest(
        id: r.id,
        uid: r.uid,
        keyVersion: r.keyVersion,
        sshPublicKey: r.sshPublicKey,
        requestedAt: r.requestedAt,
        signature: r.signature,
        deviceKey: r.deviceKey,
        deviceSignature: await stranger.sign(certDeviceMessage(message)),
      ),
    );
    await expectLater(
      g.laptop.service.reviewHandedRequest(swapped.toText()),
      throwsA(isA<HandedRequestRefused>().having((e) => e.refusal, 'refusal', CertRequestRefusal.notSignedByDevice)),
    );
  });

  test('a sign-in says which device it is once, only for an account in an Orchard; one that cannot is told so',
      () async {
    // In no Orchard: nothing is said, and no key is made.
    final alice = device(_alice, 'alice-laptop');
    expect(await alice.service.refresh(), isEmpty);
    expect((server.sessionAsks, server.nameDeviceCalls), (0, 0));
    expect(alice.keychain.values, isEmpty);

    final laptop = device(_owner, 'laptop');
    final o = await orchard(laptop);
    await laptop.service.refresh();
    expect((server.sessionAsks, server.nameDeviceCalls), (1, 1));
    expect(server.namedDevices[laptop.session], await laptop.key);
    expect(laptop.keychain.values.keys, [DeviceIdentityStore.storageKey(_owner)]);
    // Not again while the app runs.
    await laptop.service.refresh();
    await laptop.service.refresh();
    expect((server.sessionAsks, server.nameDeviceCalls), (1, 1));

    // A device held back as not approved asks which sign-in it is at each
    // look (it may have signed in anew), and says nothing twice.
    await laptop.service.approveThisDevice(o.id);
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    await approve(phone, laptop, o.id);
    await laptop.service.setRules(o.id, _rule);
    final tablet = device(_owner, 'tablet');
    final asks = server.sessionAsks;
    final names = server.nameDeviceCalls;
    expect(await tablet.service.refresh(), isEmpty);
    expect((server.sessionAsks, server.nameDeviceCalls), (asks + 1, names + 1));
    await tablet.service.refresh();
    expect((server.sessionAsks, server.nameDeviceCalls), (asks + 2, names + 1));

    // A sign-in with no session, and a device with nowhere to keep a key:
    // neither can be named, and so neither asks. Nothing else stops working.
    final bare = device(_owner, null);
    expect(await bare.service.refresh(), isEmpty);
    await expectLater(bare.service.askDeviceApproval(o.id), throwsA(isA<DeviceCannotBeNamed>()));
    await expectLater(bare.service.approveThisDevice(o.id), throwsA(isA<DeviceCannotBeNamed>()));
    expect((await bare.service.deviceStanding(o.id)).thisKey, isNull);
    expect(await bare.service.deviceRequests(o.id), isEmpty);
    // What the server refuses it for is passed on as it is.
    await expectLater(
      bare.service.setRules(o.id, RecordRules.none),
      throwsA(isA<OrchardServerException>().having((e) => e.deviceNotApproved, 'only the device', isTrue)),
    );
    await bare.service.signedInAgain();

    // The key kept on a device was lost and made again: its sign-in names
    // the old one, and cannot name another.
    await DeviceIdentityStore(tablet.keychain).forget(_owner);
    await expectLater(tablet.service.askDeviceApproval(o.id), throwsA(isA<DeviceCannotBeNamed>()));
    expect(server.deviceRequestsOf(o.id), isEmpty);

    // A device that said which it is, and whose sign-in then has no session
    // any more: it cannot be named, and is told so, not that the server
    // refused something.
    final other = device(_owner, 'other');
    await other.service.refresh();
    expect(server.namedDevices[other.session], await other.key);
    other.name = null;
    await expectLater(other.service.askDeviceApproval(o.id), throwsA(isA<DeviceCannotBeNamed>()));
    await expectLater(other.service.approveThisDevice(o.id), throwsA(isA<DeviceCannotBeNamed>()));
    expect(server.deviceRequestsOf(o.id), isEmpty);

    // An account in no Orchard has nothing to name a device for: asked to,
    // ZestSSH Cloud keeps nothing, and the device does not count as named.
    await expectLater(alice.service.askDeviceApproval(o.id), throwsA(isA<DeviceCannotBeNamed>()));
    expect(server.namedDevices.containsKey(alice.session), isFalse);
    expect(server.deviceRequestsOf(o.id), isEmpty);
  });
}
