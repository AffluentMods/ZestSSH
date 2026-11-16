import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/locked_feature_view.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/models/workflow.dart' show Workflow;
import 'package:zestssh/providers/terminal_providers.dart' show noCommandReason;
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Maps a raw error object to a short, user-facing sentence. Avoids dumping a
/// raw exception `toString()` (internal type names, drifty internals) straight
/// into the UI where it means nothing to the user and can leak detail.
String _describeError(BuildContext context, Object error) {
  final l10n = AppLocalizations.of(context)!;
  if (error is SocketException) {
    return l10n.schedTaskErrorNetwork;
  }
  if (error is TimeoutException) return l10n.schedTaskErrorTimeout;
  return l10n.schedTaskErrorGeneric;
}

/// Screen for managing background-scheduled SSH automation tasks.
///
/// On Android, tasks run via WorkManager even when ZestSSH is closed. On a
/// computer (4.0) the app runs them itself while it is open or in the tray,
/// which the page says above the tasks ([ComputerTaskScheduler]). On iOS an
/// informational message is shown instead.
class ScheduledTasksScreen extends ConsumerWidget {
  const ScheduledTasksScreen({super.key});

  /// A test's word on where the screen is drawn as being (Android's list
  /// drawn on a computer, say); null asks the system the app runs on.
  @visibleForTesting
  static ScheduledTasksHere? debugHere;

