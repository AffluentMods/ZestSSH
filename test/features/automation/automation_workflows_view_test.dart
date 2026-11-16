import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/automation_tab.dart';
import 'package:zestssh/features/automation/pages/automation_workflows_view.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_status.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart' show kMaskedValueShown;
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/desktop_mouse.dart';
import '../../helpers/monitor_table_fixture.dart';

/// The Automation page, with the real engine and the real hosts of a database:
/// what a person's Run and Run on… do before anything runs, and what runs. (Each
/// was only tested in parts: Run on… was never run through to a run.)
class _Recording extends WorkflowService {
  _Recording(super.automation) : super(notice: (_, _, _) {});

  /// What was handed to the engine.
  final runs = <Workflow>[];

  /// Holds a run at its start, until completed, and what it was told to stop by.
  Completer<void>? hold;
  CancellationToken? token;

  @override
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    runs.add(workflow);
    token = cancellationToken;
    await hold?.future;
    return super.executeWorkflow(
      workflow,
      cancellationToken: cancellationToken,
      onStepComplete: onStepComplete,
      onStepHosts: onStepHosts,
      unattended: unattended,
    );
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  late AppDatabase db;
  late _Recording engine;
  late AutomationService automation;
  late ProviderContainer container;
  late List<String> signedIn;
  late SharedPreferences prefs;

