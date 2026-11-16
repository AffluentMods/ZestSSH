import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:uuid/uuid.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/workflow.dart';
import '../../../ui/widgets/zest_detail_scaffold.dart';

/// Selector order for the 1.7 step-type control: Snippet / Command / Wait /
/// Notify. The underlying persistence keeps the existing four
/// [WorkflowStepType] values - 1.7 relabels them but does NOT change the
/// engine or the stored blob:
///
///   * Snippet   ↔ [WorkflowStepType.snippet]
///   * Command   ↔ [WorkflowStepType.execute]
///   * Wait      ↔ [WorkflowStepType.delay]
///   * Notify    ↔ [WorkflowStepType.notify]
///
/// (A Notify step was called a Condition here, with a shell test for its
/// example, and is a notice: no condition was ever tested.)
///
/// Keeping the 1:1 map means every stored workflow - including legacy notify
/// steps - round-trips losslessly and the shipped [WorkflowService] executes
/// them unchanged.
const List<WorkflowStepType> kStepTypeOrder = [
  WorkflowStepType.snippet,
  WorkflowStepType.execute,
  WorkflowStepType.delay,
  WorkflowStepType.notify,
];

/// The already-localized selector label for a step [type].
String stepTypeLabel(AppLocalizations l10n, WorkflowStepType type) =>
    switch (type) {
      WorkflowStepType.snippet => l10n.zestAutoStepTypeSnippet,
      WorkflowStepType.execute => l10n.zestAutoStepTypeCommand,
      WorkflowStepType.delay => l10n.zestAutoStepTypeWait,
      WorkflowStepType.notify => l10n.wfEditOptNotifyLabel,
    };

/// The card glyph for a step [type]. Snippet uses `braces` (`{}`) to match the
/// Snippets navigation rail exactly - the two used to disagree (`<>` vs `{}`).
IconData stepTypeIcon(WorkflowStepType type) => switch (type) {
  WorkflowStepType.snippet => LucideIcons.braces,
  WorkflowStepType.execute => LucideIcons.terminal,
  WorkflowStepType.delay => LucideIcons.timer,
  WorkflowStepType.notify => LucideIcons.bell,
};

/// Steps that carry a target host (Command + Snippet run on a connection).
bool stepUsesTarget(WorkflowStepType type) =>
    type == WorkflowStepType.execute || type == WorkflowStepType.snippet;

/// The collapsed-row TITLE for a [draft]: the user's typed label when set,
/// otherwise a derived, human title (never the bare type name). Live -
/// recomputed on every rebuild as the user edits the step's fields.
String stepDisplayTitle(AppLocalizations l10n, StepDraft draft) {
  final label = draft.labelController.text.trim();
  return label.isNotEmpty ? label : stepDerivedTitle(l10n, draft);
}

/// The derived title used when a step has no explicit label - also the live
/// placeholder shown in the Label field so the user sees what the step will be
/// called if they leave it blank.
String stepDerivedTitle(AppLocalizations l10n, StepDraft draft) => _derivedTitle(
      l10n,
      draft.type,
      command: draft.commandController.text,
      snippet: draft.snippetName,
      seconds: int.tryParse(draft.timeoutController.text.trim()) ?? 0,
    );

/// A saved [step]'s title, as its card says it: what a run's output heads its
/// results with.
String stepTitleOf(AppLocalizations l10n, WorkflowStep step) {
  final label = step.label?.trim() ?? '';
  return label.isNotEmpty
      ? label
      : _derivedTitle(l10n, step.type, command: step.command ?? '', snippet: step.snippetName, seconds: step.timeoutSeconds);
}

String _derivedTitle(
  AppLocalizations l10n,
  WorkflowStepType type, {
  required String command,
  required String? snippet,
  required int seconds,
}) {
  switch (type) {
    case WorkflowStepType.execute:
      final cmd = command.trim();
      return cmd.isEmpty ? l10n.zestAutoStepTypeCommand : _firstTokens(cmd, 2);
    case WorkflowStepType.snippet:
      final s = snippet?.trim() ?? '';
      return s.isEmpty ? l10n.zestAutoStepTypeSnippet : s;
    case WorkflowStepType.delay:
      return l10n.zestAutoWaitTitle('${seconds}s');
    case WorkflowStepType.notify:
      final c = command.trim();
      return c.isEmpty ? l10n.wfEditOptNotifyLabel : _truncate(c, 32);
  }
}

