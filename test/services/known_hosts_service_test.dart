import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';

/// Security intent of these tests:
///
/// `KnownHostsService.verify` is ZestSSH's core defence against SSH
/// man-in-the-middle attacks. It implements Trust-On-First-Use (TOFU):
/// the first host key seen is remembered, and any later deviation -
/// a changed fingerprint OR a swapped key TYPE - must surface as
/// `changed` so the user is warned rather than silently connecting to
/// an attacker who has interposed their own key. These tests pin that
/// contract, including the delicate legacy-MD5 upgrade path which must
/// upgrade genuine same-host records without opening a re-TOFU window
/// that a MITM could exploit.

/// Build a well-formed OpenSSH ssh-ed25519 public-key blob:
///   string "ssh-ed25519"  ||  string <32-byte public key>
/// This is what a real handshake hands `verify` as `hostKey.bytes`.
/// The exact bytes only matter in that distinct keys must produce
/// distinct SHA-256 fingerprints (which they do - the blob embeds the
/// public key material).
Uint8List _ed25519Blob(List<int> publicKey) {
  final buf = BytesBuilder();
  void writeString(List<int> bytes) {
    buf.add([
      (bytes.length >> 24) & 0xFF,
      (bytes.length >> 16) & 0xFF,
      (bytes.length >> 8) & 0xFF,
      bytes.length & 0xFF,
    ]);
    buf.add(bytes);
  }

  writeString(utf8.encode('ssh-ed25519'));
  writeString(publicKey);
  return buf.toBytes();
}

/// Build an ssh-rsa-flavoured blob (only the type string differs); used
/// to exercise the key-TYPE-change branch.
Uint8List _rsaBlob(List<int> publicKey) {
  final buf = BytesBuilder();
  void writeString(List<int> bytes) {
    buf.add([
      (bytes.length >> 24) & 0xFF,
      (bytes.length >> 16) & 0xFF,
      (bytes.length >> 8) & 0xFF,
      bytes.length & 0xFF,
    ]);
    buf.add(bytes);
  }

  writeString(utf8.encode('ssh-rsa'));
  writeString(publicKey);
  return buf.toBytes();
}

/// A deterministic 32-byte "public key" seeded by [seed] so different
/// seeds yield genuinely different key material.
List<int> _pub(int seed) => List<int>.generate(32, (i) => (i * 7 + seed) & 0xFF);

