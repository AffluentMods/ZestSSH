import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/automation/workflow_run_gate.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/locked_feature_view.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';

/// Main Workflows screen - lists all saved workflows with run/toggle controls.
class WorkflowListScreen extends ConsumerWidget {
  const WorkflowListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final workflows = ref.watch(workflowsProvider);
    final activeState = ref.watch(activeWorkflowProvider);
    final isPro = ref.watch(isProProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.workflowListTitle),
        backgroundColor: AppColors.surface,
      ),
      // New workflow only where one can be made.
      floatingActionButton: !isPro
          ? null
          : FloatingActionButton(
              backgroundColor: AppColors.orange,
              // Named for a screen reader (it was an unnamed +).
              tooltip: AppLocalizations.of(context)!.workflowsEmptyAction,
              onPressed: () => context.push(Routes.workflowEditor),
              // The ink that reads on the orange (white was 2.6:1).
              child: Icon(LucideIcons.plus, color: AppColors.onBrand(AppColors.orange)),
            ),
      body: !isPro
          ? const _LockedWorkflows()
          : Stack(
        children: [
          // ── Main content ──
          Column(
            children: [
              // ── Active workflow progress bar ──
              if (activeState != null && activeState.isRunning)
                _ActiveWorkflowBanner(activeState: activeState, ref: ref),

              // ── Workflow list or empty state ──
              Expanded(
                child: workflows.isEmpty
                    ? _EmptyState(onCreateTap: () {
                        context.push(Routes.workflowEditor);
                      })
                    : ListView.builder(
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 16,
                          top: 8,
                          bottom: 96,
                        ),
                        itemCount: workflows.length,
                        itemBuilder: (context, index) {
                          final workflow = workflows[index];
                          return Dismissible(
                            key: ValueKey(workflow.id),
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
                                  .read(workflowsProvider.notifier)
                                  .deleteWorkflow(workflow.id);
                            },
                            child: _WorkflowCard(workflow: workflow),
                          );
                        },
                      ),
              ),
            ],
          ),

        ],
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.workflowListDeleteTitle,
      body: l10n.workflowListDeleteMessage,
      confirmLabel: l10n.delete,
    );
    return result ?? false;
  }
}

// ── Active workflow banner ─────────────────────────────────────────

class _ActiveWorkflowBanner extends StatelessWidget {
  final ActiveWorkflowState activeState;
  final WidgetRef ref;

