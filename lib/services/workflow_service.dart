import 'dart:async';

import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/utils/logger.dart';

// ── Cancellation ──────────────────────────────────────────────────

/// A token that can be used to cancel a running workflow.
///
/// Create one before calling [WorkflowService.executeWorkflow] and pass it
/// in. Call [cancel] to request graceful cancellation. The engine checks
/// [isCancelled] between steps and aborts if true.
class CancellationToken {
  bool _cancelled = false;

  /// Whether cancellation has been requested.
  bool get isCancelled => _cancelled;

  /// Request cancellation. The workflow will stop before the next step.
  void cancel() {
    _cancelled = true;
    AppLogger.info('WorkflowService: cancellation requested');
  }
}

// ── Step progress callback ────────────────────────────────────────

/// Called after each step completes (or is skipped) so the UI can
/// update progress in real time.
typedef StepProgressCallback =
    void Function(int stepIndex, int totalSteps, WorkflowStepResult result);

/// Called as a step with many targets starts, with how many hosts it runs on:
/// so the UI can say how far it has come.
typedef StepHostsCallback = void Function(int stepIndex, int hosts);

/// How many hosts of a step that goes on past a failure run at once (as Run on
/// hosts has it). A step that stops at a failure runs on one at a time: an
/// update rolled over a group stops at the first host it broke.
const kWorkflowHostsAtOnce = 4;

/// How many times one run goes through a step: a step whose failure goes back
/// to itself or to one before it would otherwise run for as long as it fails.
const kWorkflowStepVisits = 20;

// ── Notices ───────────────────────────────────────────────────────

/// What a workflow's notice is: what a Notify step says, or that the
/// workflow finished or failed (its "notify on success / failure").
enum WorkflowNoticeKind { said, finished, failed }

/// How a workflow's notice reaches its person (the app gives the one of
/// [WorkflowService]'s provider: the app's notices, and on a phone the
/// system's notification as well).
typedef WorkflowNotice = void Function(WorkflowNoticeKind kind, String title, String body);

/// What a Notify step's message has in place of [kWorkflowOutputToken]: the
/// output of the last command or snippet that ran.
const kWorkflowOutputToken = '{{output}}';

// ── Workflow execution engine ─────────────────────────────────────

/// Executes [Workflow] definitions step by step using [AutomationService]
/// for remote command execution.
///
/// The engine handles:
/// - Sequential step execution with per-step timeouts
/// - Failure actions: abort, continue, or goto another step
/// - Delay steps (async sleep)
/// - Notify steps (local notification with previous output)
/// - Cancellation between steps via [CancellationToken]
/// - Step-level progress reporting via [StepProgressCallback]
class WorkflowService {
  final AutomationService _automationService;

  /// Where the workflow's notices go; the system's notification where none
  /// is given (a phone's: a computer shows none of the app's).
  final WorkflowNotice _notice;

  /// The system seen on a host, where one was: which of a Command step's
  /// commands it gets. Where none was, the host is asked (`uname -s`).
  final WorkflowOsFamily? Function(String connectionId)? _osFamilyOf;

  WorkflowService(
    this._automationService, {
    WorkflowNotice? notice,
    WorkflowOsFamily? Function(String connectionId)? osFamilyOf,
  })  : _notice = notice ?? _systemNotice,
        _osFamilyOf = osFamilyOf;

  static void _systemNotice(WorkflowNoticeKind kind, String title, String body) =>
      unawaited(NotificationService.showNotice(title: title, body: body));

