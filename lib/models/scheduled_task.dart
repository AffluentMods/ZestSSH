import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Schedule types for recurring tasks.
enum ScheduleType {
  /// Run every N minutes.
  interval('interval', 'Every N Minutes'),

  /// Run once daily at a specific time.
  daily('daily', 'Daily'),

  /// Run once weekly on a specific day at a specific time.
  weekly('weekly', 'Weekly');

  const ScheduleType(this.key, this.englishName);

  final String key;

  /// Its name in English, for the log: screens show it in the
  /// person's language (lib/l10n/list_names.dart; it was shown as it is,
  /// in English, whatever the language).
  final String englishName;

  static ScheduleType fromKey(String key) {
    return ScheduleType.values.firstWhere(
      (e) => e.key == key,
      orElse: () => ScheduleType.interval,
    );
  }
}

/// Action types for scheduled tasks.
enum ScheduledTaskAction {
  /// Execute a raw shell command.
  execute('execute', 'Execute Command'),

  /// Run a saved snippet.
  snippet('snippet', 'Run Snippet'),

  /// Run a saved workflow.
  workflow('workflow', 'Run Workflow');

  const ScheduledTaskAction(this.key, this.englishName);

  final String key;

  /// Its name in English, for the log: screens show it in the
  /// person's language (lib/l10n/list_names.dart; it was shown as it is,
  /// in English, whatever the language).
  final String englishName;

  static ScheduledTaskAction fromKey(String key) {
    return ScheduledTaskAction.values.firstWhere(
      (e) => e.key == key,
      orElse: () => ScheduledTaskAction.execute,
    );
  }
}

/// Common interval presets in minutes.
class ScheduleIntervals {
  static const List<int> presets = [15, 30, 60, 120, 360, 720, 1440];

  /// [minutes] as a schedule says it, in the person's language ("Every 30
  /// min", "Every hour", "Every 6 hours", "Every day"). It was English
  /// whatever the language.
  static String displayLabel(AppLocalizations l10n, int minutes) {
    if (minutes < 60 || minutes % 60 != 0) return l10n.schedTaskEveryMinutes(minutes);
    if (minutes < 1440 || minutes % 1440 != 0) return l10n.schedTaskEveryHours(minutes ~/ 60);
    return l10n.schedTaskEveryDays(minutes ~/ 1440);
  }
}

/// Days of the week for weekly schedules, 1 (Monday) to 7 (Sunday), as
/// DateTime.weekday numbers them.
class WeekDay {
  static const List<int> days = [1, 2, 3, 4, 5, 6, 7];

  /// The date of a [day] (1 January 2024 was a Monday), to name it by.
  static DateTime _a(int day) => DateTime(2024, 1, day.clamp(1, 7));

  /// [day]'s name in the person's language ("Monday", "lundi"); it was
  /// English whatever the language.
  static String name(AppLocalizations l10n, int day) => DateFormat.EEEE(l10n.localeName).format(_a(day));

  /// [day]'s short name in the person's language ("Mon", "lun.").
  static String shortName(AppLocalizations l10n, int day) => DateFormat.E(l10n.localeName).format(_a(day));
}