  static ScheduledTasksHere get _here => debugHere ?? scheduledTasksHere;
  static bool get _runsHere => _here != ScheduledTasksHere.none;
  static bool get _computer => _here == ScheduledTasksHere.computer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.schedTaskTitle),
        backgroundColor: AppColors.surface,
      ),
      floatingActionButton: _runsHere && isPro
          ? FloatingActionButton(
              // Named for a screen reader, and on a computer's hover.
              tooltip: l10n.schedTaskNewTitle,
              backgroundColor: AppColors.orange,
              onPressed: () => _showCreateDialog(context, ref),
              // The ink that reads on the orange (white was 2.6:1).
              child: Icon(LucideIcons.plus, color: AppColors.onBrand(AppColors.orange)),
            )
          : null,
      // A computer's window is wide: the tasks keep a phone's measure.
      body: _computer
          ? Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _buildBody(context, ref, isPro),
              ),
            )
          : _buildBody(context, ref, isPro),
    );
  }

  /// What a computer's page says above its tasks (4.0): when they run, and
  /// what comes of a run missed while ZestSSH was closed.
  Widget _computerBanner(AppLocalizations l10n) => _InfoBanner(text: l10n.schedTaskComputerBanner);

  Widget _buildBody(BuildContext context, WidgetRef ref, bool isPro) {
    final l10n = AppLocalizations.of(context)!;
    // iOS: scheduling isn't available at all - say why and offer no action
    // that can't succeed here. (A computer said so too before 4.0.)
    if (!_runsHere) {
      return ZestEmptyState(
        unavailable: true,
        icon: LucideIcons.smartphone,
        title: l10n.scheduledIosTitle,
        message: l10n.scheduledIosMessage,
      );
    }

    // Before Squeezed: made-up tasks, faded, behind what they give (4.0,
    // the locked page as History has it). It was a star and "Squeezed
    // required", with no way on.
    if (!isPro) {
      final made = DateTime(2026, 1, 1);
      final now = DateTime.now();
      ScheduledTask demo(String id, String name, String action,
              {String? command, String? snippet, String? workflow, String type = 'interval', int every = 60,
              int? hour, int? day, Duration ago = const Duration(hours: 1), bool ok = true}) =>
          ScheduledTask(
            id: 'demo-$id',
            name: name,
            action: action,
            connectionId: 'demo',
            command: command,
            snippetName: snippet,
            workflowId: workflow,
            scheduleType: type,
            intervalMinutes: every,
            hour: hour,
            minute: hour == null ? null : 0,
            dayOfWeek: day,
            enabled: true,
            apiKeyId: 'demo',
            createdAt: made,
            lastRunAt: now.subtract(ago),
            lastResult: ok ? 'success' : 'failed',
          );
      final tasks = [
        demo('disk', 'Check disk space', 'execute', command: 'df -h /', every: 30, ago: const Duration(minutes: 12)),
        demo('backup', 'Nightly backup', 'workflow', workflow: 'demo-backup', type: 'daily', hour: 2,
            ago: const Duration(hours: 9)),
        demo('certs', 'Renew certificates', 'snippet', snippet: 'certbot renew', type: 'weekly', hour: 4, day: 1,
            ago: const Duration(days: 3), ok: false),
        demo('logs', 'Rotate logs', 'execute', command: 'sudo logrotate -f /etc/logrotate.conf', every: 360,
            ago: const Duration(hours: 2)),
      ];
      return LockedFeatureView(
        icon: LucideIcons.calendarClock,
        title: l10n.lockedScheduledTitle,
        benefits: [
          LockedFeatureBenefit(LucideIcons.timer, l10n.lockedScheduledTimer),
          // Where they run: a phone's in the background, a computer's while
          // ZestSSH is open or in the tray.
          _computer
              ? LockedFeatureBenefit(LucideIcons.monitor, l10n.lockedScheduledComputer)
              : LockedFeatureBenefit(LucideIcons.smartphone, l10n.lockedScheduledBackground),
          LockedFeatureBenefit(LucideIcons.history, l10n.lockedScheduledLastRun),
        ],
        preview: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [for (final t in tasks) ScheduledTaskCard(task: t, demo: true)],
        ),
      );
    }

    final tasksAsync = ref.watch(scheduledTasksStreamProvider);

    return tasksAsync.when(
      // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
      skipLoadingOnReload: true,
      loading: () => Center(
        child: CircularProgressIndicator(color: AppColors.orange),
      ),
      error: (err, _) => Center(
        child: Text(_describeError(context, err),
            style: TextStyle(color: AppColors.error)),
      ),
      data: (tasks) {
        if (tasks.isEmpty) {
          final empty = _EmptyState(
            onCreateTap: () => _showCreateDialog(context, ref),
          );
          // A computer's says when its tasks will run before there are any.
          if (!_computer) return empty;
          return Column(children: [_computerBanner(l10n), Expanded(child: empty)]);
        }
        return Column(
          children: [
            // When the tasks run: Android's (a notification asks for a tap
            // where the app is not on screen), a computer's (while ZestSSH is
            // open or in the tray).
            _computer ? _computerBanner(l10n) : _InfoBanner(text: l10n.schedTaskBackgroundBanner),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(
                  left: 16, right: 16, top: 8, bottom: 96,
                ),
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  return Dismissible(
                    key: ValueKey(task.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: AppColors.error.withAlpha(40),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        LucideIcons.trash2,
                        color: AppColors.error,
                      ),
                    ),
                    confirmDismiss: (_) => _confirmDelete(context),
                    onDismissed: (_) {
                      ref
                          .read(scheduledTasksProvider.notifier)
                          .deleteTask(task.id);
                    },
                    // A computer's pointer does not swipe: its card has a
                    // Delete button, which asks the same.
                    child: ScheduledTaskCard(
                      task: task,
                      onDelete: _computer
                          ? () async {
                              if (await _confirmDelete(context) == true) {
                                await ref.read(scheduledTasksProvider.notifier).deleteTask(task.id);
                              }
                            }
                          : null,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.schedTaskDeleteTitle,
      body: l10n.schedTaskDeleteMessage,
      confirmLabel: l10n.delete,
    );
  }

  /// A new task: the app's dialog (3.4), a phone's sheet, its fields in the
  /// body and Schedule in the footer (a sheet of its own before, its button
  /// at the bottom of the fields).
  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: const _CreateTaskSheet(),
    );
  }
}

// ── Banner ───────────────────────────────────────────────────────

/// A line above the tasks that says when they run.
class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: AppColors.orange.withAlpha(20),
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(LucideIcons.info, size: 16, color: AppColors.accentInk)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.accentInk,
                ),
              ),
            ),
          ],
        ),
      );
}

// ── Empty state ──────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateTap;

  const _EmptyState({required this.onCreateTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.calendarClock,
      title: l10n.scheduledEmptyTitle,
      message: l10n.scheduledEmptyMessage,
      actionLabel: l10n.scheduledEmptyAction,
      onAction: onCreateTap,
    );
  }
}

// ── Task card ────────────────────────────────────────────────────

class ScheduledTaskCard extends ConsumerWidget {
  final ScheduledTask task;

  /// A made-up task on the page before Squeezed is bought: no key to need.
  final bool demo;

  /// Deletes the task, after asking (a computer's card, whose pointer does
  /// not swipe); null draws no Delete button.
  final Future<void> Function()? onDelete;

