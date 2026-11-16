import 'package:flutter/foundation.dart';

import '../../../models/workflow.dart';
import '../../../services/workflow_service.dart';

/// The id a run of a workflow not saved yet goes by.
const kWorkflowDraftRunId = '__draft__';

/// Lifecycle of the inline run-output drawer.
enum WorkflowRunPhase { idle, running, finished }

/// Drives "Run now" and owns the streaming state the run-output drawer renders.
///
/// It delegates execution to the EXISTING [WorkflowService.executeWorkflow],
/// wiring a [StepProgressCallback] that appends each [WorkflowStepResult] as it
/// completes so the drawer updates live. No new execution engine - this is a
/// thin presentation shim over the shipped one.
class WorkflowRunController extends ChangeNotifier {
  bool _open = false;

  /// Whether the drawer is visible.
  bool get isOpen => _open;

  WorkflowRunPhase _phase = WorkflowRunPhase.idle;
  WorkflowRunPhase get phase => _phase;
  bool get isRunning => _phase == WorkflowRunPhase.running;

  /// The workflow id currently shown in the drawer (so a stale run for a
  /// different workflow is never rendered against the open one).
  String? _workflowId;
  String? get workflowId => _workflowId;

  String _workflowName = '';
  String get workflowName => _workflowName;

  /// What the panel shows the run of: its steps' names.
  Workflow? _workflow;
  Workflow? get workflow => _workflow;

  final List<WorkflowStepResult> _results = [];
  List<WorkflowStepResult> get results => List.unmodifiable(_results);

  int _totalSteps = 0;
  int get totalSteps => _totalSteps;

  /// How many hosts each step with many targets runs on, by step.
  final Map<int, int> _hostsOfStep = {};

  /// How many hosts step [index] runs on: one, where it has no many targets.
  int hostsOfStep(int index) => _hostsOfStep[index] ?? 1;

  /// How many results a step had before it went back to itself, on the hosts
  /// that failed: those are not of this round.
  final Map<int, int> _resultsBefore = {};

  /// How many results step [index] has so far, this time through.
  int resultsOfStep(int index) => _results.where((r) => r.stepIndex == index).length - (_resultsBefore[index] ?? 0);

  /// How many steps are through.
  int get stepsDone {
    final seen = <int>{for (final r in _results) ?r.stepIndex};
    return seen.where((i) => resultsOfStep(i) >= hostsOfStep(i)).length;
  }

  int _currentStep = 0;

  /// 1-based index of the step currently executing (0 when idle).
  int get currentStep => _currentStep;

  WorkflowResult? _finalResult;
  WorkflowResult? get finalResult => _finalResult;

  String? _blockedMessage;

  /// Set when the run could not start (e.g. no steps, Pro required).
  String? get blockedMessage => _blockedMessage;

  CancellationToken? _token;

  /// Which run the panel shows. A run left behind (the pane went to another
  /// workflow, or another run started) is told to stop, and what it still says
  /// is not listened to: its rows came up under the next run, and its end ended
  /// that run's panel.
  int _generation = 0;

  /// Stops the run going, if there is one, and stops listening to it.
  void _leaveTheRun() {
    _generation++;
    _token?.cancel();
    _token = null;
  }

  /// The draft whose run this is was saved as [workflowId]: its panel is looked
  /// for under that now, Cancel and all (they went from the screen, the run going
  /// on).
  void draftSavedAs(String workflowId) {
    if (_workflowId != kWorkflowDraftRunId) return;
    _workflowId = workflowId;
    notifyListeners();
  }

  /// Open the drawer without starting a run (e.g. to show the last result).
  void open() {
    _open = true;
    notifyListeners();
  }

  void close() {
    _open = false;
    notifyListeners();
  }

  /// Forget the last run's results, and close the panel: nothing is left to
  /// show (it could not be closed, nor emptied, before).
  void clear() {
    if (isRunning) return;
    reset();
  }

  /// Report a pre-run failure (no steps / Pro gate) into the drawer.
  void reportBlocked(Workflow workflow, String message) {
    _leaveTheRun();
    _open = true;
    _phase = WorkflowRunPhase.finished;
    _workflowId = workflow.id;
    _workflowName = workflow.name;
    _workflow = workflow;
    _results.clear();
    _hostsOfStep.clear();
    _resultsBefore.clear();
    _totalSteps = 0;
    _currentStep = 0;
    _finalResult = null;
    _blockedMessage = message;
    notifyListeners();
  }

  /// Execute [workflow] via the shipped [service], streaming per-step results
  /// into the drawer. Returns the aggregated [WorkflowResult].
  Future<WorkflowResult> run(WorkflowService service, Workflow workflow) async {
    _leaveTheRun();
    final generation = _generation;
    final token = _token = CancellationToken();
    _open = true;
    _phase = WorkflowRunPhase.running;
    _workflowId = workflow.id;
    _workflowName = workflow.name;
    _workflow = workflow;
    _results.clear();
    _hostsOfStep.clear();
    _resultsBefore.clear();
    _totalSteps = workflow.steps.length;
    _currentStep = workflow.steps.isEmpty ? 0 : 1;
    _finalResult = null;
    _blockedMessage = null;
    notifyListeners();

    final WorkflowResult result;
    try {
      result = await service.executeWorkflow(
        workflow,
        cancellationToken: token,
        onStepHosts: (stepIndex, hosts) {
          if (generation != _generation) return;
          _hostsOfStep[stepIndex] = hosts;
          _resultsBefore[stepIndex] = _results.where((r) => r.stepIndex == stepIndex).length;
          notifyListeners();
        },
        onStepComplete: (stepIndex, totalSteps, stepResult) {
          if (generation != _generation) return;
          _results.add(stepResult.located(stepIndex: stepIndex));
          _totalSteps = totalSteps;
          // Advance the "running" marker to the next step once this one is
          // through on all its hosts, capped at the total.
          _currentStep = resultsOfStep(stepIndex) >= hostsOfStep(stepIndex)
              ? (stepIndex + 2).clamp(0, totalSteps)
              : stepIndex + 1;
          notifyListeners();
        },
      );
    } catch (e) {
      // What the engine did not catch: said, not a panel on Running for ever.
      final failed = WorkflowResult(
        workflowId: workflow.id,
        workflowName: workflow.name,
        success: false,
        stepResults: List.of(_results),
        totalElapsed: Duration.zero,
        errorMessage: e.toString(),
      );
      if (generation == _generation) {
        _phase = WorkflowRunPhase.finished;
        _finalResult = failed;
        _blockedMessage = e.toString();
        _currentStep = 0;
        _token = null;
        notifyListeners();
      }
      return failed;
    }

    if (generation == _generation) {
      _phase = WorkflowRunPhase.finished;
      _finalResult = result;
      _currentStep = 0;
      _token = null;
      notifyListeners();
    }
    return result;
  }

  /// Request graceful cancellation of the active run.
  void cancel() => _token?.cancel();

  /// Reset when the pane rebinds to a different workflow. A run going stops:
  /// its Cancel is gone with its panel.
  void reset() {
    _leaveTheRun();
    _open = false;
    _phase = WorkflowRunPhase.idle;
    _workflowId = null;
    _workflowName = '';
    _workflow = null;
    _results.clear();
    _hostsOfStep.clear();
    _resultsBefore.clear();
    _totalSteps = 0;
    _currentStep = 0;
    _finalResult = null;
    _blockedMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _leaveTheRun();
    super.dispose();
  }
}
