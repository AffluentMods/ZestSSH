import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_status.dart';
import 'package:zestssh/features/automation/widgets/runs_timeline.dart';
import 'package:zestssh/features/automation/widgets/workflow_detail_pane.dart';
import 'package:zestssh/features/automation/widgets/workflow_list_pane.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

class _Workflows extends StateNotifier<List<Workflow>> implements WorkflowNotifier {
  _Workflows(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's workflows show no schedule and no device to run on (found
/// while comparing the five platforms' versions): a workflow's schedule was
/// set, listed under "Upcoming runs" and summed up in the lists, and nothing
/// ran it; "Run on" chose among devices a workflow never reaches, as
/// workflows do not sync, and could refuse a run here.
void main() {
  late AppLocalizations l10n;
  setUpAll(() async => l10n = await AppLocalizations.delegate.load(const Locale('en')));

  final scheduled = Workflow(
    id: 'w1',
    name: 'Nightly backup',
    createdAt: DateTime(2026, 10, 1),
    scheduleExpression: '0 3 * * *',
    steps: const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'backup.sh')],
  );
  final manual = Workflow(id: 'w2', name: 'Deploy', createdAt: DateTime(2026, 10, 1), steps: const []);

  /// A section headed [label] (a header draws its label in capitals).
  Finder section(String label) => find.byWidgetPredicate((w) => w is ZestSectionHeader && w.label == label);

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        workflowsProvider.overrideWith((ref) => _Workflows([scheduled, manual])),
        workflowLastRunProvider.overrideWith((ref) => const {}),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        automationLogProvider.overrideWith((ref) => Stream.value(const [])),
        scheduledTasksStreamProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // (How many workflows there are is the page head's line: see
  // automation_switch_test.dart.)
  testWidgets('the list counts steps, and says no schedule', (tester) async {
    await pump(tester, WorkflowListPane(selectedId: null, onSelect: (_) {}, onCreate: () {}));
    expect(find.text(l10n.zestAutoRowStepCount(1)), findsOneWidget);
    expect(find.textContaining('Manual'), findsNothing);
    expect(find.textContaining('3:00'), findsNothing);
  });

  testWidgets('the editor has no schedule and no device to run on; its header gives the steps', (tester) async {
    final controller = WorkflowEditController()..bind(scheduled);
    final run = WorkflowRunController();
    addTearDown(controller.dispose);
    addTearDown(run.dispose);
    await pump(
        tester,
        WorkflowDetailPane(
          controller: controller,
          runController: run,
          hasSelection: true,
          onSave: () async => true,
          onClose: () {},
          onDelete: () {},
          onRun: () {},
        ));
    expect(find.text('Nightly backup'), findsWidgets);
    expect(section('Schedule'), findsNothing);
    expect(section(l10n.autoTellMeSection), findsOneWidget, reason: 'the sections are found as they are drawn');
    // The words the schedule and the device to run on had.
    for (final gone in ['Cron', 'Run on', 'This device', 'All devices']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.text(l10n.zestAutoRowStepCount(1)), findsOneWidget);
    // A schedule an earlier version set is kept as it was.
    expect(controller.buildWorkflow('w1').scheduleExpression, '0 3 * * *');
  });

  testWidgets('a workflow with a schedule is not listed among the upcoming runs', (tester) async {
    await pump(tester, const RunsTimeline());
    expect(section(l10n.zestAutoScheduleAgendaTitle), findsNothing);
    expect(find.text('Nightly backup'), findsNothing);
  });
}
