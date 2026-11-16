import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Words left from before the Account page (3.0): a phone's Settings row and
/// a computer's command palette named it "Profile & Cloud Sync", and the help
/// FAQ sent people to "your Profile (Settings on desktop)" to delete their
/// account, saying it removes "all data" (purchase records are kept for
/// accounting, and what someone added to a team stays with the team). In
/// every language: the row and the command name the Account page as its own
/// title does, and the FAQ names the page and its Delete account button.
void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    test('the Account page is called by its name, and the FAQ names the way to delete ($locale)', () {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n.settingsProfileCloudSync, l10n.accountTitle, reason: "a phone's Settings row");
      expect(l10n.desktopCmdProfileCloudSync, l10n.accountTitle, reason: "a computer's command palette");
      expect(l10n.helpFaqDeleteAccountBody, contains(l10n.accountTitle));
      expect(l10n.helpFaqDeleteAccountBody, contains(l10n.accountDeleteAccount));
    });
  }

  test('the English FAQ says what is kept, not that everything goes', () {
    final en = lookupAppLocalizations(AppLocalizations.supportedLocales.firstWhere((l) => l.languageCode == 'en'));
    expect(en.helpFaqDeleteAccountBody, isNot(contains('all data')));
    expect(en.helpFaqDeleteAccountBody, contains('Purchase records are kept'));
    expect(en.helpFaqDeleteAccountBody, contains('stays with the team'));
  });
}