  /// Execute a workflow from start to finish.
  ///
  /// Returns a [WorkflowResult] with per-step results.
  ///
  /// - [cancellationToken]: optional token to request early termination.
  /// - [onStepComplete]: optional callback fired after each step.
  Future<WorkflowResult> executeWorkflow(
    Workflow workflow, {
    CancellationToken? cancellationToken,
    StepProgressCallback? onStepComplete,
    StepHostsCallback? onStepHosts,
    bool unattended = false,
  }) async {
    AppLogger.info(
      'WorkflowService: starting "${workflow.name}" '
      '(${workflow.steps.length} steps)',
    );

    final stopwatch = Stopwatch()..start();
    final stepResults = <WorkflowStepResult>[];
    var currentIndex = 0;
    var aborted = false;
    String? lastOutput;
    final visits = <int, int>{};
    final systems = <String, Future<WorkflowOsFamily?>>{};
    // Of a step with many targets that went back to itself: the hosts that
    // failed, the ones it runs on again.
    Set<String>? againOn;

    // The steps from [from] on, as skipped.
    void skipFrom(int from, String why, {bool forCancel = false}) {
      for (var i = from; i < workflow.steps.length; i++) {
        final step = workflow.steps[i];
        final skipped = WorkflowStepResult(
          stepId: step.id,
          stepType: step.type,
          success: false,
          error: why,
          skipped: true,
          stepIndex: i,
          skippedForCancel: forCancel,
        );
        stepResults.add(skipped);
        onStepComplete?.call(i, workflow.steps.length, skipped);
      }
    }

    while (currentIndex < workflow.steps.length) {
      // ── Check for cancellation before each step ──
      if (cancellationToken?.isCancelled == true) {
        AppLogger.info('WorkflowService: cancelled before step $currentIndex');
        skipFrom(currentIndex, gl10n.workflowSvcCancelled, forCancel: true);
        break;
      }

      final step = workflow.steps[currentIndex];
      AppLogger.info(
        'WorkflowService: step ${currentIndex + 1}/${workflow.steps.length} '
        '(${step.type.englishName})',
      );

      // A workflow that goes round by Go to step ends: a host that goes on
      // failing would have it run for ever, with nobody told.
      final visit = visits[currentIndex] = (visits[currentIndex] ?? 0) + 1;
      if (visit > kWorkflowStepVisits) {
        AppLogger.warning('WorkflowService: step ${step.id} reached $kWorkflowStepVisits runs, stopping');
        final stop = WorkflowStepResult(
          stepId: step.id,
          stepType: step.type,
          success: false,
          error: gl10n.workflowSvcStepLoops(kWorkflowStepVisits),
          stepIndex: currentIndex,
        );
        stepResults.add(stop);
        onStepComplete?.call(currentIndex, workflow.steps.length, stop);
        aborted = true;
        skipFrom(currentIndex + 1, gl10n.workflowSvcSkippedAborted);
        break;
      }

      final atIndex = currentIndex;
      void ran(WorkflowStepResult result) {
        stepResults.add(result);
        onStepComplete?.call(atIndex, workflow.steps.length, result);
      }

      // One result, or one per host where it has many targets.
      final List<WorkflowStepResult> results;
      final hostNames = <String, String>{};
      if (step.usesHosts && step.manyTargets) {
        final only = againOn;
        againOn = null;
        results = await _executeOnHosts(
            step, atIndex, lastOutput, unattended, cancellationToken, onStepHosts, ran, hostNames, only, systems);
      } else {
        final one = (await _executeStep(step, lastOutput, unattended, systems))
            .located(stepIndex: atIndex, connectionId: step.usesHosts ? step.connectionId : null);
        ran(one);
        results = [one];
      }

      // The output a Notify step sends: a command's or a snippet's, never a
      // wait's or a notice's own "Notification sent". Of many hosts, each one's
      // under its name.
      if (step.usesHosts) {
        final printed = [for (final r in results) if (r.success && r.output.isNotEmpty) r];
        if (printed.length == 1 && results.length == 1) {
          lastOutput = printed.single.output;
        } else if (printed.isNotEmpty) {
          lastOutput = printed.map((r) => '${hostNames[r.connectionId] ?? r.connectionId}: ${r.output.trimRight()}').join('\n');
        }
      }

      // A cancel while it ran stops at the top of the loop, whatever it found.
      final failed = results.where((r) => !r.success && !r.skipped).toList();
      if (failed.isEmpty) {
        // Step succeeded - move to next.
        currentIndex++;
        continue;
      }

      // ── Step failed - apply failure action ──
      for (final result in failed) {
        AppLogger.warning(
          'WorkflowService: step ${step.id} failed '
          '(exit=${result.exitCode}): ${result.error}',
        );
      }

      // A step whose snippet is gone stops the workflow, with an error that
      // names the snippet, whatever the step is set to do when it fails
      // (the words said such a step was skipped; it failed, and the workflow
      // went on or stopped by the step's setting).
      switch (failed.any((r) => r.stopsWorkflow) ? StepFailureAction.abort : step.onFailure) {
        case StepFailureAction.abort:
          aborted = true;
          // Mark remaining steps as skipped.
          skipFrom(currentIndex + 1, gl10n.workflowSvcSkippedAborted);
          currentIndex = workflow.steps.length; // Exit loop.

        case StepFailureAction.continueNext:
          AppLogger.info(
            'WorkflowService: continuing to next step after failure',
          );
          currentIndex++;

        case StepFailureAction.gotoStep:
          final targetId = step.gotoStepId;
          if (targetId == null) {
            AppLogger.warning(
              'WorkflowService: goto step ID is null, aborting',
            );
            aborted = true;
            currentIndex = workflow.steps.length;
          } else {
            final targetIndex = workflow.steps.indexWhere(
              (s) => s.id == targetId,
            );
            if (targetIndex < 0) {
              AppLogger.warning(
                'WorkflowService: goto target "$targetId" not found, '
                'aborting',
              );
              aborted = true;
              currentIndex = workflow.steps.length;
            } else {
              AppLogger.info(
                'WorkflowService: jumping to step $targetIndex '
                '($targetId)',
              );
              // A step with many targets that goes to itself is for the hosts
              // that failed: the others are through with it.
              if (targetIndex == currentIndex && step.usesHosts && step.manyTargets) {
                final hosts = {for (final r in failed) ?r.connectionId};
                againOn = hosts.isEmpty ? null : hosts;
              }
              currentIndex = targetIndex;
            }
          }
      }
    }

    stopwatch.stop();
    // Cancelled: what the cancel left undone, on the last step as on any other
    // (a cancel on the last step's hosts said it had finished well).
    final cancelled = cancellationToken?.isCancelled == true && stepResults.any((r) => r.skippedForCancel);
    final allSucceeded = settledStepResults(stepResults).every((r) => r.success || r.skipped);
    final success = !aborted && !cancelled && allSucceeded;

    AppLogger.info(
      'WorkflowService: "${workflow.name}" finished - '
      '${success ? "SUCCESS" : "FAILED"} '
      '(${stopwatch.elapsed.inMilliseconds}ms)',
    );

    final workflowResult = WorkflowResult(
      workflowId: workflow.id,
      workflowName: workflow.name,
      success: success,
      stepResults: stepResults,
      totalElapsed: stopwatch.elapsed,
      cancelled: cancelled,
    );
    // Its person stopped it: nothing more to tell them.
    if (cancelled) return workflowResult;

    // ── Notify based on workflow settings ──
    if (success && workflow.notifyOnSuccess) {
      _sendWorkflowNotification(
        kind: WorkflowNoticeKind.finished,
        title: gl10n.workflowSvcCompletedTitle,
        body: gl10n.workflowSvcCompletedBody(
          workflow.name,
          workflowResult.stepsSucceeded,
          workflow.steps.length,
        ),
      );
    } else if (!success && workflow.notifyOnFailure) {
      _sendWorkflowNotification(
        kind: WorkflowNoticeKind.failed,
        title: gl10n.workflowSvcFailedTitle,
        // Steps counted as steps, and hosts as hosts ("5 failed" for one step
        // on five hosts read as five steps).
        body: workflowResult.ranOnManyHosts
            ? gl10n.workflowSvcFailedBodyHosts(
                workflow.name,
                workflowResult.stepsFailed,
                workflowResult.stepsSkipped,
                workflowResult.hostsFailed,
              )
            : gl10n.workflowSvcFailedBody(
                workflow.name,
                workflowResult.stepsFailed,
                workflowResult.stepsSkipped,
              ),
      );
    }

    return workflowResult;
  }

