import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';

/// Certificates from a Crate's authority (3.0) against the REAL
/// server routes on a real Postgres: an owner gives Production an authority
/// whose key is kept in an owners-only Crate, a member's device asks with a
/// request its keys signed (the server checks the same bytes), the owner's
/// device signs a certificate the server's strict reader takes, and the
/// member's device takes it back; a new key and turning it off follow
/// through. Start the server:
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
    final uid = 'cert-$name-${now()}-${accounts++}';
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
    final d = _Device(storage, service, OrchardSyncCoordinator(service: service, server: server, databases: databases));
    devices.add(d);
    return d;
  }

  Matcher unavailable(TeamCertificateProblem problem) =>
      throwsA(isA<TeamCertificateUnavailable>().having((e) => e.problem, 'problem', problem));

  test('asked, signed and taken back through the real routes; a new key and off follow through', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final o = device(owner);
    final orchardId = await o.service.createOrchard('Certificates', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = (await o.service.server.orchards()).firstWhere((x) => x.id == orchardId).crates.single.id;
    final vault = await o.service.createCrate(orchardId, 'Owner keys', ownersOnly: true);
    final role = (await o.service.roles(orchardId)).single.id;
    await o.service.invite(orchardId, email: '${alice.uid}@example.com', role: role);
    final a = device(alice);
    await a.service.acceptInvite((await a.service.myInvites()).single.id);
    await o.service.confirmInvite(orchardId, (await o.service.invites(orchardId)).single);

    await o.service.setAuthorityKey(orchardId, production,
        keyCrate: vault,
        ttlMinutes: 60,
        principals: {
          role: ['deploy'],
          FixedRoles.owner: ['root'],
        },
        keyLabel: 'Production authority');
    // The authority's key goes to the owners-only Crate on the server.
    expect((await o.coordinator.syncAll())[orchardId]!.sent, greaterThanOrEqualTo(1));
    expect(await a.service.refresh(), contains(orchardId));

    // Alice's device asks; the server checks the request's signature over
    // the same bytes the app signed.
    await expectLater(
        a.service.teamCertificateKey(orchardId, production, userName: 'deploy', wait: Duration.zero),
        unavailable(TeamCertificateProblem.waitingForOwner));
    expect(await o.service.server.waitingCertificates(production), hasLength(1));
    // Members neither list nor sign.
    await expectLater(a.service.server.waitingCertificates(production),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'owners-only')));

    // The owner's device signs; the server's strict reader takes it.
    expect(await o.service.signWaitingCertificates(orchardId), 1);
    expect(await o.service.server.waitingCertificates(production), isEmpty);
    final pair = await a.service.teamCertificateKey(orchardId, production, userName: 'deploy', wait: Duration.zero)
        as SshCertificateKeyPair;
    expect(pair.certificate.principals, ['deploy']);
    expect(pair.certificate.keyId, contains('${alice.uid}@example.com'));

    // A new key: the old certificate stops counting, a round asks again, the
    // owner's round signs, and alice's round takes the new one.
    await o.service.setAuthorityKey(orchardId, production,
        keyCrate: vault,
        ttlMinutes: 480,
        principals: {
          role: ['deploy'],
        },
        keyLabel: 'Production authority 2');
    await a.service.refresh();
    expect(await a.service.heldCertificate(orchardId, production), isNull);
    await a.service.certificateRound(orchardId);
    expect(await o.service.server.waitingCertificates(production), hasLength(1));
    await o.coordinator.syncAll();
    expect(await o.service.server.waitingCertificates(production), isEmpty, reason: "the owner's round signed");
    await a.coordinator.syncAll();
    final held = (await a.service.heldCertificate(orchardId, production))!;
    expect(held.validBefore - held.validAfter, 480 * 60 + 300);

    // Off: nothing more is asked for, and the server takes no request.
    await o.service.turnAuthorityOff(orchardId, production);
    await a.service.refresh();
    await expectLater(
        a.service.teamCertificateKey(orchardId, production, userName: 'deploy', wait: Duration.zero),
        unavailable(TeamCertificateProblem.noAuthority));
    await expectLater(a.service.askForCertificate(orchardId, production),
        throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'no-authority')));
  });
}
