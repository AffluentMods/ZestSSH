import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/security/security_actions.dart';

/// "Hardware-backed encryption" names the hardware of the machine it is on:
/// the TPM on Windows, the Secure Enclave on a Mac (4.0), the phone's secure
/// hardware otherwise. A Mac had no such row before 4.0; with one, it must
/// not read as a PC's.
void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    final l10n = lookupAppLocalizations(locale);
    final code = locale.languageCode;

    test('$code: a Mac is told of its Secure Enclave, and nothing of a TPM or a PC', () {
      final mac = hardwareTexts(l10n, os: 'macos');
      for (final text in [mac.name, mac.notAvailable, mac.subtitle, mac.what, mac.risk]) {
        expect(text, contains('Mac'), reason: text);
        expect(text, isNot(contains('TPM')), reason: text);
        expect(RegExp(r'\bPC\b').hasMatch(text), isFalse, reason: text);
      }
      // Apple's name for it, in its own letters or (Chinese) with them beside.
      expect(mac.name, contains('Secure Enclave'));
      expect(mac.what, contains('Secure Enclave'));
      expect(mac.subtitle, contains(mac.name), reason: 'the row names the hardware it binds to');
      // What would lose the data on a Mac, by Apple's name for it in that language.
      expect(mac.risk.contains('Time Machine') || mac.risk.contains('时间机器'), isTrue, reason: mac.risk);
    });

    test('$code: Windows and a phone keep their own words', () {
      final windows = hardwareTexts(l10n, os: 'windows');
      expect(windows.name, l10n.secSetHwNameTpm);
      expect(windows.what, l10n.secBindWhatWindows);
      expect(windows.risk, l10n.secBindRiskWindows);
      expect(windows.notAvailable, l10n.secSetHwNotAvailableWindows);
      for (final phone in ['android', 'ios']) {
        final texts = hardwareTexts(l10n, os: phone);
        expect(texts.name, l10n.secSetHwNameSecureHardware);
        expect(texts.what, l10n.secBindWhatMobile);
        expect(texts.risk, l10n.secBindRiskMobile);
        expect(texts.subtitle, l10n.secSetHwBindSubtitleMobile(texts.name));
      }
    });
  }

  test('twelve languages', () => expect(AppLocalizations.supportedLocales, hasLength(12)));
}
