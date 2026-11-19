import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/features/automation/widgets/run_output_drawer.dart';
import 'package:zestssh/features/automation/widgets/workflow_detail_pane.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/desktop_mouse.dart';
import '../../helpers/monitor_table_fixture.dart';

/// A workflow's run output.
/// The panel opens at once at a fixed height, results scroll inside it,
/// its head stays put, its edge drags and the height is remembered; its rows are
/// named by host, the failures first, and each opens; Close closes it, Clear
/// empties it, and Run and Run on… are in the workflow's head.
class _Service implements WorkflowService {
  _Service(this.results);

  final List<WorkflowStepResult> results;
  final finish = Completer<void>();
  void Function()? _next;

  /// Delivers the next result.
  void deliver() => _next?.call();

  @override
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    onStepHosts?.call(0, results.length);
    var at = 0;
    _next = () {
      final r = results[at++];
      onStepComplete?.call(0, workflow.steps.length, r);
      if (at == results.length && !finish.isCompleted) finish.complete();
    };
    await finish.future;
    return WorkflowResult(
      workflowId: workflow.id,
      workflowName: workflow.name,
      success: results.every((r) => r.success),
      stepResults: results,
      totalElapsed: Duration.zero,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _step = WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'df -P', targetAll: true);

WorkflowStepResult _ok(String host) => WorkflowStepResult(
      stepId: 's1',
      stepType: WorkflowStepType.execute,
      success: true,
      output: 'printed by $host',
      exitCode: 0,
      connectionId: host,
      stepIndex: 0,
    );

WorkflowStepResult _failed(String host) => WorkflowStepResult(
      stepId: 's1',
      stepType: WorkflowStepType.execute,
      success: false,
      error: 'df: invalid option -- x',
      exitCode: 64,
      connectionId: host,
      stepIndex: 0,
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final panel = find.byKey(const ValueKey('workflow-run-panel'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  late WorkflowEditController editor;
  late WorkflowRunController run;
  late SharedPreferences prefs;
  late AppDatabase db;
  var runs = 0;
  var runsOn = 0;

  Future<void> pump(WidgetTester tester, {bool recording = false}) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    db = (await tester.runAsync(fleet.database))!;
    prefs = await fleet.preferences();
    if (recording) await prefs.setBool('recording_mode_enabled', true);
    editor = WorkflowEditController();
    run = WorkflowRunController();
    addTearDown(editor.dispose);
    addTearDown(run.dispose);
    editor.bind(Workflow(id: 'w1', name: 'Check disks', steps: const [_step], createdAt: DateTime(2026)));
    runs = 0;
    runsOn = 0;
    await tester.pumpWidget(fleet.app(
      fleet.overrides(db, prefs),
      WorkflowDetailPane(
        controller: editor,
        runController: run,
        hasSelection: true,
        onSave: () async => true,
        onClose: () {},
        onDelete: () {},
        onRun: () => runs++,
        onRunOn: () => runsOn++,
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  /// A run begun, its results to come.
  Future<_Service> begin(WidgetTester tester, List<WorkflowStepResult> results) async {
    final service = _Service(results);
    unawaited(run.run(service, Workflow(id: 'w1', name: 'Check disks', steps: const [_step], createdAt: DateTime(2026))));
    await settle(tester);
    return service;
  }

  Future<void> deliverAll(WidgetTester tester, _Service service) async {
    for (var i = 0; i < service.results.length; i++) {
      service.deliver();
      await settle(tester);
    }
  }

  desktopTest('Run and Run on… are in its head; the old Test run in its foot is gone', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('workflow-run')));
    await tester.tap(find.byKey(const ValueKey('workflow-run-on')));
    expect((runs, runsOn), (1, 1));
    expect(find.byKey(const ValueKey('workflow-test-run')), findsNothing);
    expect(find.text('Test run'), findsNothing);
    await finish(tester);
  });

  desktopTest('with no step that runs on a host, there is nothing for Run on… to choose', (tester) async {
    await pump(tester);
    editor.bind(Workflow(
      id: 'w2',
      name: 'Wait',
      steps: const [WorkflowStep(id: 'd', type: WorkflowStepType.delay, timeoutSeconds: 1)],
      createdAt: DateTime(2026),
    ));
    await settle(tester);
    expect(find.byKey(const ValueKey('workflow-run-on')), findsNothing);
    expect(find.byKey(const ValueKey('workflow-run')), findsOneWidget);
    await finish(tester);
  });

  desktopTest('it opens at once at half the view, and stays that high as results arrive', (tester) async {
    await pump(tester);
    final service = await begin(tester, [for (final h in ['web1', 'web2', 'db', 'hva', 'hvb', 'logs', 'mon', 'edge', 'mac']) _ok(h)]);
    expect(tester.getSize(panel).height, 500);
    await deliverAll(tester, service);
    expect(tester.getSize(panel).height, 500, reason: 'results load inside it');
    await finish(tester);
  });

  desktopTest('Cancel stays where it is while results come', (tester) async {
    await pump(tester);
    final service = await begin(tester, [for (final h in ['web1', 'web2', 'db', 'hva']) _ok(h)]);
    final cancel = find.byKey(const ValueKey('workflow-run-cancel'));
    final at = tester.getTopLeft(cancel);
    service.deliver();
    await settle(tester);
    service.deliver();
    await settle(tester);
    expect(tester.getTopLeft(cancel), at);
    service.deliver();
    service.deliver();
    await settle(tester);
    await finish(tester);
  });

  desktopTest('its rows are named by host, the failures first, each opening to what it printed', (tester) async {
    await pump(tester);
    final service = await begin(tester, [_ok('web1'), _failed('edge'), _ok('db')]);
    await deliverAll(tester, service);

    final line = find.byKey(const ValueKey('workflow-run-line-s1-edge'));
    expect(tester.widget<Text>(line).data, en.wfRunRowLine('edge-router', en.wfRunStateFailedExit(64)));
    expect(find.text(en.wfRunRowLine('web-01', en.wfRunStateOk)), findsOneWidget);
    // The host's own icon on each.
    expect(find.descendant(of: find.byKey(const ValueKey('workflow-run-results')), matching: find.byType(HostGlyph)), findsNWidgets(3));
    // No row says only what kind of step it was.
    expect(find.text(en.zestAutoStepTypeCommand), findsNothing);

    final failedAt = tester.getTopLeft(line).dy;
    final okAt = tester.getTopLeft(find.byKey(const ValueKey('workflow-run-line-s1-web1'))).dy;
    expect(failedAt, lessThan(okAt), reason: 'failures first');

    // Closed until asked for, where there are several.
    expect(find.text('df: invalid option -- x'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workflow-run-open-s1-edge')));
    await settle(tester);
    expect(find.text('df: invalid option -- x'), findsOneWidget);
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workflow-run-open-s1-web1')));
    await settle(tester);
    expect(find.text('printed by web1'), findsOneWidget);

    // Copied, under the hosts' names.
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.byKey(const ValueKey('workflow-run-copy')));
    await settle(tester);
    expect(copied.single, contains('edge-router: ${en.wfRunStateFailedExit(64)}'));
    expect(copied.single, contains('df: invalid option -- x'));
    await finish(tester);
  });

  desktopTest('one host that failed says why without being opened', (tester) async {
    await pump(tester);
    final service = await begin(tester, [_failed('edge')]);
    await deliverAll(tester, service);
    expect(find.text('df: invalid option -- x'), findsOneWidget);
    await finish(tester);
  });

  desktopTest('Close closes it (it could not be closed), keeps the results to show again, and Clear forgets them',
      (tester) async {
    await pump(tester);
    final service = await begin(tester, [_ok('web1')]);
    await deliverAll(tester, service);
    await tester.tap(find.byKey(const ValueKey('workflow-run-close')));
    await settle(tester);
    expect(panel, findsNothing);

    await tester.tap(find.byKey(const ValueKey('workflow-run-show')));
    await settle(tester);
    expect(panel, findsOneWidget);
    expect(find.text(en.wfRunRowLine('web-01', en.wfRunStateOk)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('workflow-run-clear')));
    await settle(tester);
    expect(panel, findsNothing);
    expect(find.byKey(const ValueKey('workflow-run-show')), findsNothing);
    await finish(tester);
  });

  desktopTest('closed while it runs, the way back to it is there', (tester) async {
    await pump(tester);
    final service = await begin(tester, [_ok('web1'), _ok('web2')]);
    expect(find.byKey(const ValueKey('workflow-run-show')), findsNothing, reason: 'it is open');
    await tester.tap(find.byKey(const ValueKey('workflow-run-close')));
    await settle(tester);
    expect(panel, findsNothing);
    expect(run.isRunning, isTrue);
    expect(run.results, isEmpty, reason: 'nothing to show yet, and still it can be opened');
    await tester.tap(find.byKey(const ValueKey('workflow-run-show')));
    await settle(tester);
    expect(panel, findsOneWidget);
    await deliverAll(tester, service);
    await finish(tester);
  });

  desktopTest('a host that ran twice has one row, with what it came to the last time', (tester) async {
    await pump(tester);
    final service = await begin(tester, [_failed('web1'), _ok('web2'), _ok('web1')]);
    await deliverAll(tester, service);
    final line = find.byKey(const ValueKey('workflow-run-line-s1-web1'));
    expect(line, findsOneWidget);
    expect(tester.widget<Text>(line).data, en.wfRunRowLine('web-01', en.wfRunStateOk));
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  group('while a screen is recorded', () {
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

    WorkflowStepResult named() => const WorkflowStepResult(
          stepId: 's1',
          stepType: WorkflowStepType.execute,
          success: false,
          error: 'ssh: connect to web-01 at 192.168.10.21 refused',
          output: 'tried web-01',
          exitCode: 1,
          connectionId: 'web1',
          stepIndex: 0,
        );

    List<String> texts(WidgetTester tester) => [
          for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
          for (final t in tester.widgetList<SelectableText>(find.byType(SelectableText))) t.data ?? t.textSpan?.toPlainText() ?? '',
        ];

    desktopTest('what a host said is masked in its row', (tester) async {
      await pump(tester, recording: true);
      // (A failed row that comes first is open by itself.)
      final service = await begin(tester, [named(), _ok('web2')]);
      await deliverAll(tester, service);
      expect(find.byKey(const ValueKey('workflow-run-details-s1-web1')), findsOneWidget);
      final all = texts(tester).join('\n');
      expect(all, isNot(contains('web-01')));
      expect(all, isNot(contains('192.168.10.21')));
      expect(all, contains('refused'));
      await finish(tester);
    });

    desktopTest('Copy all results and Copy details are masked too', (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester, recording: true);
      final service = await begin(tester, [named(), _ok('web2')]);
      await deliverAll(tester, service);
      await tester.tap(find.byKey(const ValueKey('workflow-run-copy')));
      await settle(tester);
      expect(copied, isNotNull);
      expect(copied, isNot(contains('web-01')));
      expect(copied, isNot(contains('192.168.10.21')));
      expect(copied, contains('refused'));

      copied = null;
      await tester.tap(find.byType(CopyDetailsButton));
      await settle(tester);
      expect(copied, isNotNull);
      expect(copied, isNot(contains('web-01')));
      expect(copied, isNot(contains('192.168.10.21')));
      await finish(tester);
    });
  });

  desktopTest('its top edge drags, and the height is remembered', (tester) async {
    await pump(tester);
    final service = await begin(tester, [_ok('web1')]);
    await deliverAll(tester, service);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('workflow-run-panel-edge'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -10));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await settle(tester);
    expect(tester.getSize(panel).height, closeTo(600, 12));
    expect(prefs.getDouble(kRunPanelFractionKey), closeTo(0.6, 0.02));

    // Closed and opened again: the height it was left at.
    await tester.tap(find.byKey(const ValueKey('workflow-run-close')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('workflow-run-show')));
    await settle(tester);
    expect(tester.getSize(panel).height, closeTo(600, 12));
    await finish(tester);
  });

  test('Reset all settings puts the height back', () {
    expect(SettingsService.resetKeys, contains(kRunPanelFractionKey));
  });
}
