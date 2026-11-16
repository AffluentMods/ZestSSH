import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/services/security_lock_service.dart';

/// Where the system has no way to ask for the device's lock (3.0, 17 October
/// 2026). Linux has no plugin for it, and the check of whether there is one
/// caught only a PlatformException: there it threw a MissingPluginException,
/// and the PIN setup's check failed with it. Now there is none to offer, and
/// nothing throws.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecurityLockService service;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // No handler on the plugin's channel: every call is a MissingPluginException,
    // as on Linux.
    service = SecurityLockService(const FlutterSecureStorage(), LocalAuthentication());
  });

  test('the plugin is missing here, as on Linux', () async {
    await expectLater(LocalAuthentication().isDeviceSupported(), throwsA(isA<MissingPluginException>()));
  });

  test('there is no way to unlock with the device to offer, and nothing throws', () async {
    expect(await service.isBiometricAvailable(), isFalse);
    expect(await service.getAvailableBiometrics(), isEmpty);
    expect(await service.authenticateWithBiometric(), BiometricAuthOutcome.unavailable);
  });

  test('the system saying no (a PlatformException) is none to offer too', () async {
    const channel = MethodChannel('plugins.flutter.io/local_auth');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'NotAvailable'));
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await service.isBiometricAvailable(), isFalse);
    expect(await service.getAvailableBiometrics(), isEmpty);
  });
}
