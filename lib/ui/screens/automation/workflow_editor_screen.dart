import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/widgets/step_targets_dialog.dart' show manyTargetsWords;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show noCommandReason;
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// Visual workflow builder for creating and editing automation workflows.
class WorkflowEditorScreen extends ConsumerStatefulWidget {
  /// Pass an existing [Workflow] via GoRouter `extra` to edit it.
  /// If null, creates a new workflow.
  final Workflow? workflow;

  /// When true, the editor renders without its own [Scaffold] /
  /// [AppBar] and uses [onClose] to signal "done" instead of calling
  /// `context.pop()`.  The desktop automation view embeds the editor
  /// directly in the content area so the sidebar + top chrome stay
  /// visible - that's only possible if the editor doesn't try to
  /// install its own window-level chrome.
  final bool embedded;

  /// Called when the editor wants to close itself.  [saved] is true
  /// when the user successfully hit Save (so the parent should
  /// refresh + return to the list view), false on Cancel / back.
  /// Required when [embedded] is true; ignored otherwise (the
  /// stand-alone editor uses [Navigator.pop]).
  final void Function(bool saved)? onClose;

  const WorkflowEditorScreen({
    super.key,
    this.workflow,
    this.embedded = false,
    this.onClose,
  });

  @override
  ConsumerState<WorkflowEditorScreen> createState() =>
      _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends ConsumerState<WorkflowEditorScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late List<WorkflowStep> _steps;
  bool _notifyOnFailure = true;
  bool _notifyOnSuccess = false;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    final wf = widget.workflow;
    _isEditing = wf != null;
    _nameController = TextEditingController(text: wf?.name ?? '');
    _descriptionController =
        TextEditingController(text: wf?.description ?? '');
    _steps = wf != null ? List.of(wf.steps) : [];
    _notifyOnFailure = wf?.notifyOnFailure ?? true;
    _notifyOnSuccess = wf?.notifyOnSuccess ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showTopSnackBar(context, l10n.wfEditNameRequired);
      return;
    }

    final notifier = ref.read(workflowsProvider.notifier);

    if (_isEditing) {
      final updated = widget.workflow!.copyWith(
        name: name,
        description: _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        steps: _steps,
        notifyOnFailure: _notifyOnFailure,
        notifyOnSuccess: _notifyOnSuccess,
      );
      await notifier.updateWorkflow(updated);
    } else {
      final workflow = Workflow.create(
        name: name,
        description: _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
      ).copyWith(
        steps: _steps,
        notifyOnFailure: _notifyOnFailure,
        notifyOnSuccess: _notifyOnSuccess,
      );
      await notifier.addWorkflow(workflow);
    }

    if (!mounted) return;
    if (widget.embedded) {
      widget.onClose?.call(true);
    } else {
      context.pop();
    }
  }

  /// Cancel / back handler - same dual-path as [_save] but reports
  /// `saved: false` so the embedded parent knows not to refresh.
  void _close() {
    if (widget.embedded) {
      widget.onClose?.call(false);
    } else {
      context.pop();
    }
  }

  void _addStep(WorkflowStepType type) {
    setState(() {
      _steps.add(WorkflowStep(
        id: const Uuid().v4(),
        type: type,
        timeoutSeconds: type == WorkflowStepType.delay ? 5 : 30,
      ));
    });
  }

  void _editStep(int index) {
    _showStepEditorDialog(index);
  }

  void _removeStep(int index) {
    setState(() {
      _steps.removeAt(index);
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final step = _steps.removeAt(oldIndex);
      _steps.insert(newIndex, step);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = _isEditing
        ? l10n.wfEditEditTitle(widget.workflow!.name)
        : l10n.wfEditNewTitle;

    // Centred max-width on wide screens so the form doesn't sprawl
    // across an ultra-wide automation panel.  Same pattern as the
    // connection edit dialog - keeps line lengths readable.
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final innerMax = 760.0;
        final pad = ((constraints.maxWidth - innerMax) / 2)
            .clamp(0.0, double.infinity);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              16 + pad, 16, 16 + pad, widget.embedded ? 24 : 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildFormBody(),
          ),
        );
      },
    );

    if (widget.embedded) {
      // Embedded: the parent (e.g. the desktop AutomationView) owns
      // the page chrome.  We render an inline header strip with a
      // back button + Save action and let the body fill the rest of
      // the space.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EmbeddedHeader(
            title: title,
            onBack: _close,
            onSave: _save,
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: AppColors.surface,
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              l10n.save,
              style: TextStyle(
                color: AppColors.accentInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: body,
    );
  }

  /// The form body, factored out so the embedded + standalone build
  /// paths can share it.
  List<Widget> _buildFormBody() {
    final l10n = AppLocalizations.of(context)!;
    return [
            // ── Name field ──
            TextField(
              controller: _nameController,
              style: TextStyle(color: AppColors.onSurface),
              decoration: InputDecoration(
                labelText: l10n.wfEditNameLabel,
                labelStyle: TextStyle(color: AppColors.onSurfaceDim),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.orange),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Description field ──
            TextField(
              controller: _descriptionController,
              style: TextStyle(color: AppColors.onSurface),
              maxLines: 2,
              decoration: InputDecoration(
                labelText: l10n.wfEditDescriptionLabel,
                labelStyle: TextStyle(color: AppColors.onSurfaceDim),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.orange),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Steps header ──
            Text(
              l10n.wfEditStepsHeader,
              style: TextStyle(
                color: AppColors.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),

            // ── Steps timeline ──
            if (_steps.isEmpty)
              _EmptyStepsHint(onAddStep: _showAddStepPicker)
            else
              _StepTimeline(
                steps: _steps,
                onReorder: _onReorder,
                onEdit: _editStep,
                onDelete: _removeStep,
                allSteps: _steps,
              ),

            const SizedBox(height: 12),

            // ── Add step button ──
            Center(
              child: OutlinedButton.icon(
                onPressed: _showAddStepPicker,
                icon: const Icon(LucideIcons.plus, size: 18),
                label: Text(l10n.wfEditAddStep),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentInk,
                  side: BorderSide(color: AppColors.orange),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),

            // ── Trigger URL card (saved workflows only) ──
            if (_isEditing) ...[
              Divider(color: AppColors.divider),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          LucideIcons.link,
                          size: 18,
                          color: AppColors.accentInk,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.wfEditTriggerExternally,
                          style: TextStyle(
                            color: AppColors.onSurface,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () {
                        final url =
                            'zestssh://workflow?name=${Uri.encodeComponent(widget.workflow!.name)}&key=YOUR_KEY';
                        Clipboard.setData(ClipboardData(text: url));
                        showTopSnackBar(
                          context,
                          l10n.wfEditUrlCopied,
                          duration: const Duration(seconds: 2),
                        );
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceDark,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          'zestssh://workflow?name=${Uri.encodeComponent(widget.workflow!.name)}&key=YOUR_KEY',
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11,
                            height: 1.5,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.wfEditTriggerHelp,
                      style: TextStyle(
                        color: AppColors.onSurfaceDim,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            Divider(color: AppColors.divider),
            const SizedBox(height: 12),

            // ── Notification toggles ──
            Text(
              l10n.wfEditNotifications,
              style: TextStyle(
                color: AppColors.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.wfEditNotifyOnFailure,
                style: TextStyle(color: AppColors.onSurface, fontSize: 14),
              ),
              value: _notifyOnFailure,
              onChanged: (v) => setState(() => _notifyOnFailure = v),
              activeThumbColor: AppColors.orange,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.wfEditNotifyOnSuccess,
                style: TextStyle(color: AppColors.onSurface, fontSize: 14),
              ),
              value: _notifyOnSuccess,
              onChanged: (v) => setState(() => _notifyOnSuccess = v),
              activeThumbColor: AppColors.orange,
            ),
    ];
  }

  // ── Add step type picker ──

  /// What kind of step to add: one of a few, the app's choice (3.4), a
  /// centred dialog on a computer and a sheet on a phone; the step's editor
  /// opens once it has closed. (A phone's was a sheet of its own.)
  void _showAddStepPicker() {
    final l10n = AppLocalizations.of(context)!;
    showZestChoice<WorkflowStepType>(
      context,
      title: l10n.wfEditAddStep,
      icon: LucideIcons.plus,
      choices: [
        for (final (type, icon, label, detail) in [
          (WorkflowStepType.execute, LucideIcons.terminal, l10n.wfEditOptExecuteLabel, l10n.wfEditOptExecuteSubtitle),
          (WorkflowStepType.snippet, LucideIcons.code, l10n.wfEditOptSnippetLabel, l10n.wfEditOptSnippetSubtitle),
          (WorkflowStepType.delay, LucideIcons.timer, l10n.wfEditOptDelayLabel, l10n.wfEditOptDelaySubtitle),
          (WorkflowStepType.notify, LucideIcons.bell, l10n.wfEditOptNotifyLabel, l10n.wfEditOptNotifySubtitle),
        ])
          ZestChoice(value: type, label: label, detail: detail, icon: icon, key: ValueKey('wf-add-step-${type.name}')),
      ],
    ).then((type) {
      if (type == null || !mounted) return;
      _addStep(type);
      _editStep(_steps.length - 1);
    });
  }

  // ── Step editor dialog ──

  void _showStepEditorDialog(int index) {
    showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: _StepEditorDialog(
        step: _steps[index],
        stepIndex: index,
        allSteps: _steps,
        onSave: (updatedStep) {
          setState(() {
            _steps[index] = updatedStep;
          });
        },
      ),
    );
  }
}

/// Inline header strip used when the workflow editor is embedded
/// inside the desktop AutomationView.  Mirrors the AppBar layout of
/// the standalone screen - back arrow on the left, title in the
/// middle, Save action on the right - but renders as a flat row so
/// it sits flush under the existing app chrome.
class _EmbeddedHeader extends StatelessWidget {
  const _EmbeddedHeader({
    required this.title,
    required this.onBack,
    required this.onSave,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.divider, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.wfEditBackToAutomations,
            icon: const Icon(LucideIcons.arrowLeft, size: 20),
            onPressed: onBack,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: AppColors.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: onSave,
            icon: const Icon(LucideIcons.check, size: 16),
            label: Text(l10n.save),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accentInk,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty steps hint ──────────────────────────────────────────────

class _EmptyStepsHint extends StatelessWidget {
  final VoidCallback onAddStep;

  const _EmptyStepsHint({required this.onAddStep});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InkWell(
      onTap: onAddStep,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          border: Border.all(
            color: AppColors.divider,
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(
              LucideIcons.plusCircle,
              size: 36,
              color: AppColors.onSurfaceDim.withAlpha(100),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.wfEditAddFirstStep,
              style: TextStyle(color: AppColors.onSurfaceDim, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Steps timeline (ReorderableListView) ─────────────────────────

class _StepTimeline extends StatelessWidget {
  final List<WorkflowStep> steps;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index) onEdit;
  final void Function(int index) onDelete;
  final List<WorkflowStep> allSteps;

  const _StepTimeline({
    required this.steps,
    required this.onReorder,
    required this.onEdit,
    required this.onDelete,
    required this.allSteps,
  });

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      onReorderItem: onReorder,
      proxyDecorator: (child, index, animation) {
        return Material(
          color: Colors.transparent,
          elevation: 4,
          shadowColor: AppColors.orange.withAlpha(60),
          child: child,
        );
      },
      itemCount: steps.length,
      itemBuilder: (context, index) {
        final step = steps[index];
        final isLast = index == steps.length - 1;

        return _TimelineStepCard(
          key: ValueKey(step.id),
          step: step,
          stepNumber: index + 1,
          isLast: isLast,
          onEdit: () => onEdit(index),
          onDelete: () => onDelete(index),
        );
      },
    );
  }
}

// ── Single timeline step card ─────────────────────────────────────

class _TimelineStepCard extends StatelessWidget {
  final WorkflowStep step;
  final int stepNumber;
  final bool isLast;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TimelineStepCard({
    super.key,
    required this.step,
    required this.stepNumber,
    required this.isLast,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Timeline line + dot ──
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stepColor(step.type).withAlpha(30),
                    border: Border.all(
                      color: _stepColor(step.type),
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      '$stepNumber',
                      style: TextStyle(
                        color: _stepColor(step.type),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: AppColors.divider,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // ── Step card ──
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.divider),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _stepIcon(step.type),
                          size: 16,
                          color: _stepColor(step.type),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            step.type.nameIn(l10n),
                            style: TextStyle(
                              color: AppColors.onSurface,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // Edit button
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: IconButton(
                            tooltip: AppLocalizations.of(context)!.edit,
                            onPressed: onEdit,
                            icon: const Icon(LucideIcons.pencil, size: 15),
                            color: AppColors.onSurfaceDim,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        // Delete button
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: IconButton(
                            tooltip: AppLocalizations.of(context)!.delete,
                            onPressed: onDelete,
                            icon: const Icon(LucideIcons.x, size: 15),
                            color: AppColors.error,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        // Drag handle
                        ReorderableDragStartListener(
                          index: stepNumber - 1,
                          child: Icon(
                            LucideIcons.gripHorizontal,
                            size: 18,
                            color: AppColors.onSurfaceDim,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Command preview
                    Text(
                      step.displaySummary,
                      style: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12,
                        fontFamily: 'JetBrainsMono',
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    // Failure action badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _failureActionColor(step.onFailure)
                            .withAlpha(20),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        l10n.wfEditOnFailBadge(step.onFailure.nameIn(l10n)),
                        style: TextStyle(
                          color: _failureActionColor(step.onFailure),
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _stepIcon(WorkflowStepType type) {
    switch (type) {
      case WorkflowStepType.execute:
        return LucideIcons.terminal;
      case WorkflowStepType.snippet:
        return LucideIcons.code;
      case WorkflowStepType.delay:
        return LucideIcons.timer;
      case WorkflowStepType.notify:
        return LucideIcons.bell;
    }
  }

  static Color _stepColor(WorkflowStepType type) {
    switch (type) {
      case WorkflowStepType.execute:
        return AppColors.orange;
      case WorkflowStepType.snippet:
        return AppColors.cloudSync;
      case WorkflowStepType.delay:
        return AppColors.warning;
      case WorkflowStepType.notify:
        return AppColors.success;
    }
  }

  static Color _failureActionColor(StepFailureAction action) {
    switch (action) {
      case StepFailureAction.abort:
        return AppColors.error;
      case StepFailureAction.continueNext:
        return AppColors.warning;
      case StepFailureAction.gotoStep:
        return AppColors.cloudSync;
    }
  }
}

// ── Step editor dialog ───────────────────────────────────────────

class _StepEditorDialog extends ConsumerStatefulWidget {
  final WorkflowStep step;
  final int stepIndex;
  final List<WorkflowStep> allSteps;
  final void Function(WorkflowStep updatedStep) onSave;

  const _StepEditorDialog({
    required this.step,
    required this.stepIndex,
    required this.allSteps,
    required this.onSave,
  });

  @override
  ConsumerState<_StepEditorDialog> createState() => _StepEditorDialogState();
}

class _StepEditorDialogState extends ConsumerState<_StepEditorDialog> {
  late WorkflowStepType _type;
  late TextEditingController _commandController;
  late TextEditingController _messageController;
  String? _selectedConnectionId;
  String? _selectedSnippetName;
  late double _timeoutSeconds;
  late StepFailureAction _failureAction;
  String? _gotoStepId;

  @override
  void initState() {
    super.initState();
    _type = widget.step.type;
    _commandController =
        TextEditingController(text: widget.step.command ?? '');
    _messageController = TextEditingController(
      text: widget.step.type == WorkflowStepType.notify
          ? (widget.step.command ?? '')
          : '',
    );
    _selectedConnectionId = widget.step.connectionId;
    _selectedSnippetName = widget.step.snippetName;
    _timeoutSeconds = widget.step.timeoutSeconds.toDouble();
    _failureAction = widget.step.onFailure;
    _gotoStepId = widget.step.gotoStepId;
  }

  @override
  void dispose() {
    _commandController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _saveStep() {
    // Another host picked: the step runs on that one now. (Its many targets
    // stayed, so a step saved on one host still ran on every host.)
    final picked = _selectedConnectionId;
    final base = picked != null && picked != widget.step.connectionId ? widget.step.onHosts([picked]) : widget.step;
    final updated = base.copyWith(
      type: _type,
      connectionId: _selectedConnectionId,
      command: _type == WorkflowStepType.notify
          ? _messageController.text
          : _commandController.text,
      snippetName: _selectedSnippetName,
      timeoutSeconds: _timeoutSeconds.round(),
      onFailure: _failureAction,
      gotoStepId: _failureAction == StepFailureAction.gotoStep
          ? _gotoStepId
          : null,
    );
    widget.onSave(updated);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(filteredConnectionsProvider);
    final snippetsAsync = ref.watch(snippetsProvider);
    // A step made on a computer, with many targets, says what it runs on while
    // no one host is picked in its place.
    final step = widget.step;
    final many = _selectedConnectionId == step.connectionId
        ? manyTargetsWords(l10n, ref, all: step.targetAll, groupId: step.targetGroupId, hosts: step.targetIds)
        : null;

    // The app's dialog (3.4): Cancel and Save in its footer.
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.listOrdered,
      title: l10n.wfEditStepNumber(widget.stepIndex + 1),
      maxWidth: DesktopDimensions.dialogMinWidth + 44,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Type selector ──
          SegmentedButton<WorkflowStepType>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: WorkflowStepType.execute,
                icon: const Icon(LucideIcons.terminal, size: 18),
                label: Text(l10n.wfEditSegCmd,
                    style: const TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: WorkflowStepType.snippet,
                icon: const Icon(LucideIcons.code, size: 18),
                label: Text(l10n.wfEditSegSnip,
                    style: const TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: WorkflowStepType.delay,
                icon: const Icon(LucideIcons.timer, size: 18),
                label: Text(l10n.wfEditSegWait,
                    style: const TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: WorkflowStepType.notify,
                icon: const Icon(LucideIcons.bell, size: 18),
                label: Text(l10n.wfEditSegAlert,
                    style: const TextStyle(fontSize: 11)),
              ),
            ],
            selected: {_type},
            onSelectionChanged: (selected) {
              setState(() => _type = selected.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return Colors.white;
                }
                return AppColors.onSurfaceDim;
              }),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return AppColors.orange;
                }
                return AppColors.surfaceLight;
              }),
            ),
          ),
          const SizedBox(height: 16),

          // ── Type-specific fields ──
          if (_type == WorkflowStepType.execute) ...[
            // Connection picker
            _ConnectionPicker(
              connectionsAsync: connectionsAsync,
              selectedId: _selectedConnectionId,
              manyTargets: many,
              onChanged: (id) =>
                  setState(() => _selectedConnectionId = id),
            ),
            const SizedBox(height: 12),
            // Command field
            TextField(
              controller: _commandController,
              style: TextStyle(
                color: AppColors.onSurface,
                fontFamily: 'JetBrainsMono',
                fontSize: 13,
              ),
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l10n.wfEditCommandLabel,
                labelStyle: TextStyle(color: AppColors.onSurfaceDim),
                hintText: l10n.wfEditCommandHint,
                hintStyle: TextStyle(color: AppColors.onSurfaceDim),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.orange),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Timeout slider
            _TimeoutSlider(
              value: _timeoutSeconds,
              onChanged: (v) => setState(() => _timeoutSeconds = v),
            ),
          ],

          if (_type == WorkflowStepType.snippet) ...[
            // Connection picker
            _ConnectionPicker(
              connectionsAsync: connectionsAsync,
              selectedId: _selectedConnectionId,
              manyTargets: many,
              onChanged: (id) =>
                  setState(() => _selectedConnectionId = id),
            ),
            const SizedBox(height: 12),
            // Snippet picker
            _SnippetPicker(
              snippetsAsync: snippetsAsync,
              selectedName: _selectedSnippetName,
              onChanged: (name) =>
                  setState(() => _selectedSnippetName = name),
            ),
          ],

          if (_type == WorkflowStepType.delay) ...[
            // Duration picker (reuse timeout slider)
            Text(
              l10n.wfEditWaitDuration,
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            _TimeoutSlider(
              value: _timeoutSeconds,
              max: 300,
              onChanged: (v) => setState(() => _timeoutSeconds = v),
            ),
          ],

          if (_type == WorkflowStepType.notify) ...[
            TextField(
              controller: _messageController,
              style: TextStyle(
                color: AppColors.onSurface,
                fontSize: 13,
              ),
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l10n.wfEditNotificationMessageLabel,
                labelStyle: TextStyle(color: AppColors.onSurfaceDim),
                hintText: l10n.wfEditNotificationHint('{{output}}'),
                hintStyle: TextStyle(
                  color: AppColors.onSurfaceDim,
                  fontSize: 12,
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.orange),
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),
          Divider(color: AppColors.divider),
          const SizedBox(height: 12),

          // ── Failure action ──
          Text(
            l10n.wfEditOnFailure,
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<StepFailureAction>(
            segments: [
              ButtonSegment(
                value: StepFailureAction.abort,
                label: Text(l10n.wfEditSegAbort,
                    style: const TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: StepFailureAction.continueNext,
                label: Text(l10n.wfEditSegContinue,
                    style: const TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: StepFailureAction.gotoStep,
                label: Text(l10n.wfEditSegGoTo,
                    style: const TextStyle(fontSize: 11)),
              ),
            ],
            selected: {_failureAction},
            onSelectionChanged: (selected) {
              setState(() => _failureAction = selected.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return Colors.white;
                }
                return AppColors.onSurfaceDim;
              }),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return AppColors.orange;
                }
                return AppColors.surfaceLight;
              }),
            ),
          ),

          // ── Go-to step picker ──
          if (_failureAction == StepFailureAction.gotoStep) ...[
            const SizedBox(height: 12),
            _GotoStepPicker(
              allSteps: widget.allSteps,
              currentIndex: widget.stepIndex,
              selectedStepId: _gotoStepId,
              onChanged: (id) => setState(() => _gotoStepId = id),
            ),
          ],
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      primaryKey: const ValueKey('wf-step-save'),
      primaryAction: (label: l10n.save, icon: null, onPressed: _saveStep),
    );
  }
}

// ── Connection picker dropdown ───────────────────────────────────

class _ConnectionPicker extends ConsumerWidget {
  final AsyncValue<List<Connection>> connectionsAsync;
  final String? selectedId;

  /// What the step runs on where it has many targets: in place of a host.
  final String? manyTargets;
  final ValueChanged<String?> onChanged;

  const _ConnectionPicker({
    required this.connectionsAsync,
    required this.selectedId,
    this.manyTargets,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return connectionsAsync.when(
      loading: () => const SizedBox(
        height: 48,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Text(
        l10n.wfEditErrorLoadingConnections,
        style: TextStyle(color: AppColors.error, fontSize: 12),
      ),
      data: (connections) {
        // Its name over the app's select (a Material dropdown with a
        // floating label; found in a design audit).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ZestFieldLabel(l10n.wfEditConnectionLabel),
            const SizedBox(height: 6),
            ZestSelect<String>(
              value: selectedId != null && connections.any((c) => c.id == selectedId) ? selectedId : null,
              hint: manyTargets ?? l10n.wfEditSelectConnection,
              items: [
                for (final c in connections)
                  // Display forms (recording mode): the label and the address.
                  // A host that runs no command: dimmed, with why.
                  ZestSelectItem(
                    c.id,
                    '${Redactable.host(c.label).displayIn(ref)} '
                    '(${Redactable.address(c.host).displayIn(ref)})',
                    leading: HostGlyph(host: c, size: 16),
                    enabled: noCommandReason(c, l10n) == null,
                    note: noCommandReason(c, l10n),
                  ),
              ],
              onChanged: onChanged,
            ),
          ],
        );
      },
    );
  }
}

// ── Snippet picker dropdown ──────────────────────────────────────

class _SnippetPicker extends StatelessWidget {
  final AsyncValue<List<Snippet>> snippetsAsync;
  final String? selectedName;
  final ValueChanged<String?> onChanged;

  const _SnippetPicker({
    required this.snippetsAsync,
    required this.selectedName,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return snippetsAsync.when(
      loading: () => const SizedBox(
        height: 48,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Text(
        l10n.wfEditErrorLoadingSnippets,
        style: TextStyle(color: AppColors.error, fontSize: 12),
      ),
      data: (snippets) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ZestFieldLabel(l10n.wfEditSnippetLabel),
            const SizedBox(height: 6),
            ZestSelect<String>(
              value: selectedName != null && snippets.any((s) => s.label == selectedName) ? selectedName : null,
              hint: l10n.wfEditSelectSnippet,
              items: [
                // A step names its snippet: two of one name are one choice
                // (each of the select's choices is one of a kind).
                for (final name in {for (final s in snippets) s.label}) ZestSelectItem(name, name),
              ],
              onChanged: onChanged,
            ),
          ],
        );
      },
    );
  }
}

// ── Timeout slider ──────────────────────────────────────────────

class _TimeoutSlider extends StatelessWidget {
  final double value;
  final double max;
  final ValueChanged<double> onChanged;

  const _TimeoutSlider({
    required this.value,
    this.max = 120,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l10n.wfEditTimeout,
              style: TextStyle(
                  color: AppColors.onSurfaceVariant, fontSize: 13),
            ),
            Text(
              l10n.wfEditSecondsValue(value.round()),
              style: TextStyle(
                color: AppColors.accentInk,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(1, max),
          min: 1,
          max: max,
          divisions: max.round() - 1,
          activeColor: AppColors.orange,
          inactiveColor: AppColors.surfaceLight,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

// ── Go-to step picker ───────────────────────────────────────────

class _GotoStepPicker extends StatelessWidget {
  final List<WorkflowStep> allSteps;
  final int currentIndex;
  final String? selectedStepId;
  final ValueChanged<String?> onChanged;

  const _GotoStepPicker({
    required this.allSteps,
    required this.currentIndex,
    required this.selectedStepId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final otherSteps = <MapEntry<int, WorkflowStep>>[];
    for (var i = 0; i < allSteps.length; i++) {
      if (i != currentIndex) {
        otherSteps.add(MapEntry(i, allSteps[i]));
      }
    }

    if (otherSteps.isEmpty) {
      return Text(
        l10n.wfEditGotoNeedMoreSteps,
        style: TextStyle(color: AppColors.onSurfaceDim, fontSize: 12),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ZestFieldLabel(l10n.wfEditGotoStepLabel),
        const SizedBox(height: 6),
        ZestSelect<String>(
          value: selectedStepId != null && allSteps.any((s) => s.id == selectedStepId) ? selectedStepId : null,
          hint: l10n.wfEditSelectTargetStep,
          items: [
            for (final MapEntry(key: idx, value: step) in otherSteps)
              ZestSelectItem(step.id, l10n.wfEditGotoStepItem(idx + 1, step.type.nameIn(l10n))),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }
}