  // ── Step execution ────────────────────────────────────────────

  /// [step] on each of its hosts, with a result per host handed to [ran] as it
  /// comes. Set to stop at a failure, one host at a time, and the rest are
  /// skipped once one fails; otherwise a few at a time, and all of them run. A
  /// cancel leaves those not yet started skipped. Where [only] is given, it is
  /// the hosts among them that it runs on (a step that went back to itself).
  /// [systems] is what the run has asked hosts of their system ([_commandFor]).
  Future<List<WorkflowStepResult>> _executeOnHosts(
    WorkflowStep step,
    int stepIndex,
    String? previousOutput,
    bool unattended,
    CancellationToken? cancellationToken,
    StepHostsCallback? onStepHosts,
    void Function(WorkflowStepResult result) ran,
    Map<String, String> hostNames,
    Set<String>? only,
    Map<String, Future<WorkflowOsFamily?>> systems,
  ) async {
    final List<Connection> hosts;
    try {
      hosts = [
        for (final h in await _automationService.hostsOfStep(step))
          if (only == null || only.contains(h.id)) h,
      ];
    } catch (e, stack) {
      // Outside a step's own net: thrown on, it left the run going for ever.
      AppLogger.error('WorkflowService: could not read the hosts of step ${step.id}', e, stack);
      final notRead = WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: e.toString(),
        stepIndex: stepIndex,
      );
      ran(notRead);
      return [notRead];
    }
    for (final h in hosts) {
      // As a notice paints it: masked while a screen is recorded.
      hostNames[h.id] = (h.label.isNotEmpty ? Redactable.host(h.label) : Redactable.address(h.host)).display;
    }
    if (hosts.isEmpty) {
      final none = WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: gl10n.workflowSvcNoConnection,
        stepIndex: stepIndex,
      );
      ran(none);
      return [none];
    }
    onStepHosts?.call(stepIndex, hosts.length);
    final stopAtFirst = step.onFailure == StepFailureAction.abort;
    final results = <WorkflowStepResult>[];
    var next = 0;
    var stopped = false;

    void skipOf(String connectionId, String why, {bool forCancel = false}) {
      final skipped = WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: why,
        skipped: true,
        connectionId: connectionId,
        stepIndex: stepIndex,
        skippedForCancel: forCancel,
      );
      results.add(skipped);
      ran(skipped);
    }

    Future<void> worker() async {
      while (next < hosts.length) {
        final host = hosts[next++];
        if (cancellationToken?.isCancelled == true) {
          skipOf(host.id, gl10n.workflowSvcCancelled, forCancel: true);
          continue;
        }
        if (stopped) {
          skipOf(host.id, gl10n.workflowSvcSkippedAborted);
          continue;
        }
        final one = (await _executeStep(step.onHosts([host.id]), previousOutput, unattended, systems))
            .located(stepIndex: stepIndex, connectionId: host.id);
        results.add(one);
        ran(one);
        if (!one.success && (stopAtFirst || one.stopsWorkflow)) stopped = true;
      }
    }

    await Future.wait([
      for (var i = 0; i < (stopAtFirst ? 1 : kWorkflowHostsAtOnce); i++) worker(),
    ]);
    return results;
  }

  /// The command [step] runs on [connectionId]: the one for the host's system
  /// where the step has one for it, else its own. A host whose system was not
  /// seen yet is asked, once in a run ([systems], by host), however many of its
  /// steps have such commands: each signed in for it, and a host out of reach
  /// waited out its time at each.
  Future<String?> _commandFor(
    WorkflowStep step,
    String connectionId,
    bool unattended,
    Map<String, Future<WorkflowOsFamily?>> systems,
  ) async {
    if (step.commandsByOs.isEmpty) return step.command;
    final family =
        _osFamilyOf?.call(connectionId) ?? await (systems[connectionId] ??= _systemOf(connectionId, unattended));
    return (family == null ? null : step.commandsByOs[family.name]) ?? step.command;
  }

  /// What host [connectionId] says it runs. One that answers without having
  /// `uname` is taken for Windows, whose cmd and PowerShell both end such a
  /// command with an exit status of their own; a POSIX shell says 126 or 127, and
  /// a host that could not be reached has no status: for those, null.
  Future<WorkflowOsFamily?> _systemOf(String connectionId, bool unattended) async {
    final said = await _automationService.executeCommand(
      connectionId: connectionId,
      command: 'uname -s',
      timeout: const Duration(seconds: 15),
      unattended: unattended,
    );
    final exit = said.exitCode;
    if (said.success) return WorkflowOsFamily.ofUname(said.output);
    return exit != null && exit != 126 && exit != 127 ? WorkflowOsFamily.windows : null;
  }

  Future<WorkflowStepResult> _executeStep(
    WorkflowStep step,
    String? previousOutput,
    bool unattended,
    Map<String, Future<WorkflowOsFamily?>> systems,
  ) async {
    final stopwatch = Stopwatch()..start();

    try {
      switch (step.type) {
        case WorkflowStepType.execute:
          return await _executeCommandStep(step, stopwatch, unattended, systems);

        case WorkflowStepType.snippet:
          return await _executeSnippetStep(step, stopwatch, unattended);

        case WorkflowStepType.delay:
          return await _executeDelayStep(step, stopwatch);

        case WorkflowStepType.notify:
          return _executeNotifyStep(step, previousOutput, stopwatch);
      }
    } catch (e, stack) {
      stopwatch.stop();
      AppLogger.error(
        'WorkflowService: unexpected error in step ${step.id}',
        e,
        stack,
      );
      return WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: e.toString(),
        elapsed: stopwatch.elapsed,
      );
    }
  }

  Future<WorkflowStepResult> _executeCommandStep(
    WorkflowStep step,
    Stopwatch stopwatch,
    bool unattended,
    Map<String, Future<WorkflowOsFamily?>> systems,
  ) async {
    final connectionId = step.connectionId;

    if (step.command == null || step.command!.isEmpty) {
      stopwatch.stop();
      return WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: gl10n.workflowSvcNoCommand,
        elapsed: stopwatch.elapsed,
      );
    }

    if (connectionId == null || connectionId.isEmpty) {
      stopwatch.stop();
      return WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: gl10n.workflowSvcNoConnection,
        elapsed: stopwatch.elapsed,
      );
    }

    final command = (await _commandFor(step, connectionId, unattended, systems))!;
    final result = await _automationService.executeCommand(
      connectionId: connectionId,
      command: command,
      timeout: Duration(seconds: step.timeoutSeconds),
      unattended: unattended,
    );

    stopwatch.stop();
    return WorkflowStepResult(
      stepId: step.id,
      stepType: step.type,
      success: result.success,
      output: result.output,
      error: result.error,
      exitCode: result.exitCode,
      elapsed: stopwatch.elapsed,
      needsCredentials: result.needsCredentials,
    );
  }

  Future<WorkflowStepResult> _executeSnippetStep(
    WorkflowStep step,
    Stopwatch stopwatch,
    bool unattended,
  ) async {
    final snippetName = step.snippetName;
    final connectionId = step.connectionId;

    if (snippetName == null || snippetName.isEmpty) {
      stopwatch.stop();
      return WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: gl10n.workflowSvcNoSnippetName,
        elapsed: stopwatch.elapsed,
      );
    }

    if (connectionId == null || connectionId.isEmpty) {
      stopwatch.stop();
      return WorkflowStepResult(
        stepId: step.id,
        stepType: step.type,
        success: false,
        error: gl10n.workflowSvcNoConnection,
        elapsed: stopwatch.elapsed,
      );
    }

    final result = await _automationService.runSnippet(
      connectionId: connectionId,
      snippetName: snippetName,
      variables: step.variables.isNotEmpty ? step.variables : null,
      timeout: Duration(seconds: step.timeoutSeconds),
      unattended: unattended,
    );

    stopwatch.stop();
    return WorkflowStepResult(
      stepId: step.id,
      stepType: step.type,
      success: result.success,
      output: result.output,
      error: result.error,
      exitCode: result.exitCode,
      elapsed: stopwatch.elapsed,
      needsCredentials: result.needsCredentials,
      stopsWorkflow: result.snippetMissing || result.variablesMissing,
    );
  }

  Future<WorkflowStepResult> _executeDelayStep(
    WorkflowStep step,
    Stopwatch stopwatch,
  ) async {
    final seconds = step.timeoutSeconds;
    AppLogger.info('WorkflowService: delaying $seconds seconds');

    await Future<void>.delayed(Duration(seconds: seconds));

    stopwatch.stop();
    return WorkflowStepResult(
      stepId: step.id,
      stepType: step.type,
      success: true,
      output: gl10n.workflowSvcDelayOutput(seconds),
      elapsed: stopwatch.elapsed,
    );
  }

  WorkflowStepResult _executeNotifyStep(
    WorkflowStep step,
    String? previousOutput,
    Stopwatch stopwatch,
  ) {
    // The message as typed, the last output where it says {{output}}; with
    // none typed (a phone saved an empty one as typed), the last output
    // itself, else a notice of its own. The output as the run's panel shows it:
    // masked while a screen is recorded, on a card that comes up by itself.
    final typed = step.command?.trim() ?? '';
    final output = Redactable.freeText(previousOutput?.trim() ?? '').display;
    final message = typed.isNotEmpty
        ? typed.replaceAll(kWorkflowOutputToken, output)
        : output.isNotEmpty
            ? output
            : gl10n.workflowSvcDefaultNotification;
    final truncated = message.length > 500
        ? '${message.substring(0, 497)}...'
        : message;

    _sendWorkflowNotification(
      kind: WorkflowNoticeKind.said,
      title: gl10n.workflowSvcNotifyTitle,
      body: truncated,
    );

    stopwatch.stop();
    return WorkflowStepResult(
      stepId: step.id,
      stepType: step.type,
      success: true,
      output: gl10n.workflowSvcNotificationSent,
      elapsed: stopwatch.elapsed,
    );
  }

  // ── Notifications ─────────────────────────────────────────────

  void _sendWorkflowNotification({
    required WorkflowNoticeKind kind,
    required String title,
    required String body,
  }) {
    // Fire and forget - notification failures should not affect workflows.
    try {
      _notice(kind, title, body);
    } catch (e) {
      AppLogger.warning('WorkflowService: notification failed: $e');
    }
  }
}
