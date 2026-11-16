import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/ui/screens/automation/workflow_list_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import '../helpers/desktop_mouse.dart';
import '../helpers/monitor_table_fixture.dart';

/// The list's Run now (a phone's, and a computer's from the palette's Open
/// workflows): the other way a person starts a workflow, asked what Run on the
/// Automation page asks. And its banner, which moved to the next step at the
/// first host's result.
class _Engine extends WorkflowService {
  _Engine(super.automation) : super(notice: (_, _, _) {});

  final runs = <Workflow>[];
  StepProgressCallback? complete;
  StepHostsCallback? hosts;
  final finish = Completer<void>();

  @override
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    runs.add(workflow);
    complete = onStepComplete;
    hosts = onStepHosts;
    await finish.future;
    return WorkflowResult(
      workflowId: workflow.id,
      workflowName: workflow.name,
      success: true,
      stepResults: const [],
      totalElapsed: Duration.zero,
    );
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  late AppDatabase db;
  late _Engine engine;
  late AutomationService automation;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, List<Workflow> workflows, {List<(String, String)> snippets = const []}) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    final prefs = await fleet.preferences();
    automation = AutomationService(db, const FlutterSecureStorage(), signIn: (c, {required unattended, onLog}) async {
      throw Exception('no host here');
    });
    engine = _Engine(automation);
    await tester.runAsync(() async {
      final at = DateTime(2026);
      for (final (label, command) in snippets) {
        await db.into(db.snippets).insert(SnippetsCompanion.insert(id: label, label: label, command: command, createdAt: at, updatedAt: at));
      }
    });
    await tester.pumpWidget(fleet.app(
      [
        ...fleet.overrides(db, prefs),
        treeDatabaseProvider.overrideWithValue(db),
        automationServiceProvider.overrideWithValue(automation),
        workflowServiceProvider.overrideWithValue(engine),
      ],
      Builder(builder: (context) {
        container = ProviderScope.containerOf(context);
        return const WorkflowListScreen();
      }),
    ));
    await settle(tester);
    await tester.runAsync(() async {
      for (final w in workflows) {
        await container.read(workflowsProvider.notifier).addWorkflow(w);
      }
    });
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    if (!engine.finish.isCompleted) engine.finish.complete();
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    automation.dispose();
    await db.close();
  }

  Workflow one(WorkflowStep step, {String id = 'w1', String name = 'Check disks'}) =>
      Workflow(id: id, name: name, steps: [step], createdAt: DateTime(2026));

  Future<void> runNow(WidgetTester tester, [String id = 'w1']) async {
    await tester.tap(find.byKey(ValueKey('workflow-run-now-$id')));
    await settle(tester);
  }

  const harmless = WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'uptime', connectionId: 'web1');

  desktopTest("in a team's space it says why, and nothing runs", (tester) async {
    await pump(tester, [one(harmless)]);
    container.read(activeSpaceProvider.notifier).state = const OrchardSpace('team');
    await settle(tester);
    await runNow(tester);
    expect(find.text(en.wfRunTeamSpace), findsOneWidget);
    expect(engine.runs, isEmpty);
    await finish(tester);
  });

  desktopTest('a risky command is asked about, on how many hosts, and No runs nothing', (tester) async {
    await pump(tester, [
      one(const WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'sudo reboot', targetIds: ['web1', 'web2'])),
    ]);
    await runNow(tester);
    expect(find.text(en.dangerCommandTitle), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('danger-on-hosts'))).data, en.wfDangerOnHosts(2));
    await tester.tap(find.byKey(const ValueKey('zest-dialog-secondary')));
    await settle(tester);
    expect(engine.runs, isEmpty);

    await runNow(tester);
    await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
    await settle(tester);
    expect(engine.runs, hasLength(1));
    await finish(tester);
  });

  desktopTest('a snippet with no value is asked for; backing out runs nothing; what is given is for this run alone',
      (tester) async {
    await pump(
      tester,
      [
        one(const WorkflowStep(
          id: 's1',
          type: WorkflowStepType.snippet,
          snippetName: 'Restart',
          connectionId: 'web1',
          variables: {'NAME': ''},
        )),
      ],
      snippets: [('Restart', r'docker restart ${NAME}')],
    );
    await runNow(tester);
    expect(find.text(en.snippetVarEnterValueFor('NAME')), findsOneWidget);
    await tester.tap(find.text(en.cancel).last);
    await settle(tester);
    expect(engine.runs, isEmpty);

    await runNow(tester);
    await tester.enterText(find.byType(TextFormField), 'shop');
    await settle(tester);
    await tester.tap(find.text(en.zestSnippetsRunButton).last);
    await settle(tester);
    expect(engine.runs.single.steps.single.variables, {'NAME': 'shop'});

    engine.finish.complete();
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await settle(tester);
    final saved = container.read(workflowsProvider).single;
    expect(saved.steps.single.variables, {'NAME': ''}, reason: 'the run marks when it ran, and keeps nothing asked');
    expect(saved.lastRunAt, isNotNull);
    await finish(tester);
  });

  desktopTest('while one runs, no other can be started: it stopped with an error nobody saw', (tester) async {
    await pump(tester, [one(harmless), one(harmless, id: 'w2', name: 'Another')]);
    await runNow(tester);
    expect(engine.runs, hasLength(1));
    final other = tester.widget<IconButton>(find.byKey(const ValueKey('workflow-run-now-w2')));
    expect(other.onPressed, isNull);
    await finish(tester);
  });

  desktopTest("the banner moves on when a step is through on all its hosts, not at the first host's result", (tester) async {
    await pump(tester, [
      Workflow(id: 'w1', name: 'Check disks', createdAt: DateTime(2026), steps: const [
        WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'first-command', targetIds: ['web1', 'web2', 'db']),
        WorkflowStep(id: 's2', type: WorkflowStepType.execute, command: 'second-command', connectionId: 'web1'),
      ]),
    ]);
    await runNow(tester);
    final first = find.text(en.workflowListStepProgress(1, 2, 'first-command'));
    final second = find.text(en.workflowListStepProgress(2, 2, 'second-command'));
    expect(first, findsOneWidget);

    WorkflowStepResult of(String host) =>
        WorkflowStepResult(stepId: 's1', stepType: WorkflowStepType.execute, success: true, connectionId: host, stepIndex: 0);
    engine.hosts!(0, 3);
    for (final host in ['web1', 'web2']) {
      engine.complete!(0, 2, of(host));
      await settle(tester);
      expect(first, findsOneWidget, reason: 'after $host');
      expect(second, findsNothing);
    }
    engine.complete!(0, 2, of('db'));
    await settle(tester);
    expect(second, findsOneWidget);
    expect(first, findsNothing);
    await finish(tester);
  });

  desktopTest('runWorkflow itself: a person\'s run refuses in a team\'s space, and what runs by itself is not touched', (tester) async {
    await pump(tester, [one(harmless)]);
    container.read(activeSpaceProvider.notifier).state = const OrchardSpace('team');
    final notifier = container.read(workflowsProvider.notifier);
    final person = await notifier.runWorkflow('w1');
    expect(person.success, isFalse);
    expect(person.errorMessage, en.wfRunTeamSpace);
    expect(engine.runs, isEmpty);

    unawaited(notifier.runWorkflow('w1', unattended: true));
    await settle(tester);
    expect(engine.runs, hasLength(1));
    await finish(tester);
  });
}
