import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

// When something was, in the person's language (3.0, 17 October 2026). The
// automation's runs and API keys, the bell, the Keys page, the palette, the
// Hosts page's recent hosts and the Server Monitor said it in English in
// every language ("just now", "5m ago", "3d", "Sep 28"), each with words of
// its own; they say it here, in the strings of the twelve languages, and a
// date as the language writes it.
//
// One compact style for every time a person reads (a
// design audit found "2 mins
// ago", "4m ago", "1 h 59 min left" and "2h" side by side): "4m ago", "2h
// ago", "1h 59m left", "2h 5m", each language with its own short form. When
// something was, how long is left and how long something lasted are all said
// here, with the same words on every screen.

/// When [when] was, in [l10n]'s language, as words of their own (a line or a
/// value that stands alone): just now, minutes, hours or days ago, and past a
/// week the date as the language writes it. A time ahead of the clock (a
/// device's that runs ahead) is just now. With [seconds], from 10 seconds to
/// a minute it says the seconds (a reading that refreshes every few seconds).
/// With [keepCounting], past a week it counts on instead of the date: weeks
/// under five, then months (a list that says how long ago each was used).
/// [now] is for tests.
String timeAgoWords(AppLocalizations l10n, DateTime when,
        {DateTime? now, bool seconds = false, bool keepCounting = false}) =>
    _ago(l10n, when, now ?? DateTime.now(), l10n.timeJustNow,
        seconds: seconds, keepCounting: keepCounting, date: () => DateFormat.yMMMd(l10n.localeName).format(when));

/// When [when] was, as words that follow others in a sentence ("Created
/// {time}", "Last used {time}"): they begin with a small letter where the
/// language has them (a French key "Créée il y a 5 min", not "Créée Il y a 5
/// min"), the same compact words as [timeAgoWords] with just now begun small;
/// past a week the date as the language writes it. With [seconds], from 10
/// seconds to a minute it says the seconds; [keepCounting] as in
/// [timeAgoWords].
String timeAgoInSentence(AppLocalizations l10n, DateTime when,
        {DateTime? now, bool seconds = false, bool keepCounting = false}) =>
    _ago(l10n, when, now ?? DateTime.now(), l10n.settingsMobJustNow,
        seconds: seconds, keepCounting: keepCounting, date: () => DateFormat.yMMMd(l10n.localeName).format(when));

/// When [when] was, for a narrow cell: the words of [timeAgoWords] ("2h ago",
/// not "2h"), and past a week the day and
/// the month in figures as the language orders them, and in a year before
/// this one the year.
String timeAgoShort(AppLocalizations l10n, DateTime when, {DateTime? now}) {
  final at = now ?? DateTime.now();
  return _ago(l10n, when, at, l10n.timeJustNow,
      seconds: false,
      keepCounting: false,
      date: () => when.year == at.year
          ? DateFormat.Md(l10n.localeName).format(when)
          : DateFormat.y(l10n.localeName).format(when));
}

/// The compact words of when [when] was, [justNow] under a minute, [date]
/// past a week unless [keepCounting].
String _ago(AppLocalizations l10n, DateTime when, DateTime now, String justNow,
    {required bool seconds, required bool keepCounting, required String Function() date}) {
  final diff = now.difference(when);
  if (seconds && diff.inSeconds >= 10 && diff.inSeconds < 60) return l10n.timeSecondsAgo(diff.inSeconds);
  if (diff.isNegative || diff.inSeconds < 60) return justNow;
  if (diff.inMinutes < 60) return l10n.timeMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l10n.timeHoursAgo(diff.inHours);
  if (diff.inDays < 7) return l10n.timeDaysAgo(diff.inDays);
  if (!keepCounting) return date();
  if (diff.inDays < 35) return l10n.timeWeeksAgo(diff.inDays ~/ 7);
  return l10n.timeMonthsAgo(diff.inDays ~/ 30);
}

/// How long ago [since] was, in a few letters, for a reading said to be that
/// old ("checked {time} ago"): under a minute, minutes, hours, then days.
String timeSinceShort(AppLocalizations l10n, DateTime since, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(since);
  if (diff.inMinutes < 1) return '<${l10n.notificationsRelativeMinutes(1)}';
  if (diff.inMinutes < 60) return l10n.notificationsRelativeMinutes(diff.inMinutes);
  if (diff.inHours < 24) return l10n.notificationsRelativeHours(diff.inHours);
  return l10n.notificationsRelativeDays(diff.inDays);
}

/// How long is left of [left], compact ("1h 59m left"): days past a day,
/// hours and minutes past an hour, else minutes, at least one (what has not
/// ended never says none left). With [seconds], under an hour it says the
/// minutes and the seconds, and under a minute the seconds (a count that
/// ticks, as a transfer's).
String timeLeftWords(AppLocalizations l10n, Duration left, {bool seconds = false}) {
  if (left.inDays >= 1) return l10n.timeLeftDays(left.inDays);
  if (left.inHours >= 1) return l10n.timeLeftHoursMinutes(left.inHours, left.inMinutes % 60);
  if (!seconds) return l10n.timeLeftMinutes(left.inMinutes < 1 ? 1 : left.inMinutes);
  final s = left.isNegative ? 0 : left.inSeconds;
  if (s < 60) return l10n.timeLeftSeconds(s);
  return l10n.timeLeftMinutesSeconds(s ~/ 60, s % 60);
}

/// How long [length] lasted or has lasted so far, compact ("2h 5m"): days and
/// hours past a day, hours and minutes past an hour, else minutes, at least
/// one. With [seconds], under an hour it says the minutes and the seconds,
/// and under a minute the seconds.
String durationWords(AppLocalizations l10n, Duration length, {bool seconds = false}) {
  if (length.inDays >= 1) return l10n.durationDaysHours(length.inDays, length.inHours % 24);
  if (length.inHours >= 1) return l10n.durationHoursMinutes(length.inHours, length.inMinutes % 60);
  if (!seconds) return l10n.durationMinutes(length.inMinutes < 1 ? 1 : length.inMinutes);
  final s = length.isNegative ? 0 : length.inSeconds;
  if (s < 60) return l10n.durationSeconds(s);
  return l10n.durationMinutesSeconds(s ~/ 60, s % 60);
}
