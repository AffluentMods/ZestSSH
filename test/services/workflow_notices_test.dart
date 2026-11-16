// A workflow's notices (found while comparing the five
// versions). On a computer a Notify step, and a workflow's "notify on success"
// and "on failure", showed nothing, and the step said "Notification sent": the
// system's notification is a phone's alone in this app. A computer's editor
// called a Notify step a Condition, with a shell test for its example, and no
// condition was ever tested. And a message's {{output}}, which a phone's
// editor offers, was sent as it was typed; a message a phone saved empty sent
// an empty notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/widgets/step_card.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/utils/redactor.dart';

import '../helpers/fake_notifications_plugin.dart';

/// Every command says "4 updates", or [says].
class _Automation implements AutomationService {
  _Automation([this.says = '4 updates']);
  final String says;

  @override
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async =>
      AutomationResult(success: true, output: says, error: '', exitCode: 0, elapsed: Duration.zero);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Workflow _workflow(String name, List<WorkflowStep> steps, {bool onSuccess = false, bool onFailure = false}) => Workflow(
      id: name,
      name: name,
      createdAt: DateTime(2026, 10, 1),
      notifyOnSuccess: onSuccess,
      notifyOnFailure: onFailure,
      steps: steps,
    );

WorkflowStep _notify(String id, String? message) =>
    WorkflowStep(id: id, type: WorkflowStepType.notify, command: message);

const _wait = WorkflowStep(id: 'wait', type: WorkflowStepType.delay, timeoutSeconds: 0);
const _updates =
    WorkflowStep(id: 'updates', type: WorkflowStepType.execute, connectionId: 'c1', command: 'apt list --upgradable');

/// A command with no host to run on: it fails.
const _broken = WorkflowStep(id: 'broken', type: WorkflowStepType.execute, command: 'uptime');

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test("a Notify step sends its message with the last command's output where it says {{output}}; with none typed, "
      "that output; with no output either, a notice of its own; a wait's words and a notice's own are no output",
      () async {
    final said = <(WorkflowNoticeKind, String, String)>[];
    final service = WorkflowService(_Automation(), notice: (kind, title, body) => said.add((kind, title, body)));
    final result = await service.executeWorkflow(_workflow('Updates', [
      _updates,
      _notify('typed', 'Updates: {{output}}'),
      _wait,
      _notify('saved empty', ''),
      _notify('none', null),
    ]));
    expect(result.success, isTrue);
    expect(said, [
      (WorkflowNoticeKind.said, en.workflowSvcNotifyTitle, 'Updates: 4 updates'),
      (WorkflowNoticeKind.said, en.workflowSvcNotifyTitle, '4 updates'),
      (WorkflowNoticeKind.said, en.workflowSvcNotifyTitle, '4 updates'),
    ]);

    said.clear();
    await service.executeWorkflow(_workflow('Nothing run', [_wait, _notify('blank', '  '), _notify('typed', 'Done: {{output}}')]));
    expect(said, [
      (WorkflowNoticeKind.said, en.workflowSvcNotifyTitle, en.workflowSvcDefaultNotification),
      (WorkflowNoticeKind.said, en.workflowSvcNotifyTitle, 'Done: '),
    ]);
  });

  group('while a screen is recorded', () {
    const said = 'ssh: web-01 at 192.168.10.21 is ok';
    setUp(() {
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout
        ..registerNames(['web-01'])
        ..registerAddresses(['192.168.10.21']);
    });
    tearDown(() {
      Redactor.instance
        ..clearNames()
        ..enabled = false;
    });

    test("{{output}} is masked as the run's panel masks it, on a card that comes up by itself", () async {
      final bodies = <String>[];
      await WorkflowService(_Automation(said), notice: (_, _, body) => bodies.add(body)).executeWorkflow(_workflow('N', [
        _updates,
        _notify('n1', 'Says: {{output}}'),
        _notify('n2', ''),
      ]));
      expect(bodies, hasLength(2));
      for (final body in bodies) {
        expect(body, isNot(contains('web-01')));
        expect(body, isNot(contains('192.168.10.21')));
      }
      expect(bodies.first, 'Says: ${Redactable.freeText(said).display}');
    });

    test('and nothing is made up where there was no output', () async {
      final bodies = <String>[];
      await WorkflowService(_Automation(), notice: (_, _, body) => bodies.add(body)).executeWorkflow(_workflow('N', [_wait, _notify('n1', null)]));
      expect(bodies.single, en.workflowSvcDefaultNotification);
    });
  });

