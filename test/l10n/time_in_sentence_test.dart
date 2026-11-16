import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

// A time said inside a sentence takes the words made for it, and a reading
// that refreshes every few seconds says its seconds (3.0):
// "Last synced: Just now", "Checked Just now." and the French "Vérifié Il y
// a 5 min." began a word mid-sentence with a capital.
void main() {
  setUpAll(initializeDateFormatting);

  final now = DateTime(2026, 10, 18, 9);
  DateTime ago(Duration d) => now.subtract(d);

  for (final locale in AppLocalizations.supportedLocales) {
    test('in $locale, times to the second, and inside a sentence', () {
      final l10n = lookupAppLocalizations(locale);

      expect(timeAgoWords(l10n, ago(const Duration(seconds: 5)), now: now, seconds: true), l10n.timeJustNow);
      expect(timeAgoWords(l10n, ago(const Duration(seconds: 30)), now: now, seconds: true), l10n.timeSecondsAgo(30));
      expect(timeAgoWords(l10n, ago(const Duration(seconds: 30)), now: now), l10n.timeJustNow);
      expect(timeAgoInSentence(l10n, ago(const Duration(seconds: 30)), now: now, seconds: true),
          l10n.timeSecondsAgo(30));
      expect(timeAgoInSentence(l10n, ago(const Duration(seconds: 30)), now: now), l10n.settingsMobJustNow);

      expect(monitorCheckedPhrase(l10n, ago(const Duration(seconds: 5)), now: now), l10n.settingsMobJustNow);
      expect(monitorCheckedPhrase(l10n, ago(const Duration(seconds: 30)), now: now), l10n.timeSecondsAgo(30));
      expect(monitorCheckedPhrase(l10n, ago(const Duration(minutes: 5)), now: now), l10n.timeMinutesAgo(5));
      expect(monitorCheckedPhrase(l10n, ago(const Duration(hours: 3)), now: now), l10n.timeHoursAgo(3));

      expect(profileLastSyncedText(l10n, ago(const Duration(hours: 3)), now: now),
          l10n.profileLastSynced(l10n.timeHoursAgo(3)));
    });
  }

  test('in English and French the words inside the sentence begin small', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final fr = lookupAppLocalizations(const Locale('fr'));
    expect(profileLastSyncedText(en, ago(const Duration(seconds: 5)), now: now), 'Last synced: just now');
    expect(en.zestMonitorTipChecked(monitorCheckedPhrase(en, ago(const Duration(seconds: 5)), now: now)),
        'Checked just now.');
    // The compact words, not "2 mins ago".
    expect(en.monitorLastCollected(monitorCheckedPhrase(en, ago(const Duration(minutes: 2)), now: now)),
        'Last collected 2m ago');
    final checked = fr.zestMonitorTipChecked(monitorCheckedPhrase(fr, ago(const Duration(minutes: 5)), now: now));
    expect(checked, contains('il y a'));
    expect(checked, isNot(contains('Il y a')));
  });
}
