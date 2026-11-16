import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/update_dialog.dart';

/// The in-app updater's words, and above all its errors, say what happened
/// in every language the app speaks, each with its own code.
void main() {
  final codes = [
    ErrorCodes.updateDownloadFailed,
    ErrorCodes.updateNotSigned,
    ErrorCodes.updateFileMismatch,
    ErrorCodes.updateCannotInstallHere,
    ErrorCodes.updateInstallFailed,
  ];
  final en = lookupAppLocalizations(const Locale('en'));

  for (final locale in AppLocalizations.supportedLocales) {
    final l10n = lookupAppLocalizations(locale);
    final lang = locale.languageCode;

    test('$lang: every update error has words of its own, and its code after them', () {
      final words = [for (final c in codes) updateFailureWords(l10n, c)];
      expect(words.toSet(), hasLength(codes.length), reason: 'one text per situation');
      for (var i = 0; i < codes.length; i++) {
        final w = words[i];
        expect(w.trim(), isNotEmpty);
        expect(w, isNot(matches(RegExp('[\u2013\u2014]'))), reason: 'no en or em dashes');
        if (lang != 'en') expect(w, isNot(updateFailureWords(en, codes[i])), reason: 'translated');
        final shown = ErrorCodes.withCode(w, codes[i]);
        expect(shown, endsWith('(${codes[i].code})'));
        expect(ErrorCodes.codeIn(shown), codes[i]);
      }
    });

    test('$lang: the pill, the dialog and its steps are all there, without dashes', () {
      final all = [
        l10n.appUpdatePill,
        l10n.appUpdateYouHave('3.0.0'),
        l10n.appUpdateWhatsNew,
        l10n.appUpdateHowItGoes,
        l10n.appUpdateNow,
        l10n.appUpdateLater,
        l10n.appUpdateConfirmTitle,
        l10n.appUpdateDownloading,
        l10n.appUpdateProgress('12.3', '21.0'),
        l10n.appUpdateVerifying,
        l10n.appUpdatePreparing,
        l10n.appUpdateRestarting,
        l10n.appUpdateDownloadPage,
        l10n.appUpdateMacMoveHint,
        l10n.appUpdateNoPackage,
        l10n.appUpdateInstalled('3.0.1'),
        l10n.appUpdateNotInstalledTitle,
      ];
      for (final s in all) {
        expect(s.trim(), isNotEmpty);
        expect(s, isNot(matches(RegExp('[\u2013\u2014]'))));
      }
      expect(l10n.appUpdateYouHave('3.0.0'), contains('3.0.0'));
      expect(l10n.appUpdateProgress('12.3', '21.0'), allOf(contains('12.3'), contains('21.0')));
      expect(l10n.appUpdateInstalled('3.0.1'), contains('3.0.1'));
    });
  }

  test('German says Sie, Spanish tu, where they ask something of the person', () {
    final de = lookupAppLocalizations(const Locale('de'));
    final es = lookupAppLocalizations(const Locale('es'));
    expect(de.appUpdateErrCannotHere, contains('Laden Sie'));
    expect(de.appUpdateMacMoveHint, contains('Verschieben Sie'));
    expect(es.appUpdateErrCannotHere, contains('Descarga la'));
    expect(es.appUpdateMacMoveHint, startsWith('Mueve'));
  });

  test('Chinese uses full-width marks, with no space after them', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    for (final s in [zh.appUpdateHowItGoes, zh.appUpdateErrCannotHere, zh.appUpdateConfirmTitle, zh.appUpdateErrInstall]) {
      expect(s, isNot(matches(RegExp(r'[一-鿿][,.?!:;]'))));
      expect(s, isNot(matches(RegExp('[，。？！：；] '))));
    }
  });
}