/// The mono command PREVIEW for the collapsed row's flex slot: the command
/// text for Command steps and the message for Notify steps, empty otherwise
/// (their title carries the meaning, so nothing mono to show).
String stepCommandPreview(StepDraft draft) {
  switch (draft.type) {
    case WorkflowStepType.execute:
    case WorkflowStepType.notify:
      return draft.commandController.text.trim();
    case WorkflowStepType.snippet:
    case WorkflowStepType.delay:
      return '';
  }
}

String _firstTokens(String s, int n) {
  final parts = s.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  return parts.length <= n ? s.trim() : parts.take(n).join(' ');
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1).trimRight()}…';

// ══════════════════════════════════════════════════════════════════
// Mutable step draft
// ══════════════════════════════════════════════════════════════════

/// A mutable, editor-side view of a single [WorkflowStep] - the automation
/// analogue of the Networks [TriggerDraft]. It owns the text controllers a
/// step needs while it is being edited inline, and bakes back into an
/// immutable [WorkflowStep] via [toStep].
///
/// One draft class covers all four kinds (rather than a sealed hierarchy) so
/// switching a step's type in place is a single field write and disposal stays
/// trivial - the small set of shared controllers is always allocated.
class StepDraft {
  StepDraft({
    required this.id,
    required this.type,
    String label = '',
    this.connectionId,
    this.snippetName,
    String command = '',
    int timeoutSeconds = 30,
    int retries = 0,
    this.onFailure = StepFailureAction.abort,
    this.gotoStepId,
    String workingDir = '',
    this.runIfPrevious = true,
    this.disabled = false,
    Map<String, String>? variables,
    List<String>? targetIds,
    this.targetGroupId,
    this.targetAll = false,
    Map<String, String>? commandsByOs,
  }) : targetIds = [...?targetIds],
       altCommands = {
         for (final e in (commandsByOs ?? const <String, String>{}).entries)
           e.key: TextEditingController(text: e.value),
       },
       labelController = TextEditingController(text: label),
       commandController = TextEditingController(text: command),
       timeoutController = TextEditingController(text: '$timeoutSeconds'),
       retriesController = TextEditingController(text: '$retries'),
       workingDirController = TextEditingController(text: workingDir),
       variables = {...?variables};

  /// A fresh draft of [type] with sensible defaults (a Wait defaults to 5s).
  factory StepDraft.ofType(WorkflowStepType type) => StepDraft(
    id: const Uuid().v4(),
    type: type,
    timeoutSeconds: type == WorkflowStepType.delay ? 5 : 30,
  );

  /// Rebuild a draft from a stored [WorkflowStep].
  factory StepDraft.fromStep(WorkflowStep step) => StepDraft(
    id: step.id,
    type: step.type,
    label: step.label ?? '',
    connectionId: step.connectionId,
    snippetName: step.snippetName,
    command: step.command ?? '',
    timeoutSeconds: step.timeoutSeconds,
    retries: step.retries,
    // Carry the FULL failure action (incl. Go-to-Step + its target) so an
    // untouched goto step survives an inline edit + save.
    onFailure: step.onFailure,
    gotoStepId: step.gotoStepId,
    workingDir: step.workingDir ?? '',
    runIfPrevious: step.runIfPrevious,
    disabled: step.disabled,
    variables: step.variables,
    targetIds: step.targetIds,
    targetGroupId: step.targetGroupId,
    targetAll: step.targetAll,
    commandsByOs: step.commandsByOs,
  );

  final String id;
  WorkflowStepType type;
  String? connectionId;
  String? snippetName;

  /// The hosts it runs on where it is many; [connectionId] where it is one.
  List<String> targetIds;

  /// The group it runs on, or all hosts: what those are when it runs.
  String? targetGroupId;
  bool targetAll;

  /// What a Command step runs on another system, by [WorkflowOsFamily]'s name.
  final Map<String, TextEditingController> altCommands;

  /// Optional user-typed step title. Empty → the collapsed row shows a derived
  /// title (see [stepDerivedTitle]).
  final TextEditingController labelController;

