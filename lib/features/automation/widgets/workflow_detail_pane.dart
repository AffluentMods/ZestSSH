import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../database/database.dart' show Connection;
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/connection_providers.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/zest_button.dart';
import '../../../ui/widgets/zest_detail_scaffold.dart';
import '../../../ui/widgets/zest_field.dart';
import '../../../ui/widgets/zest_mode_toggle.dart';
import '../../../ui/widgets/zest_section_header.dart';
import '../../../ui/widgets/zest_switch.dart';
import '../state/workflow_edit_controller.dart';
import '../state/workflow_run_controller.dart';
import 'package:zestssh/ui/widgets/tab_focus_traversal.dart';
import 'run_output_drawer.dart';
import 'step_card.dart';

/// The right-hand detail pane of the 1.7 Automation master/detail. Composes a
/// [ZestDetailScaffold] (sticky footer, dirty dot, close X) with the workflow
/// form - real Name/Description fields, an inline step stack, the per-workflow
/// schedule, and the Notifications section - plus Run and Run on… in its head
/// (the play icon and the list's Run now were not
/// found) and the overlaid [RunOutputPanel].
class WorkflowDetailPane extends ConsumerWidget {
  const WorkflowDetailPane({
    super.key,
    required this.controller,
    required this.runController,
    required this.hasSelection,
    required this.onNew,
    required this.onSave,
    required this.onClose,
    required this.onDelete,
    required this.onRun,
    this.onRunOn,
  });

  final WorkflowEditController controller;
  final WorkflowRunController runController;
  final bool hasSelection;
  final VoidCallback onNew;
  final Future<bool> Function() onSave;
  final VoidCallback onClose;
  final VoidCallback onDelete;
  final VoidCallback onRun;

  /// Run on…: the hosts picked as it starts. Null where nothing runs on hosts.
  final VoidCallback? onRunOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connections =
        ref
            .watch(connectionsWithDetailsProvider)
            .valueOrNull
            ?.map((c) => c.connection)
            .toList() ??
        const <Connection>[];

    // The detail pane is ALWAYS the editor now - a blank/creating controller
    // renders a ready-to-fill "new" form, so there is no empty state. Clearing
    // (footer) or deleting simply rebinds a blank new one.
    // The run's too: the panel opens and closes with it (listening to the
    // editor alone, its Close closed nothing until something else redrew the
    // pane: the Run output panel could not be closed).
    return ListenableBuilder(
      listenable: Listenable.merge([controller, runController]),
      builder: (context, _) => _editor(context, connections),
    );
  }

  Widget _editor(BuildContext context, List<Connection> connections) {
    final l10n = AppLocalizations.of(context)!;
    final typed = controller.nameController.text.trim();
    final title = typed.isNotEmpty
        ? typed
        : (controller.isCreating
              ? l10n.zestAutoNewLabel
              : controller.original!.name);
    final showDelete = !controller.isCreating;

    final scaffold = ZestDetailScaffold(
      title: title,
      icon: LucideIcons.play,
      // The mono second line carries the step count. (A schedule and the
      // device a workflow runs on were shown and set here, and nothing ran
      // a schedule: found while comparing the five versions.)
      // ("from template" while it is one, unsaved.)
      subtitle: controller.fromTemplate
          ? '${l10n.autoFromTemplate} · ${l10n.zestAutoRowStepCount(controller.steps.length)}'
          : l10n.zestAutoRowStepCount(controller.steps.length),
      subtitleMono: true,
      isDirty: controller.isDirty,
      onSave: () => onSave(),
      saveLabel: l10n.autoSaveWorkflow,
      // Clear resets to a blank new workflow (runs the dirty guard first).
      onCancel: onNew,
      onClose: onClose,
      // Run, Run on… and, for a saved workflow, Delete in the head, beside its
      // close: the foot is Cancel and Save workflow.
      headerAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The run going or the last one's results, where its panel was closed.
          if (!runController.isOpen && (runController.isRunning || runController.results.isNotEmpty)) ...[
            IconButton(
              key: const ValueKey('workflow-run-show'),
              tooltip: l10n.wfRunShowOutput,
              icon: Icon(LucideIcons.terminal, size: 16, color: ZestTokens.textSecondary),
              onPressed: runController.open,
            ),
            const SizedBox(width: 2),
          ],
          if (onRunOn != null && controller.steps.any((s) => stepUsesTarget(s.type))) ...[
            ZestButton(
              key: const ValueKey('workflow-run-on'),
              label: l10n.zestSnippetsRunOn,
              variant: ZestButtonVariant.secondary,
              onPressed: runController.isRunning ? null : onRunOn,
            ),
            const SizedBox(width: 6),
          ],
          // Runs the workflow as it is now, saved or not, to try it.
          ZestButton(
            key: const ValueKey('workflow-run'),
            label: l10n.snippetPageRun,
            icon: LucideIcons.play,
            variant: ZestButtonVariant.primary,
            isLoading: runController.isRunning,
            onPressed: runController.isRunning ? null : onRun,
          ),
          if (showDelete) ...[
            const SizedBox(width: 2),
            IconButton(
              key: const ValueKey('workflow-delete'),
              tooltip: l10n.zestAutoStepDelete,
              icon: Icon(LucideIcons.trash2, size: 16, color: ZestTokens.statusCritical),
              onPressed: onDelete,
            ),
          ],
        ],
      ),
      body: _WorkflowForm(controller: controller, connections: connections),
    );

    // Overlay the run panel over the bottom of the pane (only for THIS
    // workflow's run) so a failing step surfaces without leaving the pane.
    final showDrawer =
        runController.isOpen &&
        (runController.workflowId == null ||
            runController.workflowId == (controller.original?.id ?? kWorkflowDraftRunId));

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(child: scaffold),
            if (showDrawer)
              Positioned.fill(
                child: RunOutputPanel(controller: runController, available: constraints.maxHeight),
              ),
          ],
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Form body
// ══════════════════════════════════════════════════════════════════

