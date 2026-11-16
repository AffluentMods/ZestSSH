import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/state/workflow_edit_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_controller.dart';
import 'package:zestssh/features/automation/state/workflow_run_status.dart';
import 'package:zestssh/features/automation/workflow_templates.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/workflow_service.dart';
import 'package:zestssh/utils/redactor.dart';

/// One step with many targets, with a result per host (before,
/// "Check disk space everywhere" was 21 copies of one step), and a
/// command for another system (an OPNsense failed with "df: invalid option -- x").
Connection _host(String id) => Connection(
      id: id,
      label: 'name-$id',
      host: '192.0.2.1',
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
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

class _Automation implements AutomationService {
  _Automation(this.hosts, {this.failOn = const {}, this.unames = const {}, this.unameFails, this.hostsThrow = false});

  final List<String> hosts;
  final Set<String> failOn;
  final Map<String, String> unames;

  /// What `uname -s` ends with, on a host not in [unames]: none (not reached)
  /// where null.
  final int? unameFails;
  final bool hostsThrow;
  final ran = <(String, String)>[];

  /// The hosts asked `uname -s`, each time.
  final unameAsked = <String>[];
  var atOnce = 0;
  var mostAtOnce = 0;

  @override
  Future<List<Connection>> hostsOfStep(WorkflowStep step) async {
    if (hostsThrow) throw StateError('AutomationService has been disposed');
    return [for (final id in hosts) _host(id)];
  }

  @override
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async {
    if (command == 'uname -s') {
      unameAsked.add(connectionId);
      final said = unames[connectionId];
      return AutomationResult(
          success: said != null,
          output: '${said ?? ''}\n',
          error: said != null ? '' : "'uname' is not recognized",
          exitCode: said != null ? 0 : unameFails,
          elapsed: Duration.zero);
    }
    ran.add((connectionId, command));
    atOnce++;
    if (atOnce > mostAtOnce) mostAtOnce = atOnce;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    atOnce--;
    final fails = failOn.contains(connectionId);
    return AutomationResult(
      success: !fails,
      output: fails ? '' : 'ok $connectionId\n',
      error: fails ? 'df: invalid option -- x' : '',
      exitCode: fails ? 64 : 0,
      elapsed: Duration.zero,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Workflow _workflow(List<WorkflowStep> steps) => Workflow(id: 'w', name: 'W', steps: steps, createdAt: DateTime(2026));

WorkflowStep _many({StepFailureAction onFailure = StepFailureAction.continueNext, Map<String, String> byOs = const {}}) =>
    WorkflowStep(
      id: 's1',
      type: WorkflowStepType.execute,
      command: 'df',
      targetAll: true,
      onFailure: onFailure,
      commandsByOs: byOs,
    );

void main() {
  setUpAll(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));

  test('a step with many targets runs on each of them, with a result per host, a few at a time', () async {
    final automation = _Automation([for (var i = 0; i < 9; i++) 'h$i'], failOn: {'h3'});
    final hostsOf = <int>[];
    final results = <WorkflowStepResult>[];
    final result = await WorkflowService(automation, notice: (_, _, _) {}).executeWorkflow(
      _workflow([_many()]),
      onStepHosts: (_, n) => hostsOf.add(n),
      onStepComplete: (_, _, r) => results.add(r),
    );
    expect(hostsOf, [9]);
    expect(results.map((r) => r.connectionId).toSet(), {for (var i = 0; i < 9; i++) 'h$i'});
    expect(results.every((r) => r.stepIndex == 0), isTrue);
    expect(automation.mostAtOnce, greaterThan(1));
    expect(automation.mostAtOnce, lessThanOrEqualTo(kWorkflowHostsAtOnce));
    expect(result.success, isFalse);
    expect(result.failureCount, 1);
    final failed = result.stepResults.singleWhere((r) => !r.success);
    expect((failed.connectionId, failed.exitCode, failed.error), ('h3', 64, 'df: invalid option -- x'));
  });

  test('set to stop at a failure, it goes one host at a time, and the rest are skipped; the steps after it too',
      () async {
    final automation = _Automation(['a', 'b', 'c'], failOn: {'b'});
    final result = await WorkflowService(automation, notice: (_, _, _) {}).executeWorkflow(_workflow([
      _many(onFailure: StepFailureAction.abort),
      const WorkflowStep(id: 's2', type: WorkflowStepType.execute, command: 'x', connectionId: 'a'),
    ]));
    expect(automation.mostAtOnce, 1);
    expect(automation.ran.map((r) => r.$1), ['a', 'b']);
    expect([for (final r in result.stepResults) (r.stepId, r.connectionId, r.success, r.skipped)], [
      ('s1', 'a', true, false),
      ('s1', 'b', false, false),
      ('s1', 'c', false, true),
      ('s2', null, false, true),
    ]);
    expect(WorkflowRunSummary.fromResult(result).failedStepNumber, 1, reason: 'the step, not the result, counted');
  });

  test('a host of no target at all fails the step with why', () async {
    final none = await WorkflowService(_Automation(const []), notice: (_, _, _) {}).executeWorkflow(_workflow([_many()]));
    expect(none.stepResults.single.error, isNotEmpty);
    expect(none.success, isFalse);
  });

  test('a cancel on the last step skips what has not started, and the run is cancelled: no success, no notice of one',
      () async {
    final token = CancellationToken();
    final automation = _Automation(['a', 'b', 'c']);
    final notices = <WorkflowNoticeKind>[];
    final cancelled = await WorkflowService(automation, notice: (kind, _, _) => notices.add(kind)).executeWorkflow(
      Workflow(
        id: 'w',
        name: 'W',
        steps: [_many(onFailure: StepFailureAction.abort)],
        createdAt: DateTime(2026),
        notifyOnSuccess: true,
      ),
      cancellationToken: token,
      onStepComplete: (_, _, _) => token.cancel(),
    );
    expect(automation.ran.map((r) => r.$1), ['a']);
    expect(cancelled.stepResults.where((r) => r.skipped).map((r) => r.connectionId), ['b', 'c']);
    expect(cancelled.cancelled, isTrue);
    expect(cancelled.success, isFalse);
    expect(notices, isEmpty);
    expect(WorkflowRunSummary.fromResult(cancelled).success, isFalse);
  });

  test('a cancel after every host started is no cancel: nothing was skipped for it, and it ended as it ended', () async {
    final token = CancellationToken();
    var seen = 0;
    final result = await WorkflowService(_Automation(['a', 'b']), notice: (_, _, _) {}).executeWorkflow(
      _workflow([_many(onFailure: StepFailureAction.abort)]),
      cancellationToken: token,
      onStepComplete: (_, _, _) {
        if (++seen == 2) token.cancel();
      },
    );
    expect(result.cancelled, isFalse);
    expect(result.success, isTrue);
  });

  test('the hosts that cannot be read fail the step with why, and the run ends', () async {
    final controller = WorkflowRunController();
    addTearDown(controller.dispose);
    final result = await controller.run(
      WorkflowService(_Automation(const [], hostsThrow: true), notice: (_, _, _) {}),
      _workflow([_many()]),
    );
    expect(result.success, isFalse);
    expect(result.stepResults.single.error, contains('disposed'));
    expect(controller.isRunning, isFalse);
    expect(controller.phase, WorkflowRunPhase.finished);
    expect(controller.results.single.success, isFalse);
  });

  test("each host gets its system's command: as seen on it, or asked; none for it, the step's own", () async {
    final automation = _Automation(['linux', 'seen-bsd', 'asked-bsd', 'mac', 'silent'],
        unames: {'linux': 'Linux', 'asked-bsd': 'FreeBSD', 'mac': 'Darwin'});
    await WorkflowService(
      automation,
      notice: (_, _, _) {},
      osFamilyOf: (id) => id == 'seen-bsd' ? WorkflowOsFamily.bsd : null,
    ).executeWorkflow(_workflow([
      _many(onFailure: StepFailureAction.abort, byOs: {'bsd': 'df-bsd', 'macos': 'df-mac'}),
    ]));
    expect(automation.ran, [
      ('linux', 'df'),
      ('seen-bsd', 'df-bsd'),
      ('asked-bsd', 'df-bsd'),
      ('mac', 'df-mac'),
      ('silent', 'df'),
    ]);
  });

  test('a Notify step after many hosts says each one under its name', () async {
    final said = <String>[];
    await WorkflowService(_Automation(['a', 'b']), notice: (_, _, body) => said.add(body)).executeWorkflow(_workflow([
      _many(),
      const WorkflowStep(id: 'n', type: WorkflowStepType.notify, command: 'Found: $kWorkflowOutputToken'),
    ]));
    expect(said.single, contains('name-a: ok a'));
    expect(said.single, contains('name-b: ok b'));
  });

  test("a Notify step's hosts are masked while a screen is recorded", () async {
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerNames(['name-a', 'name-b']);
    addTearDown(() {
      Redactor.instance
        ..clearNames()
        ..enabled = false;
    });
    final said = <String>[];
    await WorkflowService(_Automation(['a', 'b']), notice: (_, _, body) => said.add(body)).executeWorkflow(_workflow([
      _many(),
      const WorkflowStep(id: 'n', type: WorkflowStepType.notify, command: 'Found: $kWorkflowOutputToken'),
    ]));
    expect(said.single, isNot(contains('name-a')));
    expect(said.single, isNot(contains('name-b')));
    expect(said.single, contains(Redactor.instance.apply('name-a', RedactKind.host)));
  });

  group('Go to step', () {
    test('one host that goes on failing stops at the limit, with an error that says so, and the rest is skipped',
        () async {
      final automation = _Automation(const [], failOn: {'a'});
      final notices = <String>[];
      final result = await WorkflowService(automation, notice: (_, _, body) => notices.add(body)).executeWorkflow(_workflow([
        const WorkflowStep(
          id: 's1',
          type: WorkflowStepType.execute,
          command: 'x',
          connectionId: 'a',
          onFailure: StepFailureAction.gotoStep,
          gotoStepId: 's1',
        ),
        const WorkflowStep(id: 's2', type: WorkflowStepType.execute, command: 'y', connectionId: 'a'),
      ]));
      expect(automation.ran, hasLength(kWorkflowStepVisits));
      expect(automation.ran.toSet(), {('a', 'x')});
      expect(result.success, isFalse);
      expect(result.cancelled, isFalse);
      final en = lookupAppLocalizations(const Locale('en'));
      expect(result.stepResults.where((r) => r.error == en.workflowSvcStepLoops(kWorkflowStepVisits)), hasLength(1));
      expect(result.stepResults.last.stepId, 's2');
      expect(result.stepResults.last.skipped, isTrue);
      expect(notices, hasLength(1), reason: 'its failure is told');
    });

    test('two steps that go back and forth stop too', () async {
      final automation = _Automation(const [], failOn: {'a'});
      final result = await WorkflowService(automation, notice: (_, _, _) {}).executeWorkflow(_workflow([
        const WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'x', connectionId: 'b'),
        const WorkflowStep(
          id: 's2',
          type: WorkflowStepType.execute,
          command: 'y',
          connectionId: 'a',
          onFailure: StepFailureAction.gotoStep,
          gotoStepId: 's1',
        ),
      ]));
      expect(result.success, isFalse);
      expect(automation.ran.where((r) => r.$1 == 'b'), hasLength(kWorkflowStepVisits));
    });

    test('a step with many targets that goes to itself runs again only on the hosts that failed', () async {
      final automation = _Automation(['good', 'bad'], failOn: {'bad'});
      final hostsOf = <int>[];
      final result = await WorkflowService(automation, notice: (_, _, _) {}).executeWorkflow(
        _workflow([
          const WorkflowStep(
            id: 's1',
            type: WorkflowStepType.execute,
            command: 'restart',
            targetAll: true,
            onFailure: StepFailureAction.gotoStep,
            gotoStepId: 's1',
          ),
        ]),
        onStepHosts: (_, n) => hostsOf.add(n),
      );
      expect(automation.ran.where((r) => r.$1 == 'good'), hasLength(1));
      expect(automation.ran.where((r) => r.$1 == 'bad'), hasLength(kWorkflowStepVisits));
      expect(hostsOf.first, 2);
      expect(hostsOf.skip(1).toSet(), {1});
      expect(result.success, isFalse);
    });

    test('what went well the second time stands: the run went well, and a step counts once', () async {
      final automation = _Flaky(['a', 'b'], failFirst: {'b'});
      final result = await WorkflowService(automation, notice: (_, _, _) {}).executeWorkflow(
        _workflow([
          const WorkflowStep(
            id: 's1',
            type: WorkflowStepType.execute,
            command: 'restart',
            targetAll: true,
            onFailure: StepFailureAction.gotoStep,
            gotoStepId: 's1',
          ),
        ]),
      );
      expect(automation.ran.map((r) => r.$1), ['a', 'b', 'b']);
      expect(result.success, isTrue);
      expect(result.failureCount, 0);
      expect(result.stepsSucceeded, 1);
    });

    test('the summary of a run names the step that stands as failed', () {
      WorkflowStepResult of(String step, int at, {required bool ok}) =>
          WorkflowStepResult(stepId: step, stepType: WorkflowStepType.execute, success: ok, connectionId: 'a', stepIndex: at);
      final result = WorkflowResult(
        workflowId: 'w',
        workflowName: 'W',
        success: false,
        totalElapsed: Duration.zero,
        stepResults: [of('s1', 0, ok: false), of('s1', 0, ok: true), of('s2', 1, ok: false)],
      );
      expect(WorkflowRunSummary.fromResult(result).failedStepNumber, 2);
    });

    test("the run's controller counts the second round as a round of its own", () async {
      final controller = WorkflowRunController();
      addTearDown(controller.dispose);
      final automation = _Flaky(['a', 'b', 'c'], failFirst: {'b'});
      await controller.run(
        WorkflowService(automation, notice: (_, _, _) {}),
        _workflow([
          const WorkflowStep(
            id: 's1',
            type: WorkflowStepType.execute,
            command: 'restart',
            targetAll: true,
            onFailure: StepFailureAction.gotoStep,
            gotoStepId: 's1',
          ),
        ]),
      );
      expect(controller.hostsOfStep(0), 1);
      expect(controller.resultsOfStep(0), 1);
      expect(controller.results, hasLength(4), reason: 'Copy all results has them all');
      expect(controller.stepsDone, 1);
    });
  });

  group('hosts counted as hosts', () {
    test('one step on five hosts that all failed: one step, five hosts', () async {
      final said = <String>[];
      final result = await WorkflowService(
        _Automation(['a', 'b', 'c', 'd', 'e'], failOn: {'a', 'b', 'c', 'd', 'e'}),
        notice: (_, _, body) => said.add(body),
      ).executeWorkflow(_workflow([_many()]));
      final en = lookupAppLocalizations(const Locale('en'));
      expect(said.single, en.workflowSvcFailedBodyHosts('W', 1, 0, 5));
      expect(said.single, contains('Steps failed: 1'));
      expect(said.single, contains('Hosts failed: 5'));
      expect(result.stepsFailed, 1);
      expect(result.hostsFailed, 5);
      expect(result.stepsOkLine, '0/1 steps OK, 0/5 hosts OK');
    });

    test('steps on one host each say nothing of hosts', () async {
      final said = <String>[];
      final result = await WorkflowService(_Automation(const [], failOn: {'a'}), notice: (_, _, body) => said.add(body))
          .executeWorkflow(_workflow([
        const WorkflowStep(id: 's1', type: WorkflowStepType.execute, command: 'x', connectionId: 'b'),
        const WorkflowStep(id: 's2', type: WorkflowStepType.execute, command: 'y', connectionId: 'a'),
        const WorkflowStep(id: 's3', type: WorkflowStepType.execute, command: 'z', connectionId: 'a'),
      ]));
      final en = lookupAppLocalizations(const Locale('en'));
      expect(said.single, en.workflowSvcFailedBody('W', 1, 1));
      expect(result.stepsOkLine, '1/3 steps OK');
    });

    test('a link is answered with steps as steps and hosts as hosts', () async {
      final result = await WorkflowService(_Automation(['a', 'b', 'c'], failOn: {'c'}), notice: (_, _, _) {})
          .executeWorkflow(_workflow([_many()]));
      expect(result.stepsOkLine, '0/1 steps OK, 2/3 hosts OK');
      expect(result.toString(), contains('0/1 steps OK, 2/3 hosts OK'));
    });
  });

  group('a host of a system not seen, and a command for Windows', () {
    const step = WorkflowStep(
      id: 's1',
      type: WorkflowStepType.execute,
      command: 'linux-only',
      commandsByOs: {'windows': 'windows-cmd'},
      targetAll: true,
    );

    Future<List<String>> commandsWith({int? unameFails}) async {
      final automation = _Automation(['h'], unameFails: unameFails);
      await WorkflowService(automation, notice: (_, _, _) {}, osFamilyOf: (_) => null).executeWorkflow(_workflow([step]));
      return [for (final r in automation.ran) r.$2];
    }

    test('one that was reached and has no uname is Windows: cmd and PowerShell end it so', () async {
      expect(await commandsWith(unameFails: 1), ['windows-cmd']);
    });

    test('a POSIX shell with no uname says 127, and one that could not be reached says nothing: the own command',
        () async {
      expect(await commandsWith(unameFails: 127), ['linux-only']);
      expect(await commandsWith(unameFails: 126), ['linux-only']);
      expect(await commandsWith(), ['linux-only']);
    });
  });

  group('asked of its system', () {
    WorkflowStep byOs(String id) => WorkflowStep(
          id: id,
          type: WorkflowStepType.execute,
          command: 'df',
          commandsByOs: const {'bsd': 'df -P'},
          targetAll: true,
          onFailure: StepFailureAction.continueNext,
        );

    test('once in a run for each host, however many steps have commands per system', () async {
      final automation = _Automation(['a', 'b'], unames: {'a': 'FreeBSD', 'b': 'Linux'});
      await WorkflowService(automation, notice: (_, _, _) {}, osFamilyOf: (_) => null)
          .executeWorkflow(_workflow([byOs('s1'), byOs('s2'), byOs('s3')]));
      expect(automation.unameAsked..sort(), ['a', 'b']);
      expect([for (final r in automation.ran) if (r.$1 == 'a') r.$2], ['df -P', 'df -P', 'df -P'], reason: 'its answer stands');
      expect([for (final r in automation.ran) if (r.$1 == 'b') r.$2], ['df', 'df', 'df']);
    });

    test('a host out of reach is waited for once', () async {
      final automation = _Automation(['a']);
      await WorkflowService(automation, notice: (_, _, _) {}, osFamilyOf: (_) => null)
          .executeWorkflow(_workflow([byOs('s1'), byOs('s2')]));
      expect(automation.unameAsked, ['a']);
    });

    test('a step on the one host it names, the same', () async {
      final automation = _Automation(['a'], unames: {'a': 'Linux'});
      WorkflowStep one(String id) => byOs(id).copyWith(targetAll: false, connectionId: 'a');
      await WorkflowService(automation, notice: (_, _, _) {}, osFamilyOf: (_) => null)
          .executeWorkflow(_workflow([one('s1'), one('s2')]));
      expect(automation.unameAsked, ['a']);
    });

    test('another run asks again: a host may be something else by then', () async {
      final automation = _Automation(['a'], unames: {'a': 'Linux'});
      final service = WorkflowService(automation, notice: (_, _, _) {}, osFamilyOf: (_) => null);
      await service.executeWorkflow(_workflow([byOs('s1')]));
      await service.executeWorkflow(_workflow([byOs('s1')]));
      expect(automation.unameAsked, ['a', 'a']);
    });
  });

  group('what stands', () {
    WorkflowStepResult result({bool success = false, bool skipped = false}) => WorkflowStepResult(
          stepId: 's1',
          stepType: WorkflowStepType.execute,
          success: success,
          skipped: skipped,
          connectionId: 'a',
        );

    test('a skip does not replace a result of that step on that host', () {
      expect(settledStepResults([result(), result(skipped: true)]).single.skipped, isFalse);
      expect(settledStepResults([result(success: true), result(skipped: true)]).single.success, isTrue);
    });

    test('a result replaces a skip, and the last result stands', () {
      expect(settledStepResults([result(skipped: true), result(success: true)]).single.success, isTrue);
      expect(settledStepResults([result(), result(success: true)]).single.success, isTrue);
    });

    test('a cancel during a retry leaves the failure it was retrying', () async {
      final hosts = [for (var i = 0; i <= kWorkflowHostsAtOnce; i++) 'h$i'];
      final token = CancellationToken();
      var results = 0;
      final done = await WorkflowService(_Automation(hosts, failOn: hosts.toSet()), notice: (_, _, _) {}).executeWorkflow(
        _workflow([_many(onFailure: StepFailureAction.gotoStep).copyWith(gotoStepId: 's1')]),
        cancellationToken: token,
        // Through the first round, and one of the second: the last host has not
        // started the second time.
        onStepComplete: (_, _, _) {
          if (++results == hosts.length + 1) token.cancel();
        },
      );
      expect(done.stepResults.any((r) => r.skippedForCancel), isTrue);
      expect(done.failureCount, hosts.length, reason: 'each failed, and none was only skipped');
      expect(done.skippedCount, 0);
      expect(done.hostsFailed, hosts.length);
    });
  });

  test('what `uname -s` says is a system', () {
    expect(WorkflowOsFamily.ofUname('Linux\n'), WorkflowOsFamily.linux);
    expect(WorkflowOsFamily.ofUname('FreeBSD'), WorkflowOsFamily.bsd);
    expect(WorkflowOsFamily.ofUname('OpenBSD'), WorkflowOsFamily.bsd);
    expect(WorkflowOsFamily.ofUname('NetBSD'), WorkflowOsFamily.bsd);
    expect(WorkflowOsFamily.ofUname('DragonFly'), WorkflowOsFamily.bsd);
    expect(WorkflowOsFamily.ofUname('Darwin'), WorkflowOsFamily.macos);
    expect(WorkflowOsFamily.ofUname('MINGW64_NT-10.0'), WorkflowOsFamily.windows);
    expect(WorkflowOsFamily.ofUname('SunOS'), isNull);
  });

  test('a system seen on a host counts as its family; where it could be more than one the host is asked', () {
    expect(workflowOsFamilyOf(OsKind.debian), WorkflowOsFamily.linux);
    expect(workflowOsFamilyOf(OsKind.freebsd), WorkflowOsFamily.bsd);
    expect(workflowOsFamilyOf(OsKind.macos), WorkflowOsFamily.macos);
    expect(workflowOsFamilyOf(OsKind.windows), WorkflowOsFamily.windows);
    expect(workflowOsFamilyOf(OsKind.truenas), isNull);
    expect(workflowOsFamilyOf(OsKind.unknown), isNull);
    expect(workflowOsFamilyOf(null), isNull);
  });

  test('saved and read back as it was; a step with one host keeps the blob it had', () {
    const many = WorkflowStep(
      id: 'm',
      type: WorkflowStepType.execute,
      command: 'df',
      targetIds: ['a', 'b'],
      commandsByOs: {'bsd': 'df -P'},
    );
    final back = WorkflowStep.fromJson(many.toJson());
    expect(back.targetIds, ['a', 'b']);
    expect(back.commandsByOs, {'bsd': 'df -P'});
    expect(back.manyTargets, isTrue);
    expect(WorkflowStep.fromJson(const WorkflowStep(id: 'g', type: WorkflowStepType.snippet, targetGroupId: 'x').toJson()).targetGroupId, 'x');
    expect(WorkflowStep.fromJson(const WorkflowStep(id: 'g', type: WorkflowStepType.snippet, targetAll: true).toJson()).targetAll, isTrue);

    const one = WorkflowStep(id: 'o', type: WorkflowStepType.execute, command: 'df', connectionId: 'a');
    expect(one.toJson().keys, isNot(containsAll(['targetIds', 'targetGroupId', 'targetAll', 'commandsByOs'])));
    expect(one.manyTargets, isFalse);
  });

  test('Run on…: the picked hosts take the place of what a step runs on', () {
    const step = WorkflowStep(id: 'o', type: WorkflowStepType.execute, command: 'df', targetAll: true, commandsByOs: {'bsd': 'x'});
    final two = step.onHosts(['a', 'b']);
    expect(two.targetAll, isFalse);
    expect(two.targetIds, ['a', 'b']);
    expect(two.connectionId, isNull);
    expect(two.commandsByOs, {'bsd': 'x'});
    final one = step.onHosts(['a']);
    expect(one.targetAll, isFalse);
    expect(one.targetIds, isEmpty);
    expect(one.connectionId, 'a');
  });

  test("the editor's draft keeps a step's targets and commands through an edit, and a target one replaces the other",
      () {
    const step = WorkflowStep(
      id: 'm',
      type: WorkflowStepType.execute,
      command: 'df',
      targetIds: ['a', 'b'],
      commandsByOs: {'bsd': 'df -P'},
    );
    final draft = StepDraft.fromStep(step);
    expect(draft.toStep().targetIds, ['a', 'b']);
    expect(draft.toStep().commandsByOs, {'bsd': 'df -P'});

    final controller = WorkflowEditController();
    addTearDown(controller.dispose);
    controller.setStepTargets(draft, all: true);
    expect(draft.toStep().targetAll, isTrue);
    expect(draft.toStep().targetIds, isEmpty);
    expect(draft.toStep().connectionId, isNull);
    controller.setStepTargets(draft, groupId: 'g');
    expect((draft.toStep().targetAll, draft.toStep().targetGroupId), (false, 'g'));
    controller.setStepTargets(draft, hosts: ['one']);
    expect((draft.toStep().connectionId, draft.toStep().targetGroupId), ('one', null));
    expect(draft.toStep().targetIds, isEmpty);

    controller.addAltCommand(draft, WorkflowOsFamily.macos);
    draft.altCommands['macos']!.text = 'df -l';
    expect(draft.toStep().commandsByOs, {'bsd': 'df -P', 'macos': 'df -l'});
    controller.removeAltCommand(draft, WorkflowOsFamily.bsd);
    expect(draft.toStep().commandsByOs, {'macos': 'df -l'});
  });

  test("the run's controller counts a step with many hosts as one step, and Clear forgets the run", () async {
    final controller = WorkflowRunController();
    addTearDown(controller.dispose);
    final automation = _Automation(['a', 'b', 'c']);
    await controller.run(
      WorkflowService(automation, notice: (_, _, _) {}),
      _workflow([_many(onFailure: StepFailureAction.abort)]),
    );
    expect(controller.totalSteps, 1);
    expect(controller.stepsDone, 1);
    expect(controller.hostsOfStep(0), 3);
    expect(controller.resultsOfStep(0), 3);
    expect(controller.isOpen, isTrue);
    controller.close();
    expect(controller.isOpen, isFalse);
    expect(controller.results, hasLength(3), reason: 'closed, its results are kept to show again');
    controller.open();
    controller.clear();
    expect(controller.isOpen, isFalse);
    expect(controller.results, isEmpty);
  });

  group('a run left behind', () {
    Workflow many(String name) => Workflow(id: name, name: name, createdAt: DateTime(2026), steps: [
          _many(onFailure: StepFailureAction.abort),
        ]);

    test('leaving it mid-run stops it: Cancel went with the panel, and the rest of its hosts ran on', () async {
      final controller = WorkflowRunController();
      addTearDown(controller.dispose);
      final automation = _Automation(['a', 'b', 'c', 'd', 'e', 'f']);
      final running = controller.run(WorkflowService(automation, notice: (_, _, _) {}), many('A'));
      await Future<void>.delayed(const Duration(milliseconds: 3));
      controller.reset();
      expect(controller.isRunning, isFalse);
      final result = await running;
      expect(automation.ran.length, lessThan(6));
      expect(result.cancelled, isTrue);
      expect(controller.results, isEmpty, reason: 'nothing of it comes back to the panel');
      expect(controller.isRunning, isFalse);
    });

    test("a second run never shows the first's rows, and the first's end does not end it", () async {
      final controller = WorkflowRunController();
      addTearDown(controller.dispose);
      final first = _Automation(['a1', 'a2', 'a3', 'a4', 'a5', 'a6']);
      final second = _Automation([for (var i = 0; i < 30; i++) 'b$i']);
      final one = controller.run(WorkflowService(first, notice: (_, _, _) {}), many('A'));
      await Future<void>.delayed(const Duration(milliseconds: 3));
      controller.reset();
      final two = controller.run(WorkflowService(second, notice: (_, _, _) {}), many('B'));
      await one;
      expect(controller.isRunning, isTrue, reason: 'the second is still going');
      expect(controller.workflowId, 'B');
      await two;
      expect(controller.results.map((r) => r.connectionId).where((id) => id!.startsWith('a')), isEmpty);
      expect(controller.results, hasLength(30));
      expect(controller.isRunning, isFalse);
      expect(controller.finalResult!.workflowId, 'B');
    });

    test('a page closed mid-run stops it, and what it still says reaches nothing', () async {
      final controller = WorkflowRunController();
      final automation = _Automation(['a', 'b', 'c', 'd', 'e', 'f']);
      final running = controller.run(WorkflowService(automation, notice: (_, _, _) {}), many('A'));
      await Future<void>.delayed(const Duration(milliseconds: 3));
      controller.dispose();
      final result = await running;
      expect(result.cancelled, isTrue);
      expect(automation.ran.length, lessThan(6));
    });
  });

  test('the disk check for BSD and macOS has no -x, and leaves out what is no disk', () {
    expect(kDiskOver85BsdCommand, isNot(contains(' -x')));
    expect(kDiskOver85BsdCommand, contains('devfs'));
  });
}

/// Fails on [failFirst] the first time, and not after.
class _Flaky extends _Automation {
  _Flaky(super.hosts, {required this.failFirst});

  final Set<String> failFirst;
  final _failed = <String>{};

  @override
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async {
    ran.add((connectionId, command));
    final fails = failFirst.contains(connectionId) && _failed.add(connectionId);
    return AutomationResult(success: !fails, output: '', error: fails ? 'not yet' : '', exitCode: fails ? 1 : 0, elapsed: Duration.zero);
  }
}
