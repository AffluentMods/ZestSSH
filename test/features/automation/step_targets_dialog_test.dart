import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/widgets/step_card.dart';
import 'package:zestssh/features/automation/widgets/step_targets_dialog.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';

import '../../helpers/desktop_mouse.dart';
import '../../helpers/monitor_table_fixture.dart';

/// What a workflow's step runs on, and Run on… (a workflow like
/// "Check disk space everywhere" was 21 copies of a step, and its hosts could
/// only be chosen by editing them): hosts, a group or all hosts, what is picked
/// reaching the step, and a command of its own for another system.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<AppDatabase> pump(WidgetTester tester, Widget Function(BuildContext context) child) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(fleet.database))!;
    await tester.runAsync(() async {
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-web', name: 'Web', createdAt: DateTime(2026)));
      for (final id in ['web1', 'web2']) {
        await (db.update(db.connections)..where((t) => t.id.equals(id)))
            .write(const ConnectionsCompanion(groupId: Value('g-web')));
      }
    });
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(fleet.overrides(db, prefs), Builder(builder: child)));
    await settle(tester);
    return db;
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  Future<void> tap(WidgetTester tester, Finder what) async {
    await tester.tap(what);
    await settle(tester);
  }

  final dialog = find.byKey(const ValueKey('step-targets-kind'));
  final done = find.text(en.done);

  /// The dialog opened from [current], and what it comes back with.
  Future<({AppDatabase db, StepTargets? Function() result})> open(WidgetTester tester, StepTargets current) async {
    StepTargets? result;
    final db = await pump(
      tester,
      (context) => TextButton(
        onPressed: () async => result = await showStepTargets(context, current: current),
        child: const Text('open'),
      ),
    );
    await tap(tester, find.text('open'));
    return (db: db, result: () => result);
  }

  desktopTest('hosts: Done waits for one, and those ticked come back', (tester) async {
    final t = await open(tester, const StepTargets());
    await tap(tester, done);
    expect(dialog, findsOneWidget, reason: 'nothing ticked, nothing to run on');

    await tap(tester, find.byKey(const ValueKey('step-targets-host-web1')));
    await tap(tester, find.byKey(const ValueKey('step-targets-host-db')));
    await tap(tester, done);
    expect(dialog, findsNothing);
    final result = t.result()!;
    expect(result.hosts.toSet(), {'web1', 'db'});
    expect(result.groupId, isNull);
    expect(result.all, isFalse);
    await finish(tester, t.db);
  });

  desktopTest('a group: Done waits for one, each says how many hosts it has, and the one chosen comes back', (tester) async {
    final t = await open(tester, const StepTargets());
    await tap(tester, find.text(en.wfTargetKindGroup));
    expect(find.text(en.wfTargetGroupHelp), findsOneWidget);
    expect(find.text(en.wfTargetHosts(2)), findsOneWidget);
    await tap(tester, done);
    expect(dialog, findsOneWidget);

    await tap(tester, find.byKey(const ValueKey('step-targets-group-g-web')));
    await tap(tester, done);
    final result = t.result()!;
    expect(result.groupId, 'g-web');
    expect(result.hosts, isEmpty);
    expect(result.all, isFalse);
    await finish(tester, t.db);
  });

  desktopTest("a group's count is what will really run: Mosh and Eternal Terminal in, SFTP only and Telnet out", (tester) async {
    final t = await open(tester, const StepTargets());
    Future<void> set(String id, String protocol) => tester.runAsync(() => (t.db.update(t.db.connections)..where((c) => c.id.equals(id))).write(
          ConnectionsCompanion(protocol: Value(protocol), groupId: const Value('g-web')),
        ));
    await set('db', 'mosh');
    await set('hva', 'et');
    await set('hvb', 'sftp');
    await set('build', 'telnet');
    await settle(tester);
    await tap(tester, find.text(en.wfTargetKindGroup));
    // web1 and web2, ssh; db, mosh; hva, et.
    expect(find.text(en.wfTargetHosts(4)), findsOneWidget);
    await finish(tester, t.db);
  });

  desktopTest('a host that cannot run a command cannot be ticked, and one saved on the step is not handed back', (tester) async {
    final t = await open(tester, const StepTargets(hosts: ['web1', 'build']));
    await tester.runAsync(() => (t.db.update(t.db.connections)..where((c) => c.id.equals('build'))).write(
          const ConnectionsCompanion(protocol: Value('telnet')),
        ));
    await settle(tester);
    expect(find.byKey(const ValueKey('step-targets-host-build-no-terminal')), findsOneWidget);
    expect(find.text(en.hostNoCommandsNotSsh), findsOneWidget);
    await tap(tester, done);
    expect(t.result()!.hosts, ['web1']);
    await finish(tester, t.db);
  });

  test('what Group and All say is true of Mosh and Eternal Terminal: no language says SSH hosts alone', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      for (final said in [t.wfTargetAllHelp, t.wfTargetGroupHelp]) {
        expect(said, contains('Mosh'), reason: '$locale');
        expect(said, contains('Eternal Terminal'), reason: '$locale');
      }
    }
  });

  desktopTest('all hosts: says what that means, and comes back', (tester) async {
    final t = await open(tester, const StepTargets());
    await tap(tester, find.text(en.wfTargetAll));
    expect(find.byKey(const ValueKey('step-targets-all-help')), findsOneWidget);
    await tap(tester, done);
    expect(t.result()!.all, isTrue);
    await finish(tester, t.db);
  });

  desktopTest('it opens on what the step has; Cancel gives nothing', (tester) async {
    final t = await open(tester, const StepTargets(all: true));
    expect(find.byKey(const ValueKey('step-targets-all-help')), findsOneWidget);
    await tap(tester, find.text(en.cancel));
    expect(dialog, findsNothing);
    expect(t.result(), isNull);
    await finish(tester, t.db);
  });

  desktopTest('Run on…: Active first is on by itself, Run waits for a host, those ticked come back', (tester) async {
    List<String>? result;
    late ProviderContainer container;
    final db = await pump(tester, (context) {
      container = ProviderScope.containerOf(context);
      return TextButton(
        onPressed: () async => result = await showWorkflowRunOn(context, workflowName: 'Check disk'),
        child: const Text('open'),
      );
    });
    await tap(tester, find.text('open'));
    expect(find.text(en.wfRunOnTitle('Check disk')), findsOneWidget);
    expect(container.read(activeFirstProvider(HostListPlace.workflowRun)), isTrue);

    await tap(tester, find.text(en.runOnHostsRun(0)));
    expect(find.text(en.wfRunOnHelp), findsOneWidget, reason: 'nothing ticked, it stays');

    await tap(tester, find.byKey(const ValueKey('workflow-run-host-web2')));
    await tap(tester, find.text(en.runOnHostsRun(1)));
    expect(find.text(en.wfRunOnHelp), findsNothing);
    expect(result, ['web2']);
    await finish(tester, db);
  });

  Widget card(WorkflowEditController c) => Scaffold(
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
      );

  WorkflowEditController editing(List<WorkflowStep> steps) {
    final c = WorkflowEditController()
      ..bind(Workflow(id: 'w1', name: 'W', createdAt: DateTime(2026), steps: steps));
    addTearDown(c.dispose);
    c.toggleExpanded(steps.first.id);
    return c;
  }

  desktopTest('on the card: what is picked is what the step says and what a run gets', (tester) async {
    final c = editing(const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'uptime')]);
    final db = await pump(tester, (_) => card(c));
    final field = find.byKey(const ValueKey('step-targets-s1'));
    expect(find.descendant(of: field, matching: find.text(en.zestAutoStepSelectHost)), findsOneWidget);

    await tap(tester, field);
    await tap(tester, find.text(en.wfTargetAll));
    await tap(tester, done);
    expect(find.descendant(of: field, matching: find.text(en.wfTargetAll)), findsOneWidget);
    expect(c.buildRunnable('w1').steps.single.targetAll, isTrue);

    await tap(tester, field);
    expect(find.byKey(const ValueKey('step-targets-all-help')), findsOneWidget, reason: 'it opens on what it has');
    await tap(tester, find.text(en.wfTargetKindHosts));
    await tap(tester, find.byKey(const ValueKey('step-targets-host-web1')));
    await tap(tester, find.byKey(const ValueKey('step-targets-host-hva')));
    await tap(tester, done);
    expect(find.descendant(of: field, matching: find.text(en.wfTargetHosts(2))), findsOneWidget);
    final step = c.buildRunnable('w1').steps.single;
    expect(step.targetAll, isFalse);
    expect(step.targetIds.toSet(), {'web1', 'hva'});
    await finish(tester, db);
  });

  desktopTest("on the card: another system's command, in Advanced, reaches a run; removing it takes it away", (tester) async {
    final c = editing(const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'df -x tmpfs')]);
    final db = await pump(tester, (_) => card(c));
    await tap(tester, find.text(en.zestAutoStepAdvanced));
    await tap(tester, find.byKey(const ValueKey('step-alt-add-s1')));
    await tap(tester, find.text(en.wfOsBsd).last);
    final alt = find.byKey(const ValueKey('step-alt-s1-bsd'));
    expect(alt, findsOneWidget);
    await tester.enterText(alt, 'df -k');
    await settle(tester);
    expect(c.buildRunnable('w1').steps.single.commandsByOs, {'bsd': 'df -k'});

    await tap(tester, find.descendant(of: find.ancestor(of: alt, matching: find.byType(Row)).first, matching: find.byType(IconButton)));
    expect(alt, findsNothing);
    expect(c.buildRunnable('w1').steps.single.commandsByOs, isEmpty);
    await finish(tester, db);
  });
}
