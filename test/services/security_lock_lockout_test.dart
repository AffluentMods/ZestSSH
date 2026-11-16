import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/services/security_lock_service.dart';

/// The brute-force lockout state machine that every protection-stripping gate
/// (App-Lock-off, unbind, and now encryption-off) routes through. Proves a
/// wrong-PIN storm locks out, that the lockout throttles even a CORRECT PIN,
/// and that setting a new PIN clears the slate (so a change never strands the
/// owner behind a stale lockout).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecurityLockService svc;

  test('clearLock removes the stored PIN so a later setup is a fresh one '
      '(turning App Lock off must not leave a stale, forgettable PIN)', () async {
    await svc.setPin('4812');
    expect(await svc.hasPinConfigured(), isTrue);
    await svc.clearLock();
    expect(await svc.hasPinConfigured(), isFalse,
        reason: 'a disabled lock must not keep a PIN that would gate setup');
    // And a brand-new PIN takes with no leftover lockout.
    await svc.setPin('9930');
    expect(await svc.verifyPin('9930'), isTrue);
    expect(svc.isLockedOut, isFalse);
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    svc = SecurityLockService(const FlutterSecureStorage(), LocalAuthentication());
  });

  test('correct PIN verifies; wrong-PIN storm triggers lockout; lockout '
      'throttles even the correct PIN; setPin resets it', () async {
    await svc.setPin('1379');
    expect(await svc.verifyPin('1379'), isTrue);
    expect(svc.isLockedOut, isFalse);

    // Hammer wrong PINs up to the threshold.
    for (var i = 0; i < svc.maxAttempts; i++) {
      expect(await svc.verifyPin('0000'), isFalse);
    }
    expect(svc.isLockedOut, isTrue,
        reason: 'must lock out after maxAttempts failures');
    expect(svc.remainingLockoutSeconds, greaterThan(0));

    // While locked out, even the CORRECT PIN must not pass.
    expect(await svc.verifyPin('1379'), isFalse,
        reason: 'lockout must throttle the correct PIN too');

    // Setting a new PIN clears the lockout (fresh slate).
    await svc.setPin('2846');
    expect(svc.isLockedOut, isFalse);
    expect(await svc.verifyPin('2846'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
