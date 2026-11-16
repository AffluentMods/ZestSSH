import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/models/workflow.dart';

Workflow _wf(List<WorkflowStep> steps) => Workflow(
      id: 'w1',
      name: 'Deploy',
      steps: steps,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorkflowEditController - steps insert inline + reorder-persist', () {
    test('addStep appends, opens the card, and marks dirty', () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);

      expect(c.isDirty, isFalse);
      final draft = c.addStep(type: WorkflowStepType.execute);

      expect(c.steps, hasLength(1));
      expect(c.steps.single, same(draft));
      expect(c.isExpanded(draft.id), isTrue, reason: 'new step opens in place');
      expect(c.isDirty, isTrue);
    });

    test('addStep(index:) inserts mid-list (the "+ between cards" affordance)',
        () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);
      final a = c.addStep();
      final b = c.addStep();
      // Insert above b (index 1).
      final mid = c.addStep(index: 1);

      expect(c.steps.map((s) => s.id).toList(),
          [a.id, mid.id, b.id]);
    });

    test('reorderSteps reorders and buildWorkflow persists the new order', () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);
      final a = c.addStep()..commandController.text = 'a';
      final b = c.addStep()..commandController.text = 'b';
      final cc = c.addStep()..commandController.text = 'c';

      // Move the last step to the front.
      c.reorderSteps(2, 0);
      expect(c.steps.map((s) => s.id).toList(), [cc.id, a.id, b.id]);

      final built = c.buildWorkflow('w1');
      expect(built.steps.map((s) => s.command).toList(),
          ['c', 'a', 'b']);
    });

    test('buildRunnable drops disabled steps; buildWorkflow keeps them', () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);
      c.addStep()..commandController.text = 'keep';
      final off = c.addStep()..commandController.text = 'skip';
      c.toggleDisabled(off);

      expect(c.buildWorkflow('w1').steps, hasLength(2));
      final runnable = c.buildRunnable('w1');
      expect(runnable.steps, hasLength(1));
      expect(runnable.steps.single.command, 'keep');
    });
  });

  group('WorkflowEditController - round-trips stored workflows', () {
    test('a loaded command step round-trips through build unchanged', () {
      final c = WorkflowEditController()
        ..bind(_wf([
          const WorkflowStep(
            id: 's1',
            type: WorkflowStepType.execute,
            command: 'systemctl restart nginx',
            connectionId: 'conn-1',
            timeoutSeconds: 45,
            onFailure: StepFailureAction.continueNext,
          ),
        ]));
      addTearDown(c.dispose);

      final step = c.buildWorkflow('w1').steps.single;
      expect(step.type, WorkflowStepType.execute);
      expect(step.command, 'systemctl restart nginx');
      expect(step.connectionId, 'conn-1');
      expect(step.timeoutSeconds, 45);
      expect(step.onFailure, StepFailureAction.continueNext);
    });

    test('a "Go to Step" failure branch survives a load + rebuild (regression)',
        () {
      // Opening a stored gotoStep workflow in the inline editor and saving it
      // must NOT silently downgrade it to abort or drop the branch target.
      final c = WorkflowEditController()
        ..bind(_wf([
          const WorkflowStep(
            id: 's1',
            type: WorkflowStepType.execute,
            command: 'deploy.sh',
            onFailure: StepFailureAction.gotoStep,
            gotoStepId: 's2',
          ),
          const WorkflowStep(
            id: 's2',
            type: WorkflowStepType.execute,
            command: 'rollback.sh',
          ),
        ]));
      addTearDown(c.dispose);

      final first = c.buildWorkflow('w1').steps.first;
      expect(first.onFailure, StepFailureAction.gotoStep,
          reason: 'failure action preserved, not reverted to abort');
      expect(first.gotoStepId, 's2', reason: 'branch target preserved');
    });

    test('toggling continue-on-error off a gotoStep clears the stale target',
        () {
      final c = WorkflowEditController()
        ..bind(_wf([
          const WorkflowStep(
            id: 's1',
            type: WorkflowStepType.execute,
            command: 'deploy.sh',
            onFailure: StepFailureAction.gotoStep,
            gotoStepId: 's2',
          ),
        ]));
      addTearDown(c.dispose);
      // The inline editor only exposes a continue/abort switch; flipping it must
      // resolve to a concrete action and not leave a dangling goto target.
      c.steps.single.continueOnError = true;

      final step = c.buildWorkflow('w1').steps.single;
      expect(step.onFailure, StepFailureAction.continueNext);
      expect(step.gotoStepId, isNull);
    });

    test('advanced fields (retries/workingDir/runIfPrevious) survive a rebuild',
        () {
      final c = WorkflowEditController()
        ..bind(_wf([
          const WorkflowStep(
            id: 's1',
            type: WorkflowStepType.execute,
            command: 'ls',
            retries: 3,
            workingDir: '/opt/app',
            runIfPrevious: false,
          ),
        ]));
      addTearDown(c.dispose);

      final step = c.buildWorkflow('w1').steps.single;
      expect(step.retries, 3);
      expect(step.workingDir, '/opt/app');
      expect(step.runIfPrevious, isFalse);
    });

    test('a snippet step keeps its selected snippet + variable values', () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);
      final draft = c.addStep(type: WorkflowStepType.snippet);
      c.setStepSnippet(draft, 'Greet', ['NAME']);
      c.setStepVariable(draft, 'NAME', 'world');

      final step = c.buildWorkflow('w1').steps.single;
      expect(step.type, WorkflowStepType.snippet);
      expect(step.snippetName, 'Greet');
      expect(step.variables, {'NAME': 'world'});
    });

    test('re-picking a snippet prunes variables that no longer exist', () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);
      final draft = c.addStep(type: WorkflowStepType.snippet);
      c.setStepSnippet(draft, 'Greet', ['NAME']);
      c.setStepVariable(draft, 'NAME', 'world');
      // Pick a different snippet whose only variable is HOST.
      c.setStepSnippet(draft, 'Ping', ['HOST']);

      expect(draft.variables.containsKey('NAME'), isFalse);
    });
  });

  group('WorkflowEditController - persistence surface', () {
    test('buildWorkflow carries name/description/notify flags, and a schedule an earlier version set as it was',
        () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);
      c.nameController.text = 'Nightly';
      c.descriptionController.text = 'Runs backups';
      c.setNotifyOnSuccess(true);

      final wf = c.buildWorkflow('w1');
      expect(wf.name, 'Nightly');
      expect(wf.description, 'Runs backups');
      expect(wf.scheduleExpression, isNull);
      expect(wf.notifyOnSuccess, isTrue);

      c.bind(wf.copyWith(scheduleExpression: '0 3 * * *'));
      expect(c.buildWorkflow('w1').scheduleExpression, '0 3 * * *');
    });

    test('markSaved clears the dirty flag', () {
      final c = WorkflowEditController()..bind(null);
      addTearDown(c.dispose);
      c.addStep();
      expect(c.isDirty, isTrue);
      c.markSaved(c.buildWorkflow('w1'));
      expect(c.isDirty, isFalse);
    });
  });
}