  const ScheduledTaskCard({super.key, required this.task, this.demo = false, this.onDelete});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scheduleType = ScheduleType.fromKey(task.scheduleType);
    final action = ScheduledTaskAction.fromKey(task.action);
    // A key that is not on this device (it stayed out when guest data came in, or it was
    // revoked): said here, as a host says of its key when it connects.
    final needsKey = !demo && !ref.watch(automationKeysProvider).any((k) => k.id == task.apiKeyId);
    // When a computer runs it next (4.0): it runs it itself, so it can say.
    final next = !demo && task.enabled && ScheduledTasksScreen._computer
        ? ref.read(computerTaskSchedulerProvider).nextDue(task)
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: task.enabled
              ? AppColors.divider
              : AppColors.divider.withAlpha(80),
        ),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(
          _actionIcon(action),
          color: task.enabled ? AppColors.accentInk : AppColors.textSecondary,
          size: 28,
        ),
        title: Text(
          task.name,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: task.enabled
                ? AppColors.onSurface
                : AppColors.textSecondary,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              _scheduleDescription(context, scheduleType, task),
              style: TextStyle(
                fontSize: 12,
                color: task.enabled
                    ? AppColors.textSecondary
                    : AppColors.textSecondary.withAlpha(150),
              ),
            ),
            if (task.lastRunAt != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(
                    task.lastResult?.startsWith('success') == true
                        ? LucideIcons.checkCircle2
                        : LucideIcons.alertCircle,
                    size: 12,
                    color: task.lastResult?.startsWith('success') == true
                        ? AppColors.success
                        : AppColors.error,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l10n.schedTaskLastRun(_formatTime(context, task.lastRunAt!)),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
            if (next != null) ...[
              const SizedBox(height: 2),
              Text(
                l10n.schedTaskNextRun(_formatNext(context, next)),
                key: ValueKey('sched-task-next-${task.id}'),
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
            if (needsKey) ...[
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.alertCircle, size: 12, color: AppColors.error),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      l10n.schedTaskNeedsApiKey,
                      style: TextStyle(fontSize: 11, color: AppColors.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        // The app's own switch: the system's, tinted orange, drew an orange
        // knob on an orange track, so a task that is on showed no knob at
        // all (seen in the screenshot tests).
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZestSwitch(
              key: ValueKey('sched-task-on-${task.id}'),
              value: task.enabled,
              semanticLabel: task.name,
              onChanged: (enabled) {
                ref
                    .read(scheduledTasksProvider.notifier)
                    .setEnabled(task.id, enabled);
              },
            ),
            if (onDelete != null)
              IconButton(
                key: ValueKey('sched-task-delete-${task.id}'),
                tooltip: l10n.schedTaskDeleteNamed(task.name),
                icon: Icon(LucideIcons.trash2, size: 18, color: AppColors.textSecondary),
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }

  /// When a computer runs the task next: the time today, else the day and
  /// the time; a time already past is now (it runs at the next look).
  String _formatNext(BuildContext context, DateTime next) {
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();
    final at = next.isBefore(now) ? now : next;
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? DateFormat.Hm(l10n.localeName).formatPlain(at)
        : DateFormat.MMMd(l10n.localeName).add_Hm().formatPlain(at);
  }

  IconData _actionIcon(ScheduledTaskAction action) {
    switch (action) {
      case ScheduledTaskAction.execute:
        return LucideIcons.terminal;
      case ScheduledTaskAction.snippet:
        return LucideIcons.code;
      case ScheduledTaskAction.workflow:
        return LucideIcons.gitFork;
    }
  }

  String _scheduleDescription(
          BuildContext context, ScheduleType type, ScheduledTask task) =>
      describeSchedule(
        context,
        type,
        intervalMinutes: task.intervalMinutes,
        hour: task.hour,
        minute: task.minute,
        dayOfWeek: task.dayOfWeek,
      );

  String _formatTime(BuildContext context, DateTime time) {
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();
    // After "Last: ", within a day the shared compact words begun small, then
    // the day and the time.
    if (now.difference(time).inHours < 24) return timeAgoInSentence(l10n, time, now: now);
    return DateFormat.MMMd(l10n.localeName).add_Hm().formatPlain(time);
  }
}

/// Human-readable one-line summary of a schedule (e.g. "Every hour",
/// "Daily at 09:00", "Every Mon at 09:00"). Shared by the saved-task card
/// and the create sheet's live preview so both read identically.
String describeSchedule(
  BuildContext context,
  ScheduleType type, {
  required int intervalMinutes,
  int? hour,
  int? minute,
  int? dayOfWeek,
}) {
  final l10n = AppLocalizations.of(context)!;
  switch (type) {
    case ScheduleType.interval:
      return ScheduleIntervals.displayLabel(l10n, intervalMinutes);
    case ScheduleType.daily:
      final h = (hour ?? 9).toString().padLeft(2, '0');
      final m = (minute ?? 0).toString().padLeft(2, '0');
      return l10n.schedTaskDailyAt('$h:$m');
    case ScheduleType.weekly:
      final day = WeekDay.shortName(l10n, dayOfWeek ?? 1);
      final h = (hour ?? 9).toString().padLeft(2, '0');
      final m = (minute ?? 0).toString().padLeft(2, '0');
      return l10n.schedTaskWeeklyAt(day, '$h:$m');
  }
}

// ── Create task bottom sheet ─────────────────────────────────────

class _CreateTaskSheet extends ConsumerStatefulWidget {
  const _CreateTaskSheet();

  @override
  ConsumerState<_CreateTaskSheet> createState() => _CreateTaskSheetState();
}

class _CreateTaskSheetState extends ConsumerState<_CreateTaskSheet> {
  final _nameController = TextEditingController();
  final _commandController = TextEditingController();

  ScheduledTaskAction _action = ScheduledTaskAction.execute;
  String? _selectedConnectionId;
  String? _selectedSnippetName;
  String? _selectedWorkflowId;
  ScheduleType _scheduleType = ScheduleType.interval;
  int _intervalMinutes = 60;
  int _hour = 9;
  int _minute = 0;
  int _dayOfWeek = 1;
  String? _selectedApiKeyId;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    super.dispose();
  }

  /// Live "Runs ..." summary of the currently-configured schedule, kept in
  /// sync with the segmented type + interval / time / day controls below.
  /// Mirrors the desktop per-workflow cron preview.
  String _schedulePreview(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final desc = describeSchedule(
      context,
      _scheduleType,
      intervalMinutes: _intervalMinutes,
      hour: _hour,
      minute: _minute,
      dayOfWeek: _dayOfWeek,
    );
    final lower =
        desc.isEmpty ? desc : '${desc[0].toLowerCase()}${desc.substring(1)}';
    return l10n.schedTaskRunsPreview(lower);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final snippetsAsync = ref.watch(snippetsProvider);
    final workflows = ref.watch(automationWorkflowsProvider).valueOrNull ?? const <Workflow>[];
    final apiKeys = ref.watch(automationKeysProvider);

    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.calendarClock,
      title: l10n.schedTaskNewTitle,
      secondaryAction: (label: l10n.cancel, onPressed: _saving ? null : () => Navigator.of(context).pop()),
      primaryKey: const ValueKey('sched-task-schedule'),
      primaryAction: (
        label: l10n.schedTaskScheduleButton,
        icon: null,
        onPressed: _saving ? null : _onSave,
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Name ──
          ZestTextField(
            controller: _nameController,
            label: l10n.schedTaskNameLabel,
            hintText: l10n.schedTaskNameHint,
          ),
          const SizedBox(height: 20),

          // ── Action Type ──
          _FieldLabel(label: l10n.schedTaskActionType),
          const SizedBox(height: 8),
          SegmentedButton<ScheduledTaskAction>(
            segments: ScheduledTaskAction.values
                .map((a) => ButtonSegment(
                      value: a,
                      label: Text(a.nameIn(l10n), style: const TextStyle(fontSize: 12)),
                    ))
                .toList(),
            selected: {_action},
            onSelectionChanged: (s) => setState(() {
              _action = s.first;
            }),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: AppColors.orange.withAlpha(40),
              selectedForegroundColor: AppColors.accentInk,
            ),
          ),
          const SizedBox(height: 20),

          // ── Connection picker ──
          if (_action != ScheduledTaskAction.workflow) ...[
            _FieldLabel(label: l10n.schedTaskConnection),
            const SizedBox(height: 8),
            connectionsAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(_describeError(context, e),
                  style: TextStyle(color: AppColors.error)),
              data: (connections) {
                // The app's select (a Material dropdown; found in a design
                // audit).
                // A host that runs no command: dimmed, with why.
                return ZestSelect<String>(
                  value: _selectedConnectionId,
                  hint: l10n.schedTaskSelectConnection,
                  items: [
                    for (final c in connections)
                      ZestSelectItem(
                        c.connection.id,
                        Redactable.host(c.connection.label).displayIn(ref),
                        leading: HostGlyph(host: c.connection, group: c.group, size: 16),
                        enabled: noCommandReason(c.connection, l10n) == null,
                        note: noCommandReason(c.connection, l10n),
                      ),
                  ],
                  onChanged: (v) => setState(() => _selectedConnectionId = v),
                );
              },
            ),
            const SizedBox(height: 20),
          ],

          // ── Command (execute) ──
          if (_action == ScheduledTaskAction.execute) ...[
            ZestTextField(
              controller: _commandController,
              label: l10n.schedTaskCommand,
              hintText: l10n.schedTaskCommandHint,
              autofocus: false,
              maxLines: 3,
              minLines: 1,
            ),
            const SizedBox(height: 20),
          ],

          // ── Snippet picker ──
          if (_action == ScheduledTaskAction.snippet) ...[
            _FieldLabel(label: l10n.schedTaskSnippet),
            const SizedBox(height: 8),
            snippetsAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(_describeError(context, e),
                  style: TextStyle(color: AppColors.error)),
              data: (snippets) {
                return ZestSelect<String>(
                  value: _selectedSnippetName,
                  hint: l10n.schedTaskSelectSnippet,
                  items: [
                    // A task names its snippet: two of one name are one
                    // choice (each of the select's choices is one of a kind).
                    for (final name in {for (final s in snippets) s.label}) ZestSelectItem(name, name),
                  ],
                  onChanged: (v) =>
                      setState(() => _selectedSnippetName = v),
                );
              },
            ),
            const SizedBox(height: 20),
          ],

          // ── Workflow picker ──
          if (_action == ScheduledTaskAction.workflow) ...[
            _FieldLabel(label: l10n.schedTaskWorkflow),
            const SizedBox(height: 8),
            ZestSelect<String>(
              value: _selectedWorkflowId,
              hint: l10n.schedTaskSelectWorkflow,
              items: [for (final w in workflows) ZestSelectItem(w.id, w.name)],
              onChanged: (v) => setState(() => _selectedWorkflowId = v),
            ),
            const SizedBox(height: 20),
          ],

          // ── Schedule Type ──
          _FieldLabel(label: l10n.schedTaskSchedule),
          const SizedBox(height: 8),
          SegmentedButton<ScheduleType>(
            segments: ScheduleType.values
                .map((s) => ButtonSegment(
                      value: s,
                      label: Text(s.nameIn(l10n), style: const TextStyle(fontSize: 12)),
                    ))
                .toList(),
            selected: {_scheduleType},
            onSelectionChanged: (s) => setState(() {
              _scheduleType = s.first;
            }),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: AppColors.orange.withAlpha(40),
              selectedForegroundColor: AppColors.accentInk,
            ),
          ),
          const SizedBox(height: 16),

          // ── Schedule details ──
          if (_scheduleType == ScheduleType.interval) ...[
            _FieldLabel(label: l10n.schedTaskInterval),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ScheduleIntervals.presets.map((mins) {
                final selected = _intervalMinutes == mins;
                return ChoiceChip(
                  label: Text(ScheduleIntervals.displayLabel(l10n, mins)),
                  selected: selected,
                  selectedColor: AppColors.orange.withAlpha(40),
                  checkmarkColor: AppColors.orange,
                  onSelected: (_) => setState(() => _intervalMinutes = mins),
                );
              }).toList(),
            ),
          ],

          if (_scheduleType == ScheduleType.daily) ...[
            _FieldLabel(label: l10n.schedTaskTime),
            const SizedBox(height: 8),
            _TimePicker(
              hour: _hour,
              minute: _minute,
              onChanged: (h, m) => setState(() {
                _hour = h;
                _minute = m;
              }),
            ),
          ],

          if (_scheduleType == ScheduleType.weekly) ...[
            _FieldLabel(label: l10n.schedTaskDay),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: WeekDay.days.map((day) {
                final selected = _dayOfWeek == day;
                return ChoiceChip(
                  label: Text(WeekDay.shortName(l10n, day)),
                  selected: selected,
                  selectedColor: AppColors.orange.withAlpha(40),
                  checkmarkColor: AppColors.orange,
                  onSelected: (_) =>
                      setState(() => _dayOfWeek = day),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            _FieldLabel(label: l10n.schedTaskTime),
            const SizedBox(height: 8),
            _TimePicker(
              hour: _hour,
              minute: _minute,
              onChanged: (h, m) => setState(() {
                _hour = h;
                _minute = m;
              }),
            ),
          ],

          // ── Live schedule summary (mobile counterpart to the desktop
          // per-workflow cron preview): a line, not an orange tile ──
          const SizedBox(height: 16),
          Row(
            key: const ValueKey('sched-task-preview'),
            children: [
              Icon(LucideIcons.calendarClock, size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _schedulePreview(context),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── API Key picker ──
          _FieldLabel(label: l10n.schedTaskApiKey),
          const SizedBox(height: 8),
          // None to pick: the one sentence that warns, in amber (a red tile
          // before).
          if (apiKeys.isEmpty)
            ZestCallout(l10n.schedTaskNoApiKeys)
          else
            ZestSelect<String>(
              value: _selectedApiKeyId,
              hint: l10n.schedTaskSelectApiKey,
              items: [for (final k in apiKeys) ZestSelectItem(k.id, k.label)],
              onChanged: (v) => setState(() => _selectedApiKeyId = v),
            ),
          const SizedBox(height: 8),
          Text(
            l10n.schedTaskApiKeyHelp,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onSave() async {
    final l10n = AppLocalizations.of(context)!;
    // Validate
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showError(l10n.schedTaskErrorNoName);
      return;
    }

    if (_action != ScheduledTaskAction.workflow &&
        _selectedConnectionId == null) {
      _showError(l10n.schedTaskErrorNoConnection);
      return;
    }

    if (_action == ScheduledTaskAction.execute &&
        _commandController.text.trim().isEmpty) {
      _showError(l10n.schedTaskErrorNoCommand);
      return;
    }

    if (_action == ScheduledTaskAction.snippet &&
        _selectedSnippetName == null) {
      _showError(l10n.schedTaskErrorNoSnippet);
      return;
    }

    if (_action == ScheduledTaskAction.workflow &&
        _selectedWorkflowId == null) {
      _showError(l10n.schedTaskErrorNoWorkflow);
      return;
    }

    if (_selectedApiKeyId == null) {
      _showError(l10n.schedTaskErrorNoApiKey);
      return;
    }

    setState(() => _saving = true);

    await ref.read(scheduledTasksProvider.notifier).createTask(
          name: name,
          action: _action,
          // A workflow names its hosts in its steps: its task has none (the
          // scheduler takes an empty one for a workflow).
          connectionId: _action == ScheduledTaskAction.workflow ? '' : _selectedConnectionId!,
          command: _action == ScheduledTaskAction.execute
              ? _commandController.text.trim()
              : null,
          snippetName: _action == ScheduledTaskAction.snippet
              ? _selectedSnippetName
              : null,
          workflowId: _action == ScheduledTaskAction.workflow
              ? _selectedWorkflowId
              : null,
          scheduleType: _scheduleType,
          intervalMinutes: _intervalMinutes,
          hour: _scheduleType != ScheduleType.interval ? _hour : null,
          minute: _scheduleType != ScheduleType.interval ? _minute : null,
          dayOfWeek:
              _scheduleType == ScheduleType.weekly ? _dayOfWeek : null,
          apiKeyId: _selectedApiKeyId!,
        );

    if (mounted) {
      Navigator.pop(context);
      showTopSnackBar(context, l10n.schedTaskScheduledConfirm(name),
          isSuccess: true);
    }
  }

  void _showError(String message) {
    showTopSnackBar(context, message, isError: true);
  }
}

// ── Helper widgets ───────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String label;

  const _FieldLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
    );
  }
}

class _TimePicker extends StatelessWidget {
  final int hour;
  final int minute;
  final void Function(int hour, int minute) onChanged;

  const _TimePicker({
    required this.hour,
    required this.minute,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InkWell(
      onTap: () async {
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: hour, minute: minute),
        );
        if (time != null) {
          onChanged(time.hour, time.minute);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.clock, size: 20, color: AppColors.accentInk),
            const SizedBox(width: 12),
            Text(
              '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: AppColors.onSurface,
              ),
            ),
            const Spacer(),
            Text(
              l10n.schedTaskChange,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
