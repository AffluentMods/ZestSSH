import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/workflow.dart';
import '../../../providers/purchase_providers.dart';
import '../../../providers/workflow_provider.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/edit_drafts.dart';
import '../../../ui/widgets/top_snackbar.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../../../ui/widgets/zest_master_detail.dart';
import '../../../utils/line_breaks.dart';
import '../../../providers/connection_providers.dart';
import '../../../providers/snippet_providers.dart';
import '../../snippets/save_snippet.dart';
import '../automation_tab.dart';
import '../state/workflow_edit_controller.dart';
import '../state/workflow_run_controller.dart';
import '../state/workflow_run_status.dart';
import '../workflow_run_gate.dart';
import '../widgets/step_targets_dialog.dart';
import '../widgets/workflow_detail_pane.dart';
import '../widgets/workflow_list_pane.dart';
import '../workflow_templates.dart';

/// Sentinel selection id used while creating a brand-new workflow.
const String _kNewSelection = '__new__';

/// A workflow's editor with unsaved edits, kept while its page is away, and
/// the template it was opened from (if it was).
typedef WorkflowKeptEdit = ({WorkflowEditController editor, WorkflowTemplate? template});

/// The Automation workflows editor's unsaved edits while its page is away
/// ([EditDrafts]): the editor itself, kept as it was, by the workflow's id
/// (or the new workflow's key). A workflow holds nothing secret. A kept
/// editor that is let go is disposed; a run that was going is not kept.
final workflowDraftsProvider = editDraftsProvider<WorkflowKeptEdit>(onForget: (k) => k.editor.dispose());

/// The 1.7 desktop Automation workflows screen - a [ZestMasterDetail] with the
/// workflow list on the left and the inline-editing detail pane on the right.
/// Follows the Networks reference: all editor state + the dirty guard live in
/// one [WorkflowEditController]; this screen owns selection + the workflow
/// repository I/O the controller deliberately avoids, plus the "Run now" wiring
/// to the existing [WorkflowService].
class AutomationWorkflowsView extends ConsumerStatefulWidget {
  const AutomationWorkflowsView({super.key});

  @override
  ConsumerState<AutomationWorkflowsView> createState() =>
      _AutomationWorkflowsViewState();
}

/// The id a run goes by: a draft's, until the draft is saved during the run.
class _RanAs {
  _RanAs(this.id);
  String id;
}

