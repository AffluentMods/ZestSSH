import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';

/// Guards the v32 route-scoped host-key trust, especially the migration
/// compatibility: a pre-v32 pin (via_scope NULL) must be HONORED by a scoped
/// (jump-reached) connect - adopted into the route - instead of silently
/// re-TOFU'ing, while a DIFFERENT route to the same endpoint stays separate.
void main() {
  late AppDatabase db;
  late KnownHostsService svc;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    svc = KnownHostsService(db.knownHostsDao);
  });
  tearDown(() => db.close());

  final keyBytes = Uint8List.fromList(List<int>.generate(48, (i) => i + 1));
  final fp = OpenSSHKeySerializer.fingerprintFromBlob(keyBytes);
  final hostKey = SSHHostKey(type: 'ssh-ed25519', bytes: keyBytes);

  // A pre-v32 pinned key: via_scope NULL (route scoping didn't exist yet).
  Future<void> seedLegacyNullScopePin() async {
    await db.knownHostsDao.upsertHost(KnownHostsCompanion(
      id: const Value('kh1'),
      host: const Value('192.168.10.30'),
      port: const Value(22),
      keyType: const Value('ssh-ed25519'),
      fingerprint: Value(fp),
      publicKeyBase64: Value(base64Encode(keyBytes)),
      firstSeen: Value(DateTime.utc(2026)),
      lastSeen: Value(DateTime.utc(2026)),
      locallyVerified: const Value(true),
      viaScope: const Value(null),
    ));
  }

  test('a scoped (jump) connect ADOPTS a legacy NULL-scope pin -> trusted',
      () async {
    await seedLegacyNullScopePin();
    final outcome = await svc.verify('192.168.10.30', 22, hostKey,
        viaScope: 'jump-a.example.com:22');
    // The pre-v32 pin is honored, not re-TOFU'd.
    expect(outcome.result, HostKeyVerifyResult.trusted);
    // The row was adopted into the route...
    expect(
      await db.knownHostsDao.findHost('192.168.10.30', 22, 'ssh-ed25519',
          viaScope: 'jump-a.example.com:22'),
      isNotNull,
    );
    // ...and the NULL-scope row stays, for direct connections.
    expect(
      await db.knownHostsDao
          .findHost('192.168.10.30', 22, 'ssh-ed25519', viaScope: null),
      isNotNull,
    );
  });

  // A host trusted on a direct connection kept its pin only until it was
  // reached once through a jump host: the row moved to that route, and a man
  // in the middle on the next direct connection met "new host" instead of
  // "changed" (found in a security review).
  test('a direct pin stays after a connect through a jump host: a different key directly is changed', () async {
    final realKey = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => i + 1)));
    final attackerKey =
        SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => 250 - i)));
    expect((await svc.verify('db.example.com', 22, realKey)).result, HostKeyVerifyResult.newHost);
    await svc.trustHost('db.example.com', 22, realKey);

    expect((await svc.verify('db.example.com', 22, realKey, viaScope: 'bastion.example.com:22')).result,
        HostKeyVerifyResult.trusted,
        reason: 'the direct pin holds on the route too');

    expect((await svc.verify('db.example.com', 22, attackerKey)).result, HostKeyVerifyResult.changed);
    expect((await svc.verify('db.example.com', 22, realKey)).result, HostKeyVerifyResult.trusted);
    // And on the route, where it was copied.
    expect((await svc.verify('db.example.com', 22, attackerKey, viaScope: 'bastion.example.com:22')).result,
        HostKeyVerifyResult.changed);

    final rows = await db.knownHostsDao.getAll();
    expect(rows.map((r) => r.viaScope).toList()..sort((a, b) => (a ?? '').compareTo(b ?? '')),
        [null, 'bastion.example.com:22']);
    expect(rows.map((r) => r.id).toSet(), hasLength(2), reason: 'two records, each of its own');
    expect(rows.map((r) => r.fingerprint).toSet(), hasLength(1));
  });

  group('a direct pin an earlier app moved to a route', () {
    final realKey = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => i + 1)));
    final otherKey =
        SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => 250 - i)));

    // What an app up to 3.3 left: the host's one record, confirmed here, on
    // the route it was last reached through.
    Future<void> moved() => db.knownHostsDao.upsertHost(KnownHostsCompanion(
          id: const Value('kh-moved'),
          host: const Value('db.example.com'),
          port: const Value(22),
          keyType: const Value('ssh-ed25519'),
          fingerprint: Value(OpenSSHKeySerializer.fingerprintFromBlob(realKey.bytes)),
          publicKeyBase64: Value(base64Encode(realKey.bytes)),
          firstSeen: Value(DateTime.utc(2025)),
          lastSeen: Value(DateTime.utc(2026)),
          locallyVerified: const Value(true),
          viaScope: const Value('bastion.example.com:22'),
        ));

    // A route's row cannot tell a moved direct pin from another machine at
    // the same address, so the direct path asks once, as for a new host, and
    // what is trusted there is its own pin from then on.
    test('a direct connection asks about any key once as a new host, then holds what was trusted', () async {
      await moved();
      expect((await svc.verify('db.example.com', 22, otherKey)).result, HostKeyVerifyResult.newHost);
      expect((await svc.verify('db.example.com', 22, realKey)).result, HostKeyVerifyResult.newHost);
      expect(await db.knownHostsDao.findHost('db.example.com', 22, 'ssh-ed25519'), isNull,
          reason: 'nothing was trusted without being asked');
      expect(await svc.trustedKeyInfo('db.example.com', 22, 'ssh-ed25519'), isNull,
          reason: 'no key is shown as expected on the direct path');

      await svc.trustHost('db.example.com', 22, realKey);
      expect((await svc.verify('db.example.com', 22, realKey)).result, HostKeyVerifyResult.trusted);
      expect((await svc.verify('db.example.com', 22, otherKey)).result, HostKeyVerifyResult.changed);
      expect((await svc.verify('db.example.com', 22, otherKey, viaScope: 'bastion.example.com:22')).result,
          HostKeyVerifyResult.changed,
          reason: 'the route keeps its own pin');
    });
  });

  // Two machines at one private address on two networks: the office's
  // 192.168.1.50 behind its jump host and a Raspberry Pi at 192.168.1.50 at
  // home. For a day the direct connection counted the
  // route's key as its own and called the Pi's first connection a changed key.
  test('another machine at the same private address, reached directly for the first time, is a new host', () async {
    final officeKey = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => i + 1)));
    final homeKey = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => 200 - i)));
    const office = 'bastion.example.com:22';

    expect((await svc.verify('192.168.1.50', 22, officeKey, viaScope: office)).result, HostKeyVerifyResult.newHost);
    await svc.trustHost('192.168.1.50', 22, officeKey, viaScope: office);

    expect((await svc.verify('192.168.1.50', 22, homeKey)).result, HostKeyVerifyResult.newHost,
        reason: 'a first connection told as a changed key');
    expect(await svc.trustedKeyInfo('192.168.1.50', 22, 'ssh-ed25519'), isNull);
    await svc.trustHost('192.168.1.50', 22, homeKey);

    // Each keeps its own pin.
    expect((await svc.verify('192.168.1.50', 22, homeKey)).result, HostKeyVerifyResult.trusted);
    expect((await svc.verify('192.168.1.50', 22, officeKey, viaScope: office)).result, HostKeyVerifyResult.trusted);
    expect((await svc.verify('192.168.1.50', 22, officeKey)).result, HostKeyVerifyResult.changed);
    expect((await svc.verify('192.168.1.50', 22, homeKey, viaScope: office)).result, HostKeyVerifyResult.changed);
  });

  test('a DIFFERENT route to the same IP is a NEW host, not an inherited pin',
      () async {
    await seedLegacyNullScopePin();
    // Route A adopts the legacy pin.
    await svc.verify('192.168.10.30', 22, hostKey, viaScope: 'jump-a:22');
    // A different server at the same IP via a different jump presents a
    // different key -> must be newHost (separate trust), never a false changed.
    final otherKey = SSHHostKey(
        type: 'ssh-ed25519',
        bytes: Uint8List.fromList(List<int>.generate(48, (i) => 200 - i)));
    final outcome =
        await svc.verify('192.168.10.30', 22, otherKey, viaScope: 'jump-b:22');
    expect(outcome.result, HostKeyVerifyResult.newHost);
  });

  test('a direct connect still matches a legacy NULL-scope pin', () async {
    await seedLegacyNullScopePin();
    final outcome = await svc.verify('192.168.10.30', 22, hostKey);
    expect(outcome.result, HostKeyVerifyResult.trusted);
  });

  test('a scoped connect with a CHANGED key (adopted pin differs) -> changed',
      () async {
    await seedLegacyNullScopePin();
    // Same endpoint + route, but a different key than the pinned one.
    final changedKey = SSHHostKey(
        type: 'ssh-ed25519',
        bytes: Uint8List.fromList(List<int>.generate(48, (i) => 99 - i)));
    final outcome = await svc.verify('192.168.10.30', 22, changedKey,
        viaScope: 'jump-a:22');
    expect(outcome.result, HostKeyVerifyResult.changed);
  });
}
