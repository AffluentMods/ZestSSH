import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/secret_seal.dart';

/// Coverage for the v1.6 "unattended runs" security gate: a headless run
/// (scheduled workflow / deep link / API key) may only use a saved credential
/// when the user has explicitly opted that identity in to unattended runs.
void main() {
  // ── The gate decision (pure, exhaustive truth table) ────────────────
  group('AutomationService.unattendedBlocked', () {
    test('headless run against a NON-opted-in credential is BLOCKED', () {
      expect(
        AutomationService.unattendedBlocked(
            unattended: true, allowUnattended: false),
        isTrue,
      );
    });

    test('headless run against an OPTED-IN credential is allowed', () {
      expect(
        AutomationService.unattendedBlocked(
            unattended: true, allowUnattended: true),
        isFalse,
      );
    });

    test('interactive run is never blocked - opted-in', () {
      expect(
        AutomationService.unattendedBlocked(
            unattended: false, allowUnattended: true),
        isFalse,
      );
    });

    test('interactive run is never blocked - not opted-in', () {
      expect(
        AutomationService.unattendedBlocked(
            unattended: false, allowUnattended: false),
        isFalse,
      );
    });
  });

  // ── Wiring: executeCommand refuses a blocked run before any SSH ──────
  group('AutomationService.executeCommand unattended gate', () {
    late AppDatabase db;
    late AutomationService service;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      // The block path throws inside credential resolution BEFORE any secret is
      // read or any socket opened, so a real (never-invoked) secure-storage
      // instance is fine - no plugin call is made on this path.
      service = AutomationService(db, const FlutterSecureStorage());
    });

    tearDown(() async {
      await db.close();
    });

    Future<String> seed({required bool allowUnattended}) async {
      final now = DateTime.now();
      const identityId = 'id-1';
      await db.identitiesDao.insertIdentity(IdentitiesCompanion(
        id: const Value(identityId),
        label: const Value('prod-root'),
        username: const Value('root'),
        authMethod: const Value('password'),
        allowUnattended: Value(allowUnattended),
        createdAt: Value(now),
      ));
      const connId = 'conn-1';
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: const Value(connId),
        label: const Value('prod'),
        // TEST-NET-1 - guaranteed non-routable, so a regression that let the
        // run proceed past the gate would hang/fail rather than silently pass.
        host: const Value('192.0.2.1'),
        port: const Value(22),
        identityId: const Value(identityId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      return connId;
    }

    test(
        'an unattended run on a NON-opted-in credential is refused with '
        'needsCredentials - the gate fires before any SSH attempt', () async {
      final connId = await seed(allowUnattended: false);
      final result = await service.executeCommand(
        connectionId: connId,
        command: 'echo hi',
        unattended: true,
      );
      expect(result.success, isFalse);
      expect(result.needsCredentials, isTrue,
          reason: 'a blocked unattended run must be flagged, never silent');
    });
  });

  // ── What a run carries: only a password key its password (3.0) ──
  group('a run carries a password only for a password key', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() async => db.close());

    for (final (method, carries) in [
      ('password', true),
      ('hardwareToken', false),
      ('passwordManager', false),
      ('teamCertificate', false),
      ('publicKey', false),
    ]) {
      test('$method: ${carries ? 'its saved password' : 'never a stale saved password'}', () async {
        FlutterSecureStorage.setMockInitialValues({'identity_password_id-$method': 'stale-or-saved'});
        await db.identitiesDao.insertIdentity(IdentitiesCompanion(
          id: Value('id-$method'),
          label: const Value('k'),
          username: const Value('root'),
          authMethod: Value(method),
          allowUnattended: const Value(true),
          createdAt: Value(DateTime(2026)),
        ));
        final creds = await AutomationService(db, const FlutterSecureStorage()).loadCredentialsForTest('id-$method');
        expect(creds.password, carries ? 'stale-or-saved' : isNull);
        expect(creds.keyPairs, isNull);
      });
    }
  });

  // ── A key's own password, after the key (3.0, accounts per host) ──
  group('a key with a password saved with it as that carries it, after the key', () {
    late AppDatabase db;
    final pem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() async => db.close());

    Future<({String? password, bool keys})> carried(String method, {bool afterKey = true, bool withKey = true}) async {
      FlutterSecureStorage.setMockInitialValues({
        'identity_password_id-$method': 'saved-with-the-key',
        if (withKey) 'identity_key_id-$method': pem,
      });
      await db.identitiesDao.insertIdentity(IdentitiesCompanion(
        id: Value('id-$method'),
        label: const Value('k'),
        username: const Value('root'),
        authMethod: Value(method),
        allowUnattended: const Value(true),
        passwordAfterKey: Value(afterKey),
        createdAt: Value(DateTime(2026)),
      ));
      final creds = await AutomationService(db, const FlutterSecureStorage()).loadCredentialsForTest('id-$method');
      return (password: creds.password, keys: creds.keyPairs?.isNotEmpty ?? false);
    }

    test('with the encrypting lock on, the key and the password are opened where they are sealed (a run read them '
        'as kept)', () async {
      FlutterSecureStorage.setMockInitialValues({});
      await SecretSeal.setActive(db, true);
      final secrets = SecureStorageIdentitySecrets(const FlutterSecureStorage(), sealedBy: db);
      await secrets.write('id-sealed', IdentitySecret.privateKey, pem);
      await secrets.write('id-sealed', IdentitySecret.password, 'saved-with-the-key');
      expect(await const FlutterSecureStorage().read(key: 'identity_key_id-sealed'), startsWith(SecretSeal.prefix));
      await db.identitiesDao.insertIdentity(IdentitiesCompanion(
        id: const Value('id-sealed'),
        label: const Value('k'),
        username: const Value('root'),
        authMethod: const Value('publicKey'),
        allowUnattended: const Value(true),
        passwordAfterKey: const Value(true),
        createdAt: Value(DateTime(2026)),
      ));
      final creds = await AutomationService(db, const FlutterSecureStorage()).loadCredentialsForTest('id-sealed');
      expect(creds.password, 'saved-with-the-key');
      expect(creds.keyPairs, isNotEmpty);
    });

    test('a key and a certificate key: the key, and the password after it', () async {
      expect(await carried('publicKey'), (password: 'saved-with-the-key', keys: true));
      await db.delete(db.identities).go();
      expect(await carried('certificate'), (password: 'saved-with-the-key', keys: true));
    });

    test('a key that cannot be read: no password either, so the run fails rather than sign in by password alone',
        () async {
      expect(await carried('publicKey', withKey: false), (password: null, keys: false));
    });

    test('not saved as that (one left from before), or a kind a run does not sign in with: none', () async {
      expect(await carried('publicKey', afterKey: false), (password: null, keys: true));
      await db.delete(db.identities).go();
      expect(await carried('hardwareToken'), (password: null, keys: false));
    });
  });
}
