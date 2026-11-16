import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// What the app says of where a certificate is (3.0, found
/// while comparing the five versions): a phone's certificate card, and the
/// sign-in that found none for a key, said that a certificate stays on the
/// device it was added to; since 3.0 it goes with its key to the other
/// devices, through sync and backups (3ab855b).
void main() {
  // What each language said, which is no longer so.
  const stays = {
    'ar': ['تبقى الشهادة على الجهاز'],
    'de': ['bleibt auf dem Gerät'],
    'en': ['stays on the device'],
    'es': ['se queda en el dispositivo'],
    'fr': ["reste sur l'appareil"],
    'hi': ['उसी डिवाइस पर रहता है'],
    'it': ['resta sul dispositivo'],
    'ja': ['追加したデバイスにだけ保存'],
    'ko': ['추가한 기기에만 남'],
    'pt': ['fica no dispositivo'],
    'ru': ['остаётся на'],
    'zh': ['只保存在添加它的设备上', '只保留在添加它的设备上'],
  };

  test('no language says a certificate stays on the device it was added to', () {
    expect(stays.keys.toSet(), {for (final l in AppLocalizations.supportedLocales) l.languageCode});
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final said in [l.connCertNotOnDevice('deploy key')]) {
        for (final old in stays[locale.languageCode]!) {
          expect(said, isNot(contains(old)), reason: '$locale');
        }
      }
    }
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.connCertNotOnDevice('deploy key'), contains('comes here with its key once this device syncs'));
  });

  test('where a certificate is added is said as both places have it: a phone\'s key editor (4.0) and a computer\'s '
      'Keys page; it was the desktop app alone', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final said = [
        l.connCertNotOnDevice('deploy key'),
        l.connCertRanOut('deploy key', '4 October'),
        l.connCertUnusable('deploy key'),
        l.certReminderRanOutBody,
        l.certReminderSoonBody('Certificate runs out in 5 days'),
      ];
      for (final s in said) {
        expect(s, contains(l.zestKeysImportCertificate), reason: '$locale: $s');
        if (locale.languageCode == 'en') {
          expect(s, contains("in the key's editor on a phone"), reason: s);
          expect(s, isNot(contains('desktop app')), reason: s);
        } else {
          expect(s, isNot(contains(en.zestKeysImportCertificate)), reason: '$locale: $s');
        }
      }
    }
  });
}
