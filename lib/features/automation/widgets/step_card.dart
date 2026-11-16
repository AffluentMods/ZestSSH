import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../database/database.dart' show Connection, Snippet;
import '../../../features/hosts/host_list_layout.dart' show hostsByIdProvider;
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../models/workflow.dart';
import '../../../providers/snippet_providers.dart';
import '../../../services/workflow_service.dart' show kWorkflowOutputToken;
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/host_row.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../state/workflow_edit_controller.dart';
import 'step_targets_dialog.dart';

/// A single inline step card in the 1.7 Automation editor. Collapsed it is a
/// dense summary row (drag handle, number, type icon, title, command preview,
/// target chip, kebab); tapping it expands the SAME card in place into its
/// editor - no modal, no route push.
class StepCard extends ConsumerWidget {
  const StepCard({
    super.key,
    required this.draft,
    required this.controller,
    required this.stepNumber,
    required this.index,
    required this.connections,
  });

  final StepDraft draft;
  final WorkflowEditController controller;

  /// 1-based ordinal shown in the number circle.
  final int stepNumber;

  /// 0-based position (drives the drag handle + insert-above affordance).
  final int index;

  final List<Connection> connections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = controller.isExpanded(draft.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Mid-list insert: a hover-revealed "+" above every card.
        _InsertAffordance(onInsert: () => controller.addStep(index: index)),
        Opacity(
          opacity: draft.disabled ? 0.55 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: expanded
                  ? ZestTokens.surfaceRaised
                  : ZestTokens.surfaceBase,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: expanded ? ZestTokens.brandBorder : ZestTokens.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context, ref, expanded),
                if (expanded) _expandedBody(context, ref),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Collapsed / always-visible header ──────────────────────────

  Widget _header(BuildContext context, WidgetRef ref, bool expanded) {
    final l10n = AppLocalizations.of(context)!;
    final titledByPreview =
        draft.type == WorkflowStepType.notify && draft.labelController.text.trim().isEmpty && stepCommandPreview(draft).isNotEmpty;
    final title = Row(
      children: [
        Flexible(
          child: Text(
            // Its message whole, where the title is the message.
            titledByPreview ? stepCommandPreview(draft) : stepDisplayTitle(l10n, draft),
            key: ValueKey('step-title-${draft.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: ZestTokens.textPrimary,
            ),
          ),
        ),
        if (draft.disabled) ...[
          const SizedBox(width: 8),
          _DisabledTag(label: l10n.zestAutoStepDisable),
        ],
      ],
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => controller.toggleExpanded(draft.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    LucideIcons.gripVertical,
                    size: 15,
                    color: ZestTokens.textTertiary,
                  ),
                ),
              ),
              _numberBadge(expanded),
              const SizedBox(width: 10),
              Tooltip(
                message: stepTypeLabel(l10n, draft.type),
                child: Icon(
                  stepTypeIcon(draft.type),
                  size: 15,
                  color: ZestTokens.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              // Fixed-width title slot so the mono command previews below it
              // line up down the whole stack regardless of title length. A
              // message step with no name of its own is titled by its message:
              // the title has the row, not a cut copy beside the whole one in
              // mono.
              if (titledByPreview)
                Expanded(child: title)
              else ...[
                SizedBox(width: 180, child: title),
                const SizedBox(width: 8),
                // Command preview - empty string still holds the flex slot so the
                // target chips stay right-aligned across every row.
                Expanded(
                  child: Text(
                    stepCommandPreview(draft),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: ZestTokens.textSecondary,
                    ),
                  ),
                ),
              ],
              if (stepUsesTarget(draft.type)) ...[
                const SizedBox(width: 8),
                if (!_hasTarget(draft))
                  Tooltip(
                    message: l10n.zestAutoStepSelectHost,
                    child: const _TargetChip(draft: null),
                  )
                else
                  _TargetChip(draft: draft),
              ],
              const SizedBox(width: 8),
              Tooltip(
                message: expanded
                    ? l10n.zestAutoStepCollapse
                    : l10n.zestAutoStepExpand,
                child: Icon(
                  expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                  size: 14,
                  color: ZestTokens.textTertiary,
                ),
              ),
              const SizedBox(width: 2),
              _KebabMenu(draft: draft, controller: controller),
            ],
          ),
        ),
      ),
    );
  }

  Widget _numberBadge(bool expanded) {
    final color = expanded ? ZestTokens.brandInk : ZestTokens.textTertiary;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$stepNumber',
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'JetBrainsMono',
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  // ── Expanded editor body ───────────────────────────────────────

  Widget _expandedBody(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: ZestTokens.border),
          const SizedBox(height: 12),
          // Optional label - first field, its placeholder previews the derived
          // title the step falls back to when left blank.
          _leftLabel(
            l10n.zestAutoStepLabel,
            _RawField(
              controller: draft.labelController,
              placeholder: stepDerivedTitle(l10n, draft),
              onChanged: () => controller.markDirty(),
            ),
          ),
          const SizedBox(height: 12),
          _typeSelector(context),
          const SizedBox(height: 12),
          ..._typeFields(context, ref),
          const SizedBox(height: 8),
          _AdvancedSection(draft: draft, controller: controller),
        ],
      ),
    );
  }

  Widget _typeSelector(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // A compact 4-way wrap of type chips (a ZestModeToggle is too narrow for
    // four labels in a split pane); the active chip fills with the brand tint.
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final type in kStepTypeOrder)
          _TypeChip(
            label: stepTypeLabel(l10n, type),
            icon: stepTypeIcon(type),
            active: draft.type == type,
            onTap: () => controller.setStepType(draft, type),
          ),
      ],
    );
  }

  List<Widget> _typeFields(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    switch (draft.type) {
      case WorkflowStepType.execute:
        return [
          _TargetField(
            draft: draft,
            controller: controller,
            connections: connections,
          ),
          const SizedBox(height: 10),
          _leftLabel(
            l10n.zestAutoStepTypeCommand,
            _monoField(
              controller: draft.commandController,
              placeholder: 'systemctl restart nginx',
              maxLines: 3,
            ),
            alignTop: true,
          ),
        ];
      case WorkflowStepType.snippet:
        return [
          _TargetField(
            draft: draft,
            controller: controller,
            connections: connections,
          ),
          const SizedBox(height: 10),
          _SnippetField(draft: draft, controller: controller),
        ];
      case WorkflowStepType.delay:
        return [
          _leftLabel(
            l10n.zestAutoStepTypeWait,
            _monoField(
              controller: draft.timeoutController,
              placeholder: '5',
              keyboardType: TextInputType.number,
            ),
          ),
        ];
      case WorkflowStepType.notify:
        return [
          _leftLabel(
            l10n.wfEditOptNotifyLabel,
            _monoField(
              controller: draft.commandController,
              placeholder: l10n.wfEditNotificationHint(kWorkflowOutputToken),
              maxLines: 2,
            ),
            alignTop: true,
          ),
        ];
    }
  }

  Widget _monoField({
    required TextEditingController controller,
    String? placeholder,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return _RawField(
      controller: controller,
      placeholder: placeholder,
      maxLines: maxLines,
      keyboardType: keyboardType,
      mono: true,
      onChanged: () => this.controller.markDirty(),
    );
  }
}

