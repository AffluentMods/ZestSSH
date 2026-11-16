import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart' as db;
import 'package:zestssh/database/daos/workflows_dao.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart' show OrchardSpace;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

// ── Active workflow state ─────────────────────────────────────────

/// Tracks the execution state of a currently running workflow.
class ActiveWorkflowState {
  /// The workflow being executed.
  final Workflow workflow;

  /// Current execution status.
  final WorkflowRunStatus status;

  /// Index of the step currently executing (0-based).
  final int currentStepIndex;

  /// Total number of steps in the workflow.
  final int totalSteps;

  /// Results collected so far (grows as steps complete).
  final List<WorkflowStepResult> stepResults;

  /// The final aggregated result (populated when execution finishes).
  final WorkflowResult? result;

  /// A human-readable error message if the run failed to start.
  final String? errorMessage;

  const ActiveWorkflowState({
    required this.workflow,
    this.status = WorkflowRunStatus.idle,
    this.currentStepIndex = 0,
    this.totalSteps = 0,
    this.stepResults = const [],
    this.result,
    this.errorMessage,
  });

  ActiveWorkflowState copyWith({
    Workflow? workflow,
    WorkflowRunStatus? status,
    int? currentStepIndex,
    int? totalSteps,
    List<WorkflowStepResult>? stepResults,
    WorkflowResult? result,
    String? errorMessage,
  }) {
    return ActiveWorkflowState(
      workflow: workflow ?? this.workflow,
      status: status ?? this.status,
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
      totalSteps: totalSteps ?? this.totalSteps,
      stepResults: stepResults ?? this.stepResults,
      result: result ?? this.result,
      errorMessage: errorMessage,
    );
  }

  /// Progress as a fraction [0.0, 1.0].
  double get progress => totalSteps > 0 ? currentStepIndex / totalSteps : 0.0;

  /// Whether a workflow is currently running.
  bool get isRunning => status == WorkflowRunStatus.running;
}

enum WorkflowRunStatus {
  /// No workflow running.
  idle,

  /// Workflow is executing steps.
  running,

  /// Workflow completed (check [ActiveWorkflowState.result] for details).
  completed,

  /// Workflow was cancelled by the user.
  cancelled,

  /// Workflow failed to start (e.g., not Pro, workflow not found).
  error,
}

// ── Providers ─────────────────────────────────────────────────────

/// Persisted list of saved workflows (backed by Drift database).
final workflowsProvider =
    StateNotifierProvider<WorkflowNotifier, List<Workflow>>((ref) {
      return WorkflowNotifier(ref.watch(workflowsDaoProvider), ref);
    });

/// The workflows a link, another app and a schedule can run: your Tree's,
/// whichever space is on screen ([WorkflowNotifier.ofTheTree]). What their pickers
/// offer: with a team's space open they offered its workflows, which never run
/// that way.
final automationWorkflowsProvider = FutureProvider<List<Workflow>>((ref) {
  // Anew whenever the list on screen changes.
  ref.watch(workflowsProvider);
  return ref.read(workflowsProvider.notifier).ofTheTree();
});

/// Currently running workflow state (step progress, results).
final activeWorkflowProvider =
    StateNotifierProvider<ActiveWorkflowNotifier, ActiveWorkflowState?>((ref) {
      return ActiveWorkflowNotifier();
    });

/// The [WorkflowService] instance for executing workflows.
final workflowServiceProvider = Provider<WorkflowService>((ref) {
  final automationService = ref.watch(automationServiceProvider);
  return WorkflowService(
    automationService,
    notice: (kind, title, body) => showWorkflowNotice(ref, kind, title, body),
    osFamilyOf: (connectionId) => workflowOsFamilyOf(ref.read(osDetectionCacheProvider)[connectionId]),
  );
});

