import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:zest_ssh_core/dartssh2.dart' show OpenSSHEd25519KeyPair;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/orchards/certs/team_certificate_login.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show OrchardAuthorSource, orchardServiceProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show SSHAuthFailedException, teamCertificateSignIn;
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';

import 'fake_crate_server.dart';

/// Certificates from a Crate's authority, from the devices' side (3.0):
/// an owner gives Production an authority whose key is kept in an
/// owners-only Crate; a member's device asks with a request signed by the
/// member's keys, an owner's device checks it against the record and signs
/// it, and the member's device takes back only what the record's authority
/// signed for its own key. A server that makes up requests, or hands back
/// certificates from anyone else, gets nothing out of either device. The
/// (fake) server holds to the same rules as ZestSSH Cloud's routes.

const _owner = 'owner-1';
const _owner2 = 'owner-2';
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

class _Device {
  _Device(FakeCrateServer shared, this.uid, this.keys, {Duration? recordWait, bool knowsCloud = true})
      : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () => (whoAmI ?? () async => CrateAuthor(uid: uid, keys: keys))(),
      cloudAway: knowsCloud ? () => away : null,
      loginRecordWait: recordWait ?? const Duration(seconds: 6),
    );
  }

  final String uid;
  final AccountKeys keys;

  /// Whether the app on this device knows that ZestSSH Cloud is not
  /// answering just now.
  bool away = false;

  /// Where this device learns which keys are its account's, when a test
  /// gives it another answer than "these".
  Future<CrateAuthor?> Function()? whoAmI;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;

  Future<LocalStateStore> state(String orchardId) async => LocalStateStore(await service.databases.open(orchardId));

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

  setUpAll(() async {
    for (final uid in [_owner, _owner2, _alice, _bob, _carol]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _owner2, _alice, _bob, _carol]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid, {Duration? recordWait, bool knowsCloud = true}) {
    final d = _Device(server, uid, keys[uid]!, recordWait: recordWait, knowsCloud: knowsCloud);
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

  /// An Orchard with alice in the first role (use of Production) and bob in
  /// Viewers (connect to Production); Production's authority on, its key in
  /// the owners-only Crate "Owner keys", members signing in as deploy and
  /// owners as root, Viewers as nobody.
  Future<({String id, String production, String vault, String member, _Device owner, _Device alice, _Device bob})>
      team({int ttl = 60}) async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single;
    final production = member.crates.keys.single;
    final vault = await owner.service.createCrate(id, 'Owner keys', ownersOnly: true);
    final viewers = await owner.service.saveRole(id,
        name: 'Viewers', can: const {}, crates: {production: levelSwitches(CrateLevel.connect)});
    await join(owner, alice, id, member.id);
    await join(owner, bob, id, viewers);
    await owner.service.setAuthorityKey(id, production,
        keyCrate: vault,
        ttlMinutes: ttl,
        principals: {
          member.id: ['deploy'],
          FixedRoles.owner: ['root'],
        },
        keyLabel: 'Production authority');
    for (final d in [alice, bob]) {
      await d.service.refresh();
    }
    return (id: id, production: production, vault: vault, member: member.id, owner: owner, alice: alice, bob: bob);
  }

  /// [who]'s request in [t]'s Production for [key], signed with [signer]'s keys.
  Future<CertRequest> requestBy(String orchardId, String crateId, String who, Uint8List key,
      {AccountKeys? signer, int? at, int keyVersion = 1}) async {
    final unsigned = CertRequest(
      id: const Uuid().v4(),
      uid: who,
      keyVersion: keyVersion,
      sshPublicKey: key,
      requestedAt: at ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      signature: Uint8List(64),
    );
    return CertRequest(
      id: unsigned.id,
      uid: who,
      keyVersion: keyVersion,
      sshPublicKey: key,
      requestedAt: unsigned.requestedAt,
      signature: await (signer ?? keys[who]!).sign(unsigned.message(orchardId: orchardId, crateId: crateId)),
    );
  }

  test('a member asks, an owner signs what the record allows, the member connects with its own key', () async {
    final t = await team();
    final ca = server.recordOf(t.id).crates[t.production]!.ca!;
    expect(ca.generation, 1);
    expect(ca.principals, {
      t.member: ['deploy'],
      FixedRoles.owner: ['root'],
    });
    // The authority's key is a key in the owners-only Crate, on the owner's device.
    expect(await t.owner.service.authorityKey(t.id, t.production), isNotNull);
    expect(await t.alice.service.authorityKey(t.id, t.production), isNull, reason: 'alice cannot open Owner keys');

    // No owner signs within the wait: alice's device says so, and its request waits.
    await expectLater(
      t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
      throwsA(isA<TeamCertificateUnavailable>()
          .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
    );
    expect(server.certRequests, hasLength(1));
    // Asking again right away sends nothing new.
    await t.alice.service.askForCertificate(t.id, t.production);
    expect(server.certRequests, hasLength(1));

    expect(await t.owner.service.signWaitingCertificates(t.id), 1);
    expect(await t.owner.service.signWaitingCertificates(t.id), 0, reason: 'signed once');

    final pair = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
        as SshCertificateKeyPair;
    final cert = pair.certificate;
    expect(cert.principals, ['deploy']);
    expect(cert.keyId, contains('alice@example.com'));
    expect(cert.extensions.keys.toSet(), {'permit-pty', 'permit-user-rc', 'permit-port-forwarding'},
        reason: "alice's role forwards ports in Production; agent forwarding is not in any preset");
    expect(cert.validBefore - cert.validAfter, 60 * 60 + kCertBackdateSeconds);
    final device = await t.alice.service.teamDeviceKey(t.id);
    expect(pair.innerKey.toPublicKey().encode(), ed25519PublicBlob(device.publicKey),
        reason: "the device's own key signs the login");
    // The same key the next time, from what is held.
    final again = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
        as SshCertificateKeyPair;
    expect(again.certificate.fullBlob, cert.fullBlob);
    expect(server.certRequests, hasLength(1));

    // A user name the role does not sign in as, and a role that signs in as nobody.
    await expectLater(
      t.alice.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
      throwsA(isA<TeamCertificateUnavailable>()
          .having((e) => e.problem, 'problem', TeamCertificateProblem.notThisUserName)
          .having((e) => e.userNames, 'names', ['deploy'])),
    );
    await expectLater(
      t.bob.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
      throwsA(isA<TeamCertificateUnavailable>()
          .having((e) => e.problem, 'problem', TeamCertificateProblem.noUserNames)),
    );
  });

  // If ZestSSH Cloud is down, what a device holds still works (3.0: SSH
  // must keep working for a team even while the
  // backend is down). The app asks the
  // server which keys are the account's every ten minutes, and with no
  // answer every use of the keys failed: ten minutes into an outage a
  // certificate that was good for another day could not be used.
  group('while ZestSSH Cloud cannot be reached', () {
    /// alice's device as the app runs it: which keys are hers is asked of
    /// the server at most every ten minutes, by [clock].
    OrchardAuthorSource asTheAppAsks(_Device alice, DateTime Function() clock,
            {Future<CrateAuthor?> Function()? lastConfirmed}) =>
        OrchardAuthorSource(
          () async {
            if (server.down) throw const SocketException('Connection refused');
            return CrateAuthor(uid: alice.uid, keys: alice.keys);
          },
          clock: clock,
          lastConfirmed: lastConfirmed,
        );

    test('a certificate the device holds logs in, ten minutes into the outage and a day into it', () async {
      final t = await team(ttl: 10080);
      var now = DateTime(2026, 10, 8, 9);
      t.alice.whoAmI = asTheAppAsks(t.alice, () => now).call;

      // alice has her certificate while all is well.
      await t.alice.service.askForCertificate(t.id, t.production);
      expect(await t.owner.service.signWaitingCertificates(t.id), 1);
      final held = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;

      server.down = true;
      for (final later in const [Duration(minutes: 11), Duration(hours: 26)]) {
        now = now.add(later);
        final pair = await t.alice.service
            .teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero) as SshCertificateKeyPair;
        expect(pair.certificate.fullBlob, held.certificate.fullBlob, reason: '$later into the outage');
      }
      // The monitor and automations, which ask nothing of anyone, too.
      final quiet = await t.alice.service.teamCertificateKey(t.id, t.production,
          userName: 'deploy', ask: false, wait: Duration.zero) as SshCertificateKeyPair;
      expect(quiet.certificate.fullBlob, held.certificate.fullBlob);
    });

    // An entry a newer version wrote, which this one cannot read:
    // the login goes on with the record here and the certificate held,
    // as in an outage. It failed, in 3.2.7 too.
    test('an entry from a newer version: the certificate the device holds still logs in', () async {
      final t = await team(ttl: 10080);
      final now = DateTime(2026, 10, 8, 9);
      t.alice.whoAmI = asTheAppAsks(t.alice, () => now).call;
      await t.alice.service.askForCertificate(t.id, t.production);
      expect(await t.owner.service.signWaitingCertificates(t.id), 1);
      final held = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;
      server.serveNewerEntry(t.id);
      final pair = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;
      expect(pair.certificate.fullBlob, held.certificate.fullBlob);
    });

    test('also when the app was started during the outage, with the keys the device holds as confirmed', () async {
      final t = await team(ttl: 10080);
      await t.alice.service.askForCertificate(t.id, t.production);
      expect(await t.owner.service.signWaitingCertificates(t.id), 1);
      final held = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;

      // The app is started again, and the server is down: nothing was said
      // to this run yet.
      server.down = true;
      t.alice.whoAmI = asTheAppAsks(t.alice, DateTime.now,
          lastConfirmed: () async => CrateAuthor(uid: t.alice.uid, keys: t.alice.keys)).call;
      final pair = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;
      expect(pair.certificate.fullBlob, held.certificate.fullBlob);
    });

    test('a device that holds no confirmed keys still cannot say who it is', () async {
      final t = await team(ttl: 10080);
      await t.alice.service.askForCertificate(t.id, t.production);
      await t.owner.service.signWaitingCertificates(t.id);
      await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero);

      server.down = true;
      t.alice.whoAmI = asTheAppAsks(t.alice, DateTime.now).call;
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<SocketException>()),
      );
    });

    test('a certificate that has run out is not used, outage or not: a new one cannot be had until the server is back',
        () async {
      final t = await team(ttl: 60);
      var now = DateTime.now();
      addTearDown(() => OrchardService.debugNow = DateTime.now);
      OrchardService.debugNow = () => now;
      t.alice.whoAmI = asTheAppAsks(t.alice, () => now).call;
      await t.alice.service.askForCertificate(t.id, t.production);
      await t.owner.service.signWaitingCertificates(t.id);
      final held = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;

      server.down = true;
      // Fifty minutes in, its hour is not over.
      now = now.add(const Duration(minutes: 50));
      final still = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;
      expect(still.certificate.fullBlob, held.certificate.fullBlob);

      // Two hours in, it is: asking for a new one is what fails, as what it
      // is (the server not reached), and whoever asks nothing gets nothing.
      now = now.add(const Duration(minutes: 70));
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', ask: false, wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
      );
    });
  });

  // An owner holds the key every certificate of the Crate is signed with:
  // they need nobody to sign for them, and no server to carry a request
  // (3.0: an owner must be able to reach the team's hosts
  // whatever ZestSSH Cloud is doing).
  group("an owner's own certificate", () {
    Future<Uint8List?> heldBlob(_Device d, String orchardId, String crateId) async {
      final raw = await (await d.state(orchardId)).read('certs.crate.$crateId');
      return raw == null ? null : base64Decode(raw);
    }

    test('is signed on their own device at once: nobody is asked, and nothing waits on the server', () async {
      final t = await team();
      expect(await t.owner.service.heldCertificate(t.id, t.production), isNull);
      final lines = <String>[];
      final pair = await t.owner.service
              .teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero, onLog: lines.add)
          as SshCertificateKeyPair;
      final cert = pair.certificate;
      expect(cert.principals, ['root'], reason: 'the user names the owners sign in as');
      expect(cert.keyId, contains('$_owner@example.com'));
      expect(cert.validBefore - cert.validAfter, 60 * 60 + kCertBackdateSeconds, reason: 'as long as any certificate here');
      expect(cert.extensions.keys, containsAll(['permit-pty', 'permit-user-rc', 'permit-port-forwarding']));
      final device = await t.owner.service.teamDeviceKey(t.id);
      expect(pair.innerKey.toPublicKey().encode(), ed25519PublicBlob(device.publicKey),
          reason: "the device's own key signs the login");
      // It is a certificate of the Crate's authority, for this device's key.
      final ca = server.recordOf(t.id).crates[t.production]!.ca!;
      final blob = (await heldBlob(t.owner, t.id, t.production))!;
      expect(await readTeamCertificate(blob, caPublicKey: ca.publicKey, subject: device.publicKey), isNotNull);
      expect(server.certRequests, isEmpty, reason: 'nothing was asked of anybody');
      expect(server.signAttempts, isEmpty);
      expect(lines, contains(contains('signed on this device')));

      // The same one the next time, from what is held.
      final again = await t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero)
          as SshCertificateKeyPair;
      expect(again.certificate.fullBlob, cert.fullBlob);
    });

    test('with ZestSSH Cloud not to be reached and nothing held, an owner still gets to the hosts', () async {
      final t = await team();
      server.down = true;
      final pair = await t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero);
      expect(pair, isA<SshCertificateKeyPair>());
      expect((pair as SshCertificateKeyPair).certificate.principals, ['root']);
    });

    Future<(String, String?)> standingOf(_Device d, String orchardId) async {
      final info = await (await d.service.databases.open(orchardId))
          .customSelect('SELECT status, held FROM orchard_info WHERE id = 1')
          .getSingle();
      return (info.read<String>('status'), info.read<String?>('held'));
    }

    test('ZestSSH Cloud answering with a fault of its own, or with "too many requests", is no reason either', () async {
      for (final status in [500, 502, 503, 429]) {
        final t = await team();
        server.fault = status;
        final pair = await t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero);
        expect(pair, isA<SshCertificateKeyPair>(), reason: 'HTTP $status');
        expect(await standingOf(t.owner, t.id), ('active', null), reason: 'and it is not taken for being held back');
        server.fault = null;
      }
    });

    test('turned away by ZestSSH Cloud, a device signs nothing for itself: what it last knew stands in for no answer only',
        () async {
      // Signed out there, refused, no longer in the Orchard.
      for (final status in [401, 403, 404]) {
        final t = await team();
        server.fault = status;
        await expectLater(
          t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
          throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', status)),
          reason: 'HTTP $status',
        );
        expect(await heldBlob(t.owner, t.id, t.production), isNull, reason: 'HTTP $status');
        expect(await standingOf(t.owner, t.id), ('active', null),
            reason: 'only a refusal by the rules is kept as one (HTTP $status)');
        // The server answering as it should again, the device signs.
        server.fault = null;
        expect(
          await t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
          isA<SshCertificateKeyPair>(),
        );
      }
    });

    test('with nobody there to wait (the monitor, an automation) it is signed all the same', () async {
      final t = await team();
      server.down = true;
      final pair = await t.owner.service
          .teamCertificateKey(t.id, t.production, userName: 'root', ask: false, wait: Duration.zero);
      expect(pair, isA<SshCertificateKeyPair>());
      expect(server.askedWhileDown, 0, reason: 'and the server was not asked a thing');
    });

    test('an Orchard its offline limit closed on the device signs nothing: nothing of it opens', () async {
      final t = await team();
      await t.owner.service.databases.closeOffline(t.id);
      server.down = true;
      for (final ask in [false, true]) {
        await expectLater(
          t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', ask: ask, wait: Duration.zero),
          throwsA(isA<OrchardClosedOffline>()),
          reason: ask ? 'at a login' : 'where nobody is asked',
        );
      }
    });

    test('nothing is signed with an authority whose Crate, or the Crate that keeps its key, is closed on the device '
        'by an offline limit of its own', () async {
      final t = await team();
      final db = await t.owner.service.databases.open(t.id);
      // The device's clock and when it last reached ZestSSH Cloud, as the
      // test sets them.
      var now = 1790000000;
      var last = now;
      attachDeviceContact(
          db, DeviceContact(read: () => OrchardContact(lastContact: last, latest: now), now: () => now));
      Future<bool> signsHere() async => await t.owner.service.authorityKey(t.id, t.production) != null;
      final ask = (await t.alice.service.handRequest(t.id, t.production)).toText();

      // The Crate that keeps the authority's key closes after a day away.
      await t.owner.service.setCrateOfflineLimit(t.id, t.vault, 24);
      expect(await signsHere(), isTrue);
      now = last + 24 * 3600 + 1;
      expect(await closedCratesIn(db), {t.vault: 24});
      expect(await signsHere(), isFalse, reason: 'as far as this device goes, the key is not here');
      server.down = true;
      // Nothing for itself: with the key away it would have to ask, and
      // where nobody is asked (the monitor) nothing is to be had.
      await expectLater(
        t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', ask: false, wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()),
      );
      expect(await heldBlob(t.owner, t.id, t.production), isNull);
      // Nothing for a member who hands it a request.
      await expectLater(
        t.owner.service.reviewHandedRequest(ask),
        throwsA(isA<HandedRequestRefused>().having((e) => e.problem, 'problem', HandedRequestProblem.keyNotHere)),
      );
      // Back in contact, it signs again.
      last = now;
      expect(await signsHere(), isTrue);
      expect((await t.owner.service.reviewHandedRequest(ask)).uid, _alice);

      // The Crate the certificates are for closes, the key's Crate does not.
      server.down = false;
      await t.owner.service.setCrateOfflineLimit(t.id, t.vault, 0);
      await t.owner.service.setCrateOfflineLimit(t.id, t.production, 24);
      expect(await signsHere(), isTrue);
      now = last + 24 * 3600 + 1;
      expect(await closedCratesIn(db), {t.production: 24});
      expect(await signsHere(), isFalse);
      server.down = true;
      await expectLater(
        t.owner.service.reviewHandedRequest(ask),
        throwsA(isA<HandedRequestRefused>().having((e) => e.problem, 'problem', HandedRequestProblem.keyNotHere)),
      );
      expect(await heldBlob(t.owner, t.id, t.production), isNull);
      // An authority of a Crate that is open is not touched by it: with
      // both limits off, it signs however long the device was away.
      server.down = false;
      last = now;
      await t.owner.service.setCrateOfflineLimit(t.id, t.production, 0);
      now += 1000 * 3600;
      expect(await closedCratesIn(db), isEmpty);
      expect(await signsHere(), isTrue);
      // Nor by a Crate that is closed and is neither its own nor its key's.
      final lab = await t.owner.service.createCrate(t.id, 'Lab');
      await t.owner.service.setCrateOfflineLimit(t.id, lab, 24);
      expect(await closedCratesIn(db), {lab: 24});
      expect(await signsHere(), isTrue);
      expect((await t.owner.service.reviewHandedRequest(ask)).uid, _alice);
    });

    test('a user name the owners do not sign in as is refused all the same', () async {
      final t = await team();
      await expectLater(
        t.owner.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.notThisUserName)
            .having((e) => e.userNames, 'names', ['root'])),
      );
      expect(await heldBlob(t.owner, t.id, t.production), isNull, reason: 'and nothing was signed for it');
    });

    test('whoever is no owner signs nothing for themselves, with the server or without', () async {
      final t = await team();
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
      );
      expect(server.certRequests, hasLength(1), reason: 'it asks, as before');
      expect(await heldBlob(t.alice, t.id, t.production), isNull);
      server.down = true;
      await (await t.alice.state(t.id)).removeWithPrefix('certs.asked.');
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(anything),
      );
      expect(await heldBlob(t.alice, t.id, t.production), isNull);
    });

    test("an owner whose device does not hold the authority's key yet asks like anybody", () async {
      final t = await team();
      final owner2 = device(_owner2);
      await join(t.owner, owner2, t.id, FixedRoles.owner);
      expect(await owner2.service.authorityKey(t.id, t.production), isNull, reason: 'the key Crate has not synced here');
      await expectLater(
        owner2.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
      );
      expect(server.certRequests, hasLength(1));
      expect(await heldBlob(owner2, t.id, t.production), isNull);
    });

    test('an owner whose keys were replaced signs nothing with the old ones', () async {
      final t = await team();
      final next = await AccountKeys.generate(version: 2);
      final published = await next.publish(_owner);
      final entry = (await t.owner.service
          .memberKeysEntries(_owner, next, published, await keys[_owner]!.endorse(published)))[t.id]!;
      await server.appendAs(_owner, t.id, [entry]);
      await server.publish(_owner, next, email: '$_owner@example.com');
      expect(server.recordOf(t.id).members[_owner]!.currentKeys.version, 2);
      // This device still holds the old keys, and the authority's key.
      await expectLater(
        t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
        throwsA(anything),
      );
      expect(await heldBlob(t.owner, t.id, t.production), isNull);
    });

    test('past half its time a round signs the next one here, and asks nobody', () async {
      final t = await team();
      final device = await t.owner.service.teamDeviceKey(t.id);
      final authority = (await t.owner.service.authorityKey(t.id, t.production))!;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // Signed 40 minutes ago for an hour: 20 minutes left, past half.
      final old = issueTeamCertificate(
        ca: authority,
        request: CertRequest(
            id: 'old', uid: _owner, keyVersion: 1, sshPublicKey: device.publicKey, requestedAt: now, signature: Uint8List(64)),
        principals: const ['root'],
        extensions: certExtensions(const {}),
        ttlMinutes: 60,
        nowSeconds: now - 2400,
        keyId: 'old',
      );
      await (await t.owner.state(t.id)).write('certs.crate.${t.production}', base64Encode(old));
      final before = (await t.owner.service.heldCertificate(t.id, t.production))!;
      expect(before.dueAt(now), isTrue);
      await t.owner.service.certificateRound(t.id);
      final after = (await t.owner.service.heldCertificate(t.id, t.production))!;
      expect(after.validBefore, greaterThan(before.validBefore), reason: 'a new one, good for longer');
      expect(after.certificate.keyId, contains('$_owner@example.com'));
      expect(server.certRequests, isEmpty, reason: 'nobody was asked');
    });

    test('a request of theirs that was waiting is no longer waited on once they have signed', () async {
      final t = await team();
      // As a version before this one left it: asked, and waiting on the server.
      await t.owner.service.askForCertificate(t.id, t.production);
      expect(await (await t.owner.state(t.id)).read('certs.asked.${t.production}'), isNotNull);
      await t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero);
      expect(await (await t.owner.state(t.id)).read('certs.asked.${t.production}'), isNull);
    });

    test('with the authority off, or the Crate closed to them, nothing is signed', () async {
      final t = await team();
      await t.owner.service.turnAuthorityOff(t.id, t.production);
      await expectLater(
        t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.noAuthority)),
      );
      expect(await heldBlob(t.owner, t.id, t.production), isNull);
    });

    test("an owner who was made a member signs nothing for themselves, though the authority's key is still on the device",
        () async {
      final t = await team();
      final owner2 = device(_owner2);
      await join(t.owner, owner2, t.id, FixedRoles.owner);
      OrchardSyncCoordinator coordinator(_Device d) =>
          OrchardSyncCoordinator(service: d.service, server: d.server, databases: d.service.databases);
      await coordinator(t.owner).syncOne(t.id);
      await coordinator(owner2).syncOne(t.id);
      expect(await owner2.service.authorityKey(t.id, t.production), isNotNull);
      // They step down on another device of theirs, and the first owner
      // makes them a member. This device has not synced since, so the Crate
      // that keeps the key has not left it yet.
      final theirPhone = device(_owner2);
      expect(await theirPhone.service.refresh(), contains(t.id));
      await theirPhone.service.stepDown(t.id);
      await t.owner.service.setMemberRole(t.id, _owner2, t.member);
      expect(server.recordOf(t.id).isOwner(_owner2), isFalse);
      expect(server.recordOf(t.id).members[_owner2]!.role, t.member);
      expect(await owner2.service.authorityKey(t.id, t.production), isNotNull);
      // A member of that role signs in as deploy, and asks for it like any member.
      await expectLater(
        owner2.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
      );
      expect(await heldBlob(owner2, t.id, t.production), isNull, reason: 'the record no longer has them as an owner');
      expect(server.certRequests, hasLength(1));
      // An owner's device signs it, as for any member.
      expect(await t.owner.service.signWaitingCertificates(t.id), 1);
      final pair = await owner2.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;
      expect(pair.certificate.principals, ['deploy']);
    });

    test('nothing is signed on a device whose own copy of the Orchard says it is not let in', () async {
      final t = await team();
      final db = await t.owner.service.databases.open(t.id);
      Future<void> standing(String status) =>
          db.customStatement('UPDATE orchard_info SET status = ? WHERE id = 1', [status]);
      // Held back by a rule the server checks, suspended, the access ended,
      // waiting to be recovered: the server gives such a device no
      // certificate, and it signs none for itself.
      for (final status in ['rules', 'suspended', 'ended', kRecoveryWaitStatus]) {
        await standing(status);
        await expectLater(
          t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', ask: false, wait: Duration.zero),
          throwsA(isA<TeamCertificateUnavailable>()
              .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
          reason: status,
        );
        expect(await heldBlob(t.owner, t.id, t.production), isNull, reason: status);
      }
      await standing('active');
      expect(
        await t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', ask: false, wait: Duration.zero),
        isA<SshCertificateKeyPair>(),
      );
      // A device that knows nothing of where it stands signs nothing either.
      await (await t.owner.state(t.id)).remove('certs.crate.${t.production}');
      await db.customStatement('DELETE FROM orchard_info WHERE id = 1');
      await expectLater(
        t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', ask: false, wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()),
      );
      expect(await heldBlob(t.owner, t.id, t.production), isNull);
    });
  });

  // Someone is watching a login. What the device holds works whatever the
  // server does, so the server is not what a login waits for (3.0;
  // the record was asked for with the API's own patience, half a
  // minute, before a certificate on the device was used).
  group('a login does not wait on a server that will not answer', () {
    /// [d] holding a certificate for Production, signed the usual way.
    Future<void> certified(({String id, String production, _Device owner}) t, _Device d) async {
      await d.service.askForCertificate(t.id, t.production);
      expect(await t.owner.service.signWaitingCertificates(t.id), 1);
      expect(await d.service.collectCertificates(t.id), {t.production});
    }

    test('one the app knows is not answering is not asked: what the device holds is used at once', () async {
      final t = await team();
      await certified((id: t.id, production: t.production, owner: t.owner), t.alice);
      server.down = true;
      t.alice.away = true;
      t.owner.away = true;
      final before = server.asked;
      expect(
        await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        isA<SshCertificateKeyPair>(),
      );
      // An owner with nothing held signs for themselves, and asks nothing either.
      expect(
        await t.owner.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
        isA<SshCertificateKeyPair>(),
      );
      expect(server.asked, before, reason: 'nothing was asked of the server');
    });

    test('a member with nothing held is told at once, and nothing is asked', () async {
      final t = await team();
      server.down = true;
      t.alice.away = true;
      final before = server.asked;
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: const Duration(seconds: 20)),
        throwsA(isA<TeamCertificateNotAsked>()),
      );
      expect(server.asked, before);
      expect(await (await t.alice.state(t.id)).read('certs.asked.${t.production}'), isNull,
          reason: 'and nothing is remembered as asked');
      // What needs no server to know is still said as what it is.
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.notThisUserName)),
      );
      // Where nobody is asked a thing anyway, it is what it was.
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', ask: false, wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
      );
      expect(server.asked, before);
    });

    test('where nothing knows how the service stands, the server is asked as ever', () async {
      final t = await team();
      final laptop = device(_alice, knowsCloud: false);
      expect(await laptop.service.refresh(), contains(t.id));
      expect(laptop.service.cloudAway, isNull);
      // Nothing is held: the login asks the server for the record, and then for a certificate.
      final before = server.asked;
      await expectLater(
        laptop.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.waitingForOwner)),
      );
      expect(server.certRequests, hasLength(1), reason: 'and a certificate was asked for');
      expect(server.asked, greaterThan(before));
    });

    test('once the app knows the service answers again, it is asked again', () async {
      final t = await team();
      await certified((id: t.id, production: t.production, owner: t.owner), t.alice);
      // The authority goes off. Alice's device has not heard.
      await t.owner.service.turnAuthorityOff(t.id, t.production);
      t.alice.away = true;
      expect(
        await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        isA<SshCertificateKeyPair>(),
        reason: 'by what the device last knew',
      );
      t.alice.away = false;
      await expectLater(
        t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.noAuthority)),
      );
    });

    test('one that takes its time is waited on for so long and no longer', () async {
      final t = await team();
      final laptop = device(_alice, recordWait: const Duration(milliseconds: 80));
      expect(await laptop.service.refresh(), contains(t.id));
      await certified((id: t.id, production: t.production, owner: t.owner), laptop);
      final never = Completer<void>();
      server.stall = never.future;
      final before = server.asked;
      final waited = Stopwatch()..start();
      final pair = await laptop.service
          .teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          .timeout(const Duration(seconds: 15));
      expect(pair, isA<SshCertificateKeyPair>());
      expect(waited.elapsed, lessThan(const Duration(seconds: 4)),
          reason: 'for the 80 milliseconds this device was told to wait, give or take a busy machine');
      expect(server.asked, before + 1, reason: 'the server was asked, and not waited for');
      // What the server would not have given is not taken as given: with the
      // default patience the same login is still waiting.
      var done = false;
      unawaited(t.alice.service
          .teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          .then<void>((_) => done = true, onError: (_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(done, isFalse, reason: 'six seconds have not passed');
      // The server answers after all: what waited on it goes on.
      server.stall = null;
      never.complete();
      await pumpEventQueue();
      expect(done, isTrue);
    });

    test('an answer that comes in time is the one that counts', () async {
      final t = await team();
      final laptop = device(_alice, recordWait: const Duration(seconds: 2));
      expect(await laptop.service.refresh(), contains(t.id));
      await certified((id: t.id, production: t.production, owner: t.owner), laptop);
      await t.owner.service.turnAuthorityOff(t.id, t.production);
      // The server takes a moment, well within what a login waits.
      final soon = Completer<void>();
      server.stall = soon.future;
      Timer(const Duration(milliseconds: 60), soon.complete);
      await expectLater(
        laptop.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
        throwsA(isA<TeamCertificateUnavailable>()
            .having((e) => e.problem, 'problem', TeamCertificateProblem.noAuthority)),
      );
      server.stall = null;
    });
  });

  // The server only ever carried a member's request to an owner's device
  // and the certificate back. Both can go any other way: as a code from
  // screen to camera, or as a line of text through whatever still works
  // (3.0). Here the two devices pass each other the texts.
  group('a certificate handed over', () {
    Future<String?> held(_Device d, String orchardId, String crateId) async =>
        (await d.state(orchardId)).read('certs.crate.$crateId');
    int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Matcher refused(HandedRequestProblem problem, [CertRequestRefusal? refusal]) => isA<HandedRequestRefused>()
        .having((e) => e.problem, 'problem', problem)
        .having((e) => e.refusal, 'refusal', refusal);
    Matcher notKept(HandedCertificateProblem problem) =>
        isA<HandedCertificateRefused>().having((e) => e.problem, 'problem', problem);

    /// What [owner]'s device hands back for the request [d]'s device shows.
    Future<String> signedFor(_Device owner, _Device d, String orchardId, String crateId) async {
      final ask = (await d.service.handRequest(orchardId, crateId)).toText();
      return (await owner.service.signHandedRequest(await owner.service.reviewHandedRequest(ask))).toText();
    }

    test('with the server away: a member shows a request, an owner signs it, the member connects', () async {
      final t = await team();
      server.down = true;
      t.alice.away = true;
      t.owner.away = true;
      final before = server.asked;

      // Alice's device makes the request, and shows it.
      final ask = (await t.alice.service.handRequest(t.id, t.production)).toText();
      expect(handedKindOf(ask), HandedKind.request);
      expect(await (await t.alice.state(t.id)).read('certs.asked.${t.production}'), isNull,
          reason: 'it was sent nowhere, and nothing waits on the server for it');

      // The owner's device reads it: who asks for what. Nothing is signed yet.
      final review = await t.owner.service.reviewHandedRequest(ask);
      expect(review.orchardId, t.id);
      expect(review.crateId, t.production);
      expect(review.uid, _alice);
      expect(review.email, 'alice@example.com');
      expect(review.role, t.member);
      expect(review.userNames, ['deploy']);
      expect(review.validUntil, closeTo(nowSeconds() + 3600, 5));
      expect(review.fromServer, isFalse, reason: 'checked against what the device last had');
      expect(await held(t.alice, t.id, t.production), isNull);

      // Signed, handed back, and kept.
      final give = (await t.owner.service.signHandedRequest(review)).toText();
      expect(handedKindOf(give), HandedKind.certificate);
      final given = HandedCertificate.fromText(give)!;
      expect((given.orchardId, given.crateId), (t.id, t.production));
      expect(given.requestId, HandedRequest.fromText(ask)!.request.id, reason: 'it says which request it answers');
      final kept = await t.alice.service.takeHandedCertificate(give);
      expect(kept.certificate.principals, ['deploy']);
      expect(kept.certificate.keyId, contains('alice@example.com'));
      expect(kept.validBefore - kept.validAfter, 3600 + kCertBackdateSeconds);
      expect(kept.certificate.extensions.keys.toSet(), {'permit-pty', 'permit-user-rc', 'permit-port-forwarding'},
          reason: 'what the Crate allows her, as in any certificate');

      // Alice connects with it, and with her device's own key.
      final pair = await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;
      expect(pair.certificate.fullBlob, kept.certificate.fullBlob);
      final device = await t.alice.service.teamDeviceKey(t.id);
      expect(pair.innerKey.toPublicKey().encode(), ed25519PublicBlob(device.publicKey));
      expect(server.asked, before, reason: 'nothing of all this went through the server');
    });

    test('with the server answering it is checked against the record as it is now, and again as it is signed',
        () async {
      final t = await team();
      final ask = (await t.alice.service.handRequest(t.id, t.production)).toText();
      final review = await t.owner.service.reviewHandedRequest(ask);
      expect(review.fromServer, isTrue);
      // Suspended between the reading and the signing: nothing is signed.
      await t.owner.service.suspendMember(t.id, _alice);
      await expectLater(t.owner.service.signHandedRequest(review),
          throwsA(refused(HandedRequestProblem.refused, CertRequestRefusal.notAMember)));
      await t.owner.service.resumeMember(t.id, _alice);
      final give = (await t.owner.service.signHandedRequest(review)).toText();
      expect((await t.alice.service.takeHandedCertificate(give)).certificate.principals, ['deploy']);
    });

    test('a certificate lasts no longer than the access it rests on, and the owner is told until when', () async {
      final t = await team();
      final ends = nowSeconds() + 600;
      await t.owner.service.setMemberEndsAt(t.id, _alice, ends);
      final ask = (await t.alice.service.handRequest(t.id, t.production)).toText();
      final review = await t.owner.service.reviewHandedRequest(ask);
      expect(review.validUntil, ends, reason: 'ten minutes, not the hour the authority gives');
      final give = (await t.owner.service.signHandedRequest(review)).toText();
      expect((await t.alice.service.takeHandedCertificate(give)).validBefore, ends);
      // Access that ends after the certificate would: the hour the authority gives.
      await t.owner.service.setMemberEndsAt(t.id, _alice, nowSeconds() + 7200);
      final later = await t.owner.service.reviewHandedRequest(ask);
      expect(later.validUntil, closeTo(nowSeconds() + 3600, 5));
    });

    test("an owner's device says what is wrong with what it will not sign", () async {
      final t = await team();
      final carol = device(_carol);
      final elsewhere = await t.owner.service.saveRole(t.id, name: 'Elsewhere', can: const {}, crates: const {});
      await join(t.owner, carol, t.id, elsewhere);
      await t.owner.service.changeAuthority(t.id, t.production, ttlMinutes: 60, principals: {
        t.member: ['deploy'],
        elsewhere: ['deploy'],
      });
      final key = (await TeamDeviceKey.generate()).publicKey;
      final now = nowSeconds();
      Future<void> read(Object text, Matcher why, {_Device? by}) =>
          expectLater((by ?? t.owner).service.reviewHandedRequest(text as String), throwsA(why));
      String handed(CertRequest r, {String? orchard, String? crate}) =>
          HandedRequest(orchardId: orchard ?? t.id, crateId: crate ?? t.production, request: r).toText();
      final good = handed(await requestBy(t.id, t.production, _alice, key));
      expect((await t.owner.service.reviewHandedRequest(good)).uid, _alice);

      // What is no request.
      await read('', refused(HandedRequestProblem.notARequest));
      await read('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA deploy@web-01', refused(HandedRequestProblem.notARequest));
      await read(good.substring(0, good.length - 8), refused(HandedRequestProblem.notARequest));
      await read(await signedFor(t.owner, t.alice, t.id, t.production), refused(HandedRequestProblem.isACertificate));

      // What is not this device's to sign.
      await read(handed(await requestBy(t.id, t.production, _alice, key), orchard: 'an-orchard-that-is-not-here'),
          refused(HandedRequestProblem.otherOrchard));
      await read(good, refused(HandedRequestProblem.notAnOwner), by: t.alice);

      // What the record does not allow, each named.
      Future<void> not(Future<CertRequest> r, CertRequestRefusal why, {String? crate}) async =>
          read(handed(await r, crate: crate), refused(HandedRequestProblem.refused, why));
      await not(requestBy(t.id, t.production, _alice, key, signer: keys[_bob]), CertRequestRefusal.notSignedByMember);
      await not(requestBy(t.id, t.production, _alice, key, keyVersion: 2), CertRequestRefusal.notCurrentKeys);
      await not(requestBy(t.id, t.production, _alice, key, at: now - 86400 - 60), CertRequestRefusal.notRecent);
      await not(requestBy(t.id, t.production, _alice, key, at: now + 7200), CertRequestRefusal.notRecent);
      await not(requestBy(t.id, t.production, _bob, key), CertRequestRefusal.noUserNames);
      await not(requestBy(t.id, t.production, _carol, key), CertRequestRefusal.noAccess);
      await not(requestBy(t.id, t.production, 'mallory', key, signer: keys[_bob]), CertRequestRefusal.notAMember);
      await not(requestBy(t.id, t.vault, _alice, key), CertRequestRefusal.noAuthority, crate: t.vault);
      // A request for one Crate is none for another: the Crate is in what is signed.
      await not(requestBy(t.id, t.vault, _alice, key), CertRequestRefusal.notSignedByMember);

      // An owner whose device has not got the authority's key signs nothing.
      final owner2 = device(_owner2);
      await join(t.owner, owner2, t.id, FixedRoles.owner);
      await read(good, refused(HandedRequestProblem.keyNotHere), by: owner2);

      // A device that is not let in signs nothing, for anybody.
      final db = await t.owner.service.databases.open(t.id);
      await db.customStatement("UPDATE orchard_info SET status = 'rules' WHERE id = 1");
      await read(good, refused(HandedRequestProblem.notLetIn));
      await db.customStatement("UPDATE orchard_info SET status = 'active' WHERE id = 1");
      for (final status in [401, 403, 404]) {
        server.fault = status;
        await read(good, refused(HandedRequestProblem.notLetIn));
      }
      // A server that cannot be asked is not that: the device's own record stands in.
      server.fault = 503;
      expect((await t.owner.service.reviewHandedRequest(good)).fromServer, isFalse);
      server.fault = null;
      await t.owner.service.databases.closeOffline(t.id);
      await read(good, refused(HandedRequestProblem.notLetIn));
    });

    test("a member's device keeps only what the Crate's authority signed for its own key", () async {
      final t = await team();
      final now = nowSeconds();
      Future<void> take(String text, HandedCertificateProblem why, {_Device? by}) =>
          expectLater((by ?? t.alice).service.takeHandedCertificate(text), throwsA(notKept(why)));

      // What is no certificate.
      await take('', HandedCertificateProblem.notACertificate);
      await take('-----BEGIN OPENSSH PRIVATE KEY-----', HandedCertificateProblem.notACertificate);
      final ask = (await t.alice.service.handRequest(t.id, t.production)).toText();
      await take(ask, HandedCertificateProblem.isARequest);

      // One for another device, hers or anybody's.
      final laptop = device(_alice);
      expect(await laptop.service.refresh(), contains(t.id));
      final forLaptop = await signedFor(t.owner, laptop, t.id, t.production);
      await take(forLaptop, HandedCertificateProblem.notForThisDevice);
      expect(await held(t.alice, t.id, t.production), isNull);
      expect((await laptop.service.takeHandedCertificate(forLaptop)).certificate.principals, ['deploy']);

      // One for her device's key that the authority did not sign.
      final herKey = await t.alice.service.teamDeviceKey(t.id);
      CertRequest forHer(String id) => CertRequest(
          id: id, uid: _alice, keyVersion: 1, sshPublicKey: herKey.publicKey, requestedAt: now, signature: Uint8List(64));
      String given(Uint8List certificate, {String? orchard}) => HandedCertificate(
              orchardId: orchard ?? t.id, crateId: t.production, requestId: 'made-up', certificate: certificate)
          .toText();
      final impostor = await TeamDeviceKey.generate();
      final forged = issueTeamCertificate(
        ca: impostor.keyPair,
        request: forHer('forged'),
        principals: const ['root'],
        extensions: certExtensions(const {}),
        ttlMinutes: 60,
        nowSeconds: now,
        keyId: 'forged',
      );
      await take(given(forged), HandedCertificateProblem.notForThisDevice);
      await take(given(Uint8List.fromList(List.filled(300, 7))), HandedCertificateProblem.notForThisDevice);

      // One that has run out, and one for a team that is not here.
      final authority = (await t.owner.service.authorityKey(t.id, t.production))!;
      Uint8List signed({required int at, int ttl = 60}) => issueTeamCertificate(
            ca: authority,
            request: forHer('made-up'),
            principals: const ['deploy'],
            extensions: certExtensions(const {}),
            ttlMinutes: ttl,
            nowSeconds: at,
            keyId: 'made-up',
          );
      await take(given(signed(at: now - 7200)), HandedCertificateProblem.expired);
      await take(given(signed(at: now), orchard: 'an-orchard-that-is-not-here'), HandedCertificateProblem.otherOrchard);
      expect(await held(t.alice, t.id, t.production), isNull, reason: 'none of these was kept');

      // A good one is kept. One that lasts less long does not take its place,
      // one that lasts longer does.
      final anHour = signed(at: now);
      final hour = await t.alice.service.takeHandedCertificate(given(anHour));
      expect(hour.validBefore, now + 3600);
      expect(base64Decode((await held(t.alice, t.id, t.production))!), anHour);
      final shorter = await t.alice.service.takeHandedCertificate(given(signed(at: now - 1800)));
      expect(shorter.validBefore, now + 3600, reason: 'what is held is what she is told');
      expect(base64Decode((await held(t.alice, t.id, t.production))!), anHour, reason: 'and it stays the one held');
      final longer = await t.alice.service.takeHandedCertificate(given(signed(at: now, ttl: 480)));
      expect(longer.validBefore, now + 480 * 60);
      expect((await t.alice.service.heldCertificate(t.id, t.production))!.validBefore, now + 480 * 60);

      // With the authority off nothing is kept, whoever signed it.
      await t.owner.service.turnAuthorityOff(t.id, t.production);
      await take(given(signed(at: now, ttl: 1440)), HandedCertificateProblem.noAuthority);
    });

    test('a request no owner would sign is not made: the device says why at once', () async {
      final t = await team();
      final carol = device(_carol);
      final elsewhere = await t.owner.service.saveRole(t.id, name: 'Elsewhere', can: const {}, crates: const {});
      await join(t.owner, carol, t.id, elsewhere);
      Matcher unavailable(TeamCertificateProblem p) =>
          isA<TeamCertificateUnavailable>().having((e) => e.problem, 'problem', p);
      await expectLater(carol.service.handRequest(t.id, t.production), throwsA(unavailable(TeamCertificateProblem.noAccess)));
      await expectLater(t.bob.service.handRequest(t.id, t.production), throwsA(unavailable(TeamCertificateProblem.noUserNames)));
      await expectLater(t.alice.service.handRequest(t.id, t.vault), throwsA(unavailable(TeamCertificateProblem.noAuthority)));
      // Keys the record does not have as hers.
      final next = await AccountKeys.generate(version: 2);
      t.alice.whoAmI = () async => CrateAuthor(uid: _alice, keys: next);
      await expectLater(
        t.alice.service.handRequest(t.id, t.production),
        throwsA(isA<OrchardServerException>().having((e) => e.staleAccountKeys, 'stale keys', isTrue)),
      );
      t.alice.whoAmI = null;
      await t.owner.service.turnAuthorityOff(t.id, t.production);
      await expectLater(t.alice.service.handRequest(t.id, t.production), throwsA(unavailable(TeamCertificateProblem.noAuthority)));
    });

    test('a device that is not let into the Orchard hands no request to an owner', () async {
      final t = await team();
      final heldBack = isA<TeamCertificateUnavailable>()
          .having((e) => e.problem, 'problem', TeamCertificateProblem.heldBack);
      // Its own copy says so: held back by a rule the server checks,
      // suspended, ended.
      final db = await t.alice.service.databases.open(t.id);
      for (final status in ['rules', 'suspended', 'ended']) {
        await db.customStatement('UPDATE orchard_info SET status = ? WHERE id = 1', [status]);
        await expectLater(t.alice.service.handRequest(t.id, t.production), throwsA(heldBack), reason: status);
      }
      await db.customStatement("UPDATE orchard_info SET status = 'active' WHERE id = 1");
      // The server, asked at that moment, turns it away.
      for (final status in [401, 403, 404]) {
        server.fault = status;
        await expectLater(t.alice.service.handRequest(t.id, t.production), throwsA(heldBack), reason: 'HTTP $status');
      }
      // A server that cannot be asked is not that: this is what a handover is for.
      for (final status in [500, 503, 429]) {
        server.fault = status;
        expect((await t.alice.service.handRequest(t.id, t.production)).request.uid, _alice, reason: 'HTTP $status');
      }
      server.fault = null;
      server.down = true;
      expect((await t.alice.service.handRequest(t.id, t.production)).request.uid, _alice);
      server.down = false;

      // Held back by the Orchard's rules: the server says so once, and the
      // device goes on knowing it when the server can no longer be asked.
      server.held[_alice] = ['two_step'];
      await expectLater(t.alice.service.handRequest(t.id, t.production), throwsA(heldBack));
      server.down = true;
      await expectLater(t.alice.service.handRequest(t.id, t.production), throwsA(heldBack));
      // The words for it are its own.
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(
          teamCertificateMessage(l10n, const TeamCertificateUnavailable(TeamCertificateProblem.heldBack), 'deploy'),
          l10n.teamCertHeldBack);
    });

    test("an owner whose device has not got the authority's key is handed a certificate like anybody", () async {
      final t = await team();
      final owner2 = device(_owner2);
      await join(t.owner, owner2, t.id, FixedRoles.owner);
      server.down = true;
      final ask = (await owner2.service.handRequest(t.id, t.production)).toText();
      final review = await t.owner.service.reviewHandedRequest(ask);
      expect(review.role, FixedRoles.owner);
      expect(review.userNames, ['root']);
      await owner2.service.takeHandedCertificate((await t.owner.service.signHandedRequest(review)).toText());
      final pair = await owner2.service.teamCertificateKey(t.id, t.production, userName: 'root', wait: Duration.zero)
          as SshCertificateKeyPair;
      expect(pair.certificate.principals, ['root']);
    });
  });

  test('a certificate ends with the access it rests on: an end date, or a Crate given until a set time',
      () async {
    final t = await team(ttl: 1440);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Future<SshCertificateKeyPair> certificateOf(_Device d) async {
      await d.service.askForCertificate(t.id, t.production);
      expect(await t.owner.service.signWaitingCertificates(t.id), 1);
      return await d.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero)
          as SshCertificateKeyPair;
    }

    // Alice's time in the Orchard ends in two hours: so does her certificate,
    // which would otherwise last a day.
    await t.owner.service.setMemberEndsAt(t.id, _alice, now + 7200);
    await t.alice.service.refresh();
    expect((await certificateOf(t.alice)).certificate.validBefore, now + 7200);

    // Carol's role opens nothing and signs in as deploy; she is given
    // Production for an hour, and her certificate lasts exactly as long.
    final carol = device(_carol);
    final temps = await t.owner.service.saveRole(t.id, name: 'Temps', can: const {}, crates: const {});
    await join(t.owner, carol, t.id, temps);
    await t.owner.service.changeAuthority(t.id, t.production, ttlMinutes: 1440, principals: {
      t.member: ['deploy'],
      FixedRoles.owner: ['root'],
      temps: ['deploy'],
    });
    await carol.service.refresh();
    await expectLater(
      carol.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
      throwsA(isA<TeamCertificateUnavailable>().having((e) => e.problem, 'problem', TeamCertificateProblem.noAccess)),
    );
    await t.owner.service.giveAccess(t.id,
        uid: _carol, crateId: t.production, level: CrateLevel.connect, duration: const Duration(hours: 1));
    await carol.service.refresh();
    final until = server.recordOf(t.id).members[_carol]!.timed[t.production]!.until;
    final hers = (await certificateOf(carol)).certificate;
    expect(hers.validBefore, until);
    expect(hers.extensions.keys.toSet(), {'permit-pty', 'permit-user-rc', 'permit-port-forwarding'},
        reason: 'what she may do there now, which she holds until then');

    // The server takes none that outlasts it, whoever signed it.
    final key = await TeamDeviceKey.generate();
    final request = await requestBy(t.id, t.production, _carol, key.publicKey);
    server.certRequests[request.id] =
        (crateId: t.production, uid: _carol, request: request, certificate: null, validBefore: null);
    final authority = (await t.owner.service.authorityKey(t.id, t.production))!;
    Uint8List signedUntil(int? notAfter) => issueTeamCertificate(
          ca: authority,
          request: request,
          principals: const ['deploy'],
          extensions: certExtensions(const {CrateSwitches.connect}),
          ttlMinutes: 1440,
          nowSeconds: now,
          keyId: 'carol',
          notAfter: notAfter,
        );
    for (final notAfter in [null, until + 1]) {
      await expectLater(t.owner.server.signCertificate(t.production, request.id, signedUntil(notAfter)),
          throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'bad-certificate')),
          reason: '$notAfter');
    }
    await t.owner.server.signCertificate(t.production, request.id, signedUntil(until));

    // What a certificate does not rest on does not cut it short: bob, who
    // connects for good and is given revealing for an hour, would get a day.
    final record = server.recordOf(t.id);
    await t.owner.service.giveAccess(t.id,
        uid: _bob, crateId: t.production, level: CrateLevel.use, duration: const Duration(hours: 1));
    expect(server.recordOf(t.id).accessEndsAt(_bob, t.production, now), isNotNull);
    expect(server.recordOf(t.id).accessEndsAt(_bob, t.production, now, of: CrateSwitches.inCertificate), isNull);
    expect(record.accessEndsAt(_bob, t.production, now), isNull, reason: 'before it was given');
    // So the certificate his device is signed, once his role signs in as
    // deploy too, lasts the day and not the hour.
    await t.owner.service.changeAuthority(t.id, t.production, ttlMinutes: 1440, principals: {
      t.member: ['deploy'],
      FixedRoles.owner: ['root'],
      temps: ['deploy'],
      server.recordOf(t.id).members[_bob]!.role: ['deploy'],
    });
    await t.bob.service.refresh();
    final his = (await certificateOf(t.bob)).certificate;
    expect(his.validBefore, closeTo(now + 1440 * 60, 60), reason: 'not cut short by what it does not carry');
  });

  test("an owner's device signs nothing the server makes up, nor for anyone the record does not allow now", () async {
    final t = await team();
    final key = (await TeamDeviceKey.generate()).publicKey;
    Future<int> signed(List<CertRequest> made) async {
      server.madeUpRequests[t.production] = made;
      final before = server.signAttempts.length;
      await t.owner.service.signWaitingCertificates(t.id);
      return server.signAttempts.length - before;
    }

    // Made up: signed by someone else in alice's name, for keys the record
    // does not hold for alice, long ago, or with a key swapped after signing.
    final good = await requestBy(t.id, t.production, _alice, key);
    final swapped = CertRequest(
      id: good.id,
      uid: good.uid,
      keyVersion: good.keyVersion,
      sshPublicKey: (await TeamDeviceKey.generate()).publicKey,
      requestedAt: good.requestedAt,
      signature: good.signature,
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(
        await signed([
          await requestBy(t.id, t.production, _alice, key, signer: keys[_bob]),
          await requestBy(t.id, t.production, _alice, key, keyVersion: 2),
          await requestBy(t.id, t.production, _alice, key, at: now - 2 * 86400),
          await requestBy(t.id, t.production, _alice, key, at: now + 7200),
          swapped,
          // For another Crate, signed for it.
          await requestBy(t.id, t.vault, _alice, key),
        ]),
        0);
    // Bob's role signs in as nobody.
    expect(await signed([await requestBy(t.id, t.production, _bob, key)]), 0);
    // Someone who is not a member.
    expect(await signed([await requestBy(t.id, t.production, 'mallory', key, signer: keys[_bob])]), 0);
    // Alice suspended: nothing; resumed: signed.
    await t.owner.service.suspendMember(t.id, _alice);
    final fresh = await requestBy(t.id, t.production, _alice, key);
    // The fake server keeps it as asked by alice, for the signature call.
    server.certRequests[fresh.id] =
        (crateId: t.production, uid: _alice, request: fresh, certificate: null, validBefore: null);
    expect(await signed(const []), 0);
    await t.owner.service.resumeMember(t.id, _alice);
    expect(await signed(const []), 1);
    expect(server.certificatesSigned.single.requestId, fresh.id);
    // A true request the server lists again after it was signed: not signed twice.
    server.certRequests[fresh.id] =
        (crateId: t.production, uid: _alice, request: fresh, certificate: null, validBefore: null);
    expect(await signed(const []), 0);
  });

  test("an owner's device names what is wrong with each request it will not sign", () async {
    final t = await team();
    final carol = device(_carol);
    final elsewhere = await t.owner.service.saveRole(t.id, name: 'Elsewhere', can: const {}, crates: const {});
    await join(t.owner, carol, t.id, elsewhere);
    await t.owner.service.changeAuthority(t.id, t.production, ttlMinutes: 60, principals: {
      t.member: ['deploy'],
      elsewhere: ['deploy'],
    });
    final key = (await TeamDeviceKey.generate()).publicKey;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Future<String?> problem(CertRequest r, {String? crate}) => certRequestProblem(server.recordOf(t.id), r,
        orchardId: t.id, crateId: crate ?? t.production, nowSeconds: now);

    expect(await problem(await requestBy(t.id, t.production, _alice, key)), isNull);
    expect(await problem(await requestBy(t.id, t.production, _alice, key, at: now - 86400 + 60)), isNull,
        reason: 'within the day');
    expect(await problem(await requestBy(t.id, t.production, _alice, key, signer: keys[_bob])), 'not signed by the member');
    expect(await problem(await requestBy(t.id, t.production, _alice, key, keyVersion: 2)), 'not their current keys');
    expect(await problem(await requestBy(t.id, t.production, _alice, key, at: now - 86400 - 60)), 'not asked in the last day');
    expect(await problem(await requestBy(t.id, t.production, _alice, key, at: now + 7200)), 'not asked in the last day');
    expect(await problem(await requestBy(t.id, t.production, _bob, key)), 'the role signs in as nobody');
    expect(await problem(await requestBy(t.id, t.production, _carol, key)), 'no access to the Crate');
    expect(await problem(await requestBy(t.id, t.production, 'mallory', key, signer: keys[_bob])), 'not a member');
    expect(await problem(await requestBy(t.id, t.vault, _alice, key), crate: t.vault), 'no certificate authority');
    await t.owner.service.suspendMember(t.id, _alice);
    expect(await problem(await requestBy(t.id, t.production, _alice, key)), 'not a member');
    await t.owner.service.resumeMember(t.id, _alice);
    await t.owner.service.turnAuthorityOff(t.id, t.production);
    expect(await problem(await requestBy(t.id, t.production, _alice, key)), 'no certificate authority');
  });

  test('a role the authority names but that cannot open the Crate: nothing signed for its members', () async {
    final t = await team();
    final carol = device(_carol);
    final elsewhere = await t.owner.service.saveRole(t.id, name: 'Elsewhere', can: const {}, crates: const {});
    await join(t.owner, carol, t.id, elsewhere);
    await t.owner.service.changeAuthority(t.id, t.production, ttlMinutes: 60, principals: {
      t.member: ['deploy'],
      elsewhere: ['deploy'],
    });
    final key = (await TeamDeviceKey.generate()).publicKey;
    server.madeUpRequests[t.production] = [await requestBy(t.id, t.production, _carol, key)];
    await t.owner.service.signWaitingCertificates(t.id);
    expect(server.signAttempts, isEmpty);
    // Carol's own device is told there is nothing for them there.
    await expectLater(
      carol.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
      throwsA(isA<TeamCertificateUnavailable>().having((e) => e.problem, 'problem', TeamCertificateProblem.noAccess)),
    );
  });

  test('after a key replacement, what the old keys signed is never signed, and the old device cannot ask', () async {
    final t = await team();
    final next = await AccountKeys.generate(version: 2);
    final published = await next.publish(_alice);
    final entry = (await t.alice.service
        .memberKeysEntries(_alice, next, published, await keys[_alice]!.endorse(published)))[t.id]!;
    await server.appendAs(_alice, t.id, [entry]);
    await server.publish(_alice, next, email: 'alice@example.com');
    expect(server.recordOf(t.id).members[_alice]!.currentKeys.version, 2);
    final key = (await TeamDeviceKey.generate()).publicKey;
    final old = await requestBy(t.id, t.production, _alice, key);
    final fresh = await requestBy(t.id, t.production, _alice, key, signer: next, keyVersion: 2);
    server.madeUpRequests[t.production] = [old];
    await t.owner.service.signWaitingCertificates(t.id);
    expect(server.signAttempts, isEmpty, reason: 'the old keys sign for nobody now');
    // The old device still holds the old keys: the server refuses its request.
    await expectLater(t.alice.service.askForCertificate(t.id, t.production), throwsA(isA<OrchardServerException>()));
    // What the new keys signed goes through.
    server.madeUpRequests.clear();
    server.certRequests[fresh.id] =
        (crateId: t.production, uid: _alice, request: fresh, certificate: null, validBefore: null);
    await t.owner.service.signWaitingCertificates(t.id);
    expect(server.signAttempts, [fresh.id]);
  });

  test("a member's device keeps only what the record's authority signed for its own key", () async {
    final t = await team();
    final device = await t.alice.service.teamDeviceKey(t.id);
    final other = await TeamDeviceKey.generate();
    final impostor = await TeamDeviceKey.generate();
    await t.alice.service.askForCertificate(t.id, t.production);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Uint8List issue(TeamDeviceKey by, Uint8List forKey) => issueTeamCertificate(
          ca: by.keyPair,
          request: CertRequest(
              id: 'x', uid: _alice, keyVersion: 1, sshPublicKey: forKey, requestedAt: now, signature: Uint8List(64)),
          principals: const ['deploy'],
          extensions: certExtensions(const {}),
          ttlMinutes: 60,
          nowSeconds: now,
          keyId: 'made up',
        );
    final asked = server.certRequests.keys.single;
    server.certificateListing = [
      // Another authority's, for this device's key.
      IssuedCertificate(
          requestId: asked, sshPublicKey: device.publicKey, certificate: issue(impostor, device.publicKey), validBefore: now + 3600),
      // The authority's, for another key, listed as this one's.
      IssuedCertificate(
          requestId: asked,
          sshPublicKey: device.publicKey,
          certificate: issue(impostor, other.publicKey),
          validBefore: now + 3600),
    ];
    expect(await t.alice.service.collectCertificates(t.id), isEmpty);
    expect(await t.alice.service.heldCertificate(t.id, t.production), isNull);
    // What the owner's device really signed is taken.
    server.certificateListing = null;
    await t.owner.service.signWaitingCertificates(t.id);
    expect(await t.alice.service.collectCertificates(t.id), {t.production});
    expect(await t.alice.service.heldCertificate(t.id, t.production), isNotNull);
    expect(await (await t.alice.state(t.id)).keysWithPrefix('certs.asked.'), isEmpty, reason: 'the request was answered');
  });

  test('a new key: old certificates stop counting and the old key leaves; off: nothing is asked for or kept', () async {
    final t = await team();
    await t.alice.service.askForCertificate(t.id, t.production);
    await t.owner.service.signWaitingCertificates(t.id);
    await t.alice.service.collectCertificates(t.id);
    expect(await t.alice.service.heldCertificate(t.id, t.production), isNotNull);
    final first = server.recordOf(t.id).crates[t.production]!.ca!.publicKey;

    // Another key kept in the same Crate, before the new one.
    final ownerDb = await t.owner.service.databases.open(t.id);
    final unrelated = await TeamDeviceKey.generate();
    await ownerDb.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
        id: 'unrelated-key',
        label: 'Backups',
        username: 'backup',
        authMethod: 'publicKey',
        publicKeyData: Value('ssh-ed25519 ${base64Encode(ed25519PublicBlob(unrelated.publicKey))} backups'),
        createdAt: DateTime(2026, 9, 25)));
    await ownerDb.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id) VALUES ('key', 'unrelated-key', ?)", [t.vault]);
    await t.owner.service.setAuthorityKey(t.id, t.production,
        keyCrate: t.vault,
        ttlMinutes: 480,
        principals: {
          t.member: ['deploy', 'app', 'deploy'],
        },
        keyLabel: 'Production authority 2');
    final ca = server.recordOf(t.id).crates[t.production]!.ca!;
    expect(ca.generation, 2);
    expect(ca.principals, {
      t.member: ['app', 'deploy'],
    });
    expect(base64Encode(ca.publicKey), isNot(base64Encode(first)));
    final authority = (await t.owner.service.authorityKey(t.id, t.production)) as OpenSSHEd25519KeyPair;
    expect(authority.publicKey, ca.publicKey, reason: 'the key the record names, not another in its Crate');
    final rows = await (await t.owner.service.databases.open(t.id))
        .customSelect("SELECT label FROM identities WHERE label LIKE 'Production authority%'")
        .get();
    expect(rows.map((r) => r.read<String>('label')), ['Production authority 2'], reason: 'the old key left');

    await t.alice.service.refresh();
    expect(await t.alice.service.heldCertificate(t.id, t.production), isNull, reason: "the old authority's");
    // A round asks again, and the next one takes the new certificate.
    await t.alice.service.certificateRound(t.id);
    await t.owner.service.signWaitingCertificates(t.id);
    await t.alice.service.certificateRound(t.id);
    final held = (await t.alice.service.heldCertificate(t.id, t.production))!;
    expect(held.certificate.principals, ['app', 'deploy']);
    expect(held.validBefore - held.validAfter, 480 * 60 + kCertBackdateSeconds);

    // Changing the policy keeps the key.
    await t.owner.service.changeAuthority(t.id, t.production, ttlMinutes: 1440, principals: {
      t.member: ['deploy'],
    });
    expect(server.recordOf(t.id).crates[t.production]!.ca!.generation, 2);

    await t.owner.service.turnAuthorityOff(t.id, t.production);
    final late = await requestBy(t.id, t.production, _alice, (await TeamDeviceKey.generate()).publicKey);
    server.certRequests[late.id] =
        (crateId: t.production, uid: _alice, request: late, certificate: null, validBefore: null);
    server.signAttempts.clear();
    await t.owner.service.signWaitingCertificates(t.id);
    expect(server.signAttempts, isEmpty, reason: 'off: owners sign nothing');
    await t.alice.service.refresh();
    await expectLater(
      t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero),
      throwsA(isA<TeamCertificateUnavailable>()
          .having((e) => e.problem, 'problem', TeamCertificateProblem.noAuthority)),
    );
    await t.alice.service.certificateRound(t.id);
    final state = await t.alice.state(t.id);
    expect(await state.keysWithPrefix('certs.crate.'), isEmpty);
    expect(await state.keysWithPrefix('certs.asked.'), isEmpty);
  });

  test('past half its time, a round asks for the next certificate', () async {
    final t = await team();
    final device = await t.alice.service.teamDeviceKey(t.id);
    final authority = (await t.owner.service.authorityKey(t.id, t.production))!;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Signed 40 minutes ago for an hour: 20 minutes left, past half.
    final old = issueTeamCertificate(
      ca: authority,
      request: CertRequest(
          id: 'old', uid: _alice, keyVersion: 1, sshPublicKey: device.publicKey, requestedAt: now, signature: Uint8List(64)),
      principals: const ['deploy'],
      extensions: certExtensions(const {}),
      ttlMinutes: 60,
      nowSeconds: now - 2400,
      keyId: 'old',
    );
    await (await t.alice.state(t.id)).write('certs.crate.${t.production}', base64Encode(old));
    final held = (await t.alice.service.heldCertificate(t.id, t.production))!;
    expect(held.dueAt(now), isTrue);
    expect(held.dueAt(held.validAfter + (held.validBefore - held.validAfter) ~/ 2 - 1), isFalse, reason: 'not before half');
    expect(server.certRequests, isEmpty);
    await t.alice.service.certificateRound(t.id);
    expect(server.certRequests, hasLength(1), reason: 'asked again');
    // Still usable meanwhile.
    expect(
        await t.alice.service.teamCertificateKey(t.id, t.production, userName: 'deploy', wait: Duration.zero), isNotNull);
    // Expired: not used, and asked for anew when connecting.
    final expired = issueTeamCertificate(
      ca: authority,
      request: CertRequest(
          id: 'gone', uid: _alice, keyVersion: 1, sshPublicKey: device.publicKey, requestedAt: now, signature: Uint8List(64)),
      principals: const ['deploy'],
      extensions: certExtensions(const {}),
      ttlMinutes: 60,
      nowSeconds: now - 7200,
      keyId: 'gone',
    );
    await (await t.alice.state(t.id)).write('certs.crate.${t.production}', base64Encode(expired));
    expect(await t.alice.service.heldCertificate(t.id, t.production), isNull);
  });

  test("another owner's device gets the authority's key with the key Crate's sync, and signs with it", () async {
    final t = await team();
    final owner2 = device(_owner2);
    await join(t.owner, owner2, t.id, FixedRoles.owner);
    await t.alice.service.askForCertificate(t.id, t.production);
    expect(await owner2.service.authorityKey(t.id, t.production), isNull);
    expect(await owner2.service.signWaitingCertificates(t.id), 0, reason: 'no key on this device yet');
    expect(server.signAttempts, isEmpty);

    OrchardSyncCoordinator coordinator(_Device d) =>
        OrchardSyncCoordinator(service: d.service, server: d.server, databases: d.service.databases);
    // The first owner's device sends the key; the second's takes it in, and
    // its round after the sync signs what waits.
    await coordinator(t.owner).syncOne(t.id);
    expect(server.signAttempts, hasLength(1), reason: "the first owner's own round signed");
    server.certRequests.clear();
    server.signAttempts.clear();
    server.certificatesSigned.clear();
    await (await t.alice.state(t.id)).removeWithPrefix('certs.asked.');
    await t.alice.service.askForCertificate(t.id, t.production);
    await coordinator(owner2).syncOne(t.id);
    expect(await owner2.service.authorityKey(t.id, t.production), isNotNull);
    expect(server.certificatesSigned.single.by, _owner2);
    // Alice's round takes it in.
    await coordinator(t.alice).syncOne(t.id);
    expect(await t.alice.service.heldCertificate(t.id, t.production), isNotNull);
  });

  test('a team certificate key: the terminal asks and waits, the monitor uses only what is here', () async {
    final t = await team();
    final db = await t.alice.service.databases.open(t.id);
    const keyId = 'team-cert-key';
    // As the sync engine leaves them from an owner's device, in Production:
    // a key naming deploy, holding nothing secret, and a host using it.
    Future<void> asSynced(Future<void> Function() write) async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await write();
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    }

    await asSynced(() async {
      await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
          id: keyId, label: 'Deploy', username: 'deploy', authMethod: kTeamCertificateAuth, createdAt: DateTime(2026, 9, 25)));
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1',
          label: 'web-1',
          host: '10.0.0.1',
          identityId: const Value(keyId),
          createdAt: DateTime(2026, 9, 25),
          updatedAt: DateTime(2026, 9, 25)));
      await db.customStatement(
          'INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES '
          "('key', ?, ?, 1), ('host', 'h1', ?, 1)",
          [keyId, t.production, t.production]);
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      identitiesDaoProvider.overrideWithValue(db.identitiesDao),
      orchardServiceProvider.overrideWithValue(t.alice.service),
    ]);
    addTearDown(container.dispose);
    final host = (await (db.select(db.connections)..where((c) => c.id.equals('h1'))).get()).single;
    final identity = (await db.identitiesDao.getById(keyId))!;

    // Nothing here yet: the monitor skips the host and asks nothing.
    final factory = container.read(sshConnectionFactoryProvider);
    expect(await factory.resolveCredentialsSilently(host), isNull);
    expect(server.certRequests, isEmpty);
    // The terminal asks, and says what it waits for.
    final l10n = lookupAppLocalizations(const Locale('en'));
    try {
      await teamCertificateLogin(t.alice.service, db, identity, wait: Duration.zero);
      fail('no owner signed yet');
    } on TeamCertificateUnavailable catch (e) {
      expect(teamCertificateMessage(l10n, e, 'deploy'), l10n.teamCertWaitingForOwner);
    }
    expect(server.certRequests, hasLength(1));
    await t.owner.service.signWaitingCertificates(t.id);
    final pair = await teamCertificateLogin(t.alice.service, db, identity, wait: Duration.zero);
    expect((pair as SshCertificateKeyPair).certificate.principals, ['deploy']);
    // Now the monitor has one.
    final creds = (await factory.resolveCredentialsSilently(host))!;
    expect(creds.username, 'deploy');
    expect(creds.password, isNull);
    expect(creds.keyPairs!.single, isA<SshCertificateKeyPair>());

    // A key naming a user name alice's role does not have: said so, with the ones it has.
    await asSynced(() =>
        (db.update(db.identities)..where((i) => i.id.equals(keyId))).write(const IdentitiesCompanion(username: Value('root'))));
    try {
      await teamCertificateLogin(t.alice.service, db, (await db.identitiesDao.getById(keyId))!, wait: Duration.zero);
      fail('root is not for this role');
    } on TeamCertificateUnavailable catch (e) {
      expect(teamCertificateMessage(l10n, e, 'root'), l10n.teamCertNotThisUserName('root', 'deploy'));
    }
    expect(await factory.resolveCredentialsSilently(host), isNull);
    // A key in a Crate with no authority.
    await asSynced(() => db.customStatement(
        "UPDATE crate_items_meta SET crate_id = ? WHERE kind = 'key' AND item_key = ?", [t.vault, keyId]));
    try {
      await teamCertificateLogin(t.alice.service, db, identity, wait: Duration.zero);
      fail('no authority there');
    } on TeamCertificateUnavailable catch (e) {
      expect(teamCertificateMessage(l10n, e, 'deploy'), l10n.teamCertNoAuthority);
    }
  });

  test('a login that gets no certificate is told why in the app\'s own words, with the Crate an owner can sign for',
      () async {
    final t = await team();
    final l10n = lookupAppLocalizations(const Locale('en'));
    L10nGlobal.update(l10n);
    final db = await t.alice.service.databases.open(t.id);
    const keyId = 'team-cert-key';
    Future<void> asSynced(Future<void> Function() write) async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await write();
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    }

    await asSynced(() async {
      await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
          id: keyId, label: 'Deploy', username: 'deploy', authMethod: kTeamCertificateAuth, createdAt: DateTime(2026, 9, 25)));
      await db.customStatement(
          "INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('key', ?, ?, 1)",
          [keyId, t.production]);
    });
    Future<Identity> identity() async => (await db.identitiesDao.getById(keyId))!;
    final lines = <String>[];
    Future<SSHAuthFailedException> failed() async {
      lines.clear();
      try {
        await teamCertificateSignIn(t.alice.service, db, await identity(), onLog: lines.add);
      } on SSHAuthFailedException catch (e) {
        return e;
      }
      fail('it got a certificate');
    }

    // The server is away, and the app knows: nothing asked, and an owner can sign one directly.
    server.down = true;
    t.alice.away = true;
    var said = await failed();
    expect(said.message, '${l10n.teamCertNotAsked} (ZS-1502)');
    expect(said.handover, (orchardId: t.id, crateId: t.production));
    expect(lines.last, startsWith('identity: ERROR getting a team certificate'));
    // The server is away, and the app does not know yet: the same.
    t.alice.away = false;
    said = await failed();
    expect(said.message, '${l10n.teamCertNotAsked} (ZS-1502)');
    expect(said.handover, (orchardId: t.id, crateId: t.production));

    // A user name the role does not sign in as: said as that, and nothing an owner could sign.
    server.down = false;
    await asSynced(() =>
        (db.update(db.identities)..where((i) => i.id.equals(keyId))).write(const IdentitiesCompanion(username: Value('root'))));
    said = await failed();
    expect(said.message, l10n.teamCertNotThisUserName('root', 'deploy'));
    expect(said.handover, isNull);
    expect(lines.last, 'identity: No team certificate (notThisUserName)');
    await asSynced(() =>
        (db.update(db.identities)..where((i) => i.id.equals(keyId))).write(const IdentitiesCompanion(username: Value('deploy'))));

    // The server turns this device away: said as that, and nothing offered.
    server.fault = 403;
    said = await failed();
    expect(said.message, l10n.teamCertHeldBack);
    expect(said.handover, isNull);
    server.fault = null;

    // A certificate on the device: it connects, and nothing is thrown.
    await t.alice.service.askForCertificate(t.id, t.production);
    expect(await t.owner.service.signWaitingCertificates(t.id), 1);
    final pair = await teamCertificateSignIn(t.alice.service, db, await identity(), onLog: lines.add);
    expect((pair as SshCertificateKeyPair).certificate.principals, ['deploy']);
  });

  test('a login whose request waits for an owner is told so, with its code and the Crate', () async {
    final t = await team();
    final l10n = lookupAppLocalizations(const Locale('en'));
    L10nGlobal.update(l10n);
    final db = await t.alice.service.databases.open(t.id);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
        id: 'k', label: 'Deploy', username: 'deploy', authMethod: kTeamCertificateAuth, createdAt: DateTime(2026, 9, 25)));
    await db.customStatement(
        "INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('key', 'k', ?, 1)",
        [t.production]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    final key = (await db.identitiesDao.getById('k'))!;
    // (teamCertificateSignIn waits the login's twenty seconds for an owner;
    // what it does with the wait running out is the same as here.)
    try {
      await teamCertificateLogin(t.alice.service, db, key, wait: Duration.zero);
      fail('no owner signed');
    } catch (e) {
      final failed = await teamCertificateFailure(l10n, e, db, key);
      expect(failed.message, '${l10n.teamCertWaitingForOwner} ${l10n.teamCertOwnerCanHand} (ZS-1501)');
      expect(failed.handover, (orchardId: t.id, crateId: t.production));
    }
    expect(server.certRequests, hasLength(1));
  });

  test('someone who held the authority\'s key leaving means a new key; a new key clears it', () async {
    final t = await team();
    final owner2 = device(_owner2);
    await join(t.owner, owner2, t.id, FixedRoles.owner);
    Future<Set<String>> due() => authoritiesNeedingNewKey(t.id, server.entriesOf(t.id));
    expect(await due(), isEmpty);
    // Members who never reached the key's Crate come and go: nothing.
    await t.owner.service.suspendMember(t.id, _bob);
    expect(await due(), isEmpty);
    // An owner (who could open Owner keys) stepping down to admin, who cannot.
    await owner2.service.stepDown(t.id);
    expect(await due(), {t.production});
    // Back as an owner changes nothing: they held it meanwhile.
    await t.owner.service.makeOwner(t.id, _owner2);
    expect(await due(), {t.production});
    // A new key clears it; a policy change does not count as one.
    await t.owner.service.changeAuthority(t.id, t.production, ttlMinutes: 480, principals: {
      t.member: ['deploy'],
    });
    expect(await due(), {t.production});
    await t.owner.service.setAuthorityKey(t.id, t.production,
        keyCrate: t.vault, ttlMinutes: 480, principals: {t.member: ['deploy']}, keyLabel: 'Production authority 2');
    expect(await due(), isEmpty);
    // An owner who holds it leaving: due again.
    await owner2.service.refresh();
    await owner2.service.leaveOrchard(t.id);
    expect(await due(), {t.production});
  });

  test('only owners set up an authority, and only with its key in a Crate only owners open', () async {
    final t = await team();
    await expectLater(
      t.alice.service.setAuthorityKey(t.id, t.production,
          keyCrate: t.vault, ttlMinutes: 60, principals: {t.member: ['deploy']}, keyLabel: 'mine'),
      throwsA(anything),
    );
    await expectLater(
      t.owner.service.setAuthorityKey(t.id, t.production,
          keyCrate: t.production, ttlMinutes: 60, principals: {t.member: ['deploy']}, keyLabel: 'here'),
      throwsA(anything),
    );
    // Nothing left behind by a refused set up.
    final rows = await (await t.owner.service.databases.open(t.id))
        .customSelect("SELECT label FROM identities WHERE label = 'here'")
        .get();
    expect(rows, isEmpty);
    await expectLater(
      t.owner.service.setAuthorityKey(t.id, t.production,
          keyCrate: t.vault, ttlMinutes: 60, principals: const {}, keyLabel: 'nobody'),
      throwsA(isA<OrchardRecordRefused>()),
    );
  });
}
