import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync/sync_manifest.dart';
import 'package:zestssh/services/sync_service.dart' show SyncException;

Uint8List _b(List<int> xs) => Uint8List.fromList(xs);

void main() {
  group('SyncManifest round-trip', () {
    test('preserves every field', () {
      final m = SyncManifest(
        version: 7,
        updatedAt: DateTime.utc(2026, 8, 4, 12, 30, 0),
        deviceId: 'windows_abc123',
        salt: _b(List.generate(32, (i) => i)),
        argon2Params: const {
          'version': 1,
          'memory': 65536,
          'iterations': 3,
          'parallelism': 4,
        },
        encryptedData: _b(List.generate(120, (i) => (i * 7) % 256)),
        passwordHash: _b(List.generate(32, (i) => 255 - i)),
        wrappedDekPassword: _b(List.generate(60, (i) => i)),
        wrappedDekRecovery: _b(List.generate(60, (i) => 60 - i)),
        recoverySalt: _b(List.generate(32, (i) => i * 2 % 256)),
        recoveryHash: _b(List.generate(32, (i) => i * 3 % 256)),
      );

      final parsed = SyncManifest.fromBytes(m.toBytes());

      expect(parsed.version, 7);
      expect(parsed.updatedAt.toUtc(), m.updatedAt);
      expect(parsed.deviceId, 'windows_abc123');
      expect(parsed.salt, m.salt);
      expect(parsed.argon2Params['memory'], 65536);
      expect(parsed.encryptedData, m.encryptedData);
      expect(parsed.passwordHash, m.passwordHash);
      expect(parsed.wrappedDekPassword, m.wrappedDekPassword);
      expect(parsed.wrappedDekRecovery, m.wrappedDekRecovery);
      expect(parsed.recoverySalt, m.recoverySalt);
      expect(parsed.recoveryHash, m.recoveryHash);
    });

    test('minimal manifest leaves optional fields null', () {
      final m = SyncManifest(
        version: 1,
        updatedAt: DateTime.utc(2026, 1, 1),
        salt: _b(List.filled(32, 9)),
        argon2Params: const {'memory': 65536},
        encryptedData: _b(List.filled(80, 1)),
      );
      final parsed = SyncManifest.fromBytes(m.toBytes());
      expect(parsed.wrappedDekPassword, isNull);
      expect(parsed.wrappedDekRecovery, isNull);
      expect(parsed.recoverySalt, isNull);
      expect(parsed.recoveryHash, isNull);
      expect(parsed.passwordHash, isNull);
    });
  });

  group('SyncManifest.fromBytes rejects hostile input (never a raw crash)', () {
    Uint8List bytesOf(Object json) =>
        Uint8List.fromList(utf8.encode(jsonEncode(json)));

    test('non-JSON garbage', () {
      expect(
        () => SyncManifest.fromBytes(_b([0xFF, 0x00, 0x13, 0x37])),
        throwsA(isA<SyncException>()),
      );
    });

    test('JSON that is not an object', () {
      expect(
        () => SyncManifest.fromBytes(bytesOf([1, 2, 3])),
        throwsA(isA<SyncException>()),
      );
    });

    test('wrong app marker', () {
      expect(
        () => SyncManifest.fromBytes(bytesOf({
          'app': 'not-zestssh',
          'salt': base64Encode(_b(List.filled(32, 0))),
          'encrypted_data': base64Encode(_b(List.filled(80, 0))),
        })),
        throwsA(isA<SyncException>()),
      );
    });

    test('missing required fields', () {
      expect(
        () => SyncManifest.fromBytes(bytesOf({'app': 'zestssh', 'version': 1})),
        throwsA(isA<SyncException>()),
      );
    });

    test('invalid base64 in a required field', () {
      expect(
        () => SyncManifest.fromBytes(bytesOf({
          'app': 'zestssh',
          'salt': 'not!!base64!!',
          'encrypted_data': base64Encode(_b(List.filled(80, 0))),
        })),
        throwsA(isA<SyncException>()),
      );
    });

    test('newer manifest_version is refused', () {
      expect(
        () => SyncManifest.fromBytes(bytesOf({
          'app': 'zestssh',
          'manifest_version': 999,
          'salt': base64Encode(_b(List.filled(32, 0))),
          'encrypted_data': base64Encode(_b(List.filled(80, 0))),
        })),
        throwsA(isA<SyncException>()),
      );
    });

    test('a required field with the wrong JSON type', () {
      expect(
        () => SyncManifest.fromBytes(bytesOf({
          'app': 'zestssh',
          'salt': 12345, // not a string
          'encrypted_data': base64Encode(_b(List.filled(80, 0))),
        })),
        throwsA(isA<SyncException>()),
      );
    });
  });
}
