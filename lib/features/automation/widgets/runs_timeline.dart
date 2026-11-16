import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart'
    show AutomationHistoryData, ScheduledTask;
import 'package:zestssh/features/automation/widgets/automation_shared.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';

// ══════════════════════════════════════════════════════════════════
// Runs timeline - the "Runs" tab.
//
// Merges what used to be two separate tabs (Schedule + History) into one
// day-grouped timeline: an "Upcoming runs" section (recurring scheduled
// workflows + OS-level scheduled tasks) at the top, then PAST runs grouped by
// day (Today / Yesterday / date). The All / Upcoming / Succeeded / Failed
// filter (Succeeded + Failed reuse the run-row outcome l10n keys) plus a
// rolling time range narrow the past runs; the upcoming section shows only
// under All + Upcoming. The whole filter bar hides when there are no runs.
// ══════════════════════════════════════════════════════════════════

class RunsTimeline extends ConsumerStatefulWidget {
  const RunsTimeline({super.key});

  @override
  ConsumerState<RunsTimeline> createState() => _RunsTimelineState();
}

/// The outcome filter for the Runs tab. Succeeded/Failed reuse the SAME l10n
/// keys as the run-row outcomes so the vocabulary is identical.
enum _RunFilter { all, upcoming, succeeded, failed }

/// A rolling time window applied to PAST runs.
enum _RunRange { last24h, last7d, last30d, all }

class _RunsTimelineState extends ConsumerState<RunsTimeline> {
  _RunFilter _filter = _RunFilter.all;
  _RunRange _range = _RunRange.all;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final historyAsync = ref.watch(automationLogProvider);

    // Upcoming: the scheduled tasks the system runs (Android's). They recur,
    // so they don't belong to a calendar day - they sit under a single
    // "Upcoming runs" header. valueOrNull so the timeline never blocks on the
    // tasks stream; the run history is the primary async. (A workflow's
    // schedule was listed here too, and nothing ran one: found
    // while comparing the five versions.)
    final tasks =
        ref.watch(scheduledTasksStreamProvider).valueOrNull ??
        const <ScheduledTask>[];