/// A left-aligned label cell + field, the single row shape every editor field
/// in the expanded card uses so their inputs align down a shared left edge.
/// [alignTop] top-aligns the label against multi-line fields (Command /
/// Condition); leave it false to vertically centre against single-line inputs.
Widget _leftLabel(
  String label,
  Widget field, {
  double labelWidth = 104,
  bool alignTop = false,
}) {
  return Row(
    crossAxisAlignment: alignTop
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center,
    children: [
      SizedBox(
        width: labelWidth,
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: field),
    ],
  );
}

// ══════════════════════════════════════════════════════════════════
// End-of-stack ghost row - the SINGLE add-step affordance
// ══════════════════════════════════════════════════════════════════

/// The ghost "+ Add step" row that closes the stack. When the workflow has no
/// steps this same row IS the empty state - the dashed hint and a separate
/// button are collapsed into one affordance (1.7 §3.5).
class AddStepGhostRow extends StatefulWidget {
  const AddStepGhostRow({super.key, required this.onAdd});

  final VoidCallback onAdd;

  @override
  State<AddStepGhostRow> createState() => _AddStepGhostRowState();
}

class _AddStepGhostRowState extends State<AddStepGhostRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onAdd,
        child: DottedBorderBox(
          highlighted: _hover,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                LucideIcons.plus,
                size: 16,
                color: _hover ? ZestTokens.brandInk : ZestTokens.textTertiary,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.zestAutoAddStep,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _hover ? ZestTokens.brandInk : ZestTokens.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded box with a 1px dashed-look border (rendered as a soft solid
/// hairline; a full dashed painter is unnecessary and heavier).
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({
    super.key,
    required this.child,
    this.highlighted = false,
  });

  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: highlighted ? ZestTokens.brandSubtle : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlighted ? ZestTokens.brandBorder : ZestTokens.border,
        ),
      ),
      child: child,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Mid-list insert affordance
