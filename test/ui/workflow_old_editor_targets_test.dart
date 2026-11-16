import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/ui/screens/automation/automation_wizard_screen.dart';
import 'package:zestssh/ui/screens/automation/workflow_editor_screen.dart';

import '../helpers/desktop_mouse.dart';
import '../helpers/monitor_table_fixture.dart';

/// The older editor of a workflow (a phone's, and a computer's from the palette's
/// Open workflows), with a step made with many targets: a step saved there on
/// "web1" kept its All hosts, and went on running on every host; what it ran on
/// was an empty select. And the wizard's and the editor's hosts: one that cannot
/// run a command cannot be chosen.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget Function() child, {List<Workflow> workflows = const []}) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    await tester.runAsync(() async {
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-web', name: 'Web', createdAt: DateTime(2026)));
      await (db.update(db.connections)..where((t) => t.id.equals('build'))).write(const ConnectionsCompanion(protocol: Value('sftp')));
      await (db.update(db.connections)..where((t) => t.id.equals('cache'))).write(const ConnectionsCompanion(protocol: Value('telnet')));
    });
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(
      fleet.overrides(db, prefs),
      Builder(builder: (context) {
        container = ProviderScope.containerOf(context);
        return child();
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
    await db.close();
  }

  Workflow saved(WorkflowStep step) => Workflow(id: 'w1', name: 'Check disks', steps: [step], createdAt: DateTime(2026));

  /// The editor of [step], its dialog open.
  Future<void> openStep(WidgetTester tester, WorkflowStep step) async {
    final wf = saved(step);
    await pump(tester, () => WorkflowEditorScreen(workflow: wf, embedded: true, onClose: (_) {}), workflows: [wf]);
    await tester.tap(find.byTooltip(en.edit));
    await settle(tester);
  }

  /// The dialog's Save, then the editor's.
  Future<WorkflowStep> saveAll(WidgetTester tester) async {
    await tester.tap(find.text(en.save).last);
    await settle(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text(en.save).first);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settle(tester);
    return container.read(workflowsProvider).single.steps.single;
  }

  const everywhere = WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'reboot', targetAll: true);

  desktopTest('a step on all hosts says so, in place of an empty select, and saved as it is it stays so', (tester) async {
    await openStep(tester, everywhere);
    expect(find.text(en.wfTargetAll), findsOneWidget);
    expect(find.text(en.wfEditSelectConnection), findsNothing);
    final step = await saveAll(tester);
    expect(step.targetAll, isTrue);
    await finish(tester);
  });

  desktopTest('a step on a group, or on hosts, says which', (tester) async {
    await openStep(tester, everywhere.onHosts(['web1', 'web2', 'db']));
    expect(find.text(en.wfTargetHosts(3)), findsOneWidget);
    await finish(tester);
  });

  desktopTest("a step on a group says the group's name", (tester) async {
    await openStep(tester, const WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'x', targetGroupId: 'g-web'));
    expect(find.text(en.wfTargetGroupNamed('Web')), findsOneWidget);
    await finish(tester);
  });

  desktopTest('a host picked takes the place of what it ran on: it runs there, and nowhere else', (tester) async {
    await openStep(tester, everywhere);
    await tester.tap(find.text(en.wfTargetAll));
    await settle(tester);
    await tester.tap(find.text('web-01 (192.168.10.21)').last);
    await settle(tester);
    expect(find.text(en.wfTargetAll), findsNothing);
    final step = await saveAll(tester);
    expect(step.connectionId, 'web1');
    expect(step.targetAll, isFalse);
    expect(step.manyTargets, isFalse);
    expect(step.command, 'reboot', reason: 'the rest of it as it was');
    await finish(tester);
  });

  desktopTest('a step on one host, given another, is on that one', (tester) async {
    await openStep(tester, const WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'x', connectionId: 'db'));
    await tester.tap(find.text('db-primary (192.168.10.31)'));
    await settle(tester);
    await tester.tap(find.text('web-01 (192.168.10.21)').last);
    await settle(tester);
    final step = await saveAll(tester);
    expect(step.connectionId, 'web1');
    expect(step.manyTargets, isFalse);
    await finish(tester);
  });

  desktopTest('a host that cannot run a command is dimmed, says why, and cannot be chosen', (tester) async {
    await openStep(tester, const WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'x', connectionId: 'db'));
    await tester.tap(find.text('db-primary (192.168.10.31)'));
    await settle(tester);
    expect(find.text(en.hostSftpOnlyNoTerminal), findsOneWidget);
    expect(find.text(en.hostNoCommandsNotSsh), findsOneWidget);
    await tester.tap(find.text('build-runner (192.168.10.50)').last);
    await settle(tester);
    expect(find.text('db-primary (192.168.10.31)'), findsWidgets, reason: 'still the one chosen');
    await finish(tester);
  });

  desktopTest("the wizard's hosts: one that cannot run a command says why, and a tap chooses nothing", (tester) async {
    await pump(tester, () => const AutomationWizardScreen());
    await tester.tap(find.text(en.autoWizExecuteTitle));
    await settle(tester);
    await tester.tap(find.text(en.next));
    await settle(tester);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('wizard-host-build')), 100, scrollable: find.byType(Scrollable).last);
    await settle(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('wizard-host-build')), matching: find.text(en.hostSftpOnlyNoTerminal)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wizard-host-build')));
    await settle(tester);
    // Nothing chosen: Next is not offered yet.
    final next = tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text(en.next), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first,
    );
    expect(next.onPressed, isNull);
    await finish(tester);
  });
}
