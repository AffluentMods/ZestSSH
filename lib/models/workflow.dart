import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:zestssh/l10n/l10n_global.dart';

// ── Enums ─────────────────────────────────────────────────────────

/// The type of action a workflow step performs.
enum WorkflowStepType {
  /// Execute a raw shell command on a remote server.
  execute('execute', 'Execute Command'),

  /// Run a saved snippet (by name) on a remote server.
  snippet('snippet', 'Run Snippet'),

  /// Pause execution for a configurable number of seconds.
  delay('delay', 'Delay'),

  /// Fire a local notification with the previous step's output.
  notify('notify', 'Notify');

  const WorkflowStepType(this.key, this.englishName);

  final String key;

  /// Its name in English, for the log: screens show it in the
  /// person's language (lib/l10n/list_names.dart; it was shown as it is,
  /// in English, whatever the language).
  final String englishName;

  static WorkflowStepType fromKey(String key) {
    return WorkflowStepType.values.firstWhere(
      (e) => e.key == key,
      orElse: () => WorkflowStepType.execute,
    );
  }
}

/// What to do when a step fails.
enum StepFailureAction {
  /// Stop the workflow immediately.
  abort('abort', 'Abort Workflow'),

  /// Log the failure and move to the next step.
  continueNext('continue', 'Continue to Next Step'),

  /// Jump to a specific step by ID.
  gotoStep('goto', 'Go to Step');

  const StepFailureAction(this.key, this.englishName);

  final String key;

  /// Its name in English, for the log: screens show it in the
  /// person's language (lib/l10n/list_names.dart; it was shown as it is,
  /// in English, whatever the language).
  final String englishName;

  static StepFailureAction fromKey(String key) {
    return StepFailureAction.values.firstWhere(
      (e) => e.key == key,
      orElse: () => StepFailureAction.abort,
    );
  }
}

/// The systems a step's command can differ on (
/// BSD's and macOS's df has no -x, and "Check disk space everywhere" failed on
/// an OPNsense with "df: invalid option -- x").
enum WorkflowOsFamily {
  linux,
  bsd,
  macos,
  windows;

  /// What `uname -s` said of a host, or null where it says none of these.
  static WorkflowOsFamily? ofUname(String said) {
    final name = said.trim().toLowerCase();
    if (name.startsWith('linux')) return WorkflowOsFamily.linux;
    if (name.startsWith('darwin')) return WorkflowOsFamily.macos;
    if (name.contains('bsd') || name.startsWith('dragonfly')) return WorkflowOsFamily.bsd;
    if (name.startsWith('mingw') || name.startsWith('msys') || name.startsWith('cygwin')) {
      return WorkflowOsFamily.windows;
    }
    return null;
  }
}

// ── WorkflowStep ──────────────────────────────────────────────────

/// A single step in a workflow.
class WorkflowStep {
  final String id;
  final WorkflowStepType type;

  /// Optional user-typed title for the step. When empty the UI derives a
  /// readable title (snippet name / first command tokens / "Wait 10s" / a
  /// truncated condition). Additive JSON field - pre-1.7 blobs deserialize it
  /// to null, so no schema migration is needed.
  final String? label;

  /// Which saved connection to execute on (for [execute] and [snippet] types).
  final String? connectionId;

  /// The shell command to run (for [execute] type).
  final String? command;

  /// The saved snippet name to run (for [snippet] type).
  final String? snippetName;

  /// Maximum seconds to wait for the step to complete.
  final int timeoutSeconds;

  /// What to do if this step fails (non-zero exit code or error).
  final StepFailureAction onFailure;

  /// Target step ID when [onFailure] is [StepFailureAction.gotoStep].
  final String? gotoStepId;

  /// Variable substitutions for snippet templates (key -> value).
  final Map<String, String> variables;

  // ── 1.7 Advanced options (ADDITIVE JSON - backward compatible) ──
  //
  // These fields live only in the `stepsJson` blob, not in a DB column, so
  // adding them is NOT a schema migration: pre-1.7 workflows simply
  // deserialize them to their defaults, and the existing [WorkflowService]
  // engine ignores the keys it does not read. They surface the 1.7 step
  // "Advanced" expander (timeout is the pre-existing [timeoutSeconds]).