// ══════════════════════════════════════════════════════════════════

class _InsertAffordance extends StatefulWidget {
  const _InsertAffordance({required this.onInsert});

  final VoidCallback onInsert;

  @override
  State<_InsertAffordance> createState() => _InsertAffordanceState();
}

class _InsertAffordanceState extends State<_InsertAffordance> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onInsert,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          // A 20px hover strip between cards; the centred "+" reveals on hover.
          height: 20,
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 100),
              opacity: _hover ? 1 : 0,
              child: Tooltip(
                message: l10n.zestAutoInsertStepHere,
                child: Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: ZestTokens.brand,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    LucideIcons.plus,
                    size: 13,
                    color: ZestTokens.surfaceSunken,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Kebab menu
// ══════════════════════════════════════════════════════════════════

class _KebabMenu extends StatelessWidget {
  const _KebabMenu({required this.draft, required this.controller});

  final StepDraft draft;
  final WorkflowEditController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      tooltip: '',
      padding: EdgeInsets.zero,
      color: ZestTokens.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: ZestTokens.border),
      ),
      onSelected: (value) {
        switch (value) {
          case 'duplicate':
            controller.duplicateStep(draft);
          case 'disable':
            controller.toggleDisabled(draft);
          case 'delete':
            controller.removeStep(draft);
        }
      },
      itemBuilder: (context) => [
        _item('duplicate', l10n.zestAutoStepDuplicate, LucideIcons.copy),
        _item(
          'disable',
          draft.disabled ? l10n.zestAutoStepEnable : l10n.zestAutoStepDisable,
          draft.disabled ? LucideIcons.eye : LucideIcons.eyeOff,
        ),
        _item(
          'delete',
          l10n.zestAutoStepDelete,
          LucideIcons.trash2,
          danger: true,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          LucideIcons.moreVertical,
          size: 15,
          color: ZestTokens.textSecondary,
        ),
      ),
    );
  }

  PopupMenuItem<String> _item(
    String value,
    String label,
    IconData icon, {
    bool danger = false,
  }) {
    final color = danger ? ZestTokens.statusCritical : ZestTokens.textPrimary;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 12.5, color: color)),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Type chip
// ══════════════════════════════════════════════════════════════════

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? ZestTokens.brandSubtle : ZestTokens.surfaceSunken,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? ZestTokens.brandBorder : ZestTokens.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? ZestTokens.brandInk : ZestTokens.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? ZestTokens.brandInk : ZestTokens.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Target (connection) chip + picker field
// ══════════════════════════════════════════════════════════════════

/// Whether [draft] says what it runs on.
bool _hasTarget(StepDraft draft) =>
    draft.targetAll || draft.targetGroupId != null || draft.targetIds.isNotEmpty || draft.connectionId != null;

/// What [draft] runs on, in a few words: a host's name (masked while a screen
/// is recorded), how many hosts, a group's name, or all hosts.
String _targetWords(BuildContext context, WidgetRef ref, StepDraft draft) {
  final l10n = AppLocalizations.of(context)!;
  final many = manyTargetsWords(l10n, ref, all: draft.targetAll, groupId: draft.targetGroupId, hosts: draft.targetIds);
  if (many != null) return many;
  final host = ref.watch(hostsByIdProvider)[draft.connectionId]?.connection;
  if (host == null) return l10n.zestAutoStepSelectHost;
  return (host.label.isNotEmpty ? Redactable.host(host.label) : Redactable.address(host.host)).displayIn(ref);
}

/// What a step runs on, on its collapsed card: the host's own icon and name,
/// or how many, or the group. With no [draft], that it has none yet.
class _TargetChip extends ConsumerWidget {
  const _TargetChip({required this.draft});

