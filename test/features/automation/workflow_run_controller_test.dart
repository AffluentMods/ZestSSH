import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/services/workflow_service.dart';

/// A mock of the shipped execution engine: it streams a crafted result for each
/// step through [onStepComplete] (step index 1 "fails"), then returns the
/// aggregate - exactly the contract the real [WorkflowService] honours.
class _FakeWorkflowService implements WorkflowService {
  @override
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    final results = <WorkflowStepResult>[];
    for (var i = 0; i < workflow.steps.length; i++) {
      // Yield so a listener can observe the results growing one at a time.
      await Future<void>.delayed(Duration.zero);
      final step = workflow.steps[i];
      final failed = i == 1;
      final result = WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: !failed,
        output: 'stdout-$i',
        error: failed ? 'permission denied' : '',
        exitCode: failed ? 1 : 0,
        elapsed: const Duration(milliseconds: 5),
      );
      results.add(result);
      onStepComplete?.call(i, workflow.steps.length, result);
    }
    return WorkflowResult(
      workflowId: workflow.id,
      workflowName: workflow.name,
      success: false,
      stepResults: results,
      totalElapsed: const Duration(milliseconds: 15),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Workflow _wf() => Workflow(
      id: 'w1',
      name: 'Deploy',
      createdAt: DateTime(2026, 1, 1),
      steps: const [
        WorkflowStep(id: 's0', type: WorkflowStepType.execute, command: 'a'),
        WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'b'),
        WorkflowStep(id: 's2', type: WorkflowStepType.execute, command: 'c'),
      ],
    );

void main() {
  test('run streams per-step results into the drawer as they complete',
      () async {
    final controller = WorkflowRunController();
    final counts = <int>[];
    controller.addListener(() => counts.add(controller.results.length));

    final result = await controller.run(_FakeWorkflowService(), _wf());

    // Every step surfaced, in order, one at a time.
    expect(controller.results, hasLength(3));
    expect(counts, containsAllInOrder(<int>[1, 2, 3]));

    // The drawer opened and finished.
    expect(controller.isOpen, isTrue);
    expect(controller.phase, WorkflowRunPhase.finished);
    expect(controller.finalResult, isNotNull);
    expect(result.success, isFalse);
  });

  test('a failing step surfaces its stderr without leaving the pane', () async {
    final controller = WorkflowRunController();
    await controller.run(_FakeWorkflowService(), _wf());

    final failing = controller.results[1];
    expect(failing.success, isFalse);
    expect(failing.exitCode, 1);
    expect(failing.error, 'permission denied');
  });

  test('reportBlocked opens the drawer with a message and no results', () {
    final controller = WorkflowRunController();
    controller.reportBlocked(_wf(), 'Pro required');

    expect(controller.isOpen, isTrue);
    expect(controller.blockedMessage, 'Pro required');
    expect(controller.results, isEmpty);
    expect(controller.isRunning, isFalse);
  });
}
