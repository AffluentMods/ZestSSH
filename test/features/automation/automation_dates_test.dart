import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/features/automation/widgets/automation_shared.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/l10n/time_text.dart';

// The automation's runs and API keys say their days, and when a key runs out,
// in the page's language (3.0): a run's day was 2026-09-28,
// and a key "Expires in 5 days", "Expires today" or "Never expires", in
// English in every language.
void main() {
  setUpAll(initializeDateFormatting);

  AutomationApiKey key({DateTime? expiresAt}) => AutomationApiKey.fromSecret(
      id: 'k1', label: 'deploy', secret: 'k' * 48, createdAt: DateTime(2026, 9, 1), expiresAt: expiresAt);

  for (final locale in AppLocalizations.supportedLocales) {
    final l10n = lookupAppLocalizations(locale);
    final language = l10n.localeName;
    test("in $locale, a run's day and time as the language writes them, and when a key runs out", () {
      final at = DateTime(2026, 9, 28, 14, 5);
      expect(automationDate(l10n, at), DateFormat.yMMMd(language).format(at));
      expect(automationDateTime(l10n, at), DateFormat.yMMMd(language).add_Hm().formatPlain(at));
      expect(automationKeyExpiry(l10n, key()), l10n.certGenerateValidityNever);
      final gone = DateTime.now().subtract(const Duration(hours: 1));
      expect(automationKeyExpiry(l10n, key(expiresAt: gone)), l10n.triggersViewExpired);
      final ends = DateTime.now().add(const Duration(days: 5));
      expect(automationKeyExpiry(l10n, key(expiresAt: ends)),
          l10n.settingsMobExpiresOn(DateFormat.yMMMd(language).format(ends)));
    });
  }

  test("in German and Japanese, not English's", () {
    final en = lookupAppLocalizations(const Locale('en'));
    final at = DateTime(2026, 9, 28, 14, 5);
    final ends = key(expiresAt: DateTime.now().add(const Duration(days: 5)));
    for (final code in const ['de', 'ja']) {
      final l10n = lookupAppLocalizations(Locale(code));
      expect(automationDate(l10n, at), isNot(automationDate(en, at)), reason: code);
      expect(automationDateTime(l10n, at), isNot(automationDateTime(en, at)), reason: code);
      expect(automationKeyExpiry(l10n, key()), isNot(automationKeyExpiry(en, key())), reason: code);
      expect(automationKeyExpiry(l10n, ends), isNot(automationKeyExpiry(en, ends)), reason: code);
    }
  });
}