class _WorkflowForm extends StatelessWidget {
  const _WorkflowForm({required this.controller, required this.connections});

  final WorkflowEditController controller;
  final List<Connection> connections;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final labelWidth = zestFieldLabelWidth(context, [l10n.zestAutoFieldName, l10n.zestAutoFieldDescription], min: 120);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestField(
            label: l10n.zestAutoFieldName,
            // As wide as the Description cell below, both measured from the
            // two names (at least 104: "Beschreibung" did not fit it).
            labelWidth: labelWidth,
            controller: controller.nameController,
            errorText: controller.nameError,
            onChanged: (_) {
              if (controller.nameError != null) controller.setNameError(null);
              controller.markDirty();
            },
          ),
          const SizedBox(height: 12),
          _ResizableDescriptionField(
            label: l10n.zestAutoFieldDescription,
            labelWidth: labelWidth,
            controller: controller.descriptionController,
            onChanged: (_) => controller.markDirty(),
          ),
          const SizedBox(height: 24),

          // ── When it runs ──
          // Here, always; from outside the app too (a link, another app, a
          // phone's schedule, with an API key) where it is on. A computer runs
          // no schedule, and an alert starts no workflow: neither is offered.
          ZestSectionHeader(label: l10n.autoWhenRunsSection),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: ZestModeToggle(
              key: const ValueKey('workflow-when-runs'),
              segments: [
                ZestModeSegment(id: 'manual', label: l10n.autoRunManually),
                ZestModeSegment(id: 'outside', label: l10n.autoRunFromOutside),
              ],
              selectedId: controller.runsFromOutside ? 'outside' : 'manual',
              onChanged: (id) => controller.setRunsFromOutside(id == 'outside'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            controller.runsFromOutside ? l10n.autoRunFromOutsideHelp : l10n.autoRunManuallyHelp,
            style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary),
          ),
          const SizedBox(height: 24),

          // ── Steps ──
          ZestSectionHeader(
            label: l10n.zestAutoStepsLabel,
            count: controller.steps.length,
          ),
          const SizedBox(height: 12),
          _StepsStack(controller: controller, connections: connections),
          const SizedBox(height: 24),

          // ── Tell me ──
          ZestSectionHeader(label: l10n.autoTellMeSection),
          const SizedBox(height: 8),
          _NotifyRow(
            key: const ValueKey('workflow-tell-fails'),
            label: l10n.autoTellWhenFails,
            value: controller.notifyOnFailure,
            onChanged: controller.setNotifyOnFailure,
          ),
          _NotifyRow(
            key: const ValueKey('workflow-tell-succeeds'),
            label: l10n.autoTellWhenSucceeds,
            value: controller.notifyOnSuccess,
            onChanged: controller.setNotifyOnSuccess,
          ),
        ],
      ),
    );
  }
}

class _StepsStack extends StatelessWidget {
  const _StepsStack({required this.controller, required this.connections});

