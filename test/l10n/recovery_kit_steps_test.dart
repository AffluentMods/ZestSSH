import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The old setup screen's heading, "Lost the password", in each language (the
/// string itself is gone with the screen: no code used it).
const _oldLostLabel = <String, String>{
  'ar': 'فقدت كلمة المرور',
  'de': 'Passwort verloren',
  'en': 'Lost the password',
  'es': 'Perdí la contraseña',
  'fr': 'Mot de passe perdu',
  'hi': 'पासवर्ड खो गया',
  'it': 'Password smarrita',
  'ja': 'パスワードを忘れた',
  'ko': '비밀번호를 잊음',
  'pt': 'Perdi a senha',
  'ru': 'Забыли пароль',
  'zh': '忘记密码',
};

/// The recovery kit is kept on paper or in a file, and read on the day a
/// device is lost: its steps must name what the app shows on the way back
/// in, in every language (found in a docs review: they
/// named "Use recovery key" under "Lost the password" and storage "in
/// Settings, Sync", which only a screen no device opens had). The way now: a
/// new device's Account page, Set up sync, then, asked for the master
/// password, "Forgot it? Use your recovery key".
void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    test('the recovery kit names the labels on the way back in ($locale)', () {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n.recoveryKitStep1Storage, contains(l10n.accountTitle), reason: 'the Account page');
      expect(l10n.recoveryKitStep1Storage, contains(l10n.accountSyncSetUp), reason: 'Set up sync');
      expect(l10n.recoveryKitStep2, contains(l10n.profileForgotUseRecovery), reason: 'the button for the recovery key');
      // The old setup screen's heading over its button (its button's words
      // are part of the live one's in some languages).
      expect(l10n.recoveryKitStep2, isNot(contains(_oldLostLabel[locale.languageCode]!)), reason: 'a label of the old setup screen');
    });
  }

  test('every language has its own kit', () {
    expect(AppLocalizations.supportedLocales, hasLength(12));
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales.where((l) => l.languageCode != 'en')) {
      expect(lookupAppLocalizations(locale).recoveryKitStep2, isNot(en.recoveryKitStep2), reason: '$locale');
    }
  });
}
