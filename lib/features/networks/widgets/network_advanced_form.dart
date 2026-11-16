import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/network_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/recording_masked_field.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_empty_state.dart';
import '../../../ui/widgets/zest_section_header.dart';
import '../models/network.dart';
import '../models/network_trigger.dart';
import '../state/network_controller.dart';
import 'host_override_table.dart';
import 'network_form_fields.dart';
import 'trigger_summary.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// Advanced mode - the full superset editor (1.7 §1 / Doc-3 §3). Everything
/// Simple has, plus: a visible match-order summary, a configured-triggers LIST
/// (add via the section header, reorder, remove), hand-edited CIDRs with live
/// validation, connection-type matching, and the per-host [HostOverrideTable].
///
/// §3 rule: the detail pane is a SINGLE column at every width - identity then
/// behaviour then overrides stack top to bottom, never side by side.
class NetworkAdvancedForm extends StatelessWidget {
  const NetworkAdvancedForm({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    // Single continuous column - the design has NO full-width horizontal
    // dividers; the section-header hairlines + spacing carry the separation.
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _IdentityColumn(controller: controller),
          const SizedBox(height: 20),
          _BehaviorColumn(controller: controller),
          const SizedBox(height: 20),
          // The reason Advanced exists - the per-host override table.
          HostOverrideTable(controller: controller),
          // The derived "Matches" artifact is hidden until a trigger exists -
          // an empty match expression is noise (§3.7).
          if (controller.triggers.isNotEmpty || controller.isFallback) ...[
            const SizedBox(height: 20),
            NetworkDerivedLine(controller: controller),
          ],
        ],
      ),
    );
  }
}

class _IdentityColumn extends StatelessWidget {
  const _IdentityColumn({required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NetworkNameField(controller: controller),
        if (!controller.isFallback) ...[
          const SizedBox(height: 20),
          ZestSectionHeader(label: l10n.networkEditorColor),
          NetworkColorField(controller: controller),
        ],
        const SizedBox(height: 20),
        ZestSectionHeader(label: l10n.networkEditorIcon),
        NetworkIconGrid(controller: controller),
      ],
    );
  }
}

class _BehaviorColumn extends StatelessWidget {
  const _BehaviorColumn({required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    // Order: triggers, then the match-order summary, then the "Reach
    // via" cell (which self-labels, so no separate field label here).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TriggersSection(controller: controller),
        // Where this network sits in first-match-wins order (§3.2). Self-spaces
        // when shown; renders nothing for an unsaved or fallback network.
        _MatchOrderRow(controller: controller),
        const SizedBox(height: 16),
        NetworkVpnField(controller: controller),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Match-order summary + reorder (§3.2)
// ══════════════════════════════════════════════════════════════════

/// A single row stating where this network is checked in evaluation order
/// ("Checked 2nd of 4. Home is checked first.") plus a Reorder action. Shown
/// only for a saved, non-fallback network - a brand-new one has no position
/// yet, and Default is pinned last by definition.
class _MatchOrderRow extends ConsumerWidget {
  const _MatchOrderRow({required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (controller.isCreating || controller.isFallback) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final networks = ref.watch(allNetworksProvider).valueOrNull ?? const [];
    final id = controller.original!.id;
    final nonFallback =
        networks.where((n) => !n.isFallback).toList(growable: false);
    final idx = nonFallback.indexWhere((n) => n.id == id);
    if (idx < 0) return const SizedBox.shrink();

    final total = networks.length;
    final position = idx + 1; // non-fallback networks fill the first slots
    var message = l10n.zestNetworkMatchOrderSummary(_ordinal(position), total);
    if (position > 1) {
      // Names the first-checked network: painted in its display form.
      final first = Redactable.network(networks.first.name).displayIn(ref);
      message = '$message ${l10n.zestNetworkMatchOrderFirstHint(first)}';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 9, 6, 9),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.arrowDown,
                size: 14, color: ZestTokens.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                    fontSize: 12, height: 1.35, color: ZestTokens.textSecondary),
              ),
            ),
            const SizedBox(width: 6),
            _ReorderMenu(
              index: idx,
              count: nonFallback.length,
              onMove: (m) => _apply(ref, nonFallback, idx, m),
            ),
          ],
        ),
      ),
    );
  }

  void _apply(WidgetRef ref, List<Network> nonFallback, int idx, _Move m) {
    final ids = nonFallback.map((n) => n.id).toList();
    final id = ids.removeAt(idx);
    final target = switch (m) {
      _Move.top => 0,
      _Move.up => idx - 1,
      _Move.down => idx + 1,
      _Move.bottom => ids.length,
    };
    ids.insert(target.clamp(0, ids.length), id);
    ref.read(networkRepositoryProvider).reorder(ids);
  }
}

