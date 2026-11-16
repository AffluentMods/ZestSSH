import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';

// When something was, in the person's language (3.0): the
// automation's runs and API keys, the bell, the Keys page, the palette, the
// Hosts page's recent hosts and the Server Monitor said it in English in
// every language ("just now", "5m ago", "3d", "Sep 28"), each with words of
// its own.
void main() {
  setUpAll(initializeDateFormatting);

  final now = DateTime(2026, 10, 17, 22, 30);
  DateTime ago(Duration d) => now.subtract(d);
  final ahead = now.add(const Duration(minutes: 3));

  for (final locale in AppLocalizations.supportedLocales) {
    final l10n = lookupAppLocalizations(locale);
    final language = l10n.localeName;

    test('in $locale, words of their own: just now, minutes, hours or days ago, and past a week the date', () {
      String said(Duration d) => timeAgoWords(l10n, ago(d), now: now);
      expect(said(Duration.zero), l10n.timeJustNow);
      expect(said(const Duration(seconds: 59)), l10n.timeJustNow);
      expect(timeAgoWords(l10n, ahead, now: now), l10n.timeJustNow, reason: 'a clock that runs ahead');
      expect(said(const Duration(minutes: 1)), l10n.timeMinutesAgo(1));
      expect(said(const Duration(minutes: 59)), l10n.timeMinutesAgo(59));
      expect(said(const Duration(hours: 1)), l10n.timeHoursAgo(1));
      expect(said(const Duration(hours: 23, minutes: 59)), l10n.timeHoursAgo(23));
      expect(said(const Duration(days: 1)), l10n.timeDaysAgo(1));
      expect(said(const Duration(days: 6, hours: 23)), l10n.timeDaysAgo(6));
      expect(said(const Duration(days: 7)), DateFormat.yMMMd(language).format(ago(const Duration(days: 7))));
    });

    test('in $locale, inside a sentence: the same compact words, just now begun small, and past a week the date',
        () {
      String said(Duration d) => timeAgoInSentence(l10n, ago(d), now: now);
      expect(said(const Duration(seconds: 30)), l10n.settingsMobJustNow);
      expect(timeAgoInSentence(l10n, ahead, now: now), l10n.settingsMobJustNow);
      expect(said(const Duration(minutes: 1)), l10n.timeMinutesAgo(1));
      expect(said(const Duration(minutes: 5)), l10n.timeMinutesAgo(5));
      expect(said(const Duration(hours: 23)), l10n.timeHoursAgo(23));
      expect(said(const Duration(days: 6)), l10n.timeDaysAgo(6));
      expect(said(const Duration(days: 10)), DateFormat.yMMMd(language).format(ago(const Duration(days: 10))));
    });

    test('in $locale, for a narrow cell: the same compact words, past a week the day and month, before this '
        'year the year', () {
      String said(Duration d) => timeAgoShort(l10n, ago(d), now: now);
      expect(said(const Duration(seconds: 30)), l10n.timeJustNow);
      expect(timeAgoShort(l10n, ahead, now: now), l10n.timeJustNow);
      expect(said(const Duration(minutes: 59)), l10n.timeMinutesAgo(59));
      expect(said(const Duration(hours: 5)), l10n.timeHoursAgo(5));
      expect(said(const Duration(days: 6)), l10n.timeDaysAgo(6));
      expect(said(const Duration(days: 19)), DateFormat.Md(language).format(DateTime(2026, 9, 28)));
      expect(timeAgoShort(l10n, DateTime(2025, 12, 30), now: now), DateFormat.y(language).format(DateTime(2025)));
    });

    test('in $locale, how long since, in a few letters: under a minute, minutes, hours, then days', () {
      String said(Duration d) => timeSinceShort(l10n, ago(d), now: now);
      expect(said(const Duration(seconds: 30)), '<${l10n.notificationsRelativeMinutes(1)}');
      expect(said(const Duration(minutes: 18)), l10n.notificationsRelativeMinutes(18));
      expect(said(const Duration(hours: 5)), l10n.notificationsRelativeHours(5));
      expect(said(const Duration(days: 40)), l10n.notificationsRelativeDays(40));
    });

    test('in $locale, inside a sentence the words begin with a small letter where the language has them', () {
      for (final d in const [Duration(seconds: 5), Duration(minutes: 5), Duration(hours: 5), Duration(days: 5)]) {
        final said = timeAgoInSentence(l10n, ago(d), now: now);
        expect(said[0], said[0].toLowerCase(), reason: '"$said"');
      }
    });
  }

  test("in German, Russian and Japanese none of it is English's", () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final code in const ['de', 'ru', 'ja']) {
      final l10n = lookupAppLocalizations(Locale(code));
      for (final d in const [Duration(seconds: 5), Duration(minutes: 5), Duration(hours: 5), Duration(days: 5)]) {
        final at = ago(d);
        expect(timeAgoWords(l10n, at, now: now), isNot(timeAgoWords(en, at, now: now)), reason: '$code, $d');
        expect(timeAgoInSentence(l10n, at, now: now), isNot(timeAgoInSentence(en, at, now: now)), reason: '$code, $d');
        expect(timeAgoShort(l10n, at, now: now), isNot(timeAgoShort(en, at, now: now)), reason: '$code, $d');
        expect(timeSinceShort(l10n, at, now: now), isNot(timeSinceShort(en, at, now: now)), reason: '$code, $d');
      }
      final before = ago(const Duration(days: 19));
      expect(timeAgoWords(l10n, before, now: now), isNot(timeAgoWords(en, before, now: now)), reason: code);
      expect(timeAgoInSentence(l10n, before, now: now), isNot(timeAgoInSentence(en, before, now: now)), reason: code);
    }
  });
}
