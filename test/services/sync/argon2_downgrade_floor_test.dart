import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/test_cryptography.dart';

/// The Argon2id parameters used to derive the master key travel WITH the
/// pulled sync blob, so a hostile or compromised store (including a
/// user-chosen WebDAV/S3/Drive bucket) gets to choose them. The floor in
/// `deriveKey` is what stops it choosing something cheap to crack offline.
void main() {
  // The last test derives for real (the others are refused before anything
  // is derived).
  useRealKeyDerivation();

  final salt = SyncService.generateSalt();

  Future<void> expectRejected(Map<String, dynamic> params) async {
    await expectLater(
      SyncService.deriveKey('pw', salt, params: params),
      throwsA(isA<FormatException>()),
      reason: 'params $params must be refused as a downgrade',
    );
  }

  test('rejects the generic OWASP minimum (below anything we ever wrote)',
      () async {
    // This was the previous floor. Nothing the app has ever written is this
    // weak, so accepting it only ever helped an attacker.
    await expectRejected(
        {'memory': 19456, 'iterations': 2, 'parallelism': 1});
  });

  test('rejects a downgrade in any single dimension', () async {
    await expectRejected(
        {'memory': 32768, 'iterations': 3, 'parallelism': 4});
    await expectRejected(
        {'memory': 65536, 'iterations': 2, 'parallelism': 4});
    await expectRejected(
        {'memory': 65536, 'iterations': 3, 'parallelism': 1});
  });

  test('rejects absurdly expensive parameters (client-wedging DoS)', () async {
    await expectRejected(
        {'memory': 4 * 1024 * 1024, 'iterations': 3, 'parallelism': 4});
    await expectRejected(
        {'memory': 65536, 'iterations': 1000, 'parallelism': 4});
    await expectRejected(
        {'memory': 65536, 'iterations': 3, 'parallelism': 999});
  });

  // A real derivation: allow for a machine busy with the whole suite.
  test('accepts the v1 legacy profile so existing accounts still derive',
      () async {
    final key = await SyncService.deriveKey('pw', salt,
        params: SyncService.legacyArgon2Params);
    expect((await key.extractBytes()).length, 32);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