/// The system [kind] counts as for a Command step's commands; null where it
/// could be more than one, and the host is asked.
WorkflowOsFamily? workflowOsFamilyOf(OsKind? kind) => switch (kind) {
      null || OsKind.unknown || OsKind.truenas || OsKind.synology || OsKind.unraid => null,
      OsKind.freebsd || OsKind.openbsd || OsKind.netbsd => WorkflowOsFamily.bsd,
      OsKind.macos => WorkflowOsFamily.macos,
      OsKind.windows => WorkflowOsFamily.windows,
      _ => WorkflowOsFamily.linux,
    };

/// A workflow's notice: one of the app's notices (the bell, and on a
/// computer a card in the window's corner), and on a phone the system's
/// notification as well; on a computer the system's too where its person
/// turned that on and the window is not in front (4.0). (A computer showed
/// nothing: the system's notification was a phone's alone in this app, and
/// a Notify step said "Notification sent".)
void showWorkflowNotice(Ref ref, WorkflowNoticeKind kind, String title, String body) {
  final center = ref.read(notificationCenterProvider.notifier);
  switch (kind) {
    case WorkflowNoticeKind.said:
      center.info(title, body: body);
    case WorkflowNoticeKind.finished:
      center.success(title, body: body);
    case WorkflowNoticeKind.failed:
      center.warning(title, body: body);
  }
  if (debugWorkflowNoticesOnPhone ?? !isDesktopPlatform) {
    unawaited(NotificationService.showNotice(title: title, body: body));
  } else {
    unawaited(NotificationService.onComputer(() => NotificationService.showNotice(title: title, body: body)));
  }
}

/// Whether [showWorkflowNotice] takes this for a phone. Null in the app.
@visibleForTesting
bool? debugWorkflowNoticesOnPhone;

// ── WorkflowNotifier - CRUD + run/cancel ──────────────────────────

/// Manages the persisted list of workflows and orchestrates execution.
class WorkflowNotifier extends StateNotifier<List<Workflow>> {
  final WorkflowsDao _dao;
  final Ref _ref;
  CancellationToken? _activeCancellationToken;

  WorkflowNotifier(this._dao, this._ref) : super(const []) {
    _load();
  }

  // ── Persistence (Drift database) ─────────────────────────────

  Future<void> _load() async {
    try {
      final rows = await _dao.getAll();
      state = rows.map(_fromDbRow).toList();
      AppLogger.info('WorkflowNotifier: loaded ${state.length} workflows');
    } catch (e, stack) {
      AppLogger.error('WorkflowNotifier: failed to load workflows', e, stack);
      state = const [];
    }
  }

  /// Convert a Drift [db.WorkflowRow] row to the domain [Workflow] model.
  static Workflow _fromDbRow(db.WorkflowRow row) {
    final steps = (jsonDecode(row.stepsJson) as List<dynamic>)
        .map((e) => WorkflowStep.fromJson(e as Map<String, dynamic>))
        .toList();
    return Workflow(
      id: row.id,
      name: row.name,
      description: row.description,
      steps: steps,
      enabled: row.enabled,
      createdAt: row.createdAt,
      lastRunAt: row.lastRunAt,
      notifyOnFailure: row.notifyOnFailure,
      notifyOnSuccess: row.notifyOnSuccess,
    );
  }

  /// Convert a domain [Workflow] model to a Drift [db.WorkflowsCompanion].
  static db.WorkflowsCompanion _toCompanion(Workflow w) {
    return db.WorkflowsCompanion(
      id: Value(w.id),
      name: Value(w.name),
      description: Value(w.description),
      stepsJson: Value(jsonEncode(w.steps.map((s) => s.toJson()).toList())),
      enabled: Value(w.enabled),
      notifyOnFailure: Value(w.notifyOnFailure),
      notifyOnSuccess: Value(w.notifyOnSuccess),
      createdAt: Value(w.createdAt),
      lastRunAt: Value(w.lastRunAt),
    );
  }

  // ── CRUD ──────────────────────────────────────────────────────

  /// Add a new workflow.
  Future<void> addWorkflow(Workflow workflow) async {
    await _dao.upsert(_toCompanion(workflow));
    state = [...state, workflow];
    AppLogger.info('WorkflowNotifier: added "${workflow.name}"');
  }

