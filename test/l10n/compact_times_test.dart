import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';

// One compact style for every time a person reads (for example
// "4m ago", "2h ago", "1h 59m left"), each language with its
// own short form. A design review found "2 mins ago",
// "4m ago", "1 h 59 min left" and "2h" side by side.
void main() {
  setUpAll(initializeDateFormatting);

  final now = DateTime(2026, 11, 4, 12);
  DateTime ago(Duration d) => now.subtract(d);
  final en = lookupAppLocalizations(const Locale('en'));

  for (final locale in AppLocalizations.supportedLocales) {
    final l10n = lookupAppLocalizations(locale);

    test('in $locale, when something was: each unit from its first moment to its last', () {
      String said(Duration d, {bool seconds = false, bool keepCounting = false}) =>
          timeAgoWords(l10n, ago(d), now: now, seconds: seconds, keepCounting: keepCounting);
      String counted(Duration d) => said(d, keepCounting: true);

      expect(counted(Duration.zero), l10n.timeJustNow);
      expect(counted(const Duration(seconds: 59)), l10n.timeJustNow);
      expect(said(const Duration(seconds: 9), seconds: true), l10n.timeJustNow);
      expect(said(const Duration(seconds: 10), seconds: true), l10n.timeSecondsAgo(10));
      expect(said(const Duration(seconds: 59), seconds: true), l10n.timeSecondsAgo(59));
      expect(said(const Duration(seconds: 60), seconds: true), l10n.timeMinutesAgo(1));
      expect(counted(const Duration(minutes: 1)), l10n.timeMinutesAgo(1));
      expect(counted(const Duration(minutes: 59, seconds: 59)), l10n.timeMinutesAgo(59));
      expect(counted(const Duration(hours: 1)), l10n.timeHoursAgo(1));
      expect(counted(const Duration(hours: 23, minutes: 59)), l10n.timeHoursAgo(23));
      expect(counted(const Duration(days: 1)), l10n.timeDaysAgo(1));
      expect(counted(const Duration(days: 6, hours: 23)), l10n.timeDaysAgo(6));
      expect(counted(const Duration(days: 7)), l10n.timeWeeksAgo(1));
      expect(counted(const Duration(days: 34, hours: 23)), l10n.timeWeeksAgo(4));
      expect(counted(const Duration(days: 35)), l10n.timeMonthsAgo(1));
      expect(counted(const Duration(days: 59)), l10n.timeMonthsAgo(1));
      expect(counted(const Duration(days: 60)), l10n.timeMonthsAgo(2));
      expect(counted(const Duration(days: 400)), l10n.timeMonthsAgo(13));
      expect(
        said(const Duration(days: 7)),
        DateFormat.yMMMd(l10n.localeName).format(ago(const Duration(days: 7))),
        reason: 'past a week the date, unless it counts on',
      );
      expect(
        timeAgoWords(l10n, now.add(const Duration(minutes: 3)), now: now, keepCounting: true),
        l10n.timeJustNow,
        reason: 'a clock that runs ahead',
      );
    });

    test('in $locale, inside a sentence the same words, just now begun small', () {
      String said(Duration d) => timeAgoInSentence(l10n, ago(d), now: now, keepCounting: true);
      expect(said(const Duration(seconds: 30)), l10n.settingsMobJustNow);
      expect(said(const Duration(minutes: 4)), timeAgoWords(l10n, ago(const Duration(minutes: 4)), now: now));
      expect(said(const Duration(days: 20)), l10n.timeWeeksAgo(2));
      for (final d in const [
        Duration(seconds: 5),
        Duration(minutes: 4),
        Duration(hours: 2),
        Duration(days: 3),
        Duration(days: 20),
        Duration(days: 90),
      ]) {
        final s = said(d);
        expect(s[0], s[0].toLowerCase(), reason: '"$s"');
      }
    });

    test('in $locale, how long is left: each unit from its first moment to its last', () {
      String left(Duration d, {bool seconds = false}) => timeLeftWords(l10n, d, seconds: seconds);

      expect(left(const Duration(seconds: -5)), l10n.timeLeftMinutes(1), reason: 'never none left');
      expect(left(Duration.zero), l10n.timeLeftMinutes(1));
      expect(left(const Duration(seconds: 59)), l10n.timeLeftMinutes(1));
      expect(left(const Duration(minutes: 1)), l10n.timeLeftMinutes(1));
      expect(left(const Duration(minutes: 59, seconds: 59)), l10n.timeLeftMinutes(59));
      expect(left(const Duration(hours: 1)), l10n.timeLeftHoursMinutes(1, 0));
      expect(left(const Duration(hours: 1, minutes: 59, seconds: 30)), l10n.timeLeftHoursMinutes(1, 59));
      expect(left(const Duration(hours: 23, minutes: 59)), l10n.timeLeftHoursMinutes(23, 59));
      expect(left(const Duration(days: 1)), l10n.timeLeftDays(1));
      expect(left(const Duration(days: 1, hours: 23)), l10n.timeLeftDays(1));
      expect(left(const Duration(days: 2)), l10n.timeLeftDays(2));

      expect(left(const Duration(seconds: -5), seconds: true), l10n.timeLeftSeconds(0));
      expect(left(const Duration(seconds: 1), seconds: true), l10n.timeLeftSeconds(1));
      expect(left(const Duration(seconds: 59), seconds: true), l10n.timeLeftSeconds(59));
      expect(left(const Duration(seconds: 60), seconds: true), l10n.timeLeftMinutesSeconds(1, 0));
      expect(left(const Duration(minutes: 59, seconds: 59), seconds: true), l10n.timeLeftMinutesSeconds(59, 59));
      expect(left(const Duration(hours: 1), seconds: true), l10n.timeLeftHoursMinutes(1, 0));
      expect(left(const Duration(days: 3), seconds: true), l10n.timeLeftDays(3));
    });

    test('in $locale, how long something lasted: each unit from its first moment to its last', () {
      String lasted(Duration d, {bool seconds = false}) => durationWords(l10n, d, seconds: seconds);

      expect(lasted(Duration.zero), l10n.durationMinutes(1), reason: 'at least a minute');
      expect(lasted(const Duration(seconds: 59)), l10n.durationMinutes(1));
      expect(lasted(const Duration(minutes: 1)), l10n.durationMinutes(1));
      expect(lasted(const Duration(minutes: 59, seconds: 59)), l10n.durationMinutes(59));
      expect(lasted(const Duration(hours: 1)), l10n.durationHoursMinutes(1, 0));
      expect(lasted(const Duration(hours: 23, minutes: 59)), l10n.durationHoursMinutes(23, 59));
      expect(lasted(const Duration(days: 1)), l10n.durationDaysHours(1, 0));
      expect(lasted(const Duration(hours: 49, minutes: 5)), l10n.durationDaysHours(2, 1));

      expect(lasted(Duration.zero, seconds: true), l10n.durationSeconds(0));
      expect(lasted(const Duration(seconds: 59), seconds: true), l10n.durationSeconds(59));
      expect(lasted(const Duration(seconds: 60), seconds: true), l10n.durationMinutesSeconds(1, 0));
      expect(lasted(const Duration(minutes: 59, seconds: 59), seconds: true), l10n.durationMinutesSeconds(59, 59));
      expect(lasted(const Duration(hours: 1), seconds: true), l10n.durationHoursMinutes(1, 0));
    });
  }

  test('in English, the words chosen', () {
    expect(timeAgoWords(en, ago(const Duration(seconds: 30)), now: now), 'Just now');
    expect(timeAgoInSentence(en, ago(const Duration(seconds: 30)), now: now), 'just now');
    expect(timeAgoInSentence(en, ago(const Duration(minutes: 2)), now: now), '2m ago', reason: 'not "2 mins ago"');
    expect(timeAgoWords(en, ago(const Duration(minutes: 4)), now: now), '4m ago');
    expect(timeAgoShort(en, ago(const Duration(hours: 2)), now: now), '2h ago', reason: 'not "2h"');
    expect(timeAgoInSentence(en, ago(const Duration(hours: 1)), now: now), '1h ago', reason: 'not "1 hour ago"');
    expect(timeAgoWords(en, ago(const Duration(days: 3)), now: now), '3d ago');
    expect(timeAgoWords(en, ago(const Duration(days: 21)), now: now, keepCounting: true), '3w ago');
    expect(timeAgoWords(en, ago(const Duration(days: 65)), now: now, keepCounting: true), '2mo ago');
    expect(timeAgoWords(en, ago(const Duration(seconds: 42)), now: now, seconds: true), '42s ago');

    expect(timeLeftWords(en, const Duration(hours: 1, minutes: 59)), '1h 59m left', reason: 'not "1 h 59 min left"');
    expect(timeLeftWords(en, const Duration(minutes: 4)), '4m left');
    expect(timeLeftWords(en, const Duration(days: 3)), '3d left');
    expect(timeLeftWords(en, const Duration(seconds: 45), seconds: true), '45s left');
    expect(timeLeftWords(en, const Duration(minutes: 4, seconds: 3), seconds: true), '4m 3s left');

    expect(durationWords(en, const Duration(minutes: 45)), '45m');
    expect(durationWords(en, const Duration(hours: 2, minutes: 5)), '2h 5m');
    expect(durationWords(en, const Duration(days: 3, hours: 4)), '3d 4h');
    expect(durationWords(en, const Duration(seconds: 42), seconds: true), '42s');
    expect(durationWords(en, const Duration(minutes: 4, seconds: 9), seconds: true), '4m 9s');
    expect(en.homeConnectedFor(durationWords(en, const Duration(hours: 2, minutes: 5))), 'Connected 2h 5m');
  });

  test("access for a set time says its time left in the compact words (a review's \"1 h 59 min left\")", () {
    final until = now.add(const Duration(hours: 1, minutes: 59, seconds: 30)).millisecondsSinceEpoch ~/ 1000;
    expect(accessLeftText(until, en, now: now), '1h 59m left');
    final day = now.add(const Duration(days: 1, hours: 2)).millisecondsSinceEpoch ~/ 1000;
    expect(accessLeftText(day, en, now: now), '1d left', reason: 'not "A day left"');
    final minute = now.add(const Duration(seconds: 20)).millisecondsSinceEpoch ~/ 1000;
    expect(accessLeftText(minute, en, now: now), '1m left', reason: 'not "A minute left"');
  });

  test('each language its own short form', () {
    String inLang(String code, String Function(AppLocalizations l) say) => say(lookupAppLocalizations(Locale(code)));

    expect(inLang('de', (l) => timeAgoWords(l, ago(const Duration(minutes: 4)), now: now)), 'vor 4 Min.');
    expect(inLang('de', (l) => timeLeftWords(l, const Duration(hours: 1, minutes: 59))), 'Noch 1 Std. 59 Min.');
    expect(inLang('de', (l) => durationWords(l, const Duration(hours: 2, minutes: 5))), '2 Std. 5 Min.');
    expect(
      inLang('de', (l) => l.homeConnectedFor(durationWords(l, const Duration(minutes: 4)))),
      'Verbunden seit 4 Min.',
      reason: 'not "Verbunden 4m"',
    );
    expect(inLang('ja', (l) => timeAgoWords(l, ago(const Duration(minutes: 4)), now: now)), '4分前');
    expect(inLang('ja', (l) => timeLeftWords(l, const Duration(hours: 1, minutes: 59))), '残り 1時間 59分');
    expect(
      inLang('es', (l) => timeAgoWords(l, ago(const Duration(minutes: 4)), now: now)),
      'hace 4 min',
      reason: 'as every other Spanish screen said it, not "hace 4m"',
    );
    expect(inLang('fr', (l) => timeAgoWords(l, ago(const Duration(minutes: 4)), now: now)), 'il y a 4 min');
    expect(
      inLang('fr', (l) => l.triggersViewCreatedAgo(timeAgoInSentence(l, ago(const Duration(hours: 2)), now: now))),
      'Créée il y a 2 h',
      reason: 'small inside a sentence',
    );
    expect(inLang('zh', (l) => timeLeftWords(l, const Duration(minutes: 5))), '还剩 5 分钟');

    // Plurals where a language's words change with the count.
    expect(inLang('es', (l) => timeLeftWords(l, const Duration(minutes: 1))), 'Queda 1 min');
    expect(inLang('es', (l) => timeLeftWords(l, const Duration(minutes: 5))), 'Quedan 5 min');
    expect(
      inLang('es', (l) => timeAgoWords(l, ago(const Duration(days: 40)), now: now, keepCounting: true)),
      'hace 1 mes',
    );
    expect(
      inLang('es', (l) => timeAgoWords(l, ago(const Duration(days: 95)), now: now, keepCounting: true)),
      'hace 3 meses',
    );
    expect(inLang('fr', (l) => timeLeftWords(l, const Duration(minutes: 1))), '1 min restante');
    expect(inLang('fr', (l) => timeLeftWords(l, const Duration(minutes: 5))), '5 min restantes');
    expect(inLang('fr', (l) => timeLeftWords(l, const Duration(days: 2))), '2 j restants');
    expect(
      inLang('it', (l) => timeAgoWords(l, ago(const Duration(days: 40)), now: now, keepCounting: true)),
      '1 mese fa',
    );
    expect(
      inLang('pt', (l) => timeAgoWords(l, ago(const Duration(days: 40)), now: now, keepCounting: true)),
      'há 1 mês',
    );
    expect(inLang('pt', (l) => timeLeftWords(l, const Duration(minutes: 5))), '5min restantes');
    expect(inLang('ru', (l) => timeLeftWords(l, const Duration(minutes: 1))), 'Осталась 1 мин');
    expect(inLang('ru', (l) => timeLeftWords(l, const Duration(minutes: 21))), 'Осталась 21 мин');
    expect(inLang('ru', (l) => timeLeftWords(l, const Duration(minutes: 5))), 'Осталось 5 мин');

    // None of it is English's in German, Russian, Japanese and Chinese.
    for (final code in const ['de', 'ru', 'ja', 'zh']) {
      final l = lookupAppLocalizations(Locale(code));
      expect(
        timeAgoWords(l, ago(const Duration(days: 21)), now: now, keepCounting: true),
        isNot(timeAgoWords(en, ago(const Duration(days: 21)), now: now, keepCounting: true)),
        reason: code,
      );
      expect(
        timeLeftWords(l, const Duration(hours: 1, minutes: 59)),
        isNot(timeLeftWords(en, const Duration(hours: 1, minutes: 59))),
        reason: code,
      );
      expect(
        durationWords(l, const Duration(hours: 2, minutes: 5)),
        isNot(durationWords(en, const Duration(hours: 2, minutes: 5))),
        reason: code,
      );
    }
  });
}
