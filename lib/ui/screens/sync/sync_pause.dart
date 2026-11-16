import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart' show AutoSyncService;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/time_text.dart';

/// When a pause of sync ends, as it is said ([until], in [localeName]): the
/// time where it is today, the day and the time where it is not.
String syncPausedUntilText(DateTime until, String localeName, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final sameDay = until.year == today.year && until.month == today.month && until.day == today.day;
  return sameDay
      ? DateFormat.jm(localeName).formatPlain(until)
      : DateFormat.MMMd(localeName).add_jm().formatPlain(until);
}

/// How long sync is paused, as the person chooses it: null while they have
/// not, and [SyncPauseLength.untilResumed] for until they resume it.
enum SyncPauseLength { hour, day, untilResumed }

/// Asks how long to pause sync on this device for (3.0; it stays set up, and
/// Sync now still syncs), and pauses it. False where they chose nothing.
Future<bool> pauseSyncAsked(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  // One of a few choices, in the shell (it was a Material SimpleDialog).
  final length = await showZestChoice<SyncPauseLength>(
    context,
    title: l10n.syncPauseTitle,
    subtitle: l10n.syncPauseNote,
    icon: LucideIcons.pauseCircle,
    choices: [
      for (final (length, label) in [
        (SyncPauseLength.hour, l10n.syncPauseForHour),
        (SyncPauseLength.day, l10n.syncPauseForDay),
        (SyncPauseLength.untilResumed, l10n.syncPauseUntilResumed),
      ])
        ZestChoice(value: length, label: label, key: ValueKey('sync-pause-${length.name}')),
    ],
  );
  if (length == null) return false;
  final now = DateTime.now();
  await ref.read(autoSyncServiceProvider).pause(
        until: switch (length) {
          SyncPauseLength.hour => now.add(const Duration(hours: 1)),
          SyncPauseLength.day => now.add(const Duration(days: 1)),
          SyncPauseLength.untilResumed => null,
        },
      );
  return true;
}

/// The schedules sync can run on, in the order they are offered: the mode,
/// and for 'auto' the minutes between two syncs.
const kSyncSchedules = <(String, int?)>[
  ('instant', null),
  ('auto', 5),
  ('auto', 10),
  ('auto', 15),
  ('auto', 30),
  ('auto', 60),
  ('auto', 120),
  ('auto', 360),
  ('auto', 1440),
  ('manual', null),
];

/// What a schedule ([mode], and [minutes] for 'auto') is called.
String syncScheduleLabel(AppLocalizations l10n, String mode, int minutes) => switch (mode) {
      'instant' => l10n.settingsSyncModeInstant,
      'auto' => syncIntervalLabel(l10n, minutes),
      'off' => l10n.settingsSyncModeOff,
      _ => l10n.settingsSyncModeManual,
    };

/// Every [minutes], as it is said.
String syncIntervalLabel(AppLocalizations l10n, int minutes) {
  if (minutes < 60) return l10n.settingsSyncIntervalMinutes(minutes);
  final hours = minutes ~/ 60;
  if (hours == 1) return l10n.settingsSyncIntervalHour;
  return l10n.settingsSyncIntervalHours(hours);
}

/// Asks when sync is to run on this device (3.0): on every change, every so
/// many minutes or hours, or only when the person syncs by hand; and makes
/// it so. False where they chose nothing.
Future<bool> chooseSyncScheduleAsked(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final mode = ref.read(syncModeProvider);
  final minutes = ref.read(syncIntervalProvider);
  bool chosen((String, int?) s) =>
      (s.$1 == mode && (s.$2 == null || s.$2 == minutes)) || (s.$1 == 'manual' && mode == 'off');
  final picked = await showZestChoice<(String, int?)>(
    context,
    title: l10n.settingsSyncMode,
    icon: LucideIcons.refreshCw,
    selected: kSyncSchedules.where(chosen).firstOrNull,
    choices: [
      for (final s in kSyncSchedules)
        ZestChoice(
          key: ValueKey('sync-schedule-${s.$1}${s.$2 ?? ''}'),
          value: s,
          label: syncScheduleLabel(l10n, s.$1, s.$2 ?? minutes),
          detail: switch (s.$1) {
            'instant' => l10n.syncInstantDescPull(AutoSyncService.instantPullEvery.inMinutes),
            'manual' => l10n.syncModeManualDesc,
            _ => null,
          },
        ),
    ],
  );
  if (picked == null) return false;
  final updater = ref.read(settingsUpdaterProvider);
  await updater.setSyncMode(picked.$1);
  if (picked.$2 != null) await updater.setSyncInterval(picked.$2!);
  // Runs by itself again as now chosen (or stops), from now.
  ref.read(autoSyncServiceProvider).startAutoSync();
  return true;
}
