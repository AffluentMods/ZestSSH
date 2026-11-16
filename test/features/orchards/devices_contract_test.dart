import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../helpers/contract_run.dart';

import 'fake_stream_server.dart' show eventually;

/// Trusted devices (3.0) against the REAL server routes on a real
/// Postgres: each device signs in for a session of its own and says which
/// device it is; an owner's first device approves itself, the second asks
/// and is approved once both screens showed the same words; the rule goes
/// on; a member's device is held back, asks, is approved by an owner and
/// syncs; a device removed drops what it holds; a certificate goes to an
/// approved device only; and a device that signed in again says which it is
/// before the change it signed in for. Start the server:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. A Firebase ID token there is
/// `fb:<uid>:<authTime>:<iat>`; a device signs in with one for a session
/// token, as a computer does through the browser.

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
  _Device(this.me, this.bearer);

  final CrateAuthor me;

  /// The session token this device signed in for; signing in again brings
  /// another.
  String bearer;
  final storage = _MemoryStorage();
  final keychain = _Keychain();
  late final OrchardsApi server;
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  /// This device's key, as the record writes it.
  Future<String> get key async => (await DeviceIdentityStore(keychain).forAccount(me.uid)).key;

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

  /// Its status in the Orchard's own database, and what holds it back.
  Future<(String?, Map<String, dynamic>?)> standing(String orchardId) async {
    final row =
        await (await db(orchardId)).customSelect('SELECT status, held FROM orchard_info WHERE id = 1').getSingleOrNull();
    final held = row?.read<String?>('held');
    return (row?.read<String>('status'), held == null ? null : jsonDecode(held) as Map<String, dynamic>);
  }
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];
  final lines = <OrchardStream>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String firebaseToken(String uid) => 'fb:$uid:${now()}:${now()}';

  /// A device signs in the way a computer does through the browser: a
  /// session of its own, named by the token it gets.
  Future<String> signIn(String uid) async {
    final r = await client.post(Uri.parse('$base/auth/session'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'id_token': firebaseToken(uid)}));
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map<String, dynamic>)['session_token'] as String;
  }

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
    for (final line in lines) {
      await line.dispose();
    }
    lines.clear();
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  String skip() => 'app contract server not running at $base';

  var accounts = 0;

  Future<CrateAuthor> account(String name) async {
    final uid = 'devices-$name-$contractRun-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => firebaseToken(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  /// A device of [me]'s, signed in just now.
  Future<_Device> device(CrateAuthor me) async {
    final d = _Device(me, await signIn(me.uid));
    d.server = OrchardsApi(client: client, baseUrl: base, bearer: () async => d.bearer);
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: d.storage);
    d.service = OrchardService(
      server: d.server,
      databases: databases,
      author: () async => me,
      deviceKeys: DeviceIdentityStore(d.keychain),
    );
    d.coordinator = OrchardSyncCoordinator(service: d.service, server: d.server, databases: databases);
    devices.add(d);
    return d;
  }

  /// [d]'s live line, what it hears in [heard].
  Future<void> line(_Device d, List<OrchardStreamEvent> heard) async {
    final l = OrchardStream(
      url: OrchardStream.urlFor(base),
      connect: (url) => WebSocket.connect(url.toString()),
      token: ({bool fresh = false}) async => d.bearer,
      session: () => null,
      retryDelay: (_, _) => const Duration(seconds: 1),
    );
    l.events.listen(heard.add);
    lines.add(l);
    l.start();
    await eventually(() => heard.whereType<StreamConnected>().isNotEmpty);
  }

  Future<void> join(_Device owner, _Device person, String orchardId, String role) async {
    await owner.service.invite(orchardId, email: '${person.me.uid}@example.com', role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
  }

  /// [asking] asks, [approver] answers, both show the same words, and
  /// [approver] approves. Returns the words.
  Future<List<String>> approve(_Device asking, _Device approver, String orchardId) async {
    final asked = await asking.service.askDeviceApproval(orchardId);
    final waiting = (await approver.service.deviceRequests(orchardId)).singleWhere((r) => r.id == asked.id);
    expect(waiting.stage, DeviceRequestStage.asks);
    await approver.service.answerDeviceRequest(orchardId, asked.id);
    final answered = (await asking.service.deviceAsk(orchardId))!;
    final shown = (await approver.service.deviceRequests(orchardId)).singleWhere((r) => r.id == asked.id);
    expect(shown.stage, DeviceRequestStage.compare);
    expect(shown.words, answered.words);
    expect(shown.deviceKey, await asking.key);
    await approver.service.approveDevice(orchardId, asked.id);
    return answered.words!;
  }

  const rule = RecordRules(trustedDevices: true);

  Matcher answered(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));
  final onlyTheDevice =
      throwsA(isA<OrchardServerException>().having((e) => e.deviceNotApproved, 'only the device', isTrue));

  test('the device someone joins on is offered with the invitation, approved as they are let in, and in at once '
      '(found in a security review)', () async {
    if (!serverUp) return markTestSkipped(skip());
    final owner = await account('owner');
    final laptop = await device(owner);
    final id = await laptop.service.createOrchard('Joining', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = (await laptop.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final member = (await laptop.service.roles(id)).single.id;
    await laptop.service.approveThisDevice(id);
    final phone = await device(owner);
    expect(await phone.service.refresh(), [id]);
    await approve(phone, laptop, id);
    await laptop.service.setRules(id, rule);
    await laptop.addHost(id, 'web-1', crateId: production);
    expect((await laptop.coordinator.syncAll())[id]!.sent, 1);

    // She accepts on her laptop, which offers itself with her account's
    // signature; the server keeps it and lists it to the owner.
    final alice = await device(await account('alice'));
    await laptop.service.invite(id, email: '${alice.me.uid}@example.com', role: member);
    final mine = (await alice.service.myInvites()).single;
    await alice.service.acceptInvite(mine.id, orchardId: mine.orchardId);
    final invite = (await laptop.service.invites(id)).single;
    expect(invite.acceptedDevice?.keyText, await alice.key);
    final offer = await laptop.service.joinDeviceOffer(id, invite);
    expect(offer, await alice.key);

    // Let in with it: one confirmation, both entries, and her device is in
    // with nothing to ask for.
    await laptop.service.confirmInvite(id, invite, approveDevice: offer);
    expect([for (final d in await laptop.service.memberDevices(id, alice.me.uid)) d.key], [await alice.key]);
    expect((await alice.coordinator.syncAll()).keys, [id]);
    expect((await alice.standing(id)).$1, 'active');
    expect(await alice.hosts(id), ['web-1']);
    expect((await alice.service.deviceStanding(id)).approved, isTrue);
  });

  test('approved with three words, the rule on, a device held back and let in, and one removed', () async {
    if (!serverUp) return markTestSkipped(skip());
    final owner = await account('owner');
    final laptop = await device(owner);
    final id = await laptop.service.createOrchard('Devices', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = (await laptop.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final member = (await laptop.service.roles(id)).single.id;

    // The owner's first device approves itself; one is not enough for the
    // rule, by this device's copy of the record and by the server's.
    await laptop.service.approveThisDevice(id);
    expect((await laptop.service.deviceStanding(id)).approved, isTrue);
    await expectLater(
      laptop.service.setRules(id, rule),
      throwsA(isA<OrchardRecordRefused>()
          .having((e) => e.reason, 'reason', 'two approved devices among the owners first')),
    );

    // The second device: in (the rule is off), asks, and is approved once
    // both showed the same three words. Each side hears of every step.
    final phone = await device(owner);
    expect(await phone.service.refresh(), [id]);
    final laptopHeard = <OrchardStreamEvent>[];
    await line(laptop, laptopHeard);
    final asked = await phone.service.askDeviceApproval(id);
    expect(asked.words, isNull);
    expect(asked.expiresAt, closeTo(now() + 600, 10));
    await eventually(() => laptopHeard.whereType<DeviceRequestsChanged>().isNotEmpty);
    expect(await phone.service.deviceRequests(id), isEmpty, reason: 'only an approved device answers');
    await laptop.service.answerDeviceRequest(id, asked.id);
    final words = (await phone.service.deviceAsk(id))!;
    expect(words.words, hasLength(kDeviceTrustWordCount));
    expect(words.sameAccount, isTrue);
    final shown = (await laptop.service.deviceRequests(id)).single;
    expect(shown.stage, DeviceRequestStage.compare);
    expect(shown.words, words.words);
    await laptop.service.approveDevice(id, asked.id);
    expect(await phone.service.deviceAsk(id), isNull);
    expect((await laptop.service.deviceRequests(id)), isEmpty);

    // A member joins while the rule is off, and holds what the Crate holds.
    final alice = await device(await account('alice'));
    await join(laptop, alice, id, member);
    await laptop.addHost(id, 'web-1', crateId: production);
    expect((await laptop.coordinator.syncAll())[id]!.sent, 1);
    await alice.coordinator.syncAll();
    expect(await alice.hosts(id), ['web-1']);

    // The rule goes on, from an approved device: hers is held back from
    // then on, and keeps what it has.
    await laptop.service.setRules(id, rule);
    expect(await alice.coordinator.syncAll(), isEmpty);
    var (status, held) = await alice.standing(id);
    expect(status, 'rules');
    expect(held!['unmet'], ['trusted_device']);
    expect(held.containsKey('device_removed'), isFalse);
    expect(await alice.hosts(id), ['web-1']);
    await expectLater(alice.server.record(id, after: 0), onlyTheDevice);
    await expectLater(alice.server.changes(production, since: 0), onlyTheDevice);

    // The owner on a third device nobody approved: no rules from it.
    final tablet = await device(owner);
    expect(await tablet.service.refresh(), isEmpty);
    await expectLater(tablet.service.setRules(id, RecordRules.none), onlyTheDevice);

    // She asks; the owner hears, answers on the phone, compares, approves;
    // her device hears and is in again.
    await phone.service.refresh();
    final aliceHeard = <OrchardStreamEvent>[];
    await line(alice, aliceHeard);
    laptopHeard.clear();
    final hers = await approve(alice, phone, id);
    expect(hers, hasLength(3));
    expect(hers, isNot(words.words));
    await eventually(() => laptopHeard.whereType<DeviceRequestsChanged>().isNotEmpty);
    await eventually(() => aliceHeard.whereType<OrchardsChanged>().isNotEmpty);
    expect((await alice.coordinator.syncAll()).keys, [id]);
    expect((await alice.standing(id)).$1, 'active');
    expect((await alice.service.deviceStanding(id)).approved, isTrue);

    // Removed: held again, told so, and nothing of the Orchard left on it.
    await laptop.addHost(id, 'web-2', crateId: production);
    await laptop.coordinator.syncAll();
    await alice.coordinator.syncAll();
    expect(await alice.hosts(id), ['web-1', 'web-2']);
    await laptop.service.removeDevice(id, uid: alice.me.uid, deviceKey: await alice.key);
    expect(await alice.coordinator.syncAll(), isEmpty);
    (status, held) = await alice.standing(id);
    expect(status, 'rules');
    expect(held!['device_removed'], isTrue);
    expect(await alice.hosts(id), isEmpty);
    expect([for (final n in await alice.service.takeDeviceNotices(id)) n.kind], [DeviceNoticeKind.removed]);
    expect(await alice.service.takeDeviceNotices(id), isEmpty, reason: 'told once');

    // The owners' last approved device stays while the rule is on.
    await laptop.service.removeDevice(id, uid: owner.uid, deviceKey: await phone.key);
    await expectLater(
      laptop.service.removeDevice(id, uid: owner.uid, deviceKey: await laptop.key),
      throwsA(isA<OrchardRecordRefused>()
          .having((e) => e.reason, 'reason', 'would leave no owner with an approved device')),
    );
  });

  test('a device that signed in again says which it is, and a certificate goes to an approved device only',
      () async {
    if (!serverUp) return markTestSkipped(skip());
    final owner = await account('owner');
    final laptop = await device(owner);
    final phone = await device(owner);
    final id = await laptop.service.createOrchard('Devices', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = (await laptop.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final member = (await laptop.service.roles(id)).single.id;
    final alice = await device(await account('alice'));
    await join(laptop, alice, id, member);
    await laptop.service.approveThisDevice(id);
    await phone.service.refresh();
    await approve(phone, laptop, id);
    await alice.service.refresh();
    await approve(alice, laptop, id);
    final vault = await laptop.service.createCrate(id, 'Owner keys', ownersOnly: true);
    await laptop.service.setAuthorityKey(id, production,
        keyCrate: vault,
        ttlMinutes: 60,
        principals: {
          member: ['deploy'],
          FixedRoles.owner: ['root'],
        },
        keyLabel: 'Production authority');
    await laptop.service.setRules(id, rule);

    // The laptop signs in again, as for a change that needs a recent
    // sign-in: a new session, which names no device yet. The change is held
    // back once, the sign-in says which device it is, and it goes through.
    final before = await laptop.server.currentSession();
    laptop.bearer = await signIn(owner.uid);
    final after = await laptop.server.currentSession();
    expect(after, isNot(before));
    await expectLater(laptop.server.record(id, after: 0), onlyTheDevice);
    await laptop.service.changeAuthority(id, production,
        ttlMinutes: 480,
        principals: {
          member: ['deploy'],
          FixedRoles.owner: ['root'],
        });
    expect((await laptop.server.record(id, after: 0)).seq, greaterThan(0));

    // Told of the new sign-in, the service names it at once.
    laptop.bearer = await signIn(owner.uid);
    await laptop.service.signedInAgain();
    expect((await laptop.server.record(id, after: 0)).seq, greaterThan(0));

    // A sign-in names one device: the key kept here was lost and made
    // again, and this sign-in cannot take the new one.
    final tablet = await device(owner);
    await tablet.service.refresh();
    await DeviceIdentityStore(tablet.keychain).forget(owner.uid);
    await expectLater(tablet.service.askDeviceApproval(id), throwsA(isA<DeviceCannotBeNamed>()));
    // Signed in again, it asks like any new device.
    tablet.bearer = await signIn(owner.uid);
    final asked = await tablet.service.askDeviceApproval(id);
    await tablet.service.withdrawDeviceAsk(id);
    expect((await laptop.service.deviceRequests(id)).where((r) => r.id == asked.id), isEmpty);

    // Her approved device asks for a certificate, naming itself and signing
    // the request; the owner's device signs it; she holds it.
    await alice.service.refresh();
    await alice.service.askForCertificate(id, production);
    final waiting = (await laptop.server.waitingCertificates(production)).single;
    expect(deviceKeyText(waiting.deviceKey!), await alice.key);
    expect(
      await verifyDeviceSignature(waiting.deviceKey!,
          certDeviceMessage(waiting.message(orchardId: id, crateId: production)), waiting.deviceSignature!),
      isTrue,
    );
    expect(await laptop.service.signWaitingCertificates(id), 1);
    expect(await alice.service.collectCertificates(id), {production});

    // Her other device, which nobody approved, asks for nothing: the Crate
    // is closed to it.
    final other = await device(alice.me);
    expect(await other.service.refresh(), isEmpty);
    await expectLater(other.service.askForCertificate(id, production), throwsA(anything));
    expect(await laptop.server.waitingCertificates(production), isEmpty);
    // And a request her approved device sends in the name of the other one,
    // signed by that device and by her account, is refused by the server.
    final unapproved = await DeviceIdentityStore(other.keychain).forAccount(alice.me.uid);
    final unsigned = CertRequest(
      id: const Uuid().v4(),
      uid: alice.me.uid,
      keyVersion: alice.me.keys.version,
      sshPublicKey: (await DeviceIdentity.generate()).publicKey,
      requestedAt: now(),
      signature: Uint8List(64),
    );
    final signed = unsigned.message(orchardId: id, crateId: production);
    await expectLater(
      alice.server.askCertificate(
        production,
        CertRequest(
          id: unsigned.id,
          uid: unsigned.uid,
          keyVersion: unsigned.keyVersion,
          sshPublicKey: unsigned.sshPublicKey,
          requestedAt: unsigned.requestedAt,
          signature: await alice.me.keys.sign(signed),
          deviceKey: unapproved.publicKey,
          deviceSignature: await unapproved.sign(certDeviceMessage(signed)),
        ),
      ),
      answered('device-not-approved'),
    );
  });
}