  /// Command text (Command steps) or the message (Notify steps).
  final TextEditingController commandController;

  /// Also serves as the Wait step's duration-in-seconds field.
  final TextEditingController timeoutController;
  final TextEditingController retriesController;
  final TextEditingController workingDirController;

  StepFailureAction onFailure;

  /// Target step id when [onFailure] is [StepFailureAction.gotoStep]. Carried
  /// through inline edits so saving a "Go to Step" workflow preserves its
  /// branch target instead of silently dropping it and reverting to abort.
  String? gotoStepId;

  /// UI toggle view over [onFailure] (continue-on-error vs abort). Reading an
  /// untouched gotoStep leaves its target intact; toggling the switch resolves
  /// to continue/abort and clears the goto target (the inline editor has no
  /// goto UI of its own).
  bool get continueOnError => onFailure == StepFailureAction.continueNext;
  set continueOnError(bool v) {
    onFailure = v ? StepFailureAction.continueNext : StepFailureAction.abort;
    gotoStepId = null;
  }

  bool runIfPrevious;
  bool disabled;

  /// Snippet variable values, keyed by [ParsedVariable.key].
  final Map<String, String> variables;

  int get _timeout =>
      int.tryParse(timeoutController.text.trim()) ??
      (type == WorkflowStepType.delay ? 5 : 30);
  int get _retries => int.tryParse(retriesController.text.trim()) ?? 0;

  String get _command => commandController.text.trim();
  String get _workingDir => workingDirController.text.trim();

  /// Bake into the immutable persistence model.
  WorkflowStep toStep() {
    final label = labelController.text.trim();
    return WorkflowStep(
      id: id,
      type: type,
      label: label.isEmpty ? null : label,
      connectionId: stepUsesTarget(type) && !targetAll && targetGroupId == null && targetIds.isEmpty ? connectionId : null,
      targetIds: stepUsesTarget(type) ? List<String>.of(targetIds) : const [],
      targetGroupId: stepUsesTarget(type) ? targetGroupId : null,
      targetAll: stepUsesTarget(type) && targetAll,
      commandsByOs: type == WorkflowStepType.execute
          ? {
              for (final e in altCommands.entries)
                if (e.value.text.trim().isNotEmpty) e.key: e.value.text,
            }
          : const {},
      command:
          (type == WorkflowStepType.execute || type == WorkflowStepType.notify)
          ? (_command.isEmpty ? null : commandController.text)
          : null,
      snippetName: type == WorkflowStepType.snippet ? snippetName : null,
      timeoutSeconds: _timeout,
      onFailure: onFailure,
      gotoStepId: onFailure == StepFailureAction.gotoStep ? gotoStepId : null,
      variables: type == WorkflowStepType.snippet
          ? Map<String, String>.from(variables)
          : const {},
      retries: _retries,
      workingDir: _workingDir.isEmpty ? null : _workingDir,
      runIfPrevious: runIfPrevious,
      disabled: disabled,
    );
  }

  void dispose() {
    labelController.dispose();
    commandController.dispose();
    timeoutController.dispose();
    retriesController.dispose();
    workingDirController.dispose();
    for (final c in altCommands.values) {
      c.dispose();
    }
  }
}

// ══════════════════════════════════════════════════════════════════
// Controller
// ══════════════════════════════════════════════════════════════════

/// Editor state + dirty guard for the 1.7 Automation detail pane.
///
/// A repository-free [ChangeNotifier] (the Networks pattern): it owns the
/// working draft, the dirty flag, and which card is expanded, but performs no
/// database I/O - the screen loads/saves through [WorkflowNotifier] and calls
/// [bind] / [markSaved]. Keeping persistence out makes the invariants
/// unit-testable without a database.
class WorkflowEditController extends ChangeNotifier {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();

  bool notifyOnFailure = true;
  bool notifyOnSuccess = false;

  /// When it runs: true, also from outside the app (a link, another app, a
  /// phone's schedule, with an API key); false, only when run here. It is
  /// the workflow's on/off ([Workflow.enabled]), which the engine holds runs
  /// from outside to.
  bool runsFromOutside = true;

  /// Whether the draft was opened from a template (the editor says so).
  bool fromTemplate = false;


  final List<StepDraft> steps = [];

