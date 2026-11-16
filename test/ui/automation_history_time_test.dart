import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';

// The automation history says when a run was in the page's language (3.0):
// it said "10 hours ago" and "Sep 28, 2026" in English in
// every language. Its words are the shared ones of lib/l10n/time_ago.dart
// (timeAgoWords).
void main() {
  setUpAll(initializeDateFormatting);

  final now = DateTime(2026, 10, 17, 22, 30);

  for (final locale in AppLocalizations.supportedLocales) {
    test('in $locale, a run is just now, minutes, hours or days ago, and past a week a date of the language', () {
      final l10n = lookupAppLocalizations(locale);
      String when(Duration ago) => timeAgoWords(l10n, now.subtract(ago), now: now);

      expect(when(const Duration(seconds: 30)), l10n.timeJustNow);
      expect(timeAgoWords(l10n, now.add(const Duration(minutes: 1)), now: now), l10n.timeJustNow);
      expect(when(const Duration(minutes: 5)), l10n.timeMinutesAgo(5));
      expect(when(const Duration(hours: 10)), l10n.timeHoursAgo(10));
      expect(when(const Duration(hours: 23, minutes: 59)), l10n.timeHoursAgo(23));
      expect(when(const Duration(days: 3)), l10n.timeDaysAgo(3));
      final old = DateTime(2026, 9, 28, 12);
      expect(timeAgoWords(l10n, old, now: now), DateFormat.yMMMd(l10n.localeName).format(old));
    });
  }

  test("a date past a week is the language's, not English's", () {
    final old = DateTime(2026, 9, 28, 12);
    final en = timeAgoWords(lookupAppLocalizations(const Locale('en')), old, now: now);
    for (final code in const ['de', 'ru', 'ja']) {
      expect(timeAgoWords(lookupAppLocalizations(Locale(code)), old, now: now), isNot(en), reason: code);
    }
  });
}