enum _Move { top, up, down, bottom }

class _ReorderMenu extends StatelessWidget {
  const _ReorderMenu({
    required this.index,
    required this.count,
    required this.onMove,
  });

  final int index;
  final int count;
  final ValueChanged<_Move> onMove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canUp = index > 0;
    final canDown = index < count - 1;
    return PopupMenuButton<_Move>(
      enabled: canUp || canDown,
      tooltip: l10n.zestNetworkReorder,
      color: ZestTokens.surfaceRaised,
      position: PopupMenuPosition.under,
      onSelected: onMove,
      itemBuilder: (context) => [
        _item(_Move.top, l10n.zestNetworkMoveToTop, LucideIcons.chevronsUp, canUp),
        _item(_Move.up, l10n.zestNetworkMoveUp, LucideIcons.chevronUp, canUp),
        _item(_Move.down, l10n.zestNetworkMoveDown, LucideIcons.chevronDown, canDown),
        _item(_Move.bottom, l10n.zestNetworkMoveToBottom, LucideIcons.chevronsDown, canDown),
      ],
      child: Opacity(
        opacity: (canUp || canDown) ? 1 : 0.4,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.arrowUpDown, size: 13, color: ZestTokens.brandInk),
            const SizedBox(width: 4),
            Text(
              l10n.zestNetworkReorder,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ZestTokens.brandInk,
              ),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<_Move> _item(
          _Move value, String label, IconData icon, bool enabled) =>
      PopupMenuItem<_Move>(
        value: value,
        enabled: enabled,
        child: Row(
          children: [
            Icon(icon,
                size: 14,
                color: enabled
                    ? ZestTokens.textSecondary
                    : ZestTokens.textPlaceholder),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color:
                    enabled ? ZestTokens.textPrimary : ZestTokens.textPlaceholder,
              ),
            ),
          ],
        ),
      );
}

/// English ordinal ("1st", "2nd", "3rd", "4th"…). Kept in Dart so the l10n
/// string only carries the pattern; other locales format the number their way.
String _ordinal(int n) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

// ══════════════════════════════════════════════════════════════════
// Triggers section (§3.1): a list of configured triggers, added from the
// section header, each row a glyph + fixed type slot + mono value + remove.
// ══════════════════════════════════════════════════════════════════

class _TriggersSection extends StatelessWidget {
  const _TriggersSection({required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (controller.isFallback) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestSectionHeader(label: l10n.zestNetworkTriggersLabel),
          const SizedBox(height: 12),
          _LockedAlways(label: l10n.networksTriggerSummaryAlways),
        ],
      );
    }

    final triggers = controller.triggers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(
          label: l10n.zestNetworkTriggersLabel,
          count: triggers.length,
          trailing: _AddTriggerAction(controller: controller),
        ),
        const SizedBox(height: 12),
        if (controller.triggersError != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              controller.triggersError!,
              style: TextStyle(
                  fontSize: 11.5, color: ZestTokens.statusCritical),
            ),
          ),
        ],
        if (triggers.isEmpty)
          ZestEmptyRow(message: l10n.zestNetworkNoTriggers)
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: triggers.length,
            // reorderTriggers takes the old onReorder index (one past the slot when moving down).
            onReorderItem: (o, n) => controller.reorderTriggers(o, n > o ? n + 1 : n),
            itemBuilder: (context, index) {
              final draft = triggers[index];
              return Padding(
                key: ObjectKey(draft),
                padding: const EdgeInsets.only(bottom: 5),
                child: _TriggerRow(
                  controller: controller,
                  draft: draft,
                  index: index,
                ),
              );
            },
          ),
      ],
    );
  }
}