  /// How many times to retry the step on failure before applying [onFailure].
  /// Captured by the editor; the shipped engine treats 0 (no retry) today.
  final int retries;

  /// Working directory the command should run in. Editor-captured metadata.
  final String? workingDir;

  /// Only run this step if the previous step succeeded. Editor-captured; the
  /// engine's default abort-on-failure already realises the common case.
  final bool runIfPrevious;

  /// A disabled step is skipped at run time (the run path drops it before
  /// handing the workflow to the engine) but is preserved in storage.
  final bool disabled;

  // ── Many targets (3.3, ADDITIVE JSON as above; before,
  // "Check disk space everywhere" was 21 copies of one step, one per host) ──

  /// The hosts it runs on, where it is more than one ([connectionId] where it
  /// is one).
  final List<String> targetIds;

  /// The group it runs on: its hosts that can run a command, as they are when
  /// it runs.
  final String? targetGroupId;

  /// It runs on every host that can run a command, as they are when it runs.
  final bool targetAll;

  /// What a Command step runs on another system than the one [command] is for,
  /// by [WorkflowOsFamily]'s name. Empty for one command everywhere.
  final Map<String, String> commandsByOs;

  const WorkflowStep({
    required this.id,
    required this.type,
    this.label,
    this.connectionId,
    this.command,
    this.snippetName,
    this.timeoutSeconds = 30,
    this.onFailure = StepFailureAction.abort,
    this.gotoStepId,
    this.variables = const {},
    this.retries = 0,
    this.workingDir,
    this.runIfPrevious = true,
    this.disabled = false,
    this.targetIds = const [],
    this.targetGroupId,
    this.targetAll = false,
    this.commandsByOs = const {},
  });

  /// Whether it runs on a host at all: a wait or a notice does not.
  bool get usesHosts => type == WorkflowStepType.execute || type == WorkflowStepType.snippet;

  /// Whether it is set to run on more than the one host [connectionId] says.
  bool get manyTargets => targetAll || targetGroupId != null || targetIds.isNotEmpty;

  /// This step on [hosts], whatever it is set to run on (Run on…, or one host
  /// of many at its turn).
  WorkflowStep onHosts(List<String> hosts) => WorkflowStep(
        id: id,
        type: type,
        label: label,
        connectionId: hosts.length == 1 ? hosts.single : null,
        command: command,
        snippetName: snippetName,
        timeoutSeconds: timeoutSeconds,
        onFailure: onFailure,
        gotoStepId: gotoStepId,
        variables: variables,
        retries: retries,
        workingDir: workingDir,
        runIfPrevious: runIfPrevious,
        disabled: disabled,
        targetIds: hosts.length == 1 ? const [] : hosts,
        commandsByOs: commandsByOs,
      );

