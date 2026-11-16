import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/utils/redactor.dart';

/// What a phone's system notifications say (3.0): a connection
/// lost in the app's language, the host's name masked in recording mode (it
/// said "Connection Lost" and "<name> disconnected" in English); a workflow's
/// notice as the workflow says it (each said "Connection Lost").
class _NoAutomation implements AutomationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final shown = <(String, String)>[];

  setUp(() {
    shown.clear();
    NotificationService.debugShown = (title, body) => shown.add((title, body));
  });

  tearDown(() {
    NotificationService.debugShown = null;
    Redactor.instance.enabled = false;
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
  });

  test("a connection lost, in the app's language, the name masked while recording", () async {
    final en = lookupAppLocalizations(const Locale('en'));
    await NotificationService.showConnectionLost(connectionLabel: 'web-01');
    expect(shown, [(en.connectionLostTitle, en.connectionLostEnded('web-01'))]);

    final de = lookupAppLocalizations(const Locale('de'));
    L10nGlobal.update(de);
    Redactor.instance.enabled = true;
    shown.clear();
    await NotificationService.showConnectionLost(connectionLabel: 'web-01');
    final masked = Redactable.host('web-01').display;
    expect(masked, isNot('web-01'));
    expect(shown, [(de.connectionLostTitle, de.connectionLostEnded(masked))]);
  });

  test("a workflow's notice says what the workflow says, not that a connection was lost", () async {
    final en = lookupAppLocalizations(const Locale('en'));
    await NotificationService.showNotice(title: 'Nightly backup', body: 'Backups are done');
    expect(shown, [('Nightly backup', 'Backups are done')]);

    shown.clear();
    final workflows = WorkflowService(_NoAutomation());
    final result = await workflows.executeWorkflow(Workflow(
      id: 'w1',
      name: 'Nightly',
      createdAt: DateTime(2026, 10, 1),
      notifyOnSuccess: true,
      steps: const [WorkflowStep(id: 's0', type: WorkflowStepType.notify, command: 'Backups are done')],
    ));
    expect(result.success, isTrue);
    expect(shown, [
      (en.workflowSvcNotifyTitle, 'Backups are done'),
      (en.workflowSvcCompletedTitle, en.workflowSvcCompletedBody('Nightly', 1, 1)),
    ]);
  });
}