/// The "+ Add trigger" action in the TRIGGERS section header - a brand-text
/// affordance (not a solid-orange button) that opens a type picker.
class _AddTriggerAction extends StatelessWidget {
  const _AddTriggerAction({required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<TriggerKind>(
      tooltip: l10n.zestNetworkAddTrigger,
      color: ZestTokens.surfaceRaised,
      position: PopupMenuPosition.under,
      onSelected: controller.addTrigger,
      itemBuilder: (context) => [
        _item(TriggerKind.subnet, LucideIcons.network, l10n.zestNetworkTriggerSubnet),
        _item(TriggerKind.ssid, LucideIcons.wifi, l10n.zestNetworkTriggerWifi),
        _item(TriggerKind.cellular, LucideIcons.signal, l10n.zestNetworkTriggerCellular),
        _item(TriggerKind.connectivity, LucideIcons.router,
            l10n.zestNetworkTriggerConnectionType),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.plus, size: 14, color: ZestTokens.brandInk),
          const SizedBox(width: 4),
          Text(
            l10n.zestNetworkAddTrigger,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ZestTokens.brandInk,
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<TriggerKind> _item(
          TriggerKind kind, IconData icon, String label) =>
      PopupMenuItem<TriggerKind>(
        value: kind,
        child: Row(
          children: [
            Icon(icon, size: 14, color: ZestTokens.textSecondary),
            const SizedBox(width: 10),
            Text(label,
                style: TextStyle(
                    fontSize: 13, color: ZestTokens.textPrimary)),
          ],
        ),
      );
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({
    required this.controller,
    required this.draft,
    required this.index,
  });

  final NetworkEditController controller;
  final TriggerDraft draft;
  final int index;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Error recomputes on every rebuild (the parent rebuilds on each keystroke
    // via markDirty), so validation is live without local state.
    final error = draft.fieldError(l10n);

    // Each configured trigger is a labeled row: [type icon] [type label]
    // [value] [remove] on one surface, like the Wi-Fi name /
    // Subnet / Connection rows. The type icon doubles as the drag handle.
    final IconData icon;
    final String cellLabel;
    final Widget value;
    switch (draft.kind) {
      case TriggerKind.subnet:
        icon = LucideIcons.network;
        cellLabel = l10n.zestNetworkTypeSubnet;
        value = _InlineField(
          controller: draft.textController!,
          placeholder: l10n.networkEditorCidrPlaceholder,
          errorText: error,
          isMono: true,
          // A subnet is an address: masked + read-only while recording.
          mask: maskedCidr,
          onChanged: () => controller.markDirty(),
        );
      case TriggerKind.ssid:
        icon = LucideIcons.wifi;
        cellLabel = l10n.zestNetworkTriggerLabelWifi;
        value = _InlineField(
          controller: draft.textController!,
          placeholder: l10n.networkEditorSsidPlaceholder,
          errorText: error,
          isMono: true,
          // An SSID names the environment: masked + read-only while recording.
          mask: (v) => Redactable.network(v).display,
          onChanged: () => controller.markDirty(),
        );
      case TriggerKind.cellular:
        icon = LucideIcons.signal;
        cellLabel = l10n.zestNetworkTypeCellular;
        value = Text(
          l10n.networkConnectivityCellular,
          style: TextStyle(
            fontSize: 13,
            fontFamily: 'JetBrainsMono',
            // A fixed value is not a placeholder - render it at full contrast.
            color: ZestTokens.textPrimary,
          ),
        );
      case TriggerKind.connectivity:
        icon = LucideIcons.router;
        cellLabel = l10n.zestNetworkTriggerLabelConnection;
        value = _ConnectivityDropdown(
          selected: draft.connectivityKind ?? ConnectivityKind.wifi,
          onChanged: (k) => controller.setConnectivityKind(draft, k),
        );
    }

    // Two-region cell (like the Name / Reach-via fields): a RAISED type-label
    // cell on the left, a SUNKEN input cell filling the rest - so the editable
    // value reads as an input (sunken), not a card (raised).
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Raised fixed-width type-label cell (the drag handle lives here);
            // its width keeps every row's value on one vertical rule.
            Container(
              color: ZestTokens.surfaceRaised,
              padding: const EdgeInsets.fromLTRB(11, 8, 9, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The type glyph is the drag handle (the design shows no
                  // separate grip). Grab cursor hints the affordance on desktop.
                  ReorderableDragStartListener(
                    index: index,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 9),
                        child: Icon(icon,
                            size: 15, color: ZestTokens.textSecondary),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _kTypeSlotWidth,
                    child: Text(
                      cellLabel,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 12,
                        color: ZestTokens.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Sunken input cell.
            Expanded(
              child: Container(
                color: ZestTokens.surfaceSunken,
                padding: const EdgeInsets.fromLTRB(11, 8, 6, 8),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Expanded(child: value),
                    _RowRemoveButton(
                      tooltip: l10n.networkEditorRemoveTrigger,
                      onTap: () => controller.removeTrigger(draft),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fixed width of the trigger row's type-label slot (§3.1).
const double _kTypeSlotWidth = 82;

/// A compact remove (x) affordance - a small square tap target that keeps the
/// dense rows from inheriting [IconButton]'s 48px min height.
class _RowRemoveButton extends StatelessWidget {
  const _RowRemoveButton({required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(LucideIcons.x, size: 14, color: ZestTokens.textTertiary),
          ),
        ),
      ),
    );
  }
}

/// A compact, borderless inline text field used inside a trigger row (the row
/// draws its own container and leading icon/type slot). With [mask] the value
/// is an identifier: while recording mode is on it renders masked and
/// read-only, and a tap runs the reveal gate.
class _InlineField extends ConsumerWidget {
  const _InlineField({
    required this.controller,
    required this.placeholder,
    required this.errorText,
    required this.isMono,
    required this.onChanged,
    this.mask,
  });

  final TextEditingController controller;
  final String placeholder;
  final String? errorText;
  final bool isMono;
  final VoidCallback onChanged;
  final String Function(String raw)? mask;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mask = this.mask;
    if (mask != null && ref.watch(recordingModeProvider)) {
      return RecordingMaskedValue(
        controller: controller,
        mask: mask,
        isMono: isMono,
        placeholder: placeholder,
      );
    }
    final hasError = errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: controller,
          onChanged: (_) => onChanged(),
          style: TextStyle(
            fontSize: 13,
            color: ZestTokens.textPrimary,
            fontFamily: isMono ? 'JetBrainsMono' : null,
            letterSpacing: isMono ? 0.4 : null,
          ),
          cursorColor: ZestTokens.brand,
          cursorWidth: 1.5,
          decoration: InputDecoration(
            isCollapsed: true,
            filled: false,
            hintText: placeholder,
            hintStyle: TextStyle(
                fontSize: 13, color: ZestTokens.textPlaceholder),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 3),
          Text(
            errorText!,
            style: TextStyle(
                fontSize: 11, color: ZestTokens.statusCritical),
          ),
        ],
      ],
    );
  }
}

class _ConnectivityDropdown extends StatelessWidget {
  const _ConnectivityDropdown({required this.selected, required this.onChanged});

  final ConnectivityKind selected;
  final ValueChanged<ConnectivityKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestSelect<ConnectivityKind>(
      value: selected,
      items: [for (final kind in ConnectivityKind.values) ZestSelectItem(kind, _connectivityLabel(l10n, kind))],
      onChanged: onChanged,
      // The app's select (it was a Material dropdown
      // before). The trigger row is its field: drawn bare in the row's
      // sunken cell, as the rows' text inputs are.
      frame: (value) => value,
    );
  }

  static String _connectivityLabel(AppLocalizations l10n, ConnectivityKind k) {
    return switch (k) {
      ConnectivityKind.wifi => l10n.networkConnectivityWifi,
      ConnectivityKind.ethernet => l10n.networkConnectivityEthernet,
      ConnectivityKind.cellular => l10n.networkConnectivityCellular,
      ConnectivityKind.vpn => l10n.networkConnectivityVpn,
      ConnectivityKind.none => l10n.networkConnectivityNone,
    };
  }
}

class _LockedAlways extends StatelessWidget {
  const _LockedAlways({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.globe, size: 14, color: ZestTokens.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: ZestTokens.textSecondary,
              ),
            ),
          ),
          Icon(LucideIcons.lock, size: 12, color: ZestTokens.textTertiary),
        ],
      ),
    );
  }
}