  final StepDraft? draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = draft;
    if (d == null) {
      return Icon(
        LucideIcons.serverOff,
        size: 14,
        color: ZestTokens.textTertiary,
      );
    }
    final host = ref.watch(hostsByIdProvider)[d.connectionId]?.connection;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (host != null && !d.targetAll && d.targetGroupId == null && d.targetIds.isEmpty)
            HostGlyph(host: host, size: 14)
          else
            Icon(
              LucideIcons.layers,
              size: 11,
              color: ZestTokens.textSecondary,
            ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              _targetWords(context, ref, d),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: ZestTokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TargetField extends ConsumerWidget {
  const _TargetField({
    required this.draft,
    required this.controller,
    required this.connections,
  });

  final StepDraft draft;
  final WorkflowEditController controller;
  final List<Connection> connections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return _leftLabel(
      l10n.wfTargetLabel,
      _PickerButton(
        key: ValueKey('step-targets-${draft.id}'),
        label: _targetWords(context, ref, draft),
        muted: !_hasTarget(draft),
        icon: LucideIcons.target,
        onTap: () async {
          final picked = await showStepTargets(
            context,
            current: StepTargets(
              hosts: draft.targetIds.isNotEmpty
                  ? draft.targetIds
                  : [if (draft.connectionId != null) draft.connectionId!],
              groupId: draft.targetGroupId,
              all: draft.targetAll,
            ),
          );
          if (picked != null) {
            controller.setStepTargets(draft, hosts: picked.hosts, groupId: picked.groupId, all: picked.all);
          }
        },
      ),
    );
  }
}

/// A Command step's commands for other systems (because
/// BSD's and macOS's df has no -x, and an OPNsense failed with "df: invalid
/// option -- x"): one row per system it has one for, and what adds another.
class _AltCommands extends StatelessWidget {
  const _AltCommands({required this.draft, required this.controller});

  final StepDraft draft;
  final WorkflowEditController controller;

  String _name(AppLocalizations l10n, WorkflowOsFamily family) => switch (family) {
        WorkflowOsFamily.linux => l10n.wfOsLinux,
        WorkflowOsFamily.bsd => l10n.wfOsBsd,
        WorkflowOsFamily.macos => l10n.wfOsMacos,
        WorkflowOsFamily.windows => l10n.wfOsWindows,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final others = [for (final f in WorkflowOsFamily.values) if (!draft.altCommands.containsKey(f.name)) f];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in WorkflowOsFamily.values)
          if (draft.altCommands[f.name] case final c?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 104,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Text(
                        _name(l10n, f),
                        maxLines: 2,
                        style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _RawField(
                      key: ValueKey('step-alt-${draft.id}-${f.name}'),
                      controller: c,
                      maxLines: 3,
                      mono: true,
                      onChanged: controller.markDirty,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.commonRemove,
                    icon: Icon(LucideIcons.x, size: 14, color: ZestTokens.textTertiary),
                    onPressed: () => controller.removeAltCommand(draft, f),
                  ),
                ],
              ),
            ),
        if (others.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: PopupMenuButton<WorkflowOsFamily>(
              key: ValueKey('step-alt-add-${draft.id}'),
              tooltip: l10n.wfAltCommandHelp,
              color: ZestTokens.surfaceRaised,
              position: PopupMenuPosition.under,
              onSelected: (f) => controller.addAltCommand(draft, f),
              itemBuilder: (_) => [
                for (final f in others)
                  PopupMenuItem(
                    value: f,
                    height: 36,
                    child: Text(_name(l10n, f), style: TextStyle(fontSize: 12.5, color: ZestTokens.textPrimary)),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.plus, size: 13, color: ZestTokens.brandInk),
                    const SizedBox(width: 6),
                    Text(
                      l10n.wfAltCommandAdd,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ZestTokens.brandInk),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Snippet field (searchable picker + detected variables)
// ══════════════════════════════════════════════════════════════════

class _SnippetField extends ConsumerWidget {
  const _SnippetField({required this.draft, required this.controller});

  final StepDraft draft;
  final WorkflowEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final snippets =
        ref.watch(snippetsProvider).valueOrNull ?? const <Snippet>[];
    Snippet? current;
    for (final s in snippets) {
      if (s.label == draft.snippetName) {
        current = s;
        break;
      }
    }

    Future<void> pick() async {
      final picked = await showZestSearchPicker(
        context,
        title: l10n.stepCardSnippetPickerTitle,
        items: [
          for (final s in snippets)
            ZestPickerItem(id: s.label, title: s.label, subtitle: s.category),
        ],
        selectedId: draft.snippetName,
      );
      if (picked == null) return;
      Snippet? chosen;
      for (final s in snippets) {
        if (s.label == picked) {
          chosen = s;
          break;
        }
      }
      final keys = chosen == null
          ? const <String>[]
          : parseVariablesWithOptions(
              chosen.command,
            ).map((v) => v.key).toList();
      controller.setStepSnippet(draft, picked, keys);
    }

    final List<ParsedVariable> variables = current == null
        ? const []
        : parseVariablesWithOptions(current.command);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _leftLabel(
          l10n.zestAutoStepTypeSnippet,
          _PickerButton(
            label: draft.snippetName ?? l10n.zestAutoStepChooseSnippet,
            muted: draft.snippetName == null,
            icon: LucideIcons.braces,
            onTap: pick,
          ),
        ),
        if (variables.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final v in variables)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _VariableField(
                key: ValueKey('${draft.id}:${v.key}'),
                label: v.name,
                value: draft.variables[v.key] ?? '',
                onChanged: (val) =>
                    controller.setStepVariable(draft, v.key, val),
              ),
            ),
        ],
      ],
    );
  }
}