  Workflow? _original;
  Workflow? get original => _original;
  bool get isCreating => _original == null;

  bool _dirty = false;
  bool get isDirty => _dirty;

  String? _expandedStepId;
  String? get expandedStepId => _expandedStepId;

  String? nameError;

  // ── Load / reset ───────────────────────────────────────────────

  /// Point the editor at [workflow] (null = creating a new one). Resets dirty.
  void bind(Workflow? workflow) {
    _disposeSteps();
    _original = workflow;
    nameController.text = workflow?.name ?? '';
    descriptionController.text = workflow?.description ?? '';
    notifyOnFailure = workflow?.notifyOnFailure ?? true;
    notifyOnSuccess = workflow?.notifyOnSuccess ?? false;
    runsFromOutside = workflow?.enabled ?? true;
    fromTemplate = false;
    steps
      ..clear()
      ..addAll((workflow?.steps ?? const []).map(StepDraft.fromStep));
    _expandedStepId = null;
    nameError = null;
    _dirty = false;
    notifyListeners();
  }

  /// Open [draft] as a NEW workflow filled in (a template): nothing is saved
  /// until Save, and it is dirty from the start.
  void bindTemplate(Workflow draft) {
    bind(draft);
    _original = null;
    fromTemplate = true;
    _dirty = true;
    notifyListeners();
  }

  /// After a successful save, rebind to the persisted [workflow] (so the "New"
  /// title flips to the name and dirty clears) without rebuilding controllers.
  void markSaved(Workflow workflow) {
    _original = workflow;
    fromTemplate = false;
    _dirty = false;
    nameError = null;
    notifyListeners();
  }

  // ── Dirty ──────────────────────────────────────────────────────

  /// Mark the draft dirty AND notify. Always notifies (even when already
  /// dirty) so live artifacts - the collapsed card preview, the step count -
  /// refresh as the user types.
  void markDirty() {
    _dirty = true;
    notifyListeners();
  }

  void setNotifyOnFailure(bool value) {
    notifyOnFailure = value;
    markDirty();
  }

  void setNotifyOnSuccess(bool value) {
    notifyOnSuccess = value;
    markDirty();
  }

  void setRunsFromOutside(bool value) {
    runsFromOutside = value;
    markDirty();
  }

  // ── Expansion (single card open at a time) ─────────────────────

  void toggleExpanded(String stepId) {
    _expandedStepId = _expandedStepId == stepId ? null : stepId;
    notifyListeners();
  }

  void collapseAll() {
    if (_expandedStepId != null) {
      _expandedStepId = null;
      notifyListeners();
    }
  }

  bool isExpanded(String stepId) => _expandedStepId == stepId;

  // ── Step edits ─────────────────────────────────────────────────

  /// Add a step of [type] at [index] (default: end), open it for editing, and
  /// mark dirty. Returns the created draft.
  StepDraft addStep({
    WorkflowStepType type = WorkflowStepType.execute,
    int? index,
  }) {
    final draft = StepDraft.ofType(type);
    final at = (index == null || index > steps.length) ? steps.length : index;
    steps.insert(at < 0 ? 0 : at, draft);
    _expandedStepId = draft.id;
    markDirty();
    return draft;
  }

  void removeStep(StepDraft draft) {
    if (steps.remove(draft)) {
      if (_expandedStepId == draft.id) _expandedStepId = null;
      draft.dispose();
      markDirty();
    }
  }

  /// Duplicate [draft] directly beneath it. The copy is collapsed.
  StepDraft duplicateStep(StepDraft draft) {
    final copy = StepDraft.fromStep(
      draft.toStep().copyWith(id: const Uuid().v4()),
    );
    final at = steps.indexOf(draft);
    steps.insert(at < 0 ? steps.length : at + 1, copy);
    markDirty();
    return copy;
  }

  void toggleDisabled(StepDraft draft) {
    draft.disabled = !draft.disabled;
    markDirty();
  }

  void setStepType(StepDraft draft, WorkflowStepType type) {
    if (draft.type == type) return;
    draft.type = type;
    markDirty();
  }

  void setStepConnection(StepDraft draft, String? connectionId) {
    draft.connectionId = connectionId;
    draft.targetIds = [];
    draft.targetGroupId = null;
    draft.targetAll = false;
    markDirty();
  }

