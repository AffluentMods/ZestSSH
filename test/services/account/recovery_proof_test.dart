import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/account/recovery_proof.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/sync_service.dart';

/// The recovery proof (3.3; the two-step contract, sections 6.5 and 7.4): an
/// Ed25519 key made from the sync password's key (HKDF-SHA256, no salt, info
/// `zestssh recovery proof v1`), its public half registered at unlock with
/// the sync password proved, and a recovery's challenge signed with it to
/// keep the data. The messages are ZestSSH Cloud's lib/lockout_recovery.js
/// proofMessage, word for word.
void main() {
  final mek = SecretKey(List<int>.generate(32, (i) => i));

  test('the key, its registration and the password hash, as Node computes them (the server verifies with Node)',
      () async {
    // node: hkdfSync('sha256', mek, empty, 'zestssh recovery proof v1', 32)
    // as an Ed25519 seed; crypto.sign of the register message; and the
    // verification hash a sync push sends.
    final key = await recoveryProofKey(mek);
    expect(b64uOf((await key.extractPublicKey()).bytes), 'd1RKT85nqO1G4HX_dPwm_jpzG6rDzXTs2j3tH8-0FQc');
    final proof = await recoveryProofRegistration(mek, 'kat-uid');
    expect(proof.publicKey, 'd1RKT85nqO1G4HX_dPwm_jpzG6rDzXTs2j3tH8-0FQc');
    expect(proof.signature,
        'lBbBpH3xpO7PR8LWYBBSQ1cPeUTuXHxeueBlcr-lW4Xg4ehabdiwEoaLsDM4EHFOwtb9X7I8WtktUKkf87GvDA');
    expect(proof.passwordHash, 'qVUcO+wz50n1Ci/nO9m//Gu3nwXP64CN7O0kyGbv3XM=');
    expect(proof.passwordHash, base64Encode(await SyncService.computeVerificationHash(mek)),
        reason: 'password_hash as a sync push sends it');
    expect(proof.publicKey, isNot(contains('=')), reason: 'base64url without padding');
  });

  test("a recovery's challenge signed by the same key, over the recover message", () async {
    const challenge = 'c2VydmVyIGNoYWxsZW5nZSBieXRlcyAzMiBsb25nISEh';
    final signature = await signRecoveryProof(mek, 'kat-uid', challenge);
    final key = await recoveryProofKey(mek);
    final message = utf8.encode('zestssh recovery proof v1\nrecover\nkat-uid\n$challenge');
    expect(
      await Ed25519().verify(message,
          signature: Signature(base64Url.decode(base64Url.normalize(signature)), publicKey: await key.extractPublicKey())),
      isTrue,
    );
    // Another account, another password: no good.
    final other = await recoveryProofKey(SecretKey(List<int>.filled(32, 9)));
    expect(b64uOf((await other.extractPublicKey()).bytes), isNot(b64uOf((await key.extractPublicKey()).bytes)));
    expect(await signRecoveryProof(mek, 'another-uid', challenge), isNot(signature));
  });

  test('the sync password, salt and settings a recovery hands out give the key of the unlock', () async {
    // The weakest settings the app takes (SyncService's floor), to keep the
    // test quick.
    const params = {'version': 1, 'memory': 65536, 'iterations': 3, 'parallelism': 4};
    final salt = SyncService.generateSalt();
    final atUnlock = await SyncService.deriveKey('correct horse battery staple', salt, params: params);
    final registered = await recoveryProofRegistration(atUnlock, 'uid-1');
    final waiting = WaitingLockout(
      email: 'a@example.com',
      ticket: 'dGlja2V0',
      completesAt: DateTime(2026, 11, 6),
      proof: RecoveryProofAsk(challenge: 'Y2hhbGxlbmdl', salt: salt, argon2Params: params),
    );
    final proof = await proveSyncPassword(waiting: waiting, password: 'correct horse battery staple', firebaseUid: 'uid-1');
    final message = utf8.encode('zestssh recovery proof v1\nrecover\nuid-1\nY2hhbGxlbmdl');
    final publicKey = SimplePublicKey(base64Url.decode(base64Url.normalize(registered.publicKey)), type: KeyPairType.ed25519);
    expect(await Ed25519().verify(message, signature: Signature(base64Url.decode(base64Url.normalize(proof!)), publicKey: publicKey)),
        isTrue);
    final wrong = await proveSyncPassword(waiting: waiting, password: 'Correct horse battery staple', firebaseUid: 'uid-1');
    expect(await Ed25519().verify(message, signature: Signature(base64Url.decode(base64Url.normalize(wrong!)), publicKey: publicKey)),
        isFalse);
    // No proof to make where the recovery can only reset.
    expect(
      await proveSyncPassword(
          waiting: WaitingLockout(email: 'a@example.com', ticket: 't', completesAt: DateTime(2026, 11, 6)),
          password: 'x',
          firebaseUid: 'uid-1'),
      isNull,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('registering it', () {
    late List<http.Request> sent;
    late int status;
    late Map<String, Object?> answer;

    TwoStepApi api() => TwoStepApi(
          baseUrl: 'https://api.test/v1',
          bearer: () async => 'tok',
          client: MockClient((request) async {
            sent.add(request);
            return http.Response(jsonEncode(answer), status);
          }),
        );

    setUp(() {
      sent = [];
      status = 200;
      answer = {'registered': true, 'changed': true};
    });

    test('once per key in a run, for sync on ZestSSH Cloud, and the account noted on this device', () async {
      final remembered = <String>[];
      final service = RecoveryProofService(
        api: api,
        accountUid: () async => 'uid-1',
        hosted: () => true,
        remember: (uid) async => remembered.add(uid),
      );
      await service.register(mek);
      await service.register(mek);
      expect(sent, hasLength(1));
      expect(sent.single.method, 'PUT');
      expect(sent.single.url.path, '/v1/account/recovery-proof');
      final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
      expect(body.keys, unorderedEquals(['public_key', 'signature', 'password_hash']));
      expect(body['public_key'], 'd1RKT85nqO1G4HX_dPwm_jpzG6rDzXTs2j3tH8-0FQc');
      expect(remembered, ['uid-1']);
      // A new sync password, a new key.
      await service.register(SecretKey(List<int>.filled(32, 1)));
      expect(sent, hasLength(2));
    });

    test('quietly not, where there is nothing to keep, the password is not the data\'s, or nobody is signed in',
        () async {
      for (final (code, refusedWith) in [
        ('recovery-proof-no-data', 409),
        ('verification-failed', 403),
        ('sync-password-required', 403),
      ]) {
        status = refusedWith;
        answer = {'code': code};
        await RecoveryProofService(api: api, accountUid: () async => 'uid-1', hosted: () => true).register(mek);
      }
      expect(sent, hasLength(3));
      // Bring-your-own sync: ZestSSH Cloud holds no data a proof could keep,
      // and is sent nothing of the password.
      sent.clear();
      await RecoveryProofService(api: api, accountUid: () async => 'uid-1', hosted: () => false).register(mek);
      await RecoveryProofService(api: api, accountUid: () async => null, hosted: () => true).register(mek);
      await RecoveryProofService(api: api, accountUid: () async => 'desktop-session', hosted: () => true).register(mek);
      expect(sent, isEmpty);
      // Offline: nothing thrown either.
      await RecoveryProofService(
        api: () => TwoStepApi(
            baseUrl: 'https://api.test/v1',
            bearer: () async => 'tok',
            client: MockClient((_) async => throw http.ClientException('offline'))),
        accountUid: () async => 'uid-1',
        hosted: () => true,
      ).register(mek);
    });
  });

  group('the recovery this device waits for', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('kept until it is done or cancelled, and never in a message', () async {
      final store = LockoutRecoveryStore(const FlutterSecureStorage());
      expect(await store.read(), isNull);
      final waiting = WaitingLockout(
        email: 'sam@example.com',
        ticket: 'dGlja2V0LXNlY3JldA',
        completesAt: DateTime.utc(2026, 11, 6, 9),
        proof: RecoveryProofAsk(challenge: 'Y2g', salt: base64Decode('AQID'), argon2Params: const {'memory': 65536}),
      );
      await store.save(waiting);
      final back = (await store.read())!;
      expect(back.email, 'sam@example.com');
      expect(back.ticket, 'dGlja2V0LXNlY3JldA');
      expect(back.completesAt.toUtc(), DateTime.utc(2026, 11, 6, 9));
      expect(back.proof!.salt, [1, 2, 3]);
      expect(back.proof!.argon2Params, {'memory': 65536});
      expect(back.dueAt(DateTime.utc(2026, 11, 6, 8)), isFalse);
      expect(back.dueAt(DateTime.utc(2026, 11, 6, 9)), isTrue);
      expect('$back', isNot(contains('dGlja2V0')));
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('while the encrypting lock is on its ticket is sealed; locked, it waits for the unlock, and is never none',
        () async {
      // Found in a cryptography review: it was kept as it
      // was, so whatever read the system's storage could complete the recovery
      // without the PIN.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        SecretSeal.openTree = null;
        await db.close();
      });
      const storage = FlutterSecureStorage();
      final store = LockoutRecoveryStore(storage);
      SecretSeal.openTree = db;
      await SecretSeal.setActive(db, true);

      await store.save(WaitingLockout(email: 'sam@example.com', ticket: 'dGlja2V0LXNlY3JldA', completesAt: DateTime.utc(2026, 11, 6)));
      final kept = (await storage.read(key: 'lockout_recovery_v1'))!;
      expect(kept, startsWith(SecretSeal.prefix));
      expect(kept, isNot(contains('dGlja2V0')));
      expect((await store.read())!.ticket, 'dGlja2V0LXNlY3JldA');

      // The app locks: the database closes, and nothing asks for it anew.
      SecretSeal.openTree = null;
      WaitingLockout? read;
      var done = false;
      unawaited(store.read().then((w) {
        read = w;
        done = true;
      }));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse, reason: 'it waits');
      SecretSeal.openTree = db;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(read!.ticket, 'dGlja2V0LXNlY3JldA');

      // Kept as it was by a version before this: sealed by the sweep at the
      // unlock, and read as ever.
      await storage.write(
          key: 'lockout_recovery_v1',
          value: jsonEncode(WaitingLockout(email: 'sam@example.com', ticket: 'b2xk', completesAt: DateTime.utc(2026, 11, 6)).toJson()));
      expect((await store.read())!.ticket, 'b2xk');
      await sealSecretsAtRest(db, storage);
      expect(await storage.read(key: 'lockout_recovery_v1'), startsWith(SecretSeal.prefix));
      expect((await store.read())!.ticket, 'b2xk');

      // Done with it: gone, sealed or not.
      await store.clear();
      expect(await storage.read(key: 'lockout_recovery_v1'), isNull);
      expect(await store.read(), isNull);
    });

    test('which account a proof was registered for here, by its address', () async {
      final store = LockoutRecoveryStore(const FlutterSecureStorage());
      expect(await store.accountFor('Sam@Example.com'), isNull);
      await store.rememberAccount(' Sam@Example.com', 'uid-1');
      await store.rememberAccount('robin@example.com', 'uid-2');
      expect(await store.accountFor('sam@example.com '), 'uid-1');
      expect(await store.accountFor('robin@example.com'), 'uid-2');
    });
  });
}