class _VariableField extends StatelessWidget {
  const _VariableField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 104,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'JetBrainsMono',
              color: ZestTokens.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _RawField(value: value, onChangedText: onChanged, mono: true),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Advanced expander
// ══════════════════════════════════════════════════════════════════

class _AdvancedSection extends StatefulWidget {
  const _AdvancedSection({required this.draft, required this.controller});

  final StepDraft draft;
  final WorkflowEditController controller;

  @override
  State<_AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<_AdvancedSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final draft = widget.draft;
    final isWait = draft.type == WorkflowStepType.delay;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _open ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    size: 14,
                    color: ZestTokens.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.zestAutoStepAdvanced,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ZestTokens.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 4),
          // What a run honours: the step's time and what follows a failure.
          // (Retries, a working folder and run-if-previous are gone: no run
          // read them.)
          if (!isWait) ...[
            _numRow(l10n.zestAutoStepTimeout, draft.timeoutController),
            const SizedBox(height: 8),
          ],
          if (draft.type == WorkflowStepType.execute) ...[
            _AltCommands(draft: draft, controller: widget.controller),
            const SizedBox(height: 8),
          ],
          _MiniSwitchRow(
            label: l10n.zestAutoStepContinueOnError,
            value: draft.continueOnError,
            onChanged: (v) => widget.controller.setContinueOnError(draft, v),
          ),
        ],
      ],
    );
  }

  Widget _numRow(String label, TextEditingController controller) {
    return _textRow(
      label,
      controller,
      keyboardType: TextInputType.number,
      width: 96,
    );
  }

  Widget _textRow(
    String label,
    TextEditingController controller, {
    String? placeholder,
    TextInputType? keyboardType,
    double? width,
  }) {
    final field = _RawField(
      controller: controller,
      placeholder: placeholder,
      keyboardType: keyboardType,
      mono: true,
      onChanged: () => widget.controller.markDirty(),
    );
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: ZestTokens.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        width == null
            ? Expanded(child: field)
            : SizedBox(width: width, child: field),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Small shared primitives
// ══════════════════════════════════════════════════════════════════

/// A minimal field styled like [ZestField] but usable inline (its own smaller
/// footprint suits the dense step editor). Either drive it with a [controller]
/// or with [value] + [onChangedText].
class _RawField extends StatefulWidget {
  const _RawField({
    super.key,
    this.controller,
    this.value,
    this.placeholder,
    this.maxLines = 1,
    this.keyboardType,
    this.mono = false,
    this.onChanged,
    this.onChangedText,
  });

  final TextEditingController? controller;
  final String? value;
  final String? placeholder;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool mono;
  final VoidCallback? onChanged;
  final ValueChanged<String>? onChangedText;

  @override
  State<_RawField> createState() => _RawFieldState();
}

class _RawFieldState extends State<_RawField> {
  TextEditingController? _internal;
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  TextEditingController get _controller =>
      widget.controller ??
      (_internal ??= TextEditingController(text: widget.value ?? ''));

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void didUpdateWidget(_RawField old) {
    super.didUpdateWidget(old);
    if (widget.controller == null &&
        widget.value != old.value &&
        widget.value != _internal?.text) {
      _internal?.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _internal?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      color: ZestTokens.textPrimary,
      fontFamily: widget.mono ? 'JetBrainsMono' : null,
      height: 1.3,
    );
    final multi = widget.maxLines > 1;
    return Container(
      constraints: BoxConstraints(
        minHeight: multi ? 40 : ZestSizing.fieldHeight - 6,
      ),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: multi ? 8 : 0),
      alignment: multi ? Alignment.topLeft : Alignment.centerLeft,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(
          color: _focused ? ZestTokens.brand : ZestTokens.border,
        ),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        maxLines: widget.maxLines,
        minLines: 1,
        keyboardType: widget.keyboardType,
        style: style,
        cursorColor: ZestTokens.brand,
        cursorWidth: 1.5,
        onChanged: (v) {
          widget.onChanged?.call();
          widget.onChangedText?.call(v);
        },
        decoration: InputDecoration(
          isCollapsed: true,
          // Opt OUT of the global filled InputDecorationTheme - its
          // surfaceContainer fill would paint a second box inside this field's
          // own border (box-in-a-box).
          filled: false,
          hintText: widget.placeholder,
          hintStyle: style.copyWith(color: ZestTokens.textPlaceholder),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
        ),
      ),
    );
  }
}