  test('a workflow that finished says so as finished, and one that failed as failed', () async {
    final said = <(WorkflowNoticeKind, String, String)>[];
    final service = WorkflowService(_Automation(), notice: (kind, title, body) => said.add((kind, title, body)));
    await service.executeWorkflow(_workflow('Nightly', [_wait], onSuccess: true, onFailure: true));
    await service.executeWorkflow(_workflow('Broken', [_broken], onSuccess: true, onFailure: true));
    expect(said, [
      (WorkflowNoticeKind.finished, en.workflowSvcCompletedTitle, en.workflowSvcCompletedBody('Nightly', 1, 1)),
      (WorkflowNoticeKind.failed, en.workflowSvcFailedTitle, en.workflowSvcFailedBody('Broken', 1, 0)),
    ]);
  });

  test("in the app, one of its notices of the notice's kind, on a computer too (it showed nothing there); on a phone "
      "the system's notification as well", () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      automationServiceProvider.overrideWithValue(_Automation()),
    ]);
    addTearDown(c.dispose);
    final system = <(String, String)>[];
    NotificationService.debugShown = (title, body) => system.add((title, body));
    addTearDown(() => NotificationService.debugShown = null);
    addTearDown(() => debugWorkflowNoticesOnPhone = null);
    List<(NotificationSeverity, String, String?)> notices() => [
          for (final n in c.read(notificationCenterProvider).history.reversed) (n.severity, n.title, n.body),
        ];

    // (The tests run on a computer.)
    final service = c.read(workflowServiceProvider);
    await service.executeWorkflow(_workflow('Nightly', [_notify('done', 'Backups are done')], onSuccess: true));
    expect(notices(), [
      (NotificationSeverity.info, en.workflowSvcNotifyTitle, 'Backups are done'),
      (NotificationSeverity.success, en.workflowSvcCompletedTitle, en.workflowSvcCompletedBody('Nightly', 1, 1)),
    ]);
    expect(system, isEmpty, reason: "a computer has no system notification of the app's");

    debugWorkflowNoticesOnPhone = true;
    await service.executeWorkflow(_workflow('Broken', [_broken], onFailure: true));
    expect(notices().last, (NotificationSeverity.warning, en.workflowSvcFailedTitle, en.workflowSvcFailedBody('Broken', 1, 0)));
    expect(system, [(en.workflowSvcFailedTitle, en.workflowSvcFailedBody('Broken', 1, 0))]);
  });

  test("on a computer whose person turned on system notifications (4.0): the system's as well while the window is "
      'not in front, and only the app\'s while it is', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      automationServiceProvider.overrideWithValue(_Automation()),
    ]);
    addTearDown(c.dispose);
    var front = false;
    await computerWithSystemNotices(inFront: () => front);
    addTearDown(NotificationService.debugReset);
    final system = <(String, String)>[];
    NotificationService.debugShown = (title, body) => system.add((title, body));
    debugWorkflowNoticesOnPhone = false;
    addTearDown(() => debugWorkflowNoticesOnPhone = null);
    final service = c.read(workflowServiceProvider);
    await service.executeWorkflow(_workflow('Nightly', [_notify('done', 'Backups are done')], onSuccess: true));
    await pumpEventQueue();
    expect(system, [
      (en.workflowSvcNotifyTitle, 'Backups are done'),
      (en.workflowSvcCompletedTitle, en.workflowSvcCompletedBody('Nightly', 1, 1)),
    ]);
    front = true;
    await service.executeWorkflow(_workflow('Again', [_notify('done', 'Done again')], onSuccess: true));
    await pumpEventQueue();
    expect(system, hasLength(2), reason: "the window's own card is in sight");
  });

  test("a computer's editor calls a Notify step what it is, with the words its message can have", () {
    final draft = StepDraft.fromStep(_notify('n', null));
    addTearDown(draft.dispose);
    expect(stepTypeLabel(en, WorkflowStepType.notify), en.wfEditOptNotifyLabel);
    expect(stepDerivedTitle(en, draft), en.wfEditOptNotifyLabel, reason: 'a Condition, where none was ever tested');
    draft.commandController.text = 'Backups are done: {{output}}';
    expect(stepDisplayTitle(en, draft), 'Backups are done: {{output}}');
    expect(kStepTypeOrder, contains(WorkflowStepType.notify));
  });

  testWidgets("a Notify step's card on a computer: Notify, with what its message can say for its example",
      (tester) async {
    final c = WorkflowEditController()..bind(_workflow('W', [_notify('n', null)]));
    addTearDown(c.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: c,
              builder: (_, _) => StepCard(
                draft: c.steps.first,
                controller: c,
                stepNumber: 1,
                index: 0,
                connections: const [],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byTooltip(en.wfEditOptNotifyLabel));
    await tester.pumpAndSettle();
    expect(find.text(en.wfEditNotificationHint('{{output}}')), findsOneWidget);
    expect(find.text('Condition'), findsNothing);
    expect(find.text('test -f /var/run/app.pid'), findsNothing, reason: 'a shell test, which no step ever ran');
  });
}