    final allEntries =
        historyAsync.valueOrNull ?? const <AutomationHistoryData>[];
    final hasUpcoming = tasks.isNotEmpty;
    // "No runs" ⇒ no past history AND nothing upcoming: hide the whole filter
    // bar (chips + time range) - there is nothing to filter.
    final hasAnyRuns = allEntries.isNotEmpty || hasUpcoming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Filter bar - hidden entirely when there are no runs.
        if (hasAnyRuns) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.zestAutoRunsHeader,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.v3TextSecondary,
                    ),
                  ),
                ),
                _TimeRangeControl(
                  range: _range,
                  onChanged: (r) => setState(() => _range = r),
                ),
                const SizedBox(width: 10),
                AutomationFilterChip(
                  label: l10n.zestAutoFilterAll,
                  isActive: _filter == _RunFilter.all,
                  onTap: () => setState(() => _filter = _RunFilter.all),
                ),
                const SizedBox(width: 4),
                AutomationFilterChip(
                  label: l10n.zestAutoFilterUpcoming,
                  isActive: _filter == _RunFilter.upcoming,
                  onTap: () => setState(() => _filter = _RunFilter.upcoming),
                ),
                const SizedBox(width: 4),
                AutomationFilterChip(
                  label: l10n.zestAutoOutcomeSucceeded,
                  isActive: _filter == _RunFilter.succeeded,
                  onTap: () => setState(() => _filter = _RunFilter.succeeded),
                ),
                const SizedBox(width: 4),
                AutomationFilterChip(
                  label: l10n.zestAutoOutcomeFailed,
                  isActive: _filter == _RunFilter.failed,
                  onTap: () => setState(() => _filter = _RunFilter.failed),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.v3BorderSubtle),
        ],

        Expanded(
          child: historyAsync.when(
            // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
            skipLoadingOnReload: true,
            loading: () => Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.v3AccentPrimary,
                ),
              ),
            ),
            error: (e, _) => Center(
              child: Text(
                AppLocalizations.of(context)!.automationRunsNotLoaded,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.v3Error.withValues(alpha: 0.8),
                ),
              ),
            ),
            data: (entries) {
              final runs = _applyFilter(entries)
                ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

              // Upcoming section shows under All + Upcoming filters only (an
              // upcoming run has no succeeded/failed outcome yet).
              final showUpcoming =
                  (_filter == _RunFilter.all ||
                      _filter == _RunFilter.upcoming) &&
                  hasUpcoming;

              if (runs.isEmpty && !showUpcoming) {
                // Tier-1: the WHOLE pane is empty, so the boxed state earns its
                // icon + heading + one sentence. Wrapped in a hairline rounded
                // box (the shared widget centres content but draws no border).
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.v3BorderSubtle,
                        width: 0.5,
                      ),
                    ),
                    child: ZestEmptyState(
                      icon: LucideIcons.history,
                      title: l10n.zestAutoRunsEmptyTitle,
                      message: l10n.zestAutoRunsEmptyBody,
                    ),
                  ),
                );
              }

              final children = <Widget>[];

              // ── Upcoming ──────────────────────────────────────────
              if (showUpcoming) {
                children.add(
                  ZestSectionHeader(label: l10n.zestAutoScheduleAgendaTitle),
                );
                children.add(const SizedBox(height: 10));
                for (final task in tasks) {
                  children.add(
                    _AgendaRow(
                      icon: LucideIcons.calendarClock,
                      title: task.name,
                      schedule: _taskSchedule(l10n, task),
                      enabled: task.enabled,
                    ),
                  );
                }
              }

              // ── Past runs, grouped by calendar day ────────────────
              String? lastDayKey;
              var firstDay = true;
              for (final run in runs) {
                final key = _dayKey(run.timestamp);
                if (key != lastDayKey) {
                  lastDayKey = key;
                  children.add(
                    SizedBox(
                      height: firstDay && !showUpcoming
                          ? 0
                          : (firstDay ? 6 : 14),
                    ),
                  );
                  firstDay = false;
                  children.add(
                    ZestSectionHeader(label: _dayLabel(l10n, run.timestamp)),
                  );
                  children.add(const SizedBox(height: 10));
                }
                children.add(
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: AutomationHistoryRow(entry: run),
                  ),
                );
              }

              return ListView(
                padding: const EdgeInsets.all(16),
                children: children,
              );
            },
          ),
        ),
      ],
    );
  }

  /// Past runs after applying BOTH the outcome filter and the time range. The
  /// "upcoming" filter shows no past runs (only the upcoming section).
  List<AutomationHistoryData> _applyFilter(
    List<AutomationHistoryData> entries,
  ) {
    if (_filter == _RunFilter.upcoming) return const [];

    final cutoff = _rangeCutoff(_range);
    return entries.where((e) {
      if (cutoff != null && e.timestamp.isBefore(cutoff)) return false;
      switch (_filter) {
        case _RunFilter.succeeded:
          return e.success;
        case _RunFilter.failed:
          return !e.success;
        case _RunFilter.all:
        case _RunFilter.upcoming:
          return true;
      }
    }).toList();
  }

  /// The earliest timestamp still inside [range], or null for "all time".
  DateTime? _rangeCutoff(_RunRange range) {
    final now = DateTime.now();
    switch (range) {
      case _RunRange.last24h:
        return now.subtract(const Duration(hours: 24));
      case _RunRange.last7d:
        return now.subtract(const Duration(days: 7));
      case _RunRange.last30d:
        return now.subtract(const Duration(days: 30));
      case _RunRange.all:
        return null;
    }
  }

  String _dayKey(DateTime dt) => '${dt.year}-${dt.month}-${dt.day}';

  String _dayLabel(AppLocalizations l10n, DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return l10n.zestAutoDayToday;
    if (diff == 1) return l10n.zestAutoDayYesterday;
    return automationDate(l10n, dt);
  }

  // ── Schedule humanization (replicated from schedule_agenda) ────────
  // In the person's language, as the phone's schedule says it (it was
  // English whatever the language).
  String _taskSchedule(AppLocalizations l10n, ScheduledTask task) {
    final type = ScheduleType.fromKey(task.scheduleType);
    switch (type) {
      case ScheduleType.interval:
        return ScheduleIntervals.displayLabel(l10n, task.intervalMinutes);
      case ScheduleType.daily:
        return l10n.schedTaskDailyAt(_time(task.hour, task.minute));
      case ScheduleType.weekly:
        return l10n.schedTaskWeeklyAt(WeekDay.name(l10n, task.dayOfWeek ?? 1), _time(task.hour, task.minute));
    }
  }

  String _time(int? hour, int? minute) {
    final h = (hour ?? 9).toString().padLeft(2, '0');
    final m = (minute ?? 0).toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ── Time-range control ───────────────────────────────────────────────

/// A compact dropdown that narrows the PAST runs to a rolling window. Styled to
/// match [AutomationFilterChip] (28px, hairline border) so it reads as part of
/// the same filter cluster.
class _TimeRangeControl extends StatelessWidget {
  const _TimeRangeControl({required this.range, required this.onChanged});

  final _RunRange range;
  final ValueChanged<_RunRange> onChanged;

  String _label(AppLocalizations l10n, _RunRange r) => switch (r) {
    _RunRange.last24h => l10n.zestAutoRange24h,
    _RunRange.last7d => l10n.zestAutoRange7d,
    _RunRange.last30d => l10n.zestAutoRange30d,
    _RunRange.all => l10n.zestAutoRangeAll,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<_RunRange>(
      tooltip: '',
      position: PopupMenuPosition.under,
      color: AppColors.v3Elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: AppColors.v3BorderDefault, width: 0.5),
      ),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final r in _RunRange.values)
          PopupMenuItem<_RunRange>(
            value: r,
            height: 36,
            child: Row(
              children: [
                Icon(
                  LucideIcons.check,
                  size: 14,
                  color: r == range
                      ? AppColors.v3AccentInk
                      : Colors.transparent,
                ),
                const SizedBox(width: 8),
                Text(
                  _label(l10n, r),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: AppColors.v3Surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.v3BorderDefault, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.calendarClock,
              size: 13,
              color: AppColors.v3TextTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              _label(l10n, range),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.v3TextSecondary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              LucideIcons.chevronDown,
              size: 12,
              color: AppColors.v3TextTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Upcoming-schedule row ────────────────────────────────────────────

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({
    required this.icon,
    required this.title,
    required this.schedule,
    required this.enabled,
  });

  final IconData icon;
  final String title;
  final String schedule;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: ZestTokens.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ZestTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  schedule,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'JetBrainsMono',
                    color: ZestTokens.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          ZestStatusPill(
            kind: enabled ? ZestStatusKind.healthy : ZestStatusKind.neutral,
            label: enabled
                ? AppLocalizations.of(context)!.autoRunsScheduleActive
                : AppLocalizations.of(context)!.autoRunsSchedulePaused,
          ),
        ],
      ),
    );
  }
}