  WorkflowStep copyWith({
    String? id,
    WorkflowStepType? type,
    String? label,
    String? connectionId,
    String? command,
    String? snippetName,
    int? timeoutSeconds,
    StepFailureAction? onFailure,
    String? gotoStepId,
    Map<String, String>? variables,
    int? retries,
    String? workingDir,
    bool? runIfPrevious,
    bool? disabled,
    List<String>? targetIds,
    String? targetGroupId,
    bool? targetAll,
    Map<String, String>? commandsByOs,
  }) {
    return WorkflowStep(
      id: id ?? this.id,
      type: type ?? this.type,
      label: label ?? this.label,
      connectionId: connectionId ?? this.connectionId,
      command: command ?? this.command,
      snippetName: snippetName ?? this.snippetName,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      onFailure: onFailure ?? this.onFailure,
      gotoStepId: gotoStepId ?? this.gotoStepId,
      variables: variables ?? this.variables,
      retries: retries ?? this.retries,
      workingDir: workingDir ?? this.workingDir,
      runIfPrevious: runIfPrevious ?? this.runIfPrevious,
      disabled: disabled ?? this.disabled,
      targetIds: targetIds ?? this.targetIds,
      targetGroupId: targetGroupId ?? this.targetGroupId,
      targetAll: targetAll ?? this.targetAll,
      commandsByOs: commandsByOs ?? this.commandsByOs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.key,
        // Only emit a label when the user set one, so unlabeled steps keep a
        // byte-compatible blob.
        if (label != null && label!.isNotEmpty) 'label': label,
        'connectionId': connectionId,
        'command': command,
        'snippetName': snippetName,
        'timeoutSeconds': timeoutSeconds,
        'onFailure': onFailure.key,
        'gotoStepId': gotoStepId,
        'variables': variables,
        // Only emit non-default advanced values so unchanged workflows keep a
        // byte-compatible blob.
        if (retries != 0) 'retries': retries,
        if (workingDir != null) 'workingDir': workingDir,
        if (!runIfPrevious) 'runIfPrevious': runIfPrevious,
        if (disabled) 'disabled': disabled,
        if (targetIds.isNotEmpty) 'targetIds': targetIds,
        if (targetGroupId != null) 'targetGroupId': targetGroupId,
        if (targetAll) 'targetAll': targetAll,
        if (commandsByOs.isNotEmpty) 'commandsByOs': commandsByOs,
      };

  factory WorkflowStep.fromJson(Map<String, dynamic> json) {
    return WorkflowStep(
      id: json['id'] as String,
      type: WorkflowStepType.fromKey(json['type'] as String),
      label: json['label'] as String?,
      connectionId: json['connectionId'] as String?,
      command: json['command'] as String?,
      snippetName: json['snippetName'] as String?,
      timeoutSeconds: json['timeoutSeconds'] as int? ?? 30,
      onFailure:
          StepFailureAction.fromKey(json['onFailure'] as String? ?? 'abort'),
      gotoStepId: json['gotoStepId'] as String?,
      variables: (json['variables'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          const {},
      retries: json['retries'] as int? ?? 0,
      workingDir: json['workingDir'] as String?,
      runIfPrevious: json['runIfPrevious'] as bool? ?? true,
      disabled: json['disabled'] as bool? ?? false,
      targetIds: (json['targetIds'] as List<dynamic>?)?.map((e) => e as String).toList() ?? const [],
      targetGroupId: json['targetGroupId'] as String?,
      targetAll: json['targetAll'] as bool? ?? false,
      commandsByOs: (json['commandsByOs'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v as String)) ?? const {},
    );
  }

  /// Human-readable summary for display in UI lists.
  String get displaySummary {
    switch (type) {
      case WorkflowStepType.execute:
        final cmd = command ?? '';
        final truncated = cmd.length > 60 ? '${cmd.substring(0, 57)}...' : cmd;
        return truncated;
      // In the app's language: they were English in every language (found in
      // a code audit).
      case WorkflowStepType.snippet:
        return snippetName ?? gl10n.wfStepUnknownSnippet;
      case WorkflowStepType.delay:
        return gl10n.wfStepWait(timeoutSeconds);
      case WorkflowStepType.notify:
        return command ?? gl10n.wfStepSendNotification;
    }
  }
}

// ── Workflow ──────────────────────────────────────────────────────

/// A workflow is a named sequence of steps that execute on servers.
class Workflow {
  final String id;
  final String name;
  final String? description;
  final List<WorkflowStep> steps;

  /// Optional cron-like schedule expression. Null means manual-only.
  final String? scheduleExpression;

  /// Whether this workflow is active (can be triggered/scheduled).
  final bool enabled;

  final DateTime createdAt;
  final DateTime? lastRunAt;

  /// Send a local notification when any step fails.
  final bool notifyOnFailure;

  /// Send a local notification when the workflow completes successfully.
  final bool notifyOnSuccess;

  const Workflow({
    required this.id,
    required this.name,
    this.description,
    required this.steps,
    this.scheduleExpression,
    this.enabled = true,
    required this.createdAt,
    this.lastRunAt,
    this.notifyOnFailure = true,
    this.notifyOnSuccess = false,
  });

  /// Create a new empty workflow with a generated UUID.
  factory Workflow.create({
    required String name,
    String? description,
  }) {
    return Workflow(
      id: const Uuid().v4(),
      name: name,
      description: description,
      steps: const [],
      createdAt: DateTime.now(),
    );
  }

  Workflow copyWith({
    String? id,
    String? name,
    String? description,
    List<WorkflowStep>? steps,
    String? scheduleExpression,
    bool? enabled,
    DateTime? createdAt,
    DateTime? lastRunAt,
    bool? notifyOnFailure,
    bool? notifyOnSuccess,
  }) {
    return Workflow(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      steps: steps ?? this.steps,
      scheduleExpression: scheduleExpression ?? this.scheduleExpression,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      notifyOnFailure: notifyOnFailure ?? this.notifyOnFailure,
      notifyOnSuccess: notifyOnSuccess ?? this.notifyOnSuccess,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'steps': steps.map((s) => s.toJson()).toList(),
        'scheduleExpression': scheduleExpression,
        'enabled': enabled,
        'createdAt': createdAt.toIso8601String(),
        'lastRunAt': lastRunAt?.toIso8601String(),
        'notifyOnFailure': notifyOnFailure,
        'notifyOnSuccess': notifyOnSuccess,
      };

  factory Workflow.fromJson(Map<String, dynamic> json) {
    return Workflow(
      id: json['id'] as String,
      name: json['name'] as String,
      steps: (json['steps'] as List<dynamic>)
          .map((e) => WorkflowStep.fromJson(e as Map<String, dynamic>))
          .toList(),
      description: json['description'] as String?,
      scheduleExpression: json['scheduleExpression'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastRunAt: json['lastRunAt'] != null
          ? DateTime.parse(json['lastRunAt'] as String)
          : null,
      notifyOnFailure: json['notifyOnFailure'] as bool? ?? true,
      notifyOnSuccess: json['notifyOnSuccess'] as bool? ?? false,
    );
  }

  /// Serialize the entire workflow list to a JSON string for SharedPreferences.
  static String encodeList(List<Workflow> workflows) {
    return jsonEncode(workflows.map((w) => w.toJson()).toList());
  }

  /// Deserialize a workflow list from a SharedPreferences JSON string.
  static List<Workflow> decodeList(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => Workflow.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

// ── Execution results ─────────────────────────────────────────────

/// Result of executing a single workflow step.
class WorkflowStepResult {
  final String stepId;
  final WorkflowStepType stepType;
  final bool success;
  final String output;
  final String error;
  final int? exitCode;
  final Duration elapsed;
  final bool skipped;

  /// True when this step was refused because it ran unattended (headless)
  /// against a credential not opted in to unattended runs. Distinguishes the
  /// "walled-off credential" case from an ordinary command failure so the row
  /// outcome reads amber "Needs credentials" rather than red "Failed".
  final bool needsCredentials;

  /// True when the step failed in a way that ends the workflow whatever the
  /// step is set to do when it fails: the snippet it runs is not there any
  /// more (deleted or renamed), so the workflow is not what it was made as.
  final bool stopsWorkflow;

  /// The host this result is of; null for a step that runs on none. A step
  /// with many targets has one result per host (before,
  /// every row of a run said "Command").
  final String? connectionId;

  /// Which step of what ran this is of, from 0. Set by what ran it.
  final int? stepIndex;

  /// It was skipped because the run was cancelled, not because another step
  /// or host failed.
  final bool skippedForCancel;

  const WorkflowStepResult({
    required this.stepId,
    required this.stepType,
    required this.success,
    this.output = '',
    this.error = '',
    this.exitCode,
    this.elapsed = Duration.zero,
    this.skipped = false,
    this.needsCredentials = false,
    this.stopsWorkflow = false,
    this.connectionId,
    this.stepIndex,
    this.skippedForCancel = false,
  });

  /// This result, said to be of step [stepIndex] and, where given, of a host.
  WorkflowStepResult located({required int stepIndex, String? connectionId}) => WorkflowStepResult(
        stepId: stepId,
        stepType: stepType,
        success: success,
        output: output,
        error: error,
        exitCode: exitCode,
        elapsed: elapsed,
        skipped: skipped,
        needsCredentials: needsCredentials,
        stopsWorkflow: stopsWorkflow,
        connectionId: connectionId ?? this.connectionId,
        stepIndex: stepIndex,
        skippedForCancel: skippedForCancel,
      );

  @override
  String toString() =>
      'StepResult($stepId: ${success ? "OK" : "FAIL"}, '
      'exit=$exitCode, ${elapsed.inMilliseconds}ms)';
}

/// What [results] came to: the last of each step on each host, in the order
/// they first came. A step gone back to by Go to step runs again, and what it
/// came to the last time is what stands. A skip is no result: it says it did not
/// run again, and what it came to before stands, on that host, or on any where the
/// skip is of the step as a whole (a cancel during a retry turned a real failure
/// into skipped).
List<WorkflowStepResult> settledStepResults(Iterable<WorkflowStepResult> results) {
  final last = <(String, String?), WorkflowStepResult>{};
  for (final r in results) {
    final key = (r.stepId, r.connectionId);
    if (r.skipped) {
      if (last.containsKey(key)) continue;
      if (r.connectionId == null && last.keys.any((k) => k.$1 == r.stepId)) continue;
    }
    last[key] = r;
  }
  return last.values.toList();
}

/// Aggregated result of running an entire workflow.
class WorkflowResult {
  final String workflowId;
  final String workflowName;
  final bool success;
  final List<WorkflowStepResult> stepResults;
  final Duration totalElapsed;
  final bool cancelled;
  final String? errorMessage;

  const WorkflowResult({
    required this.workflowId,
    required this.workflowName,
    required this.success,
    required this.stepResults,
    required this.totalElapsed,
    this.cancelled = false,
    this.errorMessage,
  });

  /// What each step on each host came to ([settledStepResults]).
  List<WorkflowStepResult> get settled => settledStepResults(stepResults);

  /// Number of results that went well: a step's, and of a step with many
  /// targets, each host's.
  int get successCount => settled.where((r) => r.success).length;

  /// Number of results that failed: a step's, and of a step with many targets,
  /// each host's.
  int get failureCount => settled.where((r) => !r.success && !r.skipped).length;

  /// Number of results skipped (not reached due to abort or a cancel).
  int get skippedCount => settled.where((r) => r.skipped).length;

  /// How many steps it has results of, each counted once, however many hosts
  /// it ran on.
  int get stepsCount => {for (final r in stepResults) r.stepId}.length;

  /// How many of the workflow's steps went through, each counted once.
  int get stepsSucceeded {
    final notWell = {for (final r in settled) if (!r.success) r.stepId};
    return {for (final r in settled) if (r.success && !notWell.contains(r.stepId)) r.stepId}.length;
  }

  /// How many steps failed, on one host or on many, each counted once.
  int get stepsFailed => {for (final r in settled) if (!r.success && !r.skipped) r.stepId}.length;

  /// How many steps were not run at all.
  int get stepsSkipped {
    final ran = {for (final r in settled) if (!r.skipped) r.stepId};
    return {for (final r in settled) if (r.skipped && !ran.contains(r.stepId)) r.stepId}.length;
  }

  /// The hosts it ran anything on, each counted once.
  int get hostsCount => {for (final r in settled) if (r.connectionId != null && !r.skipped) r.connectionId}.length;

  /// The hosts where something failed, each counted once.
  int get hostsFailed => {for (final r in settled) if (r.connectionId != null && !r.success && !r.skipped) r.connectionId}.length;

  /// Whether a step of it ran on more than one host: then its hosts say more
  /// than its steps.
  bool get ranOnManyHosts {
    final seen = <String>{};
    for (final r in settled) {
      if (r.connectionId != null && !seen.add(r.stepId)) return true;
    }
    return false;
  }

  /// How far it came, in the English of a link's or another app's answer:
  /// steps as steps, and hosts as hosts where a step ran on many.
  String get stepsOkLine => '$stepsSucceeded/$stepsCount steps OK'
      '${ranOnManyHosts ? ', ${hostsCount - hostsFailed}/$hostsCount hosts OK' : ''}';

  /// True when the run was blocked because a step targeted a credential not
  /// enabled for unattended runs. Drives the amber "Needs credentials"
  /// outcome instead of a plain failure.
  bool get needsCredentials => stepResults.any((r) => r.needsCredentials);

  @override
  String toString() =>
      'WorkflowResult($workflowName: ${success ? "OK" : "FAIL"}, '
      '$stepsOkLine, '
      '${totalElapsed.inMilliseconds}ms)';
}