class _AutomationWorkflowsViewState
    extends ConsumerState<AutomationWorkflowsView>
    with KeepsEditDrafts<AutomationWorkflowsView, WorkflowKeptEdit> {
  late final WorkflowEditController _controller;
  late final WorkflowRunController _runController;

  /// null = nothing open; [_kNewSelection] = creating; else the workflow id.
  String? _selectedId;

  /// The template open in the editor, while it is (the empty page outlines
  /// its card).
  WorkflowTemplate? _templateInUse;

  /// Whether the page is one column (the editor a route of its own).
  bool _narrow = false;

  /// What the run last started goes by.
  _RanAs? _ranAs;

  @override
  void initState() {
    super.initState();
    _runController = WorkflowRunController();
    // Unsaved edits kept as the page went (a terminal was shown in its
    // place): the same editor comes back, with them, as unsaved. A change of
    // profile builds the drafts anew, empty, and the form open here goes.
    final kept = takeEditDraft(workflowDraftsProvider, onRenewed: () {
      _bind(null);
      _runController.reset();
      setState(() {
        _selectedId = _kNewSelection;
        _templateInUse = null;
      });
    });
    _controller = kept?.editor ?? WorkflowEditController();
    if (kept != null) {
      _selectedId = kept.editor.original?.id ?? _kNewSelection;
      _templateInUse = kept.template;
    } else {
      // The detail pane always shows the editor, so start on a blank NEW
      // workflow - the right side is ready to fill out by default (no empty
      // state).
      _bind(null);
      _selectedId = _kNewSelection;
    }
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Going with unsaved edits (the shell shows a terminal in this page's
    // place): the editor is kept, in memory, for when the page comes back.
    final kept = _controller.isDirty &&
        keepEditDraft(_controller.original?.id ?? _kNewSelection, (editor: _controller, template: _templateInUse));
    if (!kept) _controller.dispose();
    _runController.dispose();
    super.dispose();
  }

  bool get _hasSelection => _selectedId != null;

  /// Bind the editor to [wf].
  void _bind(Workflow? wf) => _controller.bind(wf);

  // ── Selection / creation (all run the discard guard first) ─────────

  /// Whether what is about to open may stop the run going: its person says so,
  /// while there is one. Opening another workflow stopped it with no word, and
  /// its panel went with it (found in an independent review).
  Future<bool> _mayStopTheRun() async {
    if (!_runController.isRunning) return true;
    final l10n = AppLocalizations.of(context)!;
    final stop = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.wfStopRunTitle,
      body: l10n.wfStopRunBody,
      confirmLabel: l10n.wfStopRunAction,
    );
    return stop == true;
  }

  Future<void> _select(String id, {required bool narrow}) async {
    if (_selectedId == id) {
      // In one column it is open behind the list, after Back: open it again.
      if (narrow) await _pushDetailRoute();
      return;
    }
    if (!await _mayStopTheRun() || !mounted) return;
    final proceed = await _controller.confirmDiscardIfDirty(
      context,
      onSave: _save,
    );
    if (!proceed || !mounted) return;
    final wf = _find(id);
    if (wf == null) return;
    _bind(wf);
    _runController.reset();
    setState(() => _selectedId = id);
    if (narrow && mounted) await _pushDetailRoute();
  }

  Future<void> _createNew({required bool narrow}) async {
    if (!await _mayStopTheRun() || !mounted) return;
    final proceed = await _controller.confirmDiscardIfDirty(
      context,
      onSave: _save,
    );
    if (!proceed || !mounted) return;
    _bind(null);
    _runController.reset();
    setState(() {
      _selectedId = _kNewSelection;
      _templateInUse = null;
    });
    if (narrow && mounted) await _pushDetailRoute();
  }

  /// Open [template] in the editor, filled in from the person's own hosts
  /// and groups, unsaved. A snippet it runs that the person does not have is
  /// added to their snippets once they say so (and without it nothing opens).
  Future<void> _useTemplate(WorkflowTemplate template, {required bool narrow}) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await _mayStopTheRun() || !mounted) return;
    final proceed = await _controller.confirmDiscardIfDirty(context, onSave: _save);
    if (!proceed || !mounted) return;
    final snippets = await ref.read(snippetsProvider.future);
    final groups = await ref.read(connectionGroupsProvider.future);
    final hosts = [for (final c in await ref.read(connectionsWithDetailsProvider.future)) c.connection];
    if (!mounted) return;
    final needed = template.snippet(l10n);
    var snippetLabel = needed?.label;
    if (needed != null) {
      final have = snippetNamed(snippets, needed.label);
      if (have != null) {
        snippetLabel = have.label;
      } else {
        // The words over the command keep their last two on one line ("as:"
        // was alone on a line); the
        // command under them, on its own line in every language, as it is.
        final body = l10n.autoTplAddSnippetBody(needed.command);
        final commandLine = body.lastIndexOf('\n');
        final add = await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.info,
          title: l10n.autoTplAddSnippetTitle(needed.label),
          body: commandLine < 0 ? body : noOrphan(body.substring(0, commandLine)) + body.substring(commandLine),
          confirmLabel: l10n.autoTplAddSnippetAction,
        );
        if (add != true || !mounted) return;
        final crud = ref.read(snippetCrudProvider);
        final added = await saveSnippetSaying(
          context,
          name: needed.label,
          added: true,
          write: () => crud.create(label: needed.label, command: needed.command),
        );
        if (!added || !mounted) return;
      }
    }
    final draft = buildTemplateWorkflow(template, l10n, groups: groups, connections: hosts, snippetLabel: snippetLabel);
    _controller.bindTemplate(draft);
    _runController.reset();
    setState(() {
      _selectedId = _kNewSelection;
      _templateInUse = template;
    });
    if (narrow && mounted) await _pushDetailRoute();
  }

  Future<void> _close() async {
    if (!await _mayStopTheRun() || !mounted) return;
    final proceed = await _controller.confirmDiscardIfDirty(
      context,
      onSave: _save,
    );
    if (!proceed || !mounted) return;
    // Reset to a blank new workflow rather than an empty pane.
    _bind(null);
    _runController.reset();
    setState(() => _selectedId = _kNewSelection);
  }

  Workflow? _find(String id) {
    for (final w in ref.read(workflowsProvider)) {
      if (w.id == id) return w;
    }
    return null;
  }

  // ── Persistence ────────────────────────────────────────────────────

  Future<bool> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final nameErr = _controller.validateName(l10n);
    if (nameErr != null) {
      _controller.setNameError(nameErr);
      return false;
    }

    final notifier = ref.read(workflowsProvider.notifier);
    final creating = _controller.isCreating;
    final id = _controller.original?.id ?? Workflow.create(name: '').id;
    final workflow = _controller.buildWorkflow(id);
    try {
      if (creating) {
        await notifier.addWorkflow(workflow);
      } else {
        await notifier.updateWorkflow(workflow);
      }
    } catch (e) {
      if (mounted) showTopSnackBar(context, l10n.workflowNotSaved, isError: true, details: '$e');
      return false;
    }
    _controller.markSaved(workflow);
    // A draft saved during its own run: the run is of the workflow now.
    if (creating && _runController.workflowId == kWorkflowDraftRunId) {
      _runController.draftSavedAs(workflow.id);
      _ranAs?.id = workflow.id;
    }
    if (mounted) {
      setState(() {
        _selectedId = workflow.id;
        _templateInUse = null;
      });
    }
    return true;
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final wf = _controller.original;
    if (wf == null) return;
    if (!await _mayStopTheRun() || !mounted) return;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.workflowListDeleteTitle,
      body: l10n.workflowListDeleteMessage,
      confirmLabel: l10n.delete,
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(workflowsProvider.notifier).deleteWorkflow(wf.id);
    } catch (e) {
      if (mounted) showTopSnackBar(context, l10n.workflowNotDeleted, isError: true, details: '$e');
      return;
    }
    if (!mounted) return;
    // Reset to a blank new workflow so the deleted workflow's now-stale draft
    // can't later prompt a spurious "save?".
    _bind(null);
    _runController.reset();
    setState(() => _selectedId = _kNewSelection);
  }

  // ── Run now (drives the EXISTING WorkflowService, streams to the drawer) ──

  Future<void> _run({List<String>? onHosts}) async {
    final l10n = AppLocalizations.of(context)!;
    final id = _controller.original?.id ?? kWorkflowDraftRunId;
    var runnable = _controller.buildRunnable(id);
    // Run on…: the hosts picked take the place of what its steps run on.
    if (onHosts != null) {
      runnable = runnable.copyWith(steps: [
        for (final s in runnable.steps) s.usesHosts ? s.onHosts(onHosts) : s,
      ]);
    }

    final refused = workflowRunRefusal(ref.read, l10n);
    if (refused != null) {
      _runController.reportBlocked(runnable, refused);
      return;
    }
    final isPro = ref.read(isProProvider);
    if (!isPro) {
      _runController.reportBlocked(
        runnable,
        l10n.autoGuideTroubleSqueezedFix,
      );
      return;
    }
    if (runnable.steps.isEmpty) {
      _runController.reportBlocked(
        runnable,
        l10n.workflowNeedsStep,
      );
      return;
    }

    // Its variables, and its risky commands: asked before anything runs.
    final ready = await workflowReadyToRun(context, runnable);
    if (ready == null || !mounted) return;

    final service = ref.read(workflowServiceProvider);
    final ran = _ranAs = _RanAs(id);
    final result = await _runController.run(service, ready);
    if (!mounted) return;

    // Record the session summary that drives the list-row status pill…
    ref
        .read(workflowLastRunProvider.notifier)
        .update((m) => {...m, ran.id: WorkflowRunSummary.fromResult(result)});
    // …and persist last-run time for saved workflows (fallback after restart):
    // of the one that ran, whichever is open by now, and under its id if it was
    // saved while it ran.
    await ref.read(workflowsProvider.notifier).markRan(ran.id, DateTime.now());
  }

  /// Run on…: the hosts asked for, and then a run on them.
  Future<void> _runOn() async {
    // Without the plan, or in a team's space, a run says so at once: no hosts
    // to pick for nothing.
    if (!ref.read(isProProvider) || workflowRunRefusal(ref.read, AppLocalizations.of(context)!) != null) {
      return _run();
    }
    final hosts = await showWorkflowRunOn(context, workflowName: _controller.nameController.text.trim());
    if (hosts == null || hosts.isEmpty || !mounted) return;
    await _run(onHosts: hosts);
  }

  // ── Narrow single-column route ─────────────────────────────────────

  Future<void> _pushDetailRoute() {
    return ZestMasterDetail.pushDetail<void>(
      context,
      ListenableBuilder(
        listenable: _controller,
        builder: (routeContext, _) => PopScope<void>(
          canPop: !_controller.isDirty,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final proceed = await _controller.confirmDiscardIfDirty(
              routeContext,
              onSave: _save,
            );
            if (proceed && routeContext.mounted) {
              Navigator.of(routeContext).pop();
            }
          },
          child: WorkflowDetailPane(
            controller: _controller,
            runController: _runController,
            hasSelection: true,
            onNew: () => _createNew(narrow: false),
            onSave: _save,
            onRun: _run,
            onRunOn: _runOn,
            onClose: () async {
              final proceed = await _controller.confirmDiscardIfDirty(
                routeContext,
                onSave: _save,
              );
              if (proceed && routeContext.mounted) {
                Navigator.of(routeContext).pop();
              }
            },
            onDelete: () async {
              await _delete();
              if (_selectedId == null && routeContext.mounted) {
                Navigator.of(routeContext).pop();
              }
            },
          ),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _reconcileSelection();
    // The page head's New workflow.
    ref.listen<int>(automationNewWorkflowProvider, (_, _) => _createNew(narrow: _narrow));
    // The redundant ZestPageHeader ("Automation" + "N workflows, M scheduled")
    // was removed here: the outer AutomationView already renders the
    // "Automation" title, engine toggle and tab bar, so a second big title was
    // wasted vertical space. The workflow/scheduled count now surfaces as a
    // muted line under the list-pane search (see WorkflowListPane).
    return ColoredBox(
      color: ZestTokens.surfaceBase,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow =
              constraints.maxWidth < ZestSizing.singleColumnBreakpoint;
          _narrow = narrow;
          return ZestMasterDetail(
            screenId: 'automation',
            // The list (the templates, when there is none) is the page; the
            // editor stands beside it.
            initialRatio: 0.56,
            listPane: WorkflowListPane(
              selectedId: _selectedId,
              onSelect: (id) => _select(id, narrow: narrow),
              onCreate: () => _createNew(narrow: narrow),
              onTemplate: (t) => _useTemplate(t, narrow: narrow),
              templateInUse: _templateInUse,
            ),
            detailPane: WorkflowDetailPane(
              controller: _controller,
              runController: _runController,
              hasSelection: _hasSelection,
              onNew: () => _createNew(narrow: narrow),
              onSave: _save,
              onRun: _run,
              onRunOn: _runOn,
              onClose: _close,
              onDelete: _delete,
            ),
          );
        },
      ),
    );
  }

  /// Drop the selection if the open, saved workflow no longer exists.
  void _reconcileSelection() {
    final id = _selectedId;
    if (id == null || id == _kNewSelection) return;
    final workflows = ref.watch(workflowsProvider);
    if (!workflows.any((w) => w.id == id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedId == id) {
          _bind(null);
          _runController.reset();
          setState(() => _selectedId = _kNewSelection);
        }
      });
    }
  }
}