void main() {
  late AppDatabase db;
  late KnownHostsService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = KnownHostsService(db.knownHostsDao);
  });

  tearDown(() async {
    await db.close();
  });

  const host = 'example.com';
  const port = 22;

  test('unknown host+port+keytype is treated as a new host (TOFU prompt)',
      () async {
    final key = SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(1)));

    final result = await service.verify(host, port, key);

    // Nothing stored yet: neither the exact key nor any other key type
    // exists for this host, so the user must be asked to trust it.
    expect(result.result, HostKeyVerifyResult.newHost);
  });

  test('re-presenting the exact stored key returns trusted', () async {
    final key = SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(1)));

    // Trust the key (writes the real blob + SHA-256 fingerprint).
    await service.trustHost(host, port, key);

    final result = await service.verify(host, port, key);
    expect(result.result, HostKeyVerifyResult.trusted);
  });

  test('a different key blob for the same host+port+type is changed (MITM)',
      () async {
    final trusted =
        SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(1)));
    final imposter =
        SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(2)));

    await service.trustHost(host, port, trusted);

    // Same host/port/type but a different fingerprint => key change.
    final result = await service.verify(host, port, imposter);
    expect(result.result, HostKeyVerifyResult.changed);
  });

  test('a different key TYPE for a known host+port is changed '
      '(type-swap MITM cannot bypass a type-scoped lookup)', () async {
    final ed = SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(1)));
    final rsa = SSHHostKey(type: 'ssh-rsa', bytes: _rsaBlob(_pub(3)));

    await service.trustHost(host, port, ed);

    // No stored ssh-rsa record exists, but the host IS known with a
    // different type - findHostAnyKeyType must catch this as a change.
    final result = await service.verify(host, port, rsa);
    expect(result.result, HostKeyVerifyResult.changed);
  });

  // Found in a security review: a restored backup,
  // or sync, can bring a key of another type for a host this device trusts.
  group('a key that only came from elsewhere', () {
    // As a sync or a restore adopts it: recorded on another device, not yet
    // matched on this one.
    Future<void> adopted(SSHHostKey key, {String? via}) => db.knownHostsDao.upsertHost(KnownHostsCompanion(
          id: Value('adopted-${key.type}-$via'),
          host: const Value(host),
          port: const Value(port),
          keyType: Value(key.type),
          fingerprint: Value(OpenSSHKeySerializer.fingerprintFromBlob(key.bytes)),
          publicKeyBase64: Value(base64Encode(key.bytes)),
          firstSeen: Value(DateTime.utc(2026, 8, 14)),
          lastSeen: Value(DateTime.utc(2026, 8, 14)),
          recordedDevice: const Value('ANOTHER-PC'),
          locallyVerified: const Value(false),
          viaScope: Value(via),
        ));

    final ed = SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(1)));
    final planted = SSHHostKey(type: 'ssh-rsa', bytes: _rsaBlob(_pub(9)));

    test('of another type, for a host this device confirmed itself: changed, as if it had not come', () async {
      await service.trustHost(host, port, ed);
      await adopted(planted);

      final result = await service.verify(host, port, planted);
      expect(result.result, HostKeyVerifyResult.changed);
      // The warning shows the key this device confirmed as the one expected,
      // not the received key itself.
      final expected = await service.trustedKeyInfo(host, port, planted.type);
      expect(expected!.fingerprint, OpenSSHKeySerializer.fingerprintFromBlob(ed.bytes));
    });

    test('accepted at that warning, it is trusted from then on, not asked about again', () async {
      await service.trustHost(host, port, ed);
      await adopted(planted);
      expect((await service.verify(host, port, planted)).result, HostKeyVerifyResult.changed);

      await service.trustHost(host, port, planted); // what accepting the warning does
      expect((await service.verify(host, port, planted)).result, HostKeyVerifyResult.trusted);
      final row = await db.knownHostsDao.findHost(host, port, planted.type);
      expect(row!.locallyVerified, isTrue);
      expect(row.recordedDevice, isNot('ANOTHER-PC'), reason: 'accepted here, so recorded here');
    });

    // Found in a review: the rule holds across routes.
    test('for the same host reached through a jump host, while this device confirmed it directly: changed', () async {
      const via = 'jump.example.com:22';
      await service.trustHost(host, port, ed);
      await adopted(planted, via: via);
      expect((await service.verify(host, port, planted, viaScope: via)).result, HostKeyVerifyResult.changed);
      // Of the same type too: a key this device did not confirm.
      final other = SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(7)));
      await adopted(other, via: via);
      expect((await service.verify(host, port, other, viaScope: via)).result, HostKeyVerifyResult.changed);
    });

    test('the very key this device confirmed directly, synced for a jump route: trusted', () async {
      const via = 'jump.example.com:22';
      await service.trustHost(host, port, ed);
      await adopted(ed, via: via);
      expect((await service.verify(host, port, ed, viaScope: via)).result, HostKeyVerifyResult.trusted);
    });

    // Found in a second review: a planted row in
    // the legacy MD5 form skipped the rule, was trusted and marked confirmed.
    test('in the legacy MD5 form, of another type, for a host this device confirmed: changed, not upgraded', () async {
      await service.trustHost(host, port, ed);
      await db.knownHostsDao.upsertHost(KnownHostsCompanion(
        id: const Value('planted-md5'),
        host: const Value(host),
        port: const Value(port),
        keyType: Value(planted.type),
        fingerprint: const Value('SHA256:legacy-placeholder'),
        publicKeyBase64: Value(base64Encode(md5.convert(planted.bytes).bytes)),
        firstSeen: Value(DateTime.utc(2026, 8, 14)),
        lastSeen: Value(DateTime.utc(2026, 8, 14)),
        recordedDevice: const Value('ANOTHER-PC'),
        locallyVerified: const Value(false),
      ));
      expect((await service.verify(host, port, planted)).result, HostKeyVerifyResult.changed);
      final row = await db.knownHostsDao.findHost(host, port, planted.type);
      expect(row!.locallyVerified, isFalse, reason: 'not marked confirmed here');
      expect(row.publicKeyBase64.length, lessThan(30), reason: 'not upgraded to the presented key');
    });

    // The same, sharpened in a third review: a crafted
    // backup plants the server's real key (anyone gets it with ssh-keyscan)
    // beside an MD5 row of another type for the attacker's key.
    group('the real key and an MD5 row of another type, both planted', () {
      final real = SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(31)));
      final mitm = SSHHostKey(type: 'ssh-rsa', bytes: _rsaBlob(_pub(32)));

      Future<void> plant() async {
        await adopted(real);
        await db.knownHostsDao.upsertHost(KnownHostsCompanion(
          id: const Value('planted-md5'),
          host: const Value(host),
          port: const Value(port),
          keyType: Value(mitm.type),
          fingerprint: const Value('SHA256:legacy-placeholder'),
          publicKeyBase64: Value(base64Encode(md5.convert(mitm.bytes).bytes)),
          firstSeen: Value(DateTime.utc(2026, 8, 14)),
          lastSeen: Value(DateTime.utc(2026, 8, 14)),
          recordedDevice: const Value('ANOTHER-PC'),
          locallyVerified: const Value(false),
        ));
      }

      test('the real server first: trusted with its notice; the other type afterwards is a change', () async {
        await plant();
        final first = await service.verify(host, port, real);
        expect(first.result, HostKeyVerifyResult.trusted);
        expect(first.adoptedFrom?.device, 'ANOTHER-PC');
        expect((await service.verify(host, port, mitm)).result, HostKeyVerifyResult.changed);
      });

      test('the man in the middle first: an MD5 row that came from elsewhere is never upgraded unasked', () async {
        await plant();
        expect((await service.verify(host, port, mitm)).result, HostKeyVerifyResult.newHost,
            reason: 'asked as a key never seen here, not trusted with no notice');
        final row = await db.knownHostsDao.findHost(host, port, mitm.type);
        expect(row!.locallyVerified, isFalse);
        expect(row.publicKeyBase64.length, lessThan(30), reason: 'not upgraded to the presented key');
      });

      test('an MD5 row this device confirmed itself (before the fix) is still upgraded in place', () async {
        await db.knownHostsDao.upsertHost(KnownHostsCompanion(
          id: const Value('mine-md5'),
          host: const Value(host),
          port: const Value(port),
          keyType: Value(mitm.type),
          fingerprint: const Value('SHA256:legacy-placeholder'),
          publicKeyBase64: Value(base64Encode(md5.convert(mitm.bytes).bytes)),
          firstSeen: Value(DateTime.utc(2025, 1, 1)),
          lastSeen: Value(DateTime.utc(2025, 1, 1)),
          locallyVerified: const Value(true),
        ));
        expect((await service.verify(host, port, mitm)).result, HostKeyVerifyResult.trusted);
        expect((await db.knownHostsDao.findHost(host, port, mitm.type))!.publicKeyBase64, base64Encode(mitm.bytes));
      });
    });

    test('for a host this device has not confirmed under any type: trusted, its provenance shown once', () async {
      final synced = SSHHostKey(type: 'ssh-rsa', bytes: _rsaBlob(_pub(5)));
      await adopted(synced);

      final first = await service.verify(host, port, synced);
      expect(first.result, HostKeyVerifyResult.trusted);
      expect(first.adoptedFrom?.device, 'ANOTHER-PC');

      final again = await service.verify(host, port, synced);
      expect(again.result, HostKeyVerifyResult.trusted);
      expect(again.adoptedFrom, isNull, reason: 'matched here once, so confirmed here');
      expect((await db.knownHostsDao.findHost(host, port, synced.type))!.locallyVerified, isTrue);
    });

    test('a check with nobody to tell (the Server Monitor, the Test, an automation run) trusts it and leaves the '
        'notice for the first session a person opens', () async {
      final synced = SSHHostKey(type: 'ssh-rsa', bytes: _rsaBlob(_pub(5)));
      await adopted(synced);

      for (var i = 0; i < 3; i++) {
        final headless = await service.verify(host, port, synced, tellsPerson: false);
        expect(headless.result, HostKeyVerifyResult.trusted);
        expect((await db.knownHostsDao.findHost(host, port, synced.type))!.locallyVerified, isFalse,
            reason: 'not confirmed here by a check nobody saw');
      }

      final session = await service.verify(host, port, synced);
      expect(session.result, HostKeyVerifyResult.trusted);
      expect(session.adoptedFrom?.device, 'ANOTHER-PC', reason: 'the person is told, the first time they open it');
      expect((await db.knownHostsDao.findHost(host, port, synced.type))!.locallyVerified, isTrue);

      final after = await service.verify(host, port, synced, tellsPerson: false);
      expect(after.result, HostKeyVerifyResult.trusted);
      expect((await db.knownHostsDao.findHost(host, port, synced.type))!.locallyVerified, isTrue);
    });

    test('a check with nobody to tell still confirms a key that has no other device to name', () async {
      final own = SSHHostKey(type: 'ssh-rsa', bytes: _rsaBlob(_pub(6)));
      await service.trustHost(host, port, own);
      final row = (await db.knownHostsDao.findHost(host, port, own.type))!;
      await db.knownHostsDao.upsertHost(row.toCompanion(true).copyWith(
            recordedDevice: const Value(null),
            locallyVerified: const Value(false),
          ));
      expect((await service.verify(host, port, own, tellsPerson: false)).result, HostKeyVerifyResult.trusted);
      expect((await db.knownHostsDao.findHost(host, port, own.type))!.locallyVerified, isTrue);
    });
  });

  group('legacy MD5 migration', () {
    /// Seed a pre-fix known_hosts row whose `publicKeyBase64` holds the
    /// 16-byte MD5 of [md5Source] rather than the real key blob. These
    /// records were written before the host-key fix and must be upgraded
    /// in place, never re-TOFU'd blindly.
    Future<void> seedLegacyMd5({
      required String keyType,
      required Uint8List md5Source,
    }) async {
      final md5Digest = md5.convert(md5Source).bytes;
      // Sanity: legacy records are exactly the 16-byte MD5.
      expect(md5Digest.length, 16);
      final now = DateTime.now();
      await db.into(db.knownHosts).insert(KnownHostsCompanion(
            id: Value('legacy-$host-$port-$keyType'),
            host: const Value(host),
            port: const Value(port),
            keyType: Value(keyType),
            fingerprint: const Value('SHA256:legacy-placeholder'),
            publicKeyBase64: Value(base64Encode(md5Digest)),
            firstSeen: Value(now),
            lastSeen: Value(now),
          ));
    }

    test(
        'a DIFFERENT key type against a legacy record is changed, '
        'not a silent re-TOFU', () async {
      // REGRESSION: the key-type-change check used to exempt legacy MD5
      // records (`anyKey != null && !_isLegacyMd5(...)`), which inverted the
      // guard exactly where it mattered. Against a host whose only stored
      // record was legacy, an attacker presenting a different key type
      // skipped the change check entirely and was reported as a brand-new
      // host - re-opening trust-on-first-use for a host the user had
      // already accepted. A legacy record cannot verify a different key
      // (its MD5 is of the OLD key), so "cannot verify" must fail closed.
      await seedLegacyMd5(keyType: 'ssh-rsa', md5Source: _rsaBlob(_pub(21)));

      final result = await service.verify(
        host,
        port,
        SSHHostKey(type: 'ssh-ed25519', bytes: _ed25519Blob(_pub(22))),
      );
      expect(result.result, HostKeyVerifyResult.changed);
    });

    test('matching MD5 upgrades the record losslessly and returns trusted',
        () async {
      final blob = _ed25519Blob(_pub(9));
      final key = SSHHostKey(type: 'ssh-ed25519', bytes: blob);

      // Legacy row stores MD5(blob) - the same host presenting the same key.
      await seedLegacyMd5(keyType: 'ssh-ed25519', md5Source: blob);

      final result = await service.verify(host, port, key);
      // Genuine same host: silent upgrade, no scary prompt.
      expect(result.result, HostKeyVerifyResult.trusted);

      // The stored record must now hold the REAL key blob, not the
      // 16-byte MD5 - i.e. the legacy marker is gone and a future
      // verify() compares full fingerprints.
      final stored = await db.knownHostsDao.findHost(host, port, 'ssh-ed25519');
      expect(stored, isNotNull);
      final decoded = base64Decode(stored!.publicKeyBase64);
      expect(decoded.length, isNot(16),
          reason: 'legacy 16-byte MD5 marker should be gone after upgrade');
      expect(decoded, equals(blob),
          reason: 'record should now store the full presented key blob');

      // And verifying again (now against the upgraded real blob) still
      // trusts - proving the upgrade wrote a consistent fingerprint.
      expect((await service.verify(host, port, key)).result, HostKeyVerifyResult.trusted);
    });

    test('non-matching MD5 on a legacy record is changed (real key change)',
        () async {
      final originalBlob = _ed25519Blob(_pub(9));
      final imposterBlob = _ed25519Blob(_pub(10));
      final imposter = SSHHostKey(type: 'ssh-ed25519', bytes: imposterBlob);

      // Legacy row stores MD5(originalBlob); a DIFFERENT key is presented.
      await seedLegacyMd5(keyType: 'ssh-ed25519', md5Source: originalBlob);

      final result = await service.verify(host, port, imposter);
      // MD5 mismatch during the upgrade window == possible MITM.
      expect(result.result, HostKeyVerifyResult.changed);

      // The legacy record must NOT be silently overwritten on a mismatch.
      final stored = await db.knownHostsDao.findHost(host, port, 'ssh-ed25519');
      expect(base64Decode(stored!.publicKeyBase64).length, 16,
          reason: 'a changed key must not upgrade/overwrite the legacy record');
    });
  });
}
