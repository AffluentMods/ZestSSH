import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The MobaXterm and SecureCRT (SecureFX) import help says what comes in
/// (3.4, found by the docs check before the release): it named SSH and
/// Telnet sessions alone, though their SFTP sessions come in as hosts that
/// are SFTP only and their FTP and FTPS sessions as FTPS hosts
/// (other_app_hosts.dart). In every language the app has.
void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    test('${locale.languageCode}: both helps name FTP and FTPS', () {
      final l10n = lookupAppLocalizations(locale);
      for (final help in [l10n.migrateMobaHelp, l10n.migrateCrtHelp]) {
        expect(help, contains('FTPS'), reason: help);
        expect(help, contains('SFTP'), reason: help);
        expect(RegExp(r'\bFTP\b').hasMatch(help), isTrue, reason: help);
      }
      expect(l10n.migrateCrtHelp, contains('SecureFX'));
    });
  }
}
