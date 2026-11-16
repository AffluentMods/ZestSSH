import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/workflow.dart';
import '../../../ui/widgets/zest_status.dart';
import 'package:zestssh/l10n/time_ago.dart';

/// A one-line summary of a workflow's most recent run, shown as the last-run
/// status pill + relative time on each list row.
///
/// This is the session source of truth for row status. The 1.7 spec asks for
/// "sourced from automation_history", but the persisted history schema carries
/// no per-run failed-step index (which `zestAutoLastRunFailed` needs) and no
/// workflow-id linkage - so rather than change the schema, every "Run now"
/// records a summary here (including the 1-based failing step). Rows without a
/// summary fall back to the workflow's persisted [Workflow.lastRunAt].
class WorkflowRunSummary {
  const WorkflowRunSummary({
    required this.success,
    required this.ranAt,
    this.failedStepNumber,
    this.needsCredentials = false,
    this.cancelled = false,
  });

  /// Build a summary from an engine [WorkflowResult].
  factory WorkflowRunSummary.fromResult(WorkflowResult result) {
    int? failedStep;
    if (!result.success) {
      // What stands as failed: one that went back and went well the next time
      // does not.
      final settled = result.settled;
      final idx = settled.indexWhere(
        (r) => !r.success && !r.skipped,
      );
      // 1-based for display. (A step with many targets has many results.)
      if (idx >= 0) failedStep = (settled[idx].stepIndex ?? idx) + 1;
    }
    return WorkflowRunSummary(
      success: result.success,
      ranAt: DateTime.now(),
      failedStepNumber: failedStep,
      needsCredentials: result.needsCredentials,
      cancelled: result.cancelled,
    );
  }

  final bool success;
  final DateTime ranAt;

  /// 1-based index of the step that failed, or null on success.
  final int? failedStepNumber;

  /// True when the run was blocked because a step targeted a credential not
  /// enabled for unattended runs - surfaces the amber "Needs credentials"
  /// outcome instead of red "Failed".
  final bool needsCredentials;

  /// Its person stopped it: no failure of anything's, and it does not say Failed.
  final bool cancelled;
}

/// Per-workflow last-run summaries, keyed by workflow id. Updated by the
/// desktop "Run now" path; read by the list rows. In-memory only (resets on
/// restart), so it never needs a migration.
final workflowLastRunProvider = StateProvider<Map<String, WorkflowRunSummary>>(
  (ref) => {},
);

/// A resolved last-run outcome for a workflow list row: the state (drives the
/// left accent bar + outcome-text colour), the outcome label, and a compact
/// relative time for the right of the meta line.
///
/// The shared [ZestStatusKind] vocabulary is reused so a "failed" workflow
/// reads the same red as a failed anything-else. `kind` maps to:
///   * [ZestStatusKind.healthy]  → succeeded (green)
///   * [ZestStatusKind.critical] → failed (red)
///   * [ZestStatusKind.warning]  → needs credentials (amber)
///   * [ZestStatusKind.neutral]  → stopped / never run / ran-before-unknown (grey)
class WorkflowOutcome {
  const WorkflowOutcome({
    required this.kind,
    required this.label,
    this.relative,
  });

  final ZestStatusKind kind;

  /// Already-localized outcome text ("Succeeded" / "Failed at step 3" /
  /// "Needs credentials" / "Never run"). Empty when the state has no headline
  /// (a prior run with no recorded outcome shows only the time).
  final String label;

  /// When it last ran, in a few letters of the page's language
  /// ([timeAgoShort]), or null (never run).
  final String? relative;
}

/// Resolve a workflow's list-row outcome from its session run [summary] with a
/// fallback to the persisted [fallbackLastRun]. [now] is for tests.
WorkflowOutcome resolveWorkflowOutcome(
  AppLocalizations l10n,
  WorkflowRunSummary? summary, {
  DateTime? fallbackLastRun,
  DateTime? now,
}) {
  if (summary != null) {
    final rel = timeAgoShort(l10n, summary.ranAt, now: now);
    if (summary.success) {
      return WorkflowOutcome(
        kind: ZestStatusKind.healthy,
        label: l10n.zestAutoOutcomeSucceeded,
        relative: rel,
      );
    }
    if (summary.cancelled) {
      return WorkflowOutcome(
        kind: ZestStatusKind.neutral,
        label: l10n.zestAutoOutcomeStopped,
        relative: rel,
      );
    }
    if (summary.needsCredentials) {
      // Blocked because a step's credential isn't enabled for unattended runs.
      // Amber, not red - it's a config gap the user can fix, not a failure.
      return WorkflowOutcome(
        kind: ZestStatusKind.warning,
        label: l10n.zestAutoOutcomeNeedsCreds,
        relative: rel,
      );
    }
    final step = summary.failedStepNumber;
    return WorkflowOutcome(
      kind: ZestStatusKind.critical,
      label: step != null
          ? l10n.zestAutoOutcomeFailedAtStep(step)
          : l10n.zestAutoOutcomeFailed,
      relative: rel,
    );
  }
  if (fallbackLastRun != null) {
    // Ran at some point but this session has no outcome record - grey, no
    // headline, just the time.
    return WorkflowOutcome(
      kind: ZestStatusKind.neutral,
      label: '',
      relative: timeAgoShort(l10n, fallbackLastRun, now: now),
    );
  }
  return WorkflowOutcome(
    kind: ZestStatusKind.neutral,
    label: l10n.zestAutoOutcomeNeverRun,
    relative: null,
  );
}
