import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show readOrchardSummary;
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';

/// An offline pass, from the devices' side (3.0):
/// a member whose device is past an offline limit, at a
/// place with no internet, hands an owner a request; the owner's device
/// checks it against the record and signs a pass for that device, that
/// member, that Crate (or all of the Orchard) and a time it ends; the
/// member's device keeps it only when an owner its own record names signed
/// it for its own key, and the Crate is open until the pass ends. Nothing
/// of it goes through the (fake) server, and neither device takes the
/// other's word for anything the record says.

const _owner = 'owner-1';
const _owner2 = 'owner-2';
const _alice = 'alice';
const _bob = 'bob';
const _carol = 'carol';
const _hour = 3600;
const _day = 86400;

/// One device's Orchard databases, each in a file of its own: an Orchard
/// that its offline limit closed is opened again with what it held, as on a
/// device.
class _FileStorage implements OrchardDatabaseStorage {
  _FileStorage(this._folder);

  final Directory _folder;

  /// Every database that was opened, for closing them at the end.
  final opened = <AppDatabase>[];
  final _ids = <String>{};

  File _file(String orchardId) => File('${_folder.path}/$orchardId.sqlite');

  @override
  Future<bool> exists(String orchardId) async => _ids.contains(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    _ids.add(orchardId);
    final db = AppDatabase.forTesting(NativeDatabase(_file(orchardId)), isOrchard: true);
    opened.add(db);
    return db;
  }

  @override
  Future<void> delete(String orchardId) async {
    _ids.remove(orchardId);
    final file = _file(orchardId);
    if (file.existsSync()) file.deleteSync();
  }

  @override
  Future<List<String>> list() async => _ids.toList();
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
  _Device(FakeCrateServer shared, this.uid, this.keys, this.name, this._now, Directory folder, {bool withKey = true})
      : server = shared.as(uid, signIn: () => name),
        storage = _FileStorage(folder) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(
        OrchardDatabaseKeys(const FlutterSecureStorage()),
        storage: storage,
        contact: DeviceContact(read: () => contact, now: _now),
      ),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: withKey ? DeviceIdentityStore(keychain) : null,
      onPass: () => passes++,
    );
  }

  final String uid;
  final AccountKeys keys;

  /// What the device is called in the test, which is also its sign-in.
  final String name;
  final int Function() _now;
  final CrateServer server;
  final _FileStorage storage;
  final keychain = _Keychain();
  late final OrchardService service;

  /// How this device stands with ZestSSH Cloud, as a test says.
  OrchardContact contact = const OrchardContact();

  /// How often this device was told that a pass was handed to it.
  var passes = 0;

  /// This device reaches ZestSSH Cloud now.
  void reached() => contact = OrchardContact(lastContact: _now(), latest: _now());

  /// This device's clock is seen to read what it reads now.
  void seesTime() => contact = contact.seeing(_now());

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<Map<String, int>> closed(String orchardId) async => closedCratesIn(await db(orchardId));

  Future<Map<String, int>> closing(String orchardId) async => (await crateLimitsIn(await db(orchardId))).closing;

  /// This device's own key, as people call it.
  Future<String> get code async => deviceCode((await DeviceIdentityStore(keychain).forAccount(uid)).key);

  Future<Uint8List> get key async => (await DeviceIdentityStore(keychain).forAccount(uid)).publicKey;

  Future<void> sync() =>
      OrchardSyncCoordinator(service: service, server: server, databases: service.databases).syncAll();

  Future<void> close() async {
    for (final db in storage.opened) {
      try {
        await db.close();
      } catch (_) {/* closed already, by its offline limit */}
    }
  }
}

Matcher _notSigned(HandedPassRequestProblem problem, [PassRequestRefusal? refusal]) =>
    isA<HandedPassRequestRefused>().having((e) => (e.problem, e.refusal), 'why', (problem, refusal));