  /// Update an existing workflow by ID.
  Future<void> updateWorkflow(Workflow workflow) async {
    await _dao.upsert(_toCompanion(workflow));
    state = [
      for (final w in state)
        if (w.id == workflow.id) workflow else w,
    ];
    AppLogger.info('WorkflowNotifier: updated "${workflow.name}"');
  }

  /// Delete a workflow by ID.
  Future<void> deleteWorkflow(String workflowId) async {
    await _dao.deleteById(workflowId);
    state = state.where((w) => w.id != workflowId).toList();
    AppLogger.info('WorkflowNotifier: deleted workflow $workflowId');
  }

  /// Duplicate a workflow with a new ID and name.
  Future<void> duplicateWorkflow(String workflowId) async {
    final source = state.firstWhere(
      (w) => w.id == workflowId,
      orElse: () => throw StateError('Workflow not found: $workflowId'),
    );
    final copy =
        Workflow.create(
          name: '${source.name} (Copy)',
          description: source.description,
        ).copyWith(
          steps: source.steps,
          scheduleExpression: source.scheduleExpression,
          notifyOnFailure: source.notifyOnFailure,
          notifyOnSuccess: source.notifyOnSuccess,
        );
    await addWorkflow(copy);
  }

  /// Reorder steps within a workflow (for drag-and-drop).
  Future<void> reorderSteps(
    String workflowId,
    int oldIndex,
    int newIndex,
  ) async {
    final index = state.indexWhere((w) => w.id == workflowId);
    if (index == -1) return;
    final workflow = state[index];
    final steps = [...workflow.steps];
    final step = steps.removeAt(oldIndex);
    steps.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, step);
    await updateWorkflow(workflow.copyWith(steps: steps));
  }

  /// Record that a workflow ran at [when]. Used by the desktop "Run now" path,
  /// which drives [WorkflowService] directly (rather than [runWorkflow]) so it
  /// can stream per-step output into the inline drawer. Reuses the same DAO
  /// write [runWorkflow] performs, so it stays consistent with the mobile path.
  Future<void> markRan(String workflowId, DateTime when) async {
    final index = state.indexWhere((w) => w.id == workflowId);
    if (index == -1) return;
    await _dao.updateLastRun(workflowId, when);
    state = [
      for (final w in state)
        if (w.id == workflowId) w.copyWith(lastRunAt: when) else w,
    ];
  }

  /// Toggle a workflow's enabled state.
  Future<void> toggleEnabled(String workflowId) async {
    final index = state.indexWhere((w) => w.id == workflowId);
    if (index == -1) return;
    final workflow = state[index];
    await updateWorkflow(workflow.copyWith(enabled: !workflow.enabled));
  }

  // ── Execution ─────────────────────────────────────────────────

  /// Your Tree's workflows, whichever space is on screen: what a link, another
  /// app and a schedule run, as automation runs on the Tree's hosts. They read
  /// the space on screen: with a team's open, its workflows ran on personal hosts
  /// and the Tree's were not found (found 30 October 2026 in an independent
  /// review). A workflow saved in a team's space never runs that way.
  Future<List<Workflow>> ofTheTree() async {
    final rows = await _ref.read(treeDatabaseProvider).workflowsDao.getAll();
    return rows.map(_fromDbRow).toList();
  }

  /// Run a workflow by ID.
  ///
  /// Returns the [WorkflowResult] when execution finishes.
  /// Throws [StateError] if another workflow is already running.
  ///
  /// [unattended] MUST be true when this fires with no user present (scheduled
  /// task, `zestssh://` deep link, external intent). It gates every step's
  /// credential on the target identity's unattended opt-in, and the workflow is
  /// looked for in your Tree ([ofTheTree]). The interactive
  /// mobile "Run" button leaves it false. [thisRun] is the workflow as its
  /// person made it ready for this run ([workflowReadyToRun]: the values asked
  /// for are for this run alone).
  Future<WorkflowResult> runWorkflow(
    String workflowId, {
    bool unattended = false,
    Workflow? thisRun,
  }) async {
    // ── Pro gate ──
    final isPro = _ref.read(isProProvider);
    if (!isPro) {
      AppLogger.info('WorkflowNotifier: blocked - Pro required');
      _ref
          .read(activeWorkflowProvider.notifier)
          .setError('Squeezed required for workflows');
      return WorkflowResult(
        workflowId: workflowId,
        workflowName: '',
        success: false,
        stepResults: const [],
        totalElapsed: Duration.zero,
        errorMessage: 'Squeezed required',
      );
    }

    // ── A person's run in a team space ──
    // It would run on the hosts of the Tree (automationServiceProvider), none
    // of them listed on the screen. What runs by itself goes on.
    if (!unattended && _ref.read(activeSpaceProvider) is OrchardSpace) {
      final said = gl10n.wfRunTeamSpace;
      _ref.read(activeWorkflowProvider.notifier).setError(said);
      return WorkflowResult(
        workflowId: workflowId,
        workflowName: '',
        success: false,
        stepResults: const [],
        totalElapsed: Duration.zero,
        errorMessage: said,
      );
    }

    // ── Find workflow ──
    final List<Workflow> among;
    try {
      among = unattended ? await ofTheTree() : state;
    } catch (e, stack) {
      AppLogger.error('WorkflowNotifier: could not read the workflows', e, stack);
      return WorkflowResult(
        workflowId: workflowId,
        workflowName: 'Unknown',
        success: false,
        stepResults: const [],
        totalElapsed: Duration.zero,
        errorMessage: e.toString(),
      );
    }
    final workflow = among.cast<Workflow?>().firstWhere(
      (w) => w!.id == workflowId,
      orElse: () => null,
    );
    if (workflow == null) {
      _ref
          .read(activeWorkflowProvider.notifier)
          .setError('Workflow not found: $workflowId');
      return WorkflowResult(
        workflowId: workflowId,
        workflowName: 'Unknown',
        success: false,
        stepResults: const [],
        totalElapsed: Duration.zero,
        errorMessage: 'Workflow not found',
      );
    }

    // Enforce the per-step "disabled" (eye-off) toggle on EVERY run path.
    // The desktop Run-now button filters via buildRunnable, but the mobile Run,
    // deep-link/`zestssh://` intent, and scheduled paths all funnel through
    // here - without this, a step the user explicitly switched off (e.g. a
    // destructive `rm -rf` / `reboot`) would still execute on those paths.
    final asked = thisRun ?? workflow;
    final runnable = asked.steps.any((s) => s.disabled)
        ? asked.copyWith(
            steps: asked.steps.where((s) => !s.disabled).toList(),
          )
        : asked;

    if (runnable.steps.isEmpty) {
      _ref
          .read(activeWorkflowProvider.notifier)
          .setError('Workflow has no steps');
      return WorkflowResult(
        workflowId: workflowId,
        workflowName: workflow.name,
        success: false,
        stepResults: const [],
        totalElapsed: Duration.zero,
        errorMessage: 'Workflow has no steps',
      );
    }

    // ── Check for already-running workflow ──
    final activeNotifier = _ref.read(activeWorkflowProvider.notifier);
    final activeState = _ref.read(activeWorkflowProvider);
    if (activeState?.isRunning == true) {
      throw StateError('Another workflow is already running');
    }

    // ── Set up execution ──
    final token = CancellationToken();
    _activeCancellationToken = token;

    activeNotifier.start(runnable);

    final service = _ref.read(workflowServiceProvider);
    // The banner moves to the next step when this one is through on all its
    // hosts (it moved at the first host's result).
    final hostsOf = <int, int>{};
    final doneOf = <int, int>{};

    try {
      final result = await service.executeWorkflow(
        runnable,
        cancellationToken: token,
        unattended: unattended,
        onStepHosts: (stepIndex, hosts) {
          hostsOf[stepIndex] = hosts;
          doneOf[stepIndex] = 0;
        },
        onStepComplete: (stepIndex, totalSteps, stepResult) {
          final done = doneOf[stepIndex] = (doneOf[stepIndex] ?? 0) + 1;
          activeNotifier.onStepComplete(
            done >= (hostsOf[stepIndex] ?? 1) ? stepIndex + 1 : stepIndex,
            totalSteps,
            stepResult,
          );
        },
      );

      // ── Update lastRunAt ──
      final now = DateTime.now();
      await (unattended ? _ref.read(treeDatabaseProvider).workflowsDao : _dao).updateLastRun(workflow.id, now);
      final updatedWorkflow = workflow.copyWith(lastRunAt: now);
      // (The list on screen may be another space's by now, and of another notifier.)
      if (mounted) {
        state = [
          for (final w in state)
            if (w.id == workflow.id) updatedWorkflow else w,
        ];
      }

      // ── Finalize active state ──
      if (result.cancelled) {
        activeNotifier.setCancelled(result);
      } else {
        activeNotifier.setCompleted(result);
      }

      _activeCancellationToken = null;
      return result;
    } catch (e, stack) {
      AppLogger.error('WorkflowNotifier: execution failed', e, stack);
      activeNotifier.setError(e.toString());
      _activeCancellationToken = null;

      return WorkflowResult(
        workflowId: workflowId,
        workflowName: workflow.name,
        success: false,
        stepResults: const [],
        totalElapsed: Duration.zero,
        errorMessage: e.toString(),
      );
    }
  }

  /// Cancel the currently running workflow.
  void cancelWorkflow() {
    if (_activeCancellationToken != null) {
      _activeCancellationToken!.cancel();
      AppLogger.info('WorkflowNotifier: cancel requested');
    }
  }

  /// Get a workflow by ID, or null if not found.
  Workflow? getById(String workflowId) {
    return state.cast<Workflow?>().firstWhere(
      (w) => w!.id == workflowId,
      orElse: () => null,
    );
  }
}

