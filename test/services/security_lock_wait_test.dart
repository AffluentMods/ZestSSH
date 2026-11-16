import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/services/security_lock_service.dart';

/// What the lock screen says of the wait after wrong PINs (4.0) is what the PIN's
/// own counter does: [SecurityLockService.waitAfter] gives the wait the nth wrong
/// PIN in a row starts, none before the tenth, then 30 seconds, 60 from the
/// fifteenth and 300 from the twentieth, and the counter starts those very waits.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no wait before the tenth wrong PIN, then 30, 60 from the fifteenth, 300 from the twentieth', () {
    expect([for (var n = 1; n <= 9; n++) SecurityLockService.waitAfter(n)], everyElement(0));
    expect(SecurityLockService.waitAfter(10), 30);
    expect(SecurityLockService.waitAfter(14), 30);
    expect(SecurityLockService.waitAfter(15), 60);
    expect(SecurityLockService.waitAfter(19), 60);
    expect(SecurityLockService.waitAfter(20), 300);
    expect(SecurityLockService.waitAfter(40), 300);
  });

  for (final (before, wait) in [(9, 30), (14, 60), (19, 300)]) {
    test('the counter at $before: the next wrong PIN starts a wait of $wait seconds, as said', () async {
      FlutterSecureStorage.setMockInitialValues({'pin_failed_attempts': '$before'});
      final service = SecurityLockService(const FlutterSecureStorage(), LocalAuthentication());
      await service.setPin('1234');
      // A new PIN starts its count afresh: the count is put back as the test has it.
      FlutterSecureStorage.setMockInitialValues({
        'pin_failed_attempts': '$before',
        'security_pin_hash': (await const FlutterSecureStorage().read(key: 'security_pin_hash'))!,
      });
      final fresh = SecurityLockService(const FlutterSecureStorage(), LocalAuthentication());
      expect(await fresh.verifyPin('0000'), isFalse);
      expect(fresh.failedAttempts, before + 1);
      expect(fresh.isLockedOut, isTrue);
      expect(fresh.remainingLockoutSeconds, inInclusiveRange(wait - 2, wait));
      expect(SecurityLockService.waitAfter(fresh.failedAttempts), wait);
    });
  }

  test('nine wrong PINs: no wait, and one try left before it', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = SecurityLockService(const FlutterSecureStorage(), LocalAuthentication());
    await service.setPin('1234');
    for (var i = 0; i < 9; i++) {
      expect(await service.verifyPin('0000'), isFalse);
    }
    expect(service.isLockedOut, isFalse);
    expect(service.maxAttempts - service.failedAttempts, 1, reason: 'what the lock screen says is left');
  });
}