  /// What [draft] runs on: [hosts] (one, or many), a group, or all hosts.
  void setStepTargets(StepDraft draft, {List<String> hosts = const [], String? groupId, bool all = false}) {
    draft.connectionId = hosts.length == 1 ? hosts.single : null;
    draft.targetIds = hosts.length > 1 ? List<String>.of(hosts) : [];
    draft.targetGroupId = groupId;
    draft.targetAll = all;
    markDirty();
  }

  /// [draft] gets a command of its own for [family] (the one it has, to start
  /// from).
  void addAltCommand(StepDraft draft, WorkflowOsFamily family) {
    draft.altCommands[family.name] ??= TextEditingController(text: draft.commandController.text);
    markDirty();
  }

  void removeAltCommand(StepDraft draft, WorkflowOsFamily family) {
    draft.altCommands.remove(family.name)?.dispose();
    markDirty();
  }

  /// Select a snippet for a snippet step. [variableKeys] are the placeholder
  /// keys parsed from the snippet body; values not in the new set are dropped
  /// so a re-pick never carries stale variables.
  void setStepSnippet(
    StepDraft draft,
    String snippetName,
    List<String> variableKeys,
  ) {
    draft.snippetName = snippetName;
    draft.variables.removeWhere((k, _) => !variableKeys.contains(k));
    markDirty();
  }

  void setStepVariable(StepDraft draft, String key, String value) {
    draft.variables[key] = value;
    markDirty();
  }

  void setContinueOnError(StepDraft draft, bool value) {
    draft.continueOnError = value;
    markDirty();
  }

  void setRunIfPrevious(StepDraft draft, bool value) {
    draft.runIfPrevious = value;
    markDirty();
  }

  void reorderSteps(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final draft = steps.removeAt(oldIndex);
    steps.insert(newIndex, draft);
    markDirty();
  }

  // ── Build / validate ───────────────────────────────────────────

  /// Assemble the full persistence model (INCLUDING disabled steps, which are
  /// preserved in storage).
  Workflow buildWorkflow(String id) {
    final desc = descriptionController.text.trim();
    return Workflow(
      id: id,
      name: nameController.text.trim(),
      description: desc.isEmpty ? null : desc,
      steps: steps.map((d) => d.toStep()).toList(growable: false),
      // Nothing runs a schedule, and nothing sets one now (found while
      // comparing the five versions): one an earlier version set
      // is kept as it was.
      scheduleExpression: _original?.scheduleExpression,
      enabled: runsFromOutside,
      createdAt: _original?.createdAt ?? DateTime.now(),
      lastRunAt: _original?.lastRunAt,
      notifyOnFailure: notifyOnFailure,
      notifyOnSuccess: notifyOnSuccess,
    );
  }

  /// The workflow the engine actually runs: like [buildWorkflow] but with
  /// disabled steps dropped, so "Disable" is honoured without touching the
  /// engine.
  Workflow buildRunnable(String id) {
    final full = buildWorkflow(id);
    return full.copyWith(
      steps: full.steps.where((s) => !s.disabled).toList(growable: false),
    );
  }

  String? validateName(AppLocalizations l10n) {
    final name = nameController.text.trim();
    if (name.isEmpty) return l10n.zestAutoFieldName;
    return null;
  }

  void setNameError(String? error) {
    nameError = error;
    notifyListeners();
  }

  // ── Discard guard (shared 1.7 pattern) ─────────────────────────

  /// Returns true to PROCEED, false to ABORT. On "Save" it runs [onSave] and
  /// proceeds only if the save succeeded.
  Future<bool> confirmDiscardIfDirty(
    BuildContext context, {
    required Future<bool> Function() onSave,
  }) async {
    if (!_dirty) return true;
    final choice = await showZestDiscardDialog(context);
    switch (choice) {
      case DiscardChoice.cancel:
        return false;
      case DiscardChoice.discard:
        return true;
      case DiscardChoice.save:
        return onSave();
    }
  }

  // ── Disposal ───────────────────────────────────────────────────

  void _disposeSteps() {
    for (final s in steps) {
      s.dispose();
    }
  }

  @override
  void dispose() {
    _disposeSteps();
    nameController.dispose();
    descriptionController.dispose();
    super.dispose();
  }
}