  Future<void> pump(
    WidgetTester tester, {
    List<Workflow> workflows = const [],
    List<(String, String)> snippets = const [],
    Set<String> confirming = const {},
    bool recording = false,
    Size size = const Size(2400, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    prefs = await fleet.preferences();
    if (recording) {
      await prefs.setBool('recording_mode_enabled', true);
      addTearDown(() => Redactor.instance.enabled = false);
    }
    signedIn = [];
    automation = AutomationService(db, const FlutterSecureStorage(), signIn: (c, {required unattended, onLog}) async {
      signedIn.add(c.id);
      throw Exception('no host here');
    });
    engine = _Recording(automation);
    await tester.runAsync(() async {
      final at = DateTime(2026);
      for (final (label, command) in snippets) {
        await db.into(db.snippets).insert(SnippetsCompanion.insert(
            id: label, label: label, command: command, confirmBeforeRun: Value(confirming.contains(label)), createdAt: at, updatedAt: at));
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
        return const AutomationWorkflowsView();
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
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    automation.dispose();
    await db.close();
  }

  Workflow workflow(WorkflowStep step, {String id = 'w1', String name = 'Check disks'}) =>
      Workflow(id: id, name: name, steps: [step], createdAt: DateTime(2026));

  /// Opens the workflow named [name] from the list.
  Future<void> open(WidgetTester tester, [String name = 'Check disks']) async {
    await tester.tap(find.text(name).first);
    await settle(tester);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  /// What needs the database to answer, done.
  Future<void> settleReal(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Whether any text on screen holds [what], in clear.
  bool onScreen(WidgetTester tester, String what) => tester
      .widgetList<Text>(find.byType(Text))
      .any((t) => (t.data ?? t.textSpan?.toPlainText() ?? '').contains(what));

  const everywhere = WorkflowStep(
    id: 's1',
    type: WorkflowStepType.execute,
    command: 'uptime',
    targetAll: true,
    onFailure: StepFailureAction.continueNext,
  );

  group('Run on…', () {
    desktopTest('it reaches a run with exactly the hosts picked, in place of what the step is set to run on', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)]);
      await open(tester);
      await tapKey(tester, 'workflow-run-on');
      await tapKey(tester, 'workflow-run-host-web1');
      await tapKey(tester, 'workflow-run-host-db');
      await tester.tap(find.text(en.runOnHostsRun(2)));
      await settle(tester);
      final ran = engine.runs.single.steps.single;
      expect(ran.targetAll, isFalse);
      expect(ran.targetIds.toSet(), {'web1', 'db'});
      expect(signedIn.toSet(), {'web1', 'db'});
      expect(find.byKey(const ValueKey('workflow-run-line-s1-web1')), findsOneWidget);
      await finish(tester);
    });

    desktopTest('of one host, the same: there and nowhere else', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)]);
      await open(tester);
      await tapKey(tester, 'workflow-run-on');
      await tapKey(tester, 'workflow-run-host-hva');
      await tester.tap(find.text(en.runOnHostsRun(1)));
      await settle(tester);
      expect(signedIn, ['hva']);
      await finish(tester);
    });

    desktopTest('backed out of, nothing runs', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)]);
      await open(tester);
      await tapKey(tester, 'workflow-run-on');
      await tapKey(tester, 'workflow-run-host-web1');
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('a host that cannot run a command cannot be ticked', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)]);
      await tester.runAsync(() => (db.update(db.connections)..where((t) => t.id.equals('web2')))
          .write(const ConnectionsCompanion(protocol: Value('telnet'))));
      await settle(tester);
      await open(tester);
      await tapKey(tester, 'workflow-run-on');
      expect(find.byKey(const ValueKey('workflow-run-host-web2-no-terminal')), findsOneWidget);
      await tapKey(tester, 'zest-dialog-secondary');
      await finish(tester);
    });
  });

  group("a team's space", () {
    desktopTest('Run says why, and nothing runs', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)]);
      await open(tester);
      container.read(activeSpaceProvider.notifier).state = const OrchardSpace('team');
      await settle(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.wfRunTeamSpace), findsOneWidget);
      expect(engine.runs, isEmpty);
      expect(signedIn, isEmpty);
      await finish(tester);
    });

    desktopTest('Run on… too, before asking for any host', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)]);
      await open(tester);
      container.read(activeSpaceProvider.notifier).state = const OrchardSpace('team');
      await settle(tester);
      await tapKey(tester, 'workflow-run-on');
      expect(find.byKey(const ValueKey('workflow-run-host-web1')), findsNothing);
      expect(find.text(en.wfRunTeamSpace), findsOneWidget);
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('back in Personal it runs', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)]);
      await open(tester);
      container.read(activeSpaceProvider.notifier).state = const OrchardSpace('team');
      await settle(tester);
      await tapKey(tester, 'workflow-run');
      container.read(activeSpaceProvider.notifier).state = const TreeSpace();
      await settle(tester);
      await tapKey(tester, 'workflow-run');
      expect(engine.runs, hasLength(1));
      await finish(tester);
    });
  });

  group('a risky command', () {
    const risky = WorkflowStep(
      id: 's1',
      type: WorkflowStepType.execute,
      command: 'sudo reboot',
      targetIds: ['web1', 'web2', 'db'],
      onFailure: StepFailureAction.continueNext,
    );

    desktopTest('the question says how many hosts, and No runs nothing', (tester) async {
      await pump(tester, workflows: [workflow(risky)]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('danger-on-hosts'))).data, en.wfDangerOnHosts(3));
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      expect(signedIn, isEmpty);
      await finish(tester);
    });

    desktopTest('Run anyway runs', (tester) async {
      await pump(tester, workflows: [workflow(risky)]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await tapKey(tester, 'zest-dialog-primary');
      expect(engine.runs, hasLength(1));
      expect(signedIn.toSet(), {'web1', 'web2', 'db'});
      await finish(tester);
    });

    desktopTest('with the check off nothing is asked; "don\'t ask again" turns it off', (tester) async {
      await pump(tester, workflows: [workflow(risky)]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await tapKey(tester, 'danger-dont-ask-again');
      await tapKey(tester, 'zest-dialog-primary');
      expect(engine.runs, hasLength(1));
      expect(container.read(dangerousCommandProtectionProvider), isFalse);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.dangerCommandTitle), findsNothing);
      expect(engine.runs, hasLength(2));
      await finish(tester);
    });

    desktopTest('a command for another system counts, though its own is harmless', (tester) async {
      await pump(tester, workflows: [
        workflow(const WorkflowStep(
          id: 's1',
          type: WorkflowStepType.execute,
          command: 'uptime',
          commandsByOs: {'bsd': 'shutdown -r now'},
          connectionId: 'edge',
        )),
      ]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('danger-on-hosts'))).data, en.wfDangerOnHosts(1));
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('several: one question, each command shown, the hosts of them all counted once', (tester) async {
      await pump(tester, workflows: [
        Workflow(id: 'w1', name: 'Check disks', createdAt: DateTime(2026), steps: const [
          WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'sudo reboot', targetIds: ['web1', 'web2']),
          WorkflowStep(id: 's2', type: WorkflowStepType.execute, command: 'uptime', targetIds: ['hva', 'hvb']),
          WorkflowStep(id: 's3', type: WorkflowStepType.execute, command: 'shutdown -h now', targetIds: ['web2', 'db']),
        ]),
      ]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.wfDangerCommandsTitle), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('danger-on-hosts'))).data, en.wfDangerOnHosts(3));
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('a step that is switched off, or a step with no host, asks nothing', (tester) async {
      await pump(tester, workflows: [
        Workflow(id: 'w1', name: 'Check disks', createdAt: DateTime(2026), steps: const [
          WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'sudo reboot', connectionId: 'web1', disabled: true),
          WorkflowStep(
            id: 's2',
            type: WorkflowStepType.execute,
            command: 'sudo reboot',
            onFailure: StepFailureAction.continueNext,
          ),
          WorkflowStep(id: 's3', type: WorkflowStepType.execute, command: 'uptime', connectionId: 'web1'),
        ]),
      ]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.dangerCommandTitle), findsNothing);
      expect(engine.runs, hasLength(1));
      await finish(tester);
    });
  });

  group("a snippet step's variables", () {
    WorkflowStep snippetStep(Map<String, String> variables) => WorkflowStep(
          id: 's1',
          type: WorkflowStepType.snippet,
          snippetName: 'Restart',
          connectionId: 'web1',
          variables: variables,
        );

    desktopTest('one with no value is asked for; backing out runs nothing', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {'NAME': ''}))], snippets: [('Restart', r'docker restart ${NAME}')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetVarEnterValueFor('NAME')), findsOneWidget);
      await tester.tap(find.text(en.cancel).last);
      await settle(tester);
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('the value given is for this run alone', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {'NAME': ''}))], snippets: [('Restart', r'docker restart ${NAME}')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await tester.enterText(find.byType(TextFormField), 'shop');
      await settle(tester);
      await tester.tap(find.text(en.zestSnippetsRunButton).last);
      await settle(tester);
      expect(engine.runs.single.steps.single.variables, {'NAME': 'shop'});
      expect(signedIn, ['web1']);
      expect(container.read(workflowsProvider).single.steps.single.variables, {'NAME': ''}, reason: 'not kept');
      await finish(tester);
    });

    desktopTest('those it has are not asked for; one with a default is not asked for', (tester) async {
      await pump(
        tester,
        workflows: [workflow(snippetStep(const {'FROM': '/a', 'TO': ''}))],
        snippets: [('Restart', r'rsync ${FROM} ${TO} ${OPTS:--a}')],
      );
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetVarEnterValueFor('TO')), findsOneWidget);
      expect(find.text(en.snippetVarEnterValueFor('FROM')), findsNothing);
      await tester.enterText(find.byType(TextFormField), '/b');
      await settle(tester);
      await tester.tap(find.text(en.zestSnippetsRunButton).last);
      await settle(tester);
      expect(engine.runs.single.steps.single.variables, {'FROM': '/a', 'TO': '/b'});
      await finish(tester);
    });

    desktopTest('with all it needs, nothing is asked', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {'NAME': 'shop'}))], snippets: [('Restart', r'docker restart ${NAME} ${X:-y}')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.byType(TextFormField), findsNothing);
      expect(engine.runs, hasLength(1));
      await finish(tester);
    });

    desktopTest('a value goes in quotes, and the check reads past them: rm -rf with DIR /', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {'DIR': ''}))], snippets: [('Restart', r'rm -rf ${DIR}/*')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await tester.enterText(find.byType(TextFormField), '/');
      await settle(tester);
      await tester.tap(find.text(en.zestSnippetsRunButton).last);
      await settle(tester);
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(find.text(en.dangerCriticalDelete), findsOneWidget);
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('a default is read as it will run: nothing to ask for, and the question is asked', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {'DIR': ''}))], snippets: [('Restart', r'rm -rf ${DIR:-/}/*')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    const onThree = WorkflowStep(
      id: 's1',
      type: WorkflowStepType.snippet,
      snippetName: 'Restart',
      targetIds: ['web1', 'web2', 'db'],
      onFailure: StepFailureAction.continueNext,
    );

    desktopTest("a plain name that is the shell's is not asked for, and stays each host's own", (tester) async {
      await pump(tester, workflows: [workflow(onThree)], snippets: [('Restart', r'tar czf ${HOME}/backup.tgz /etc')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.byType(TextFormField), findsNothing);
      expect(engine.runs.single.steps.single.variables, isEmpty);
      expect(signedIn.toSet(), {'web1', 'web2', 'db'});
      await finish(tester);
    });

    desktopTest('one the command is dangerous without is asked for, and it says the value goes to all its hosts', (tester) async {
      await pump(tester, workflows: [workflow(onThree)], snippets: [('Restart', r'rm -rf ${DIR}/*')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetVarEnterValueFor('DIR')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('snippet-variable-note'))).data, en.wfVariableGoesToAllHosts(3));
      await tester.tap(find.text(en.cancel).last);
      await settle(tester);
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('on one host it has nothing of the kind to say', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {}))], snippets: [('Restart', r'rm -rf ${DIR}/*')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetVarEnterValueFor('DIR')), findsOneWidget);
      expect(find.byKey(const ValueKey('snippet-variable-note')), findsNothing);
      await tester.tap(find.text(en.cancel).last);
      await settle(tester);
      await finish(tester);
    });

    desktopTest('a blank default the command is dangerous with is asked for too', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {}))], snippets: [('Restart', r'rm -rf ${DIR:-}/*')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await tester.enterText(find.byType(TextFormField), '/tmp/a');
      await settle(tester);
      await tester.tap(find.text(en.zestSnippetsRunButton).last);
      await settle(tester);
      expect(engine.runs.single.steps.single.variables, {'DIR': '/tmp/a'});
      await finish(tester);
    });

    desktopTest('a list of the host\'s own is read on the first of them, and it says so', (tester) async {
      await pump(tester, workflows: [workflow(onThree)], snippets: [('Restart', r'docker restart $[DOCKER]')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await settleReal(tester);
      expect(tester.widget<Text>(find.byKey(const ValueKey('snippet-variable-note'))).data,
          '${en.wfVariableGoesToAllHosts(3)} ${en.wfVariableListFromFirstHost}');
      expect(signedIn, ['web1'], reason: 'read there alone');
      await tester.tap(find.text(en.cancel).last);
      await settle(tester);
      await finish(tester);
    });

    desktopTest('a secret with no value is asked for: only the app can fill one', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {}))], snippets: [('Restart', r'curl -u me:${PW:secret} https://example.com/')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetVarEnterValueFor('PW')), findsOneWidget);
      await tester.tap(find.text(en.cancel).last);
      await settle(tester);
      await finish(tester);
    });

    desktopTest('a default stands at every occurrence: what is checked is what runs', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {}))], snippets: [('Restart', r'rm -rf ${DIR:-/}; echo ${DIR}')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(onScreen(tester, "rm -rf '/'; echo '/'"), isTrue);
      await tapKey(tester, 'zest-dialog-secondary');
      await finish(tester);
    });

    for (final recording in const [false, true]) {
      final when = recording ? ', while a screen is recorded' : '';
      desktopTest('a value typed with dots stays out of its own preview and the next question, and the real one is what runs$when', (tester) async {
        await pump(tester, recording: recording, workflows: [workflow(snippetStep(const {}))], snippets: [('Restart', r'sudo reboot ${PW:secret}')]);
        await open(tester);
        await tapKey(tester, 'workflow-run');
        await tester.enterText(find.byType(TextFormField), 'hunter22');
        await settle(tester);
        expect(onScreen(tester, 'hunter22'), isFalse, reason: 'its preview');
        expect(onScreen(tester, kMaskedValueShown), isTrue);
        await tester.tap(find.text(en.zestSnippetsRunButton).last);
        await settle(tester);
        expect(find.text(en.dangerCommandTitle), findsOneWidget);
        expect(onScreen(tester, 'hunter22'), isFalse, reason: 'the question');
        expect(onScreen(tester, kMaskedValueShown), isTrue);
        await tapKey(tester, 'zest-dialog-primary');
        expect(engine.runs.single.steps.single.variables, {'PW': 'hunter22'});
        await finish(tester);
      });
    }

    desktopTest('its command is checked with what was given', (tester) async {
      await pump(tester, workflows: [workflow(snippetStep(const {'WHAT': ''}))], snippets: [('Restart', r'sudo ${WHAT}; reboot')]);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await tester.enterText(find.byType(TextFormField), 'sync');
      await settle(tester);
      await tester.tap(find.text(en.zestSnippetsRunButton).last);
      await settle(tester);
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(engine.runs, isEmpty);
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });
  });

  group("a snippet's Confirm before running", () {
    const careful = WorkflowStep(id: 's1', type: WorkflowStepType.snippet, snippetName: 'Careful', connectionId: 'web1');

    desktopTest('is asked in a run a person starts, with the command as it will run; No runs nothing', (tester) async {
      await pump(tester, workflows: [workflow(careful)], snippets: [('Careful', r'systemctl restart ${APP:-web}')], confirming: {'Careful'});
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetRunConfirmTitle), findsOneWidget);
      expect(find.text(en.snippetRunConfirmBody), findsOneWidget);
      expect(onScreen(tester, "systemctl restart 'web'"), isTrue);
      expect(engine.runs, isEmpty);
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('Run runs', (tester) async {
      await pump(tester, workflows: [workflow(careful)], snippets: [('Careful', 'systemctl restart web')], confirming: {'Careful'});
      await open(tester);
      await tapKey(tester, 'workflow-run');
      await tapKey(tester, 'zest-dialog-primary');
      expect(engine.runs, hasLength(1));
      await finish(tester);
    });

    desktopTest('a risky one is asked about once, by the question about risky commands', (tester) async {
      await pump(tester, workflows: [workflow(careful)], snippets: [('Careful', 'sudo reboot')], confirming: {'Careful'});
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      await tapKey(tester, 'zest-dialog-primary');
      expect(find.text(en.snippetRunConfirmTitle), findsNothing);
      expect(engine.runs, hasLength(1));
      await finish(tester);
    });

    desktopTest('with that check off a risky one has its own question', (tester) async {
      await pump(tester, workflows: [workflow(careful)], snippets: [('Careful', 'sudo reboot')], confirming: {'Careful'});
      await container.read(settingsUpdaterProvider).setDangerousCommandProtection(false);
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetRunConfirmTitle), findsOneWidget);
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('its masked values stay out of the question', (tester) async {
      await pump(tester, workflows: [workflow(careful.copyWith(variables: const {'PW': 'hunter22'}))], snippets: [('Careful', r'login ${PW:secret}')], confirming: {'Careful'});
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetRunConfirmTitle), findsOneWidget);
      expect(onScreen(tester, 'hunter22'), isFalse);
      expect(onScreen(tester, kMaskedValueShown), isTrue);
      await tapKey(tester, 'zest-dialog-secondary');
      await finish(tester);
    });

    desktopTest('what would draw it wrongly shows by its number, its masked values still dots', (tester) async {
      await pump(tester, workflows: [workflow(careful.copyWith(variables: const {'PW': 'hunter22'}))], snippets: [('Careful', 'login\u202e \${PW:secret}')], confirming: {'Careful'});
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetRunConfirmTitle), findsOneWidget);
      expect(onScreen(tester, r'login\u202e'), isTrue);
      expect(onScreen(tester, 'hunter22'), isFalse);
      expect(onScreen(tester, kMaskedValueShown), isTrue);
      await tapKey(tester, 'zest-dialog-secondary');
      await finish(tester);
    });

    desktopTest('what only a masked value makes risky is asked about in red, by what is shown', (tester) async {
      await pump(tester, workflows: [workflow(careful.copyWith(variables: const {'DIR': '/etc/hunter22'}))], snippets: [('Careful', r'rm -rf ${DIR:secret}')], confirming: {'Careful'});
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.dangerCommandTitle), findsOneWidget);
      expect(find.text(en.dangerCriticalDelete), findsOneWidget);
      expect(find.text(en.dangerExplainCriticalDelete("rm -rf '$kMaskedValueShown'").replaceAll('`', ''), findRichText: true), findsOneWidget);
      expect(onScreen(tester, 'hunter22'), isFalse);
      expect(onScreen(tester, '/etc'), isFalse);
      expect(onScreen(tester, kMaskedValueShown), isTrue);
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.runs, isEmpty);
      await finish(tester);
    });

    desktopTest('a step that is switched off, or on no host, asks nothing; one that does not say so asks nothing', (tester) async {
      await pump(
        tester,
        workflows: [
          Workflow(id: 'w1', name: 'Check disks', createdAt: DateTime(2026), steps: [
            careful.copyWith(disabled: true),
            const WorkflowStep(id: 's2', type: WorkflowStepType.snippet, snippetName: 'Careful', onFailure: StepFailureAction.continueNext),
            const WorkflowStep(id: 's3', type: WorkflowStepType.snippet, snippetName: 'Plain', connectionId: 'web1'),
          ]),
        ],
        snippets: [('Careful', 'systemctl restart web'), ('Plain', 'uptime')],
        confirming: {'Careful'},
      );
      await open(tester);
      await tapKey(tester, 'workflow-run');
      expect(find.text(en.snippetRunConfirmTitle), findsNothing);
      expect(engine.runs, hasLength(1));
      await finish(tester);
    });
  });

  group('leaving a run', () {
    List<Workflow> two() => [
          workflow(everywhere),
          workflow(const WorkflowStep(id: 'other', type: WorkflowStepType.notify, command: 'x'), id: 'w2', name: 'Other one'),
        ];

    Future<void> runEnds(WidgetTester tester) async {
      engine.hold!.complete();
      await settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    }

    desktopTest('another workflow opened mid-run asks first; No leaves it going, with its panel and its Cancel', (tester) async {
      await pump(tester, workflows: two());
      await open(tester);
      engine.hold = Completer<void>();
      await tapKey(tester, 'workflow-run');
      await open(tester, 'Other one');
      expect(find.text(en.wfStopRunTitle), findsOneWidget);
      expect(find.text(en.wfStopRunBody), findsOneWidget);
      expect(engine.token!.isCancelled, isFalse, reason: 'nothing yet');
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.token!.isCancelled, isFalse);
      expect(find.byKey(const ValueKey('workflow-run-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('workflow-run-cancel')), findsOneWidget);
      await runEnds(tester);
      expect(signedIn, isNotEmpty, reason: 'it went on');
      await finish(tester);
    });

    desktopTest('Stop the run stops it; it reads Stopped, not Failed; the last-run time goes to the one that ran', (tester) async {
      await pump(tester, workflows: two());
      await open(tester);
      engine.hold = Completer<void>();
      await tapKey(tester, 'workflow-run');
      await open(tester, 'Other one');
      await tapKey(tester, 'zest-dialog-primary');
      expect(engine.token!.isCancelled, isTrue);
      expect(find.byKey(const ValueKey('workflow-run-panel')), findsNothing);
      await runEnds(tester);
      expect(signedIn, isEmpty, reason: 'it had not started, and now does not');
      final saved = {for (final w in container.read(workflowsProvider)) w.id: w};
      expect(saved['w1']!.lastRunAt, isNotNull);
      expect(saved['w2']!.lastRunAt, isNull);
      expect(container.read(workflowLastRunProvider)['w1']!.cancelled, isTrue);
      expect(find.text(en.zestAutoOutcomeStopped), findsOneWidget);
      expect(find.text(en.zestAutoOutcomeFailed), findsNothing);
      expect(find.text(en.zestAutoOutcomeFailedAtStep(1)), findsNothing);
      await finish(tester);
    });

    desktopTest("a person's own Cancel reads Stopped too", (tester) async {
      await pump(tester, workflows: two());
      await open(tester);
      engine.hold = Completer<void>();
      await tapKey(tester, 'workflow-run');
      await tapKey(tester, 'workflow-run-cancel');
      await runEnds(tester);
      expect(find.text(en.zestAutoOutcomeStopped), findsOneWidget);
      expect(find.text(en.zestAutoOutcomeFailed), findsNothing);
      await finish(tester);
    });

    desktopTest('New, Close and Delete ask too; No leaves the run and the workflow as they are', (tester) async {
      await pump(tester, workflows: two());
      await open(tester);
      engine.hold = Completer<void>();
      await tapKey(tester, 'workflow-run');
      final ways = <String, Future<void> Function()>{
        'New': () async => container.read(automationNewWorkflowProvider.notifier).state++,
        'Close': () => tester.tap(find.byTooltip(en.zestCommonCancel).first),
        'Delete': () => tester.tap(find.byKey(const ValueKey('workflow-delete'))),
      };
      for (final MapEntry(key: name, value: way) in ways.entries) {
        await way();
        await settle(tester);
        expect(find.text(en.wfStopRunTitle), findsOneWidget, reason: name);
        await tapKey(tester, 'zest-dialog-secondary');
        expect(engine.token!.isCancelled, isFalse, reason: name);
        expect(find.byKey(const ValueKey('workflow-run-cancel')), findsOneWidget, reason: name);
        expect(container.read(workflowsProvider), hasLength(2), reason: name);
      }
      await runEnds(tester);
      await finish(tester);
    });

    desktopTest('a template opened mid-run asks too', (tester) async {
      await pump(tester);
      Finder use(String template) =>
          find.descendant(of: find.byKey(ValueKey('automation-template-$template')), matching: find.text(en.autoTplUse));
      await tester.tap(use('checkDiskSpace'));
      await settleReal(tester);
      engine.hold = Completer<void>();
      await tapKey(tester, 'workflow-run');
      expect(find.byKey(const ValueKey('workflow-run-cancel')), findsOneWidget);
      await tester.tap(use('updatePackages'));
      await settleReal(tester);
      expect(find.text(en.wfStopRunTitle), findsOneWidget);
      await tapKey(tester, 'zest-dialog-secondary');
      expect(engine.token!.isCancelled, isFalse);
      await runEnds(tester);
      await finish(tester);
    });

    desktopTest('with no run going nothing is asked', (tester) async {
      await pump(tester, workflows: two());
      await open(tester);
      await open(tester, 'Other one');
      expect(find.text(en.wfStopRunTitle), findsNothing);
      await finish(tester);
    });
  });

  group('a draft saved during its own run', () {
    desktopTest('keeps its panel and its Cancel, and the run is recorded under the workflow it became', (tester) async {
      await pump(tester);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('automation-template-checkDiskSpace')), matching: find.text(en.autoTplUse)));
      await settleReal(tester);
      engine.hold = Completer<void>();
      await tapKey(tester, 'workflow-run');
      expect(find.byKey(const ValueKey('workflow-run-cancel')), findsOneWidget);
      // (The panel stands over the foot, and closes: the run goes on behind it.)
      await tapKey(tester, 'workflow-run-close');
      await tester.tap(find.text(en.autoSaveWorkflow));
      await settleReal(tester);
      final saved = container.read(workflowsProvider).single;
      await tapKey(tester, 'workflow-run-show');
      expect(find.byKey(const ValueKey('workflow-run-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('workflow-run-cancel')), findsOneWidget);
      engine.hold!.complete();
      await settleReal(tester);
      expect(container.read(workflowLastRunProvider).keys, [saved.id]);
      expect(container.read(workflowLastRunProvider).containsKey(kWorkflowDraftRunId), isFalse);
      expect(container.read(workflowsProvider).single.lastRunAt, isNotNull);
      await finish(tester);
    });

    desktopTest('and it can be stopped from there', (tester) async {
      await pump(tester);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('automation-template-checkDiskSpace')), matching: find.text(en.autoTplUse)));
      await settleReal(tester);
      engine.hold = Completer<void>();
      await tapKey(tester, 'workflow-run');
      await tapKey(tester, 'workflow-run-close');
      await tester.tap(find.text(en.autoSaveWorkflow));
      await settleReal(tester);
      await tapKey(tester, 'workflow-run-show');
      await tapKey(tester, 'workflow-run-cancel');
      expect(engine.token!.isCancelled, isTrue);
      engine.hold!.complete();
      await settleReal(tester);
      expect(find.text(en.zestAutoOutcomeStopped), findsOneWidget);
      await finish(tester);
    });
  });

  group('in one column', () {
    desktopTest('after Back the same workflow opens again', (tester) async {
      await pump(tester, workflows: [workflow(everywhere)], size: const Size(800, 1000));
      await open(tester);
      expect(find.byKey(const ValueKey('workflow-run')), findsOneWidget);
      await tester.tap(find.byTooltip(en.zestCommonCancel).last);
      await settle(tester);
      expect(find.byKey(const ValueKey('workflow-run')), findsNothing, reason: 'back at the list');
      await open(tester);
      expect(find.byKey(const ValueKey('workflow-run')), findsOneWidget);
      await finish(tester);
    });
  });
}