  const _ActiveWorkflowBanner({
    required this.activeState,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final workflow = activeState.workflow;
    final stepIndex = activeState.currentStepIndex;
    final total = activeState.totalSteps;
    final stepName = stepIndex < workflow.steps.length
        ? workflow.steps[stepIndex].displaySummary
        : l10n.workflowListFinishing;

    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(AppColors.orange),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.workflowListRunning(workflow.name),
                  style: TextStyle(
                    color: AppColors.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  ref.read(workflowsProvider.notifier).cancelWorkflow();
                },
                icon: const Icon(LucideIcons.square, size: 16),
                label: Text(l10n.cancel),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.error,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: activeState.progress,
              backgroundColor: AppColors.surfaceLight,
              valueColor: AlwaysStoppedAnimation(AppColors.orange),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.workflowListStepProgress(stepIndex + 1, total, stepName),
            style: TextStyle(
              color: AppColors.onSurfaceDim,
              fontSize: 11,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ── Empty state ────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateTap;

  const _EmptyState({required this.onCreateTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.workflow,
      title: l10n.workflowsEmptyTitle,
      message: l10n.workflowsEmptyMessage,
      actionLabel: l10n.workflowsEmptyAction,
      onAction: onCreateTap,
    );
  }
}

// ── Workflow card ──────────────────────────────────────────────────

class _WorkflowCard extends ConsumerWidget {
  final Workflow workflow;

  const _WorkflowCard({required this.workflow});

  /// Run now: not in a team's space, and asked what a run a person starts is
  /// asked ([workflowReadyToRun]) before anything runs.
  Future<void> _runNow(BuildContext context, WidgetRef ref) async {
    final refused = workflowRunRefusal(ref.read, AppLocalizations.of(context)!);
    if (refused != null) {
      showTopSnackBar(context, refused, isWarning: true);
      return;
    }
    final notifier = ref.read(workflowsProvider.notifier);
    final ready = await workflowReadyToRun(context, workflow);
    if (ready == null) return;
    await notifier.runWorkflow(workflow.id, thisRun: ready);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final activeState = ref.watch(activeWorkflowProvider);
    final isThisRunning =
        activeState != null &&
        activeState.isRunning &&
        activeState.workflow.id == workflow.id;
    // One at a time: a second would have stopped with an error nobody saw.
    final anyRunning = activeState != null && activeState.isRunning;

    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isThisRunning
            ? BorderSide(color: AppColors.orange, width: 1.5)
            : BorderSide.none,
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          context.push(Routes.workflowEditor, extra: workflow);
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Top row: name + toggle ──
              Row(
                children: [
                  Expanded(
                    child: Text(
                      workflow.name,
                      style: TextStyle(
                        color: AppColors.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    height: 32,
                    child: ZestSwitch(value: workflow.enabled, onChanged: (_) {
                        ref
                            .read(workflowsProvider.notifier)
                            .toggleEnabled(workflow.id);
                      }),
                  ),
                ],
              ),

              // ── Description ──
              if (workflow.description != null &&
                  workflow.description!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    workflow.description!,
                    style: TextStyle(
                      color: AppColors.onSurfaceDim,
                      fontSize: 13,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

              const SizedBox(height: 10),

              // ── Badges row ──
              Row(
                children: [
                  // Step count badge
                  _Badge(
                    icon: LucideIcons.layers,
                    label: l10n.workflowListStepsCount(workflow.steps.length),
                  ),
                  const SizedBox(width: 8),

                  // Schedule badge - all workflows are manual/externally-triggered
                  _Badge(
                    icon: LucideIcons.pointer,
                    label: l10n.workflowListManual,
                  ),

                  const Spacer(),

                  // ── Last run status ──
                  _LastRunIndicator(workflow: workflow),
                ],
              ),

              const SizedBox(height: 10),
              Divider(color: AppColors.divider, height: 1),
              const SizedBox(height: 8),

              // ── Bottom row: play button ──
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Last run time
                  if (workflow.lastRunAt != null)
                    Expanded(
                      child: Text(
                        _formatRelativeTime(l10n, workflow.lastRunAt!),
                        style: TextStyle(
                          color: AppColors.onSurfaceDim,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  if (workflow.lastRunAt == null)
                    Expanded(
                      child: Text(
                        l10n.workflowListNeverRun,
                        style: TextStyle(
                          color: AppColors.onSurfaceDim,
                          fontSize: 11,
                        ),
                      ),
                    ),

                  // Play button
                  SizedBox(
                    height: 32,
                    width: 32,
                    child: IconButton(
                      key: ValueKey('workflow-run-now-${workflow.id}'),
                      onPressed: anyRunning ? null : () => _runNow(context, ref),
                      icon: Icon(
                        isThisRunning
                            ? LucideIcons.hourglass
                            : LucideIcons.play,
                        size: 20,
                      ),
                      color: AppColors.accentInk,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      tooltip: isThisRunning
                          ? l10n.workflowListRunningTooltip
                          : l10n.workflowListRunNow,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// When a workflow last ran, a line of its own in the shared compact words
  /// ("2m ago", "3h ago"), counting on past a week ("3w ago", then months).
  static String _formatRelativeTime(AppLocalizations l10n, DateTime dateTime) =>
      timeAgoWords(l10n, dateTime, keepCounting: true);
}

// ── Badge chip ──────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _Badge({
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.onSurfaceDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withAlpha(20),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

// ── Last run status indicator ──────────────────────────────────────

class _LastRunIndicator extends ConsumerWidget {
  final Workflow workflow;

  const _LastRunIndicator({required this.workflow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeState = ref.watch(activeWorkflowProvider);

    // Show result from a just-finished run
    if (activeState != null &&
        activeState.workflow.id == workflow.id &&
        activeState.result != null) {
      final result = activeState.result!;
      if (result.cancelled) {
        return _StatusDot(
          color: AppColors.warning,
          icon: LucideIcons.xCircle,
        );
      }
      return _StatusDot(
        color: result.success ? AppColors.success : AppColors.error,
        icon: result.success ? LucideIcons.checkCircle2 : LucideIcons.alertCircle,
      );
    }

    // No run yet
    if (workflow.lastRunAt == null) {
      return _StatusDot(
        color: AppColors.onSurfaceDim,
        icon: LucideIcons.minus,
      );
    }

    // Had a previous run - show neutral indicator
    return _StatusDot(
      color: AppColors.onSurfaceDim,
      icon: LucideIcons.history,
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  final IconData icon;

  const _StatusDot({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: 18, color: color);
  }
}

// ── Pro gate overlay ──────────────────────────────────────────────

/// Workflows before Squeezed is bought (4.0, the locked page as History
/// has it): made-up workflows, faded, behind what they give. It was a lock,
/// a line and Upgrade over the list, with New workflow still under the
/// thumb.
class _LockedWorkflows extends StatelessWidget {
  const _LockedWorkflows();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final made = DateTime(2026, 1, 1);
    Workflow demo(String id, String name, String description, List<String> commands, {Duration? ago}) => Workflow(
          id: 'demo-$id',
          name: name,
          description: description,
          steps: [
            for (var i = 0; i < commands.length; i++)
              WorkflowStep(id: 'demo-$id-$i', type: WorkflowStepType.execute, command: commands[i]),
          ],
          createdAt: made,
          lastRunAt: ago == null ? null : DateTime.now().subtract(ago),
        );
    final workflows = [
      demo('update', 'Update packages on a group', 'apt on each host, one at a time',
          ['sudo apt update', 'sudo apt upgrade -y', 'needrestart -r l'],
          ago: const Duration(hours: 3)),
      demo('restart', 'Restart a container', 'docker on web-01', ['docker restart app', 'docker ps --filter name=app'],
          ago: const Duration(days: 1)),
      demo('disk', 'Check disk space everywhere', 'Tells you when a disk is 85% full', ['df -h --output=pcent /'],
          ago: const Duration(minutes: 40)),
      demo('backup', 'Back up a folder', 'rsync to the backup host', ['rsync -a /srv/data backup-01:/backups/'],
          ago: const Duration(days: 2)),
    ];
    return LockedFeatureView(
      icon: LucideIcons.workflow,
      title: l10n.lockedWorkflowsTitle,
      benefits: [
        LockedFeatureBenefit(LucideIcons.listOrdered, l10n.lockedWorkflowsSteps),
        LockedFeatureBenefit(LucideIcons.link, l10n.lockedWorkflowsFrom),
        LockedFeatureBenefit(LucideIcons.bellRing, l10n.lockedWorkflowsNotify),
      ],
      preview: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [for (final w in workflows) _WorkflowCard(workflow: w)],
      ),
    );
  }
}