class _PickerButton extends StatelessWidget {
  const _PickerButton({
    super.key,
    required this.label,
    required this.muted,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final bool muted;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: ZestSizing.fieldHeight - 6,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceSunken,
            borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
            border: Border.all(color: ZestTokens.border),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: muted
                    ? ZestTokens.textTertiary
                    : ZestTokens.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: muted
                        ? ZestTokens.textPlaceholder
                        : ZestTokens.textPrimary,
                  ),
                ),
              ),
              Icon(
                LucideIcons.chevronsUpDown,
                size: 13,
                color: ZestTokens.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniSwitchRow extends StatelessWidget {
  const _MiniSwitchRow({
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
        onTap: () => onChanged(!value),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: ZestTokens.textSecondary,
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 34,
              height: 18,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: value ? ZestTokens.brand : ZestTokens.border,
                borderRadius: BorderRadius.circular(999),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisabledTag extends StatelessWidget {
  const _DisabledTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: ZestTokens.textTertiary,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Searchable value picker (used for target hosts + snippets)
// ══════════════════════════════════════════════════════════════════

/// One row in [showZestSearchPicker].
class ZestPickerItem {
  const ZestPickerItem({required this.id, required this.title, this.subtitle});

  final String id;
  final String title;
  final String? subtitle;
}

/// A compact searchable single-select picker. This is a VALUE picker (host /
/// snippet), not a step editor - the step itself is edited inline in the card,
/// never in a modal.
Future<String?> showZestSearchPicker(
  BuildContext context, {
  required String title,
  required List<ZestPickerItem> items,
  String? selectedId,
}) {
  return showZestModal<String>(
    context: context,
    size: ZestModalSize.compact,
    child: _SearchPickerDialog(title: title, items: items, selectedId: selectedId),
  );
}

class _SearchPickerDialog extends StatefulWidget {
  const _SearchPickerDialog({
    required this.title,
    required this.items,
    required this.selectedId,
  });

  final String title;
  final List<ZestPickerItem> items;
  final String? selectedId;

  @override
  State<_SearchPickerDialog> createState() => _SearchPickerDialogState();
}

class _SearchPickerDialogState extends State<_SearchPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.items
        : widget.items
              .where(
                (i) =>
                    i.title.toLowerCase().contains(q) ||
                    (i.subtitle ?? '').toLowerCase().contains(q),
              )
              .toList();

    // The app's dialog (3.4): the search stays as the list under it scrolls;
    // a row chooses, Cancel is in the footer.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.search,
      title: widget.title,
      maxHeight: 520,
      bodyScrolls: false,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RawField(
            value: '',
            placeholder: l10n.stepCardSearchPlaceholder,
            onChangedText: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.stepCardNoMatches,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ZestTokens.textTertiary),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final item = filtered[i];
                      final selected = item.id == widget.selectedId;
                      return _pickRow(context, item, selected);
                    },
                  ),
          ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }

  Widget _pickRow(BuildContext context, ZestPickerItem item, bool selected) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).pop(item.id),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        // The one in use: a quiet fill and a tick (colour in a dialog is for
        // what it means, 3.4).
        decoration: BoxDecoration(
          color: selected ? ZestTokens.textPrimary.withValues(alpha: 0.06) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: ZestTokens.textPrimary,
                    ),
                  ),
                  if (item.subtitle != null && item.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: ZestTokens.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              Icon(LucideIcons.check, size: 15, color: ZestTokens.textPrimary),
          ],
        ),
      ),
    );
  }
}
