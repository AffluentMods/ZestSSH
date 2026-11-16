// End-to-end test of the Windows TPM vault layer against the REAL TPM and the
// REAL DPAPI secure store. Runs only on Windows:
//   flutter test integration_test/tpm_vault_test.dart -d windows
//
// It exercises the exact path the vault uses: generate a 256-bit key, seal it
// in the TPM, persist the ciphertext, then recover it and confirm the bytes
// match. A copied ciphertext with no TPM (another machine) could not do this.
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zestssh/services/windows_tpm_vault_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage(wOptions: WindowsOptions());
  final svc = WindowsTpmVaultService(storage);

  testWidgets('TPM is available on this PC', (t) async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    expect(await svc.isAvailable(), isTrue,
        reason: 'Platform Crypto Provider / TPM should be usable');
  });

  testWidgets('generateAndStore -> read round-trips the same 256-bit key',
      (t) async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    final k1 = await svc.generateAndStore();
    expect(k1.length, 32);
    final k2 = await svc.read();
    expect(k2, equals(k1),
        reason: 'the TPM must unseal the exact key it sealed');
    await svc.delete();
  });

  testWidgets('two enables produce different keys (fresh random each time)',
      (t) async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    final a = await svc.generateAndStore();
    final b = await svc.generateAndStore();
    expect(a, isNot(equals(b)));
    await svc.delete();
  });

  testWidgets('read after delete throws (nothing left to recover)', (t) async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    await svc.generateAndStore();
    await svc.delete();
    await expectLater(svc.read(), throwsA(isA<StateError>()));
  });
}
