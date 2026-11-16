import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';

/// LIVE end-to-end validation of the S3 backend (real AWS SigV4 signing over
/// real HTTP) against a running S3-compatible store. This is the authoritative
/// check that the hand-rolled SigV4 signature is accepted by a real server -
/// the thing the pure-Dart unit tests can't prove.
///
/// Start the local stack first:
///   docker compose -f docker/sync-test/docker-compose.yml up -d
///
/// Then run:
///   RUN_S3_LIVE=1 flutter test test/services/sync/s3_live_integration_test.dart
///
/// Override the target with ZEST_S3_ENDPOINT / _REGION / _BUCKET / _KEY /
/// _SECRET env vars to point at R2, B2, etc.
void main() {
  final env = Platform.environment;
  final skipReason = env['RUN_S3_LIVE'] == '1'
      ? null
      : 'set RUN_S3_LIVE=1 and start docker/sync-test to run the live S3 test';

  S3SyncBackend backend() => S3SyncBackend(
        endpoint: env['ZEST_S3_ENDPOINT'] ?? 'http://localhost:9000',
        region: env['ZEST_S3_REGION'] ?? 'us-east-1',
        bucket: env['ZEST_S3_BUCKET'] ?? 'zestssh-sync',
        accessKeyId: env['ZEST_S3_KEY'] ?? 'zestadmin',
        secretAccessKey: env['ZEST_S3_SECRET'] ?? 'zestadmin123',
        prefix: 'zestssh-livetest/',
        usePathStyle: true,
      );

  group('S3 live round-trip', () {
    const fast = {'memory': 19456, 'iterations': 2, 'parallelism': 1};
    final payload = {
      'connections': [
        {'id': 'live1', 'host': 'test.example', 'port': 22}
      ],
    };

    setUp(() async {
      if (skipReason != null) return; // don't touch the network on skipped runs
      // Start from a clean slate.
      try {
        await backend().purge(SyncService.generateSalt());
      } catch (_) {}
    });

    tearDownAll(() async {
      if (skipReason != null) return;
      try {
        await backend().purge(SyncService.generateSalt());
      } catch (_) {}
    });

    test('checkConnection succeeds (SigV4 accepted)', () async {
      await backend().checkConnection(); // throws on a bad signature
    }, skip: skipReason);

    test('push -> getStatus -> pull -> decrypt round-trips', () async {
      final b = backend();
      final salt = SyncService.generateSalt();
      final dek = SyncService.generateDek();
      final mek = await SyncService.deriveKey('pw', salt, params: fast);
      final verHash = await SyncService.computeVerificationHash(mek);
      final wrappedPw = await SyncService.wrapDek(dek, mek);

      final res = await b.push(
        data: payload,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: wrappedPw,
        createOnly: true,
      );
      expect(res.version, 1);

      final status = await b.getStatus();
      expect(status.hasData, isTrue);
      expect(status.version, 1);

      final pull = await b.pull();
      final decrypted = await SyncService.decrypt(pull.encryptedData, dek);
      expect((decrypted['connections'] as List).first['id'], 'live1');

      // verifyPassword works against the real object.
      expect(await b.verifyPassword(mek), isTrue);
      final wrongMek = await SyncService.deriveKey('nope', salt, params: fast);
      expect(await b.verifyPassword(wrongMek), isFalse);
    }, skip: skipReason);

    test('If-None-Match create-race is enforced by the server', () async {
      final b = backend();
      final salt = SyncService.generateSalt();
      final dek = SyncService.generateDek();
      final mek = await SyncService.deriveKey('pw', salt, params: fast);
      final verHash = await SyncService.computeVerificationHash(mek);
      final wrappedPw = await SyncService.wrapDek(dek, mek);

      Future<void> create() => b.push(
            data: payload,
            dek: dek,
            salt: salt,
            verificationHash: verHash,
            wrappedDekPassword: wrappedPw,
            createOnly: true,
          );

      await create(); // first create wins
      // Second create must be rejected by MinIO's If-None-Match: * (proves the
      // server-side atomic CAS that closes the create-race).
      expect(create(), throwsA(isA<SyncConflictException>()));
    }, skip: skipReason);

    test('ETag If-Match CAS is enforced on versioned overwrite', () async {
      final b = backend();
      final salt = SyncService.generateSalt();
      final dek = SyncService.generateDek();
      final mek = await SyncService.deriveKey('pw', salt, params: fast);
      final verHash = await SyncService.computeVerificationHash(mek);
      final wrappedPw = await SyncService.wrapDek(dek, mek);

      await b.push(
        data: payload,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: wrappedPw,
        createOnly: true,
      ); // v1

      // Pushing against a stale version must conflict (server is at v1, not v0).
      expect(
        b.push(
          data: payload,
          dek: dek,
          salt: salt,
          verificationHash: verHash,
          expectedVersion: 0,
        ),
        throwsA(isA<SyncConflictException>()),
      );

      // Correct version advances.
      final ok = await b.push(
        data: payload,
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        expectedVersion: 1,
      );
      expect(ok.version, 2);
    }, skip: skipReason);
  });
}
