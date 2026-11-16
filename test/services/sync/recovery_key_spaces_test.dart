// Real Argon2id key derivation (the weakest profile deriveKey accepts),
// done once for the file. Allow for a machine busy with the whole suite.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A recovery key typed back with spaces in it (3.0 docs check).
/// Check took it (RecoveryKeyService.tidy takes spaces and dashes
/// out), but restoring with it took only the dashes out, on the hosted
/// server and on a store of the person's own: a key typed in groups, or
/// pasted with a line break, was refused there as wrong. Now every restore
/// goes through RecoveryKeyService.normalize, which takes out both.
void main() {
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const recoveryKey = 'ZEST-ABCD-EFGH-JKMN-PQRS-TUVW';
  // As a person may type it back: in groups with spaces, lower case, a line
  // break pasted with it.
  const typed = ' zest abcd efgh\njkmn pqrs tuvw ';

  late SecretKey dek;
  late Uint8List salt;
  late Uint8List recoverySalt;
  late Uint8List wrappedForRecovery;
  late Uint8List recoveryHash;
  late Uint8List blob;

  setUpAll(() async {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
    salt = SyncService.generateSalt();
    recoverySalt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    // The key is made as the app makes it: from its normalized form.
    final kek = await SyncService.deriveKey(RecoveryKeyService.normalize(recoveryKey), recoverySalt, params: fast);
    wrappedForRecovery = await SyncService.wrapDek(dek, kek);
    recoveryHash = await SyncService.computeRecoveryVerificationHash(kek);
    blob = await SyncService.encrypt({'connections': const <dynamic>[]}, dek, salt);
  });

  tearDown(() => ZestServerBackend.debugHttpClient = null);

  test('normalized, spaces and line breaks go as dashes do, and it is the key Check takes', () {
    expect(RecoveryKeyService.normalize(typed), RecoveryKeyService.normalize(recoveryKey));
    expect(RecoveryKeyService.tidy(typed), recoveryKey);
  });

  test('a store of the person\'s own opens with the key typed with spaces', () async {
    final store = MemoryStoreBackend(MemoryStore());
    await store.push(
      data: {'connections': const <dynamic>[]},
      dek: dek,
      salt: salt,
      verificationHash: Uint8List(32),
      wrappedDekPassword: await SyncService.wrapDek(dek, SyncService.generateDek()),
      wrappedDekRecovery: wrappedForRecovery,
      recoverySalt: recoverySalt,
      recoveryHash: recoveryHash,
      createOnly: true,
      argon2Params: fast,
    );
    final restored = await store.pullWithRecoveryKey(typed);
    expect(restored.pullResult.version, 1);
  });

  test('the hosted server is asked with the key typed with spaces, and the vault opens', () async {
    String? askedWith;
    ZestServerBackend.debugHttpClient = MockClient((request) async {
      if (request.url.path.endsWith('/sync/pull')) {
        return http.Response(
          jsonEncode({
            'encrypted_data': base64Encode(blob),
            'salt': base64Encode(salt),
            'version': 3,
            'updated_at': '2026-10-22T09:00:00Z',
            'wrapped_dek_password': null,
            'wrapped_dek_recovery': base64Encode(wrappedForRecovery),
            'recovery_salt': base64Encode(recoverySalt),
            'argon2_params': fast,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/sync/verify-recovery')) {
        askedWith = (jsonDecode(request.body) as Map)['recovery_hash'] as String;
        final right = askedWith == base64Encode(recoveryHash);
        return http.Response(jsonEncode({'valid': right}), 200);
      }
      return http.Response('{"error":"not here"}', 404);
    });
    final server = ZestServerBackend(
      baseUrl: 'https://sync.northwind.example/v1',
      staticToken: 'demo-token',
      requiresEntitlement: false,
      kind: SyncBackendKind.custom,
    );
    final restored = await server.pullWithRecoveryKey(typed);
    expect(askedWith, base64Encode(recoveryHash), reason: 'the hash of the right key');
    expect(await SyncService.decrypt(restored.pullResult.encryptedData, restored.dek), {'connections': const <dynamic>[]});
  });
}
