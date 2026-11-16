import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/features/automation/widgets/run_output_drawer.dart';
import 'package:zestssh/features/broadcast/host_checklist.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart';
import 'package:zestssh/ui/widgets/broadcast_dangerous_dialog.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/utils/redactor.dart';

import '../helpers/desktop_mouse.dart';
import '../helpers/monitor_table_fixture.dart';

/// A run to show, with nothing signed in to.
class _RunShown extends RunOnHostsNotifier {
  _RunShown() : super((_) async => throw StateError('nothing is signed in to here'));
  void show(HostsRun run) => state = run;
}

Connection _conn(String id) => Connection(
      id: id,
      label: id,
      host: '$id.example.com',
      port: 22,
      colorIndex: 0,
      protocol: 'ssh',
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: DateTime(2026, 10, 15),
      updatedAt: DateTime(2026, 10, 15),
    );

/// What was left of the host lists: paddings that stood on the wrong side in
/// Arabic, Enter that took the focus out of a picker with nothing to open, and the
/// question before a broadcast, which drew a server for every host.
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

  Future<void> pump(WidgetTester tester, Widget Function(BuildContext context) child,
      {Locale locale = const Locale('ar'), Size size = const Size(2400, 1200), List<Override> overrides = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    await tester.runAsync(() => (db.update(db.connections)..where((t) => t.id.equals('build')))
        .write(const ConnectionsCompanion(protocol: Value('sftp'))));
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app([...fleet.overrides(db, prefs), ...overrides], Builder(builder: child), locale: locale));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  /// The nearest [Padding] around [what], its sides as they are in right to left.
  EdgeInsets paddingOf(WidgetTester tester, Finder what) => tester
      .widget<Padding>(find.ancestor(of: what, matching: find.byType(Padding)).first)
      .padding
      .resolve(TextDirection.rtl);

  group('right to left', () {
    desktopTest("the Run output panel's head and a result's details", (tester) async {
      final run = WorkflowRunController();
      addTearDown(run.dispose);
      await pump(tester, (_) => SizedBox(height: 900, child: RunOutputDrawer(controller: run)));
      unawaited(run.run(_OneFailed(), Workflow(id: 'w', name: 'W', createdAt: DateTime(2026), steps: const [
        WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'x', connectionId: 'web1'),
      ])));
      await settle(tester);
      // The head: 16 on its start, the right, and 8 on its end.
      final head = paddingOf(tester, find.text(lookupAppLocalizations(const Locale('ar')).zestAutoRunOutput));
      expect((head.right, head.left), (16, 8));
      // A result that failed alone is open: its details start on the right.
      final details = tester.widget<Padding>(find.byKey(const ValueKey('workflow-run-details-s1-web1'))).padding.resolve(TextDirection.rtl);
      expect((details.right, details.left), (27, 4));
      await finish(tester);
    });

    desktopTest("a result's details in Run on hosts start on the right", (tester) async {
      final run = _RunShown()
        ..show(HostsRun(command: 'uptime', hosts: [
          HostRun(host: _conn('web1'), state: HostRunState.done, exitCode: 0, output: 'up 3 days'),
        ]));
      await pump(tester, (_) => const SizedBox(width: 900, height: 900, child: RunOnHostsDialog()), overrides: [
        runOnHostsProvider.overrideWith((ref) => run),
      ]);
      await tester.tap(find.byKey(const ValueKey('run-open-web1')));
      await settle(tester);
      final details = tester.widget<Padding>(find.byKey(const ValueKey('run-details-web1'))).padding.resolve(TextDirection.rtl);
      expect((details.right, details.left), (55, 4));
      await finish(tester);
    });

    desktopTest("the hosts' list of a checklist leaves room for its scrollbar on the left", (tester) async {
      await pump(tester, (_) => SizedBox(width: 800, height: 800, child: HostChecklist(picked: const {}, onChanged: (_) {}, keyPrefix: 'run')));
      final list = find.byKey(const ValueKey('run-hosts-list'));
      final padding = tester.widget<Padding>(find.descendant(of: list, matching: find.byType(Padding)).first).padding.resolve(TextDirection.rtl);
      expect((padding.left, padding.right), (10, 0));
      await finish(tester);
    });

    desktopTest("the picker's, the same", (tester) async {
      await pump(tester, (_) => const ConnectionPickerDialog(title: 'x'));
      final list = tester.widget<Padding>(find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Padding)).first);
      final padding = list.padding.resolve(TextDirection.rtl);
      expect((padding.left, padding.right), (10, 0));
      await finish(tester);
    });

    desktopTest("the thresholds' hosts, the same", (tester) async {
      await pump(tester, (context) => TextButton(onPressed: () => showMonitorThresholds(context), child: const Text('open')));
      await tester.tap(find.text('open'));
      await settle(tester);
      final pane = find.ancestor(of: find.byKey(const ValueKey('thresholds-host-web1')), matching: find.byType(SingleChildScrollView)).first;
      final padding = tester.widget<Padding>(find.descendant(of: pane, matching: find.byType(Padding)).first).padding.resolve(TextDirection.rtl);
      expect((padding.left, padding.right), (10, 0));
      await finish(tester);
    });

    // (English words, laid out right to left: Arabic in the test's font, every
    // glyph one em wide, overflows what it fits in the app.)
    // (Select ends the hosts' head since 4.0: Active first is in the Sort.)
    desktopTest('the Hosts page: Select stands in from the left edge', (tester) async {
      await pump(
        tester,
        (_) => Directionality(textDirection: TextDirection.rtl, child: HostsHomePage(onConnectTo: (_) {})),
        locale: const Locale('en'),
      );
      final padding = paddingOf(tester, find.byKey(const ValueKey('hosts-select')));
      expect((padding.left, padding.right), (24, 0));
      await finish(tester);
    });

    desktopTest("the Server monitor's cells start on the right", (tester) async {
      await pump(
        tester,
        (_) => const Directionality(textDirection: TextDirection.rtl, child: MonitorTableView()),
        locale: const Locale('en'),
      );
      final cell = tester.widget<Padding>(find.ancestor(of: find.text('1ms').first, matching: find.byType(Padding)).first).padding.resolve(TextDirection.rtl);
      expect((cell.right, cell.left), (6, 12));
      await finish(tester);
    });
  });

  group('Enter in the picker', () {
    desktopTest('with no match the focus stays in the search, to go on typing', (tester) async {
      ConnectionPickerResult? picked;
      await pump(
        tester,
        (context) => TextButton(
          onPressed: () async => picked = await ConnectionPickerDialog.show(context, needsTerminal: true),
          child: const Text('open'),
        ),
        locale: const Locale('en'),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      final field = find.byType(TextField);
      await tester.enterText(field, 'zzz-nothing');
      await settle(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(field, findsOneWidget, reason: 'it stays open');
      expect(picked, isNull);
      expect(tester.state<EditableTextState>(find.byType(EditableText)).widget.focusNode.hasFocus, isTrue);

      // Nor does it open what cannot be picked.
      await tester.enterText(field, 'build-runner');
      await settle(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(field, findsOneWidget);
      expect(picked, isNull);
      expect(tester.state<EditableTextState>(find.byType(EditableText)).widget.focusNode.hasFocus, isTrue);

      // With one, it opens it.
      await tester.enterText(field, 'web-01');
      await settle(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(picked?.connection?.connection.id, 'web1');
      await finish(tester);
    });
  });

  group('the question before a broadcast', () {
    Future<void> ask(WidgetTester tester) async {
      await pump(
        tester,
        (context) => TextButton(
          onPressed: () => showBroadcastDangerousDialog(
            context,
            command: 'reboot',
            matches: const [],
            targetHostNames: const ['web-01', 'a session of no saved host'],
            targetHostIds: const ['web1', null],
          ),
          child: const Text('open'),
        ),
        locale: const Locale('en'),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    desktopTest("a saved host has its own icon, and one that is none a server's", (tester) async {
      await ask(tester);
      expect(find.byType(HostGlyph), findsOneWidget);
      expect(find.text('web-01'), findsOneWidget);
      await finish(tester);
    });

    desktopTest('its names are masked while a screen is recorded', (tester) async {
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout
        ..registerNames(['web-01']);
      addTearDown(() {
        Redactor.instance
          ..clearNames()
          ..enabled = false;
      });
      await ask(tester);
      expect(find.text('web-01'), findsNothing);
      expect(find.text(Redactor.instance.apply('web-01', RedactKind.host)), findsOneWidget);
      await finish(tester);
    });
  });
}

/// One step on one host that fails at once.
class _OneFailed implements WorkflowService {
  @override
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    const result = WorkflowStepResult(
      stepId: 's1',
      stepType: WorkflowStepType.execute,
      success: false,
      error: 'boom',
      exitCode: 1,
      connectionId: 'web1',
      stepIndex: 0,
    );
    onStepComplete?.call(0, 1, result);
    return WorkflowResult(
      workflowId: workflow.id,
      workflowName: workflow.name,
      success: false,
      stepResults: const [result],
      totalElapsed: Duration.zero,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