Matcher _notKept(HandedPassProblem problem, [OfflinePassProblem? refusal]) =>
    isA<HandedPassRefused>().having((e) => (e.problem, e.refusal), 'why', (problem, refusal));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];
  late Directory folder;

  /// The clock of every device and of the server, in seconds: tests move it.
  late int clock;

  setUpAll(() async {
    for (final uid in [_owner, _owner2, _alice, _bob, _carol]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    folder = Directory.systemTemp.createTempSync('zest_pass_test_');
    clock = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    DateTime now() => DateTime.fromMillisecondsSinceEpoch(clock * 1000);
    OrchardService.debugNow = now;
    server = FakeCrateServer(accountUid: _owner)..clock = now;
    for (final uid in [_owner, _owner2, _alice, _bob, _carol]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    OrchardService.debugNow = DateTime.now;
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
    try {
      folder.deleteSync(recursive: true);
    } catch (_) {/* a file still held by the system: the folder is a temporary one */}
  });

  _Device device(String uid, {String name = 'laptop', bool withKey = true}) {
    final own = Directory('${folder.path}/${devices.length}')..createSync();
    final d = _Device(server, uid, keys[uid]!, name, () => clock, own, withKey: withKey);
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

  /// Acme: Production closes on a device after a day away, Lab never, and
  /// "Owner keys" is the owners' alone. alice is a Member (use of
  /// Production and of Lab), bob a Viewer (connect to Production). Every
  /// device has the Orchard as it is, and reached ZestSSH Cloud a moment
  /// ago.
  Future<
      ({
        String id,
        String production,
        String lab,
        String vault,
        String member,
        _Device owner,
        _Device alice,
        _Device bob,
      })> team() async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single;
    final production = member.crates.keys.single;
    final lab = await owner.service.createCrate(id, 'Lab');
    final vault = await owner.service.createCrate(id, 'Owner keys', ownersOnly: true);
    await owner.service.saveRole(id, id: member.id, name: 'Member', can: member.can, crates: {
      production: levelSwitches(CrateLevel.use),
      lab: levelSwitches(CrateLevel.use),
    });
    final viewers = await owner.service.saveRole(id,
        name: 'Viewers', can: const {}, crates: {production: levelSwitches(CrateLevel.connect)});
    await join(owner, alice, id, member.id);
    await join(owner, bob, id, viewers);
    await owner.service.setCrateOfflineLimit(id, production, 24);
    for (final d in [owner, alice, bob]) {
      await d.service.refresh();
      await d.sync();
      d.reached();
    }
    return (
      id: id,
      production: production,
      lab: lab,
      vault: vault,
      member: member.id,
      owner: owner,
      alice: alice,
      bob: bob,
    );
  }

  /// A request by [who] for [crateId], for the device [deviceKey], signed
  /// with [signer]'s keys (their own unless said otherwise).
  Future<String> requestBy(String orchardId, String crateId, String who, List<int> deviceKey,
      {AccountKeys? signer, int? at, int keyVersion = 1, String? handedOrchard, String? handedCrate}) async {
    final askedAt = at ?? clock;
    final message = passRequestMessage(
        orchardId: orchardId, crateId: crateId, uid: who, keyVersion: keyVersion, deviceKey: deviceKey, askedAt: askedAt);
    return HandedPassRequest(
      orchardId: handedOrchard ?? orchardId,
      crateId: handedCrate ?? crateId,
      request: PassRequest(
        uid: who,
        keyVersion: keyVersion,
        deviceKey: Uint8List.fromList(deviceKey),
        askedAt: askedAt,
        signature: await (signer ?? keys[who]!).sign(message),
      ),
    ).toText();
  }

  /// A pass for [who]'s device [deviceKey], signed with [signer]'s keys in
  /// the name of [by].
  Future<String> passBy(String orchardId, String crateId, String who, List<int> deviceKey,
      {String by = _owner, AccountKeys? signer, int? until, int? madeAt, int byKeyVersion = 1, String? handedCrate}) async {
    final made = madeAt ?? clock;
    final ends = until ?? made + _day;
    final message = offlinePassMessage(
      orchardId: orchardId,
      crateId: crateId,
      uid: who,
      deviceKey: deviceKey,
      until: ends,
      madeAt: made,
      by: by,
      byKeyVersion: byKeyVersion,
    );
    return HandedPass(
      orchardId: orchardId,
      crateId: handedCrate ?? crateId,
      pass: OfflinePass(
        uid: who,
        deviceKey: Uint8List.fromList(deviceKey),
        until: ends,
        madeAt: made,
        by: by,
        byKeyVersion: byKeyVersion,
        signature: await (signer ?? keys[by]!).sign(message),
      ),
    ).toText();
  }

  test('a member past a limit asks, an owner signs, and the Crate is open on that device until the pass ends',
      () async {
    final t = await team();
    final last = clock;
    // A day and an hour at a place with no internet: Production is closed
    // on alice's device.
    clock = last + 25 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), {t.production: 24});

    // Her device makes the request, and sends it nowhere.
    final asked = server.asked;
    final ask = (await t.alice.service.handPassRequest(t.id, crateId: t.production)).toText();
    expect(ask, startsWith(kHandedPassRequestPrefix));
    expect(server.asked, asked, reason: 'nothing of it goes to ZestSSH Cloud');
    final read = HandedPassRequest.fromText(ask)!;
    expect((read.orchardId, read.crateId, read.request.uid, read.request.keyVersion, read.request.askedAt),
        (t.id, t.production, _alice, 1, clock));
    expect(read.request.deviceKey, await t.alice.key);
    expect(await t.alice.service.ownDeviceCode(), await t.alice.code);

    // The owner, whose device is in contact, reads who asks for what, from
    // which device.
    t.owner.reached();
    final review = await t.owner.service.reviewPassRequest(ask);
    expect((review.orchardId, review.crateId, review.uid, review.email, review.role),
        (t.id, t.production, _alice, 'alice@example.com', t.member));
    expect(review.deviceCode, await t.alice.code);
    expect(review.fromServer, isTrue);

    // Signed for a day, with the owner's own keys.
    final give = (await t.owner.service.signPass(review, hours: 24)).toText();
    expect(give, startsWith(kHandedPassPrefix));
    final pass = HandedPass.fromText(give)!.pass;
    expect((pass.uid, pass.by, pass.byKeyVersion, pass.madeAt, pass.until), (_alice, _owner, 1, clock, clock + _day));
    expect(pass.deviceKey, await t.alice.key);

    // alice's device keeps it, asking nobody, and Production is open.
    final before = server.asked;
    final taken = await t.alice.service.takePass(give);
    expect((taken.orchardId, taken.crateId, taken.until, taken.orchardClosed), (t.id, t.production, clock + _day, false));
    expect(taken.crateName, 'Production', reason: 'named as this device has it, for whatever says what was taken');
    expect(server.asked, before, reason: 'a device that needs a pass is offline: it goes by its own record');
    expect(t.alice.passes, 1, reason: 'whatever shows the Orchard is told');
    expect(await t.alice.closed(t.id), isEmpty);
    expect(await t.alice.closing(t.id), isEmpty, reason: 'a day to go');
    final held = (await heldPassIn(await t.alice.db(t.id), t.production))!;
    expect((held.until, held.madeAt, held.by), (taken.until, clock, _owner));

    // In its last quarter it is about to close, and one second past its
    // end it is closed again.
    final until = taken.until;
    clock = until - 6 * _hour - 1;
    t.alice.seesTime();
    expect(await t.alice.closing(t.id), isEmpty);
    clock = until - 6 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closing(t.id), {t.production: until});
    expect(await t.alice.closed(t.id), isEmpty);
    clock = until;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), isEmpty, reason: 'its last second');
    clock = until + 1;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), {t.production: 24});
    expect(await t.alice.closing(t.id), isEmpty);
    // A clock turned back does not bring it back.
    clock = until - _hour;
    expect(await t.alice.closed(t.id), {t.production: 24});
  });

  test('a pass that ends before the limit does changes nothing, and one that reaches further is what ends it',
      () async {
    final t = await team();
    final last = clock;
    final key = await t.alice.key;
    // Twelve hours away. A pass until the sixteenth hour ends before the
    // limit: Production closes when the limit says.
    clock = last + 12 * _hour;
    await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: last + 16 * _hour));
    clock = last + 18 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closing(t.id), {t.production: last + 24 * _hour}, reason: 'in the last quarter of its day');
    // One that still holds and ends before the limit does (until the
    // twenty-second hour) changes nothing either: what ends it is the
    // limit.
    await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: last + 22 * _hour));
    clock = last + 19 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closing(t.id), {t.production: last + 24 * _hour});
    clock = last + 18 * _hour;
    // One until the fortieth hour reaches further: in the limit's last
    // quarter nothing is about to close, and past the limit it is open.
    await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: last + 40 * _hour));
    expect(await t.alice.closing(t.id), isEmpty);
    clock = last + 30 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), isEmpty);
    expect(await t.alice.closing(t.id), isEmpty,
        reason: 'made at the eighteenth hour: its last quarter is the last five and a half');
    clock = last + 35 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closing(t.id), {t.production: last + 40 * _hour});
    // Back in contact, the limit is far and the pass is of no account.
    t.alice.reached();
    expect(await t.alice.closing(t.id), isEmpty);
    expect(await t.alice.closed(t.id), isEmpty);
  });

  test("an owner's device signs only what the record allows, and says what is wrong with the rest", () async {
    final t = await team();
    final key = await t.alice.key;
    Future<void> read(String text, Matcher why, {_Device? by}) =>
        expectLater((by ?? t.owner).service.reviewPassRequest(text), throwsA(why));
    final good = await requestBy(t.id, t.production, _alice, key);
    expect((await t.owner.service.reviewPassRequest(good)).uid, _alice);

    // What is no request for a pass.
    await read('', _notSigned(HandedPassRequestProblem.notARequest));
    await read('Could you sign my pass?', _notSigned(HandedPassRequestProblem.notARequest));
    await read(good.substring(0, good.length - 8), _notSigned(HandedPassRequestProblem.notARequest));
    await read('${kHandedRequestPrefix}AAAA', _notSigned(HandedPassRequestProblem.notARequest),
        by: t.owner);
    await read(await passBy(t.id, t.production, _alice, key), _notSigned(HandedPassRequestProblem.isAPass));

    // What is not this device's to sign.
    await read(await requestBy('an-orchard-that-is-not-here', t.production, _alice, key),
        _notSigned(HandedPassRequestProblem.otherOrchard));
    await read(good, _notSigned(HandedPassRequestProblem.notAnOwner), by: t.bob);

    // What the record does not allow, each named.
    Future<void> not(Future<String> text, PassRequestRefusal why) async =>
        read(await text, _notSigned(HandedPassRequestProblem.refused, why));
    await not(requestBy(t.id, 'no-such-crate', _alice, key), PassRequestRefusal.noSuchCrate);
    await not(requestBy(t.id, t.production, 'mallory', key, signer: keys[_bob]), PassRequestRefusal.notAMember);
    await not(requestBy(t.id, t.production, _carol, key), PassRequestRefusal.notAMember);
    await not(requestBy(t.id, t.vault, _alice, key), PassRequestRefusal.noAccess);
    await not(requestBy(t.id, t.production, _alice, key, keyVersion: 2), PassRequestRefusal.notCurrentKeys);
    await not(requestBy(t.id, t.production, _alice, key, at: clock - _day - 1), PassRequestRefusal.notRecent);
    await not(requestBy(t.id, t.production, _alice, key, at: clock + 601), PassRequestRefusal.notRecent);
    await not(requestBy(t.id, t.production, _alice, key, signer: keys[_bob]), PassRequestRefusal.notSignedByMember);
    // A request for one Crate is none for another, nor for all of the
    // Orchard, nor for another device: each is in what is signed.
    await not(requestBy(t.id, t.production, _alice, key, handedCrate: t.lab), PassRequestRefusal.notSignedByMember);
    await not(requestBy(t.id, t.production, _alice, key, handedCrate: kAllOfOrchard),
        PassRequestRefusal.notSignedByMember);
    final other = HandedPassRequest.fromText(good)!;
    await not(
        Future.value(HandedPassRequest(
          orchardId: other.orchardId,
          crateId: other.crateId,
          request: PassRequest(
              uid: _alice,
              keyVersion: 1,
              deviceKey: await t.bob.key,
              askedAt: other.request.askedAt,
              signature: other.request.signature),
        ).toText()),
        PassRequestRefusal.notSignedByMember);
    // The edges that do read: a day old to the second, and dated ten
    // minutes ahead of this clock.
    expect((await t.owner.service.reviewPassRequest(await requestBy(t.id, t.production, _alice, key, at: clock - _day))).uid,
        _alice);
    expect((await t.owner.service.reviewPassRequest(await requestBy(t.id, t.production, _alice, key, at: clock + 600))).uid,
        _alice);
    // For all of the Orchard, whoever is in it may ask; and bob, who may
    // connect to Production, may ask for Production.
    expect((await t.owner.service.reviewPassRequest(await requestBy(t.id, kAllOfOrchard, _alice, key))).crateId,
        kAllOfOrchard);
    expect((await t.owner.service.reviewPassRequest(await requestBy(t.id, t.production, _bob, await t.bob.key))).uid, _bob);

    // Someone suspended is no member to sign for.
    await t.owner.service.suspendMember(t.id, _alice);
    await read(good, _notSigned(HandedPassRequestProblem.refused, PassRequestRefusal.notAMember));
    await read(await requestBy(t.id, kAllOfOrchard, _alice, key),
        _notSigned(HandedPassRequestProblem.refused, PassRequestRefusal.notAMember));
    await t.owner.service.resumeMember(t.id, _alice);
    final review = await t.owner.service.reviewPassRequest(good);

    // It is checked again as it is signed: what was read a moment ago may
    // no longer hold.
    await t.owner.service.suspendMember(t.id, _alice);
    await expectLater(t.owner.service.signPass(review, hours: 24),
        throwsA(_notSigned(HandedPassRequestProblem.refused, PassRequestRefusal.notAMember)));
    await t.owner.service.resumeMember(t.id, _alice);

    // A device that is not let in signs nothing, for anybody.
    final db = await t.owner.db(t.id);
    for (final status in ['rules', 'suspended', 'ended']) {
      await db.customStatement('UPDATE orchard_info SET status = ? WHERE id = 1', [status]);
      await read(good, _notSigned(HandedPassRequestProblem.notLetIn));
    }
    await db.customStatement("UPDATE orchard_info SET status = 'active' WHERE id = 1");
    for (final status in [401, 403, 404]) {
      server.fault = status;
      await read(good, _notSigned(HandedPassRequestProblem.notLetIn));
    }
    // A server that cannot be asked is not that: the device's own record
    // stands in, and its owner is told so.
    server.fault = 503;
    expect((await t.owner.service.reviewPassRequest(good)).fromServer, isFalse);
    server.fault = null;
    await t.owner.service.databases.closeOffline(t.id);
    await read(good, _notSigned(HandedPassRequestProblem.notLetIn));
  });

  test('a device that is past a limit itself lifts it for nobody, and nobody signs their own pass', () async {
    final t = await team();
    final last = clock;
    Future<void> closedHere(String text) => expectLater(
        t.owner.service.reviewPassRequest(text), throwsA(_notSigned(HandedPassRequestProblem.closedHere)));

    // The owner's own device has been away for a day and an hour too:
    // Production is closed on it.
    clock = last + 25 * _hour;
    t.owner.seesTime();
    final late = (await t.alice.service.handPassRequest(t.id, crateId: t.production)).toText();
    final forAll = (await t.alice.service.handPassRequest(t.id)).toText();
    final forLab = (await t.alice.service.handPassRequest(t.id, crateId: t.lab)).toText();
    await closedHere(late);
    await closedHere(forAll);
    // Lab has no limit: nothing of it is past one here.
    expect((await t.owner.service.reviewPassRequest(forLab)).crateId, t.lab);
    // A pass that holds Production open on the owner's device changes
    // nothing: the device has still not heard from the Orchard.
    await LocalStateStore(await t.owner.db(t.id)).write('$kOfflinePassState${t.production}',
        HeldPass(until: clock + _day, madeAt: clock, by: _owner2).toStored());
    expect(await t.owner.closed(t.id), isEmpty);
    await closedHere(late);
    await closedHere(forAll);
    // Back in contact, it signs.
    t.owner.reached();
    expect((await t.owner.service.reviewPassRequest(late)).uid, _alice);
    expect((await t.owner.service.reviewPassRequest(forAll)).crateId, kAllOfOrchard);

    // The Orchard's own limit, a day: an owner's device that is past it
    // (and held open by a pass for all of it) signs nothing at all.
    await t.owner.service.setRules(t.id, const RecordRules(offlineHours: 24));
    await t.owner.service.refresh();
    clock += 25 * _hour;
    t.owner.seesTime();
    await LocalStateStore(await t.owner.db(t.id))
        .write('$kOfflinePassState$kAllOfOrchard', HeldPass(until: clock + _day, madeAt: clock, by: _owner2).toStored());
    final again = (await t.alice.service.handPassRequest(t.id, crateId: t.lab)).toText();
    await closedHere(again);
    await closedHere((await t.alice.service.handPassRequest(t.id)).toText());
    t.owner.reached();
    expect((await t.owner.service.reviewPassRequest(again)).crateId, t.lab);

    // Nobody signs their own pass: an owner's device refuses its own
    // request, and signs the one of the owner's other device.
    final own = (await t.owner.service.handPassRequest(t.id, crateId: t.production)).toText();
    await expectLater(
        t.owner.service.reviewPassRequest(own), throwsA(_notSigned(HandedPassRequestProblem.ownDevice)));
    final phone = device(_owner, name: 'phone');
    await phone.service.refresh();
    phone.reached();
    final fromPhone = (await phone.service.handPassRequest(t.id, crateId: t.production)).toText();
    final review = await t.owner.service.reviewPassRequest(fromPhone);
    expect((review.uid, review.deviceCode), (_owner, await phone.code));
    expect(review.deviceCode, isNot(await t.owner.code));
    // And the phone, an owner's device too, signs the laptop's.
    expect((await phone.service.reviewPassRequest(own)).deviceCode, await t.owner.code);
  });

  test('where an Orchard lets in approved devices only, a pass is signed only for a device the record lists for '
      'the member', () async {
    final t = await team();
    final key = await t.alice.key;
    // (The record as the server has it, with the rule on: turning it on
    // takes two approved devices among the owners, which is another test's
    // business, test/features/orchards/devices.)
    final record = server.recordOf(t.id).copy()..rules = const RecordRules(trustedDevices: true);
    final ask = HandedPassRequest.fromText(await requestBy(t.id, t.production, _alice, key))!.request;
    Future<PassRequestRefusal?> refusal() =>
        passRequestRefusal(record, ask, orchardId: t.id, crateId: t.production, nowSeconds: clock);
    expect(await refusal(), PassRequestRefusal.deviceNotApproved);
    // Another device of hers is listed: still not this one.
    record.members[_alice]!.devices.add(deviceKeyText(await t.bob.key));
    expect(await refusal(), PassRequestRefusal.deviceNotApproved);
    record.members[_alice]!.devices.add(deviceKeyText(key));
    expect(await refusal(), isNull);
    // A device listed for someone else is not hers.
    record.members[_alice]!.devices.clear();
    record.members[_bob]!.devices.add(deviceKeyText(key));
    expect(await refusal(), PassRequestRefusal.deviceNotApproved);
    // With the rule off, no list is asked.
    record.rules = RecordRules.none;
    expect(await refusal(), isNull);
  });

  test('keys that were replaced sign nothing any more, a device is its whole key, and a key of another size is '
      'none', () async {
    final t = await team();
    final key = await t.alice.key;
    final record = server.recordOf(t.id).copy();
    // alice and the owner each replaced their keys: the record has both
    // versions, and the second is the one that counts.
    for (final uid in [_alice, _owner]) {
      final first = record.members[uid]!.keys[1]!;
      record.members[uid]!.keys[2] = RecordKeys(
        version: 2,
        signingKey: keys[_carol]!.signingPublicKey,
        encryptionKey: first.encryptionKey,
        createdAt: first.createdAt + 1,
        selfSignature: first.selfSignature,
      );
    }
    final ask = HandedPassRequest.fromText(await requestBy(t.id, t.production, _alice, key))!.request;
    expect(await passRequestRefusal(record, ask, orchardId: t.id, crateId: t.production, nowSeconds: clock),
        PassRequestRefusal.notCurrentKeys);
    final pass = HandedPass.fromText(await passBy(t.id, t.production, _alice, key))!.pass;
    Future<OfflinePassProblem?> problem(OfflinePass p, OrchardRecord r, {List<int>? device}) => offlinePassProblem(r, p,
        orchardId: t.id, crateId: t.production, uid: _alice, deviceKey: device ?? key, nowSeconds: clock);
    expect(await problem(pass, record), OfflinePassProblem.notCurrentKeys);
    expect(await problem(pass, server.recordOf(t.id)), isNull, reason: 'with the keys the record has, it checks out');

    // A device is its whole key: one that differs in a single byte,
    // wherever, is another device.
    for (final at in [0, 15, 31]) {
      final other = Uint8List.fromList(key)..[at] ^= 0x01;
      expect(await problem(pass, server.recordOf(t.id), device: other), OfflinePassProblem.notForThisDevice,
          reason: 'byte $at');
    }
    expect(await problem(pass, server.recordOf(t.id), device: key.sublist(0, 31)), OfflinePassProblem.notForThisDevice);

    // A request that names a device by a key of another size is not one an
    // owner's device signs, however well it is signed.
    final short = HandedPassRequest.fromText(await requestBy(t.id, t.production, _alice, key))!.request;
    final message = passRequestMessage(
        orchardId: t.id, crateId: t.production, uid: _alice, keyVersion: 1, deviceKey: key.sublist(0, 31), askedAt: clock);
    final sized = PassRequest(
        uid: _alice,
        keyVersion: 1,
        deviceKey: key.sublist(0, 31),
        askedAt: clock,
        signature: await keys[_alice]!.sign(message));
    expect(
        await passRequestRefusal(server.recordOf(t.id), sized,
            orchardId: t.id, crateId: t.production, nowSeconds: clock),
        PassRequestRefusal.notSignedByMember);
    expect(
        await passRequestRefusal(server.recordOf(t.id), short,
            orchardId: t.id, crateId: t.production, nowSeconds: clock),
        isNull);
  });

  test('a pass lasts what the owner chose, an hour at the least and seven days at the most', () async {
    final t = await team();
    final review = await t.owner.service.reviewPassRequest(
        (await t.alice.service.handPassRequest(t.id, crateId: t.production)).toText());
    Future<int> lasts(int hours) async {
      final pass = (await t.owner.service.signPass(review, hours: hours)).pass;
      expect(pass.madeAt, clock);
      return pass.until - pass.madeAt;
    }

    for (final hours in kOfflinePassChoices) {
      expect(await lasts(hours), hours * _hour);
    }
    expect(kOfflinePassChoices.last * _hour, kOfflinePassMax.inSeconds, reason: 'the longest choice is the most');
    expect(await lasts(169), 7 * _day);
    expect(await lasts(100000), 7 * _day);
    expect(await lasts(0), _hour);
    expect(await lasts(-5), _hour);
    // The longest there is, is one the member's device keeps.
    final give = (await t.owner.service.signPass(review, hours: 168)).toText();
    expect((await t.alice.service.takePass(give)).until, clock + 7 * _day);
  });

  test("a member's device keeps only a pass an owner its own record names signed, for itself", () async {
    final t = await team();
    final key = await t.alice.key;
    Future<void> take(String text, Matcher why, {_Device? by}) =>
        expectLater((by ?? t.alice).service.takePass(text), throwsA(why));
    Future<void> not(Future<String> text, OfflinePassProblem why, {_Device? by}) async =>
        take(await text, _notKept(HandedPassProblem.refused, why), by: by);
    final good = await passBy(t.id, t.production, _alice, key);

    // What is no pass.
    await take('', _notKept(HandedPassProblem.notAPass));
    await take(good.substring(0, good.length - 8), _notKept(HandedPassProblem.notAPass));
    await take('${kHandedCertificatePrefix}AAAA', _notKept(HandedPassProblem.notAPass));
    await take(await requestBy(t.id, t.production, _alice, key), _notKept(HandedPassProblem.isARequest));
    await take(await passBy('an-orchard-that-is-not-here', t.production, _alice, key),
        _notKept(HandedPassProblem.otherOrchard));

    // What does not check out, each named.
    await not(passBy(t.id, 'no-such-crate', _alice, key), OfflinePassProblem.noSuchCrate);
    await not(Future.value(good), OfflinePassProblem.notForThisAccount, by: t.bob);
    await not(passBy(t.id, t.production, _alice, await t.bob.key), OfflinePassProblem.notForThisDevice);
    final phone = device(_alice, name: 'phone');
    await phone.service.refresh();
    await not(Future.value(good), OfflinePassProblem.notForThisDevice, by: phone);
    await not(passBy(t.id, t.production, _alice, key, by: _bob), OfflinePassProblem.notAnOwner);
    await not(passBy(t.id, t.production, _alice, key, by: _alice), OfflinePassProblem.notAnOwner);
    await not(passBy(t.id, t.production, _alice, key, by: 'mallory', signer: keys[_bob]), OfflinePassProblem.notAnOwner);
    await not(passBy(t.id, t.production, _alice, key, byKeyVersion: 2), OfflinePassProblem.notCurrentKeys);
    await not(passBy(t.id, t.production, _alice, key, signer: keys[_bob]), OfflinePassProblem.notSignedByOwner);
    // A pass for one Crate is none for another, nor for all of the Orchard.
    await not(passBy(t.id, t.production, _alice, key, handedCrate: t.lab), OfflinePassProblem.notSignedByOwner);
    await not(passBy(t.id, t.production, _alice, key, handedCrate: kAllOfOrchard), OfflinePassProblem.notSignedByOwner);
    // Its end written over after it was signed.
    final signed = HandedPass.fromText(good)!;
    await not(
        Future.value(HandedPass(
          orchardId: t.id,
          crateId: t.production,
          pass: OfflinePass(
            uid: _alice,
            deviceKey: signed.pass.deviceKey,
            until: signed.pass.until + _day,
            madeAt: signed.pass.madeAt,
            by: _owner,
            byKeyVersion: 1,
            signature: signed.pass.signature,
          ),
        ).toText()),
        OfflinePassProblem.notSignedByOwner);
    // Run out, to the second.
    await not(passBy(t.id, t.production, _alice, key, madeAt: clock - _day, until: clock), OfflinePassProblem.expired);
    await not(passBy(t.id, t.production, _alice, key, madeAt: clock - 2 * _day, until: clock - _day),
        OfflinePassProblem.expired);
    // Longer than a pass may last: by its own word, and by this device's
    // clock (an owner's device whose clock runs a day ahead).
    await not(passBy(t.id, t.production, _alice, key, until: clock + 7 * _day + 1), OfflinePassProblem.tooLong);
    await not(passBy(t.id, t.production, _alice, key, madeAt: clock + _day, until: clock + 8 * _day),
        OfflinePassProblem.tooLong);
    // The edges that are kept: seven days to the second, and made by a
    // clock ten minutes ahead.
    expect((await t.alice.service.takePass(await passBy(t.id, t.lab, _alice, key, until: clock + 7 * _day))).until,
        clock + 7 * _day);
    expect(
        (await t.alice.service.takePass(
                await passBy(t.id, t.vault, _alice, key, madeAt: clock + 600, until: clock + 600 + 7 * _day)))
            .until,
        clock + 600 + 7 * _day);
    expect(await heldPassIn(await t.alice.db(t.id), t.production), isNull, reason: 'nothing that was refused is kept');

    // Signed by an owner, kept; by the second owner too.
    final owner2 = device(_owner2);
    await join(t.owner, owner2, t.id, FixedRoles.owner);
    await t.alice.service.refresh();
    expect((await t.alice.service.takePass(good)).until, clock + _day);
    expect((await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, by: _owner2, until: clock + 2 * _day)))
            .until,
        clock + 2 * _day);
    // By an owner the device's own record does not know of yet: not kept.
    // (bob was made an owner a moment ago, and alice's device is offline.)
    await t.owner.service.setMemberRole(t.id, _bob, FixedRoles.owner);
    await not(passBy(t.id, t.production, _alice, key, by: _bob, until: clock + 3 * _day), OfflinePassProblem.notAnOwner);

    // A device with nowhere to keep a key of its own asks for none, and
    // keeps none.
    final bare = device(_carol, withKey: false);
    await join(t.owner, bare, t.id, t.member);
    await expectLater(bare.service.handPassRequest(t.id, crateId: t.production),
        throwsA(isA<OfflinePassUnavailable>().having((e) => e.problem, 'problem', PassAskProblem.noDeviceKey)));
    expect(await bare.service.ownDeviceCode(), isNull);
    await not(passBy(t.id, t.production, _carol, key), OfflinePassProblem.notForThisDevice, by: bare);
    await expectLater(t.alice.service.handPassRequest('an-orchard-that-is-not-here'),
        throwsA(isA<OfflinePassUnavailable>().having((e) => e.problem, 'problem', PassAskProblem.otherOrchard)));
  });

  test('a longer pass takes the place of a shorter one, never the other way, and what has run out is cleared away',
      () async {
    final t = await team();
    final key = await t.alice.key;
    final db = await t.alice.db(t.id);
    Future<int?> kept(String crate) async => (await heldPassIn(db, crate))?.until;
    final start = clock;
    expect((await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: start + 2 * _day))).until,
        start + 2 * _day);
    // A shorter one: what is held is what counts, and is what is said.
    expect((await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: start + _day))).until,
        start + 2 * _day);
    expect(await kept(t.production), start + 2 * _day);
    // The same again: as it was.
    expect((await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: start + 2 * _day))).until,
        start + 2 * _day);
    // A longer one.
    expect((await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: start + 3 * _day))).until,
        start + 3 * _day);
    expect(await kept(t.production), start + 3 * _day);
    expect(t.alice.passes, 4);
    // One for Lab, which runs out; taking another in clears it away, and
    // leaves what still holds.
    await t.alice.service.takePass(await passBy(t.id, t.lab, _alice, key, until: start + _hour));
    await LocalStateStore(db).write('${kOfflinePassState}junk', 'not a pass');
    clock = start + _hour;
    await t.alice.service.takePass(await passBy(t.id, kAllOfOrchard, _alice, key, until: start + _day));
    expect(await LocalStateStore(db).keysWithPrefix(kOfflinePassState),
        unorderedEquals(['$kOfflinePassState${t.production}', '$kOfflinePassState$kAllOfOrchard']));
    expect(await kept(t.lab), isNull);
    expect(await kept(kAllOfOrchard), start + _day);
    // A refused pass tells whatever shows the Orchard to look as well: an
    // Orchard opened for the check has closed again.
    final told = t.alice.passes;
    await expectLater(t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, by: _bob)),
        throwsA(isA<HandedPassRefused>()));
    expect(t.alice.passes, told + 1);
    // Nothing is told for a text that is no pass, or for another Orchard.
    await expectLater(t.alice.service.takePass('hello'), throwsA(isA<HandedPassRefused>()));
    expect(t.alice.passes, told + 1);
  });

  test('a pass for all of an Orchard lifts its own limit and every Crate\'s, and opens an Orchard that was closed',
      () async {
    final t = await team();
    final key = await t.alice.key;
    final last = clock;
    await t.owner.service.setRules(t.id, const RecordRules(offlineHours: 48));
    await t.owner.service.setCrateOfflineLimit(t.id, t.lab, 8);
    await t.alice.service.refresh();
    t.alice.reached();
    final db = await t.alice.db(t.id);
    Future<int?> all() async => orchardClosingAt(db, 48);

    // Three days away: both Crates are past their own limits, and the
    // Orchard past its own. (What closes the Orchard is the scheduler; here
    // it is closed as the scheduler closes it.)
    clock = last + 72 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), {t.production: 24, t.lab: 8});
    expect(await orchardPassHoldsIn(db), isFalse);
    expect(await all(), isNull, reason: 'past its limit, it is not about to close: it closes');
    expect(await limitsReachedIn(db, orchardHours: 48), {kAllOfOrchard, t.production, t.lab});
    await t.alice.service.databases.closeOffline(t.id);

    // The request is made all the same: nothing of the Orchard's database
    // is needed for it.
    final ask = (await t.alice.service.handPassRequest(t.id)).toText();
    expect(HandedPassRequest.fromText(ask)!.crateId, kAllOfOrchard);
    t.owner.reached();
    final review = await t.owner.service.reviewPassRequest(ask);
    expect((review.crateId, review.uid), (kAllOfOrchard, _alice));
    final give = (await t.owner.service.signPass(review, hours: 72)).toText();

    // A pass that does not check out leaves the Orchard closed.
    await expectLater(
        t.alice.service.takePass(await passBy(t.id, kAllOfOrchard, _alice, key, signer: keys[_bob])),
        throwsA(_notKept(HandedPassProblem.refused, OfflinePassProblem.notSignedByOwner)));
    expect(t.alice.service.databases.closedOffline, {t.id});
    // A pass for one Crate is kept for later, and the Orchard stays closed:
    // its own limit is not lifted by it.
    final forLab = await t.alice.service.takePass(await passBy(t.id, t.lab, _alice, key, until: clock + _day));
    expect((forLab.crateId, forLab.crateName, forLab.orchardClosed), (t.lab, 'Lab', true),
        reason: 'named while it was checked: a closed Orchard lists no Crates');
    expect(t.alice.service.databases.closedOffline, {t.id});

    // The pass for all of it: the Orchard opens, and every limit is lifted.
    final taken = await t.alice.service.takePass(give);
    expect((taken.crateId, taken.crateName, taken.until, taken.orchardClosed),
        (kAllOfOrchard, null, clock + 72 * _hour, false));
    expect(t.alice.service.databases.closedOffline, isEmpty);
    final open = await t.alice.db(t.id);
    expect(await orchardPassHoldsIn(open), isTrue);
    expect(await t.alice.closed(t.id), isEmpty);
    expect((await heldPassIn(open, t.lab))!.until, forLab.until, reason: 'what was kept while it was closed is here');
    // What the limits themselves say is as it was: the pass lifts them, it
    // does not move them.
    expect(await limitsReachedIn(open, orchardHours: 48), {kAllOfOrchard, t.production, t.lab});

    // In its last quarter (eighteen hours of seventy-two) everything it
    // holds open is about to close with it.
    final until = taken.until;
    clock = until - 18 * _hour - 1;
    t.alice.seesTime();
    expect(await orchardClosingAt(open, 48), isNull);
    expect(await t.alice.closing(t.id), isEmpty);
    clock = until - 18 * _hour;
    t.alice.seesTime();
    expect(await orchardClosingAt(open, 48), until);
    expect(await t.alice.closing(t.id), {t.production: until, t.lab: until});
    // One second past its end.
    clock = until + 1;
    t.alice.seesTime();
    expect(await orchardPassHoldsIn(open), isFalse);
    expect(await t.alice.closed(t.id), {t.production: 24, t.lab: 8});
    expect(await orchardClosingAt(open, 48), isNull);
    // A clock turned back does not bring it back.
    clock = until - _hour;
    expect(await orchardPassHoldsIn(open), isFalse);
    // A database nobody told how the device stands holds nothing open.
    attachDeviceContact(open, null);
    expect(await orchardPassHoldsIn(open), isFalse);
    expect(await limitsReachedIn(open, orchardHours: 48), {kAllOfOrchard, t.production, t.lab});
    expect(await limitsReachedIn(open, orchardHours: 0), {t.production, t.lab});
  });

  test('a device knows what its passes hold open, and until when, for its screens', () async {
    final t = await team();
    final key = await t.alice.key;
    final db = await t.alice.db(t.id);
    Future<(int?, int?, int?)> shown() async {
      final o = await readOrchardSummary(db, t.id);
      int? of(String id) => o.crates.firstWhere((c) => c.id == id).passUntil;
      return (o.passUntil, of(t.production), of(t.lab));
    }

    final start = clock;
    expect(await passesHoldingIn(db), isEmpty);
    expect(await shown(), (null, null, null));
    // One for Production: Production alone.
    await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: start + 8 * _hour));
    expect(await passesHoldingIn(db), {t.production: start + 8 * _hour});
    expect(await shown(), (null, start + 8 * _hour, null));
    // One for all of the Orchard, which reaches further: the Orchard, and
    // every Crate by it.
    await t.alice.service.takePass(await passBy(t.id, kAllOfOrchard, _alice, key, until: start + 16 * _hour));
    expect(await passesHoldingIn(db), {t.production: start + 8 * _hour, kAllOfOrchard: start + 16 * _hour});
    expect(await shown(), (start + 16 * _hour, start + 16 * _hour, start + 16 * _hour));
    // Production's own now reaches further than that.
    await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: start + 24 * _hour));
    expect(await shown(), (start + 16 * _hour, start + 24 * _hour, start + 16 * _hour));
    // At the last second of the one for all of it, and one second on.
    clock = start + 16 * _hour;
    t.alice.seesTime();
    expect(await shown(), (start + 16 * _hour, start + 24 * _hour, start + 16 * _hour));
    clock = start + 16 * _hour + 1;
    t.alice.seesTime();
    expect(await passesHoldingIn(db), {t.production: start + 24 * _hour});
    expect(await shown(), (null, start + 24 * _hour, null));
    // A clock turned back brings nothing back onto the screens.
    clock = start + 10 * _hour;
    expect(await passesHoldingIn(db), {t.production: start + 24 * _hour});
    // What was kept and is no pass is none.
    await LocalStateStore(db).write('${kOfflinePassState}junk', 'not a pass');
    expect(await passesHoldingIn(db), {t.production: start + 24 * _hour});
    // A database nobody told how the device stands shows none.
    attachDeviceContact(db, null);
    expect(await passesHoldingIn(db), isEmpty);
  });

  test("the longer of a Crate's own pass and one for all of the Orchard is what holds the Crate open", () async {
    final t = await team();
    final key = await t.alice.key;
    final last = clock;
    clock = last + 25 * _hour;
    t.alice.seesTime();
    await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: clock + 8 * _hour));
    await t.alice.service.takePass(await passBy(t.id, kAllOfOrchard, _alice, key, until: clock + 16 * _hour));
    final made = clock;
    // Past the Crate's own pass, the one for all of it still holds.
    clock = made + 10 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), isEmpty);
    clock = made + 12 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closing(t.id), {t.production: made + 16 * _hour}, reason: 'the last quarter of sixteen hours');
    clock = made + 16 * _hour + 1;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), {t.production: 24});
    // And the other way round: the Crate's own reaches further than the
    // one for all of the Orchard, and holds the Crate open past it.
    final second = clock;
    await t.alice.service.takePass(await passBy(t.id, t.production, _alice, key, until: second + 16 * _hour));
    await t.alice.service.takePass(await passBy(t.id, kAllOfOrchard, _alice, key, until: second + 8 * _hour));
    expect(await t.alice.closed(t.id), isEmpty);
    clock = second + 10 * _hour;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), isEmpty, reason: 'the one for all of it has ended; its own has not');
    clock = second + 16 * _hour + 1;
    t.alice.seesTime();
    expect(await t.alice.closed(t.id), {t.production: 24});
    // A pass for Lab is none for Production.
    final bob = await t.bob.key;
    clock = last + 60 * _hour;
    t.bob.seesTime();
    final forLab = await t.bob.service.takePass(await passBy(t.id, t.lab, _bob, bob, until: clock + _day));
    expect(await t.bob.closed(t.id), {t.production: 24});
    expect(forLab.crateName, isNull, reason: "a Crate bob's device has no name for");
  });
}
