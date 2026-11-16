import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/security_lock_service.dart';

/// What the system's unlock prompt (Windows Hello, Touch ID, a fingerprint)
/// says when the app asks for it (3.0 docs check): it was
/// "Authenticate to unlock ZestSSH", in English in every language. Now it is
/// the app's words, in the app's language.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/local_auth');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final reasons = <String?>[];

  setUp(() {
    reasons.clear();
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'authenticate') {
        reasons.add((call.arguments as Map)['localizedReason'] as String?);
        return true;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
  });

  SecurityLockService service() => SecurityLockService(const FlutterSecureStorage(), LocalAuthentication());

  test('without words of its own, the prompt says it in the app\'s language', () async {
    final de = lookupAppLocalizations(const Locale('de'));
    L10nGlobal.update(de);
    expect(await service().authenticateWithBiometric(), BiometricAuthOutcome.success);
    expect(reasons.single, de.docCheckBiometricReason);
    expect(reasons.single, isNot('Authenticate to unlock ZestSSH'));
  });

  test('the words a caller gives are the ones the prompt says', () async {
    final ja = lookupAppLocalizations(const Locale('ja'));
    expect(await service().authenticateWithBiometric(reason: ja.docCheckBiometricReason), BiometricAuthOutcome.success);
    expect(reasons.single, ja.docCheckBiometricReason);
  });
}