// ── ActiveWorkflowNotifier ────────────────────────────────────────

/// Manages the real-time execution state of the active workflow.
class ActiveWorkflowNotifier extends StateNotifier<ActiveWorkflowState?> {
  ActiveWorkflowNotifier() : super(null);

  /// Begin tracking a new workflow execution.
  void start(Workflow workflow) {
    state = ActiveWorkflowState(
      workflow: workflow,
      status: WorkflowRunStatus.running,
      currentStepIndex: 0,
      totalSteps: workflow.steps.length,
    );
  }

  /// Update progress after a step completes.
  void onStepComplete(
    int completedStepIndex,
    int totalSteps,
    WorkflowStepResult stepResult,
  ) {
    if (state == null) return;
    state = state!.copyWith(
      currentStepIndex: completedStepIndex,
      totalSteps: totalSteps,
      stepResults: [...state!.stepResults, stepResult],
    );
  }

  /// Mark the workflow as completed.
  void setCompleted(WorkflowResult result) {
    if (state == null) return;
    state = state!.copyWith(
      status: result.success
          ? WorkflowRunStatus.completed
          : WorkflowRunStatus.error,
      result: result,
      currentStepIndex: state!.totalSteps,
    );
  }

  /// Mark the workflow as cancelled.
  void setCancelled(WorkflowResult result) {
    if (state == null) return;
    state = state!.copyWith(
      status: WorkflowRunStatus.cancelled,
      result: result,
    );
  }

  /// Set an error state (workflow failed to start).
  void setError(String message) {
    if (state == null) {
      // No workflow was started - create a minimal error state.
      state = ActiveWorkflowState(
        workflow: Workflow(
          id: '',
          name: '',
          steps: const [],
          createdAt: DateTime.now(),
        ),
        status: WorkflowRunStatus.error,
        errorMessage: message,
      );
    } else {
      state = state!.copyWith(
        status: WorkflowRunStatus.error,
        errorMessage: message,
      );
    }
  }

  /// Clear the active workflow state (dismiss results).
  void clear() {
    state = null;
  }
}