  final WorkflowEditController controller;
  final List<Connection> connections;

  @override
  Widget build(BuildContext context) {
    final steps = controller.steps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (steps.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: steps.length,
            // reorderSteps takes the old onReorder index (one past the slot when moving down).
            onReorderItem: (o, n) => controller.reorderSteps(o, n > o ? n + 1 : n),
            proxyDecorator: (child, index, animation) =>
                Material(color: Colors.transparent, child: child),
            itemBuilder: (context, index) {
              final draft = steps[index];
              return Padding(
                key: ValueKey(draft.id),
                padding: const EdgeInsets.only(bottom: 4),
                child: StepCard(
                  draft: draft,
                  controller: controller,
                  stepNumber: index + 1,
                  index: index,
                  connections: connections,
                ),
              );
            },
          ),
        const SizedBox(height: 4),
        AddStepGhostRow(onAdd: () => controller.addStep()),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Fields
// ══════════════════════════════════════════════════════════════════

/// A single-border, multiline Description field the user can drag taller.
///
/// Replaces the auto-sizing [ZestField] previously used for the workflow
/// Description (a one-line-tall box). It starts ~3 lines tall, grows/scrolls
/// with content, and carries a drag-to-resize grip at the bottom-right so the
/// user can make it as tall as they like. Exactly ONE border - no nested/inner
/// border - and its input aligns on the same vertical rule as the Name field.
class _ResizableDescriptionField extends StatefulWidget {
  const _ResizableDescriptionField({
    required this.label,
    required this.labelWidth,
    required this.controller,
    required this.onChanged,
  });

  final String label;

  /// The names' column of the form, as wide as the Name field's.
  final double labelWidth;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_ResizableDescriptionField> createState() =>
      _ResizableDescriptionFieldState();
}

class _ResizableDescriptionFieldState
    extends State<_ResizableDescriptionField> {
  static const double _minHeight = 56; // ~2 lines + padding
  static const double _maxHeight = 260;

  double _height = 76; // ~3 lines to start
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _onDragResize(DragUpdateDetails d) {
    setState(() {
      _height = (_height + d.delta.dy).clamp(_minHeight, _maxHeight);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Combined ZestField look: ONE rounded border encloses a RAISED label cell
    // and the SUNKEN input, split by a 1px divider - the raised fill + divider
    // are painted as full-height background layers behind the content (the same
    // technique ZestField's multiline path uses) so the input still grows.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: _height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(
          color: _focused ? ZestTokens.brand : ZestTokens.border,
        ),
      ),
      child: Stack(
        children: [
          // Raised label fill.
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: widget.labelWidth,
            child: ColoredBox(color: ZestTokens.surfaceRaised),
          ),
          // 1px divider between the label cell and the input.
          Positioned(
            top: 0,
            bottom: 0,
            left: widget.labelWidth,
            width: 1,
            child: ColoredBox(color: ZestTokens.border),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: widget.labelWidth,
                child: Padding(
                  // As a field's name is drawn beside its value (12 high, 11
                  // either side), in the column measured from the form's names.
                  padding: const EdgeInsets.only(left: 11, right: 11, top: 10),
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      color: ZestTokens.textTertiary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 1), // reserve the divider column
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                        // A script body wants a real tab character, not
                        // focus traversal.
                        child: KeepTabKeys(
                          child: TextField(
                          controller: widget.controller,
                          focusNode: _focus,
                          onChanged: widget.onChanged,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          keyboardType: TextInputType.multiline,
                          style: TextStyle(
                            fontSize: 13,
                            color: ZestTokens.textPrimary,
                            height: 1.3,
                          ),
                          cursorColor: ZestTokens.brand,
                          cursorWidth: 1.5,
                          decoration: const InputDecoration(
                            isCollapsed: true,
                            // Opt OUT of the global filled InputDecorationTheme -
                            // otherwise its surfaceContainer fill paints a second
                            // box inside this field's own border (box-in-a-box).
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                          ),
                        ),
                        ),
                      ),
                    ),
                    // Drag-to-resize grip along the bottom edge - drag to grow.
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: _onDragResize,
                        child: SizedBox(
                          height: 14,
                          width: double.infinity,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                LucideIcons.gripHorizontal,
                                size: 14,
                                color: ZestTokens.textTertiary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NotifyRow extends StatelessWidget {
  const _NotifyRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: ZestTokens.textPrimary,
                  ),
                ),
              ),
              ZestSwitch(value: value, semanticLabel: label, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}
