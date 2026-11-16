import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/connection_providers.dart';
import '../../../providers/purchase_providers.dart';
import '../../../providers/settings_providers.dart';
import '../../../router/routes.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/recording_masked_field.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_field.dart';
import '../../../ui/widgets/zest_section_header.dart';
import '../state/network_controller.dart';

// Column geometry shared by the header row and each override row so they line
// up. Host + Jump host are fixed; Address flexes; the remove (x) sits last.
const double _kHostColWidth = 104;
const double _kJumpColWidth = 76;
const double _kColGap = 9;
const double _kRemoveColWidth = 26;
const double _kRowLeadIn = 11;

/// The Advanced per-host override table, styled as a compact
/// table: a Host / Address / Jump host column header over dense rows. Each row
/// collapses to a one-line summary (host, resolved address, jump host) and
/// expands on tap into the full editor (address, port, Unreachable toggle,
/// jump-host chain). Overrides are sparse, so only overridden hosts appear; the
/// header's "+ Override" picker adds a new (auto-expanded) row.
class HostOverrideTable extends ConsumerStatefulWidget {
  const HostOverrideTable({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  ConsumerState<HostOverrideTable> createState() => _HostOverrideTableState();
}

class _HostOverrideTableState extends ConsumerState<HostOverrideTable> {
  /// Host ids whose row is expanded into the editor. State lives here (not per
  /// row) so it survives the form's frequent rebuilds.
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final l10n = AppLocalizations.of(context)!;
    final hostsAsync = ref.watch(connectionsWithDetailsProvider);
    final hosts = hostsAsync.valueOrNull ?? const [];
    // Host labels are only ever painted here (rows, hint texts, the hop and
    // override pickers key on ids), so the map holds their display forms
    // (recording mode).
    final labels = {
      for (final h in hosts)
        h.connection.id: Redactable.host(h.connection.label).displayIn(ref),
    };

    final overridden = controller.overrides.map((o) => o.hostId).toSet();
    final available = hosts
        .where((h) => !overridden.contains(h.connection.id))
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(
          label: l10n.zestNetworkOverridesTitle,
          count: controller.overrides.length,
          trailing: _AddOverrideButton(
            candidates: [
              for (final h in available)
                (id: h.connection.id, label: labels[h.connection.id]!),
            ],
            // A freshly added override opens expanded so it can be filled in.
            onSelected: (id) {
              controller.addOverride(id);
              setState(() => _expanded.add(id));
            },
          ),
        ),
        const SizedBox(height: 12),
        if (controller.overrides.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              l10n.networksOverrideListEmpty,
              style: TextStyle(
                fontSize: 12.5,
                color: ZestTokens.textTertiary,
              ),
            ),
          )
        else ...[
          _OverrideColumnHeader(l10n: l10n),
          const SizedBox(height: 6),
          for (final draft in controller.overrides)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: _OverrideRow(
                key: ValueKey(draft.hostId),
                controller: controller,
                draft: draft,
                labels: labels,
                expanded: _expanded.contains(draft.hostId),
                onToggle: () => setState(() {
                  if (!_expanded.remove(draft.hostId)) {
                    _expanded.add(draft.hostId);
                  }
                }),
              ),
            ),
        ],
      ],
    );
  }
}

/// Host / Address / Jump host column labels above the override rows.
class _OverrideColumnHeader extends StatelessWidget {
  const _OverrideColumnHeader({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 10, color: ZestTokens.textTertiary);
    return Padding(
      padding: const EdgeInsets.only(left: _kRowLeadIn),
      child: Row(
        children: [
          SizedBox(
            width: _kHostColWidth,
            child: Text(l10n.zestNetworkOverrideColHost, style: style),
          ),
          const SizedBox(width: _kColGap),
          Expanded(child: Text(l10n.hostNetworksAddress, style: style)),
          const SizedBox(width: _kColGap),
          SizedBox(
            width: _kJumpColWidth,
            child: Text(l10n.zestNetworkOverrideColJump, style: style),
          ),
          const SizedBox(width: _kRemoveColWidth),
        ],
      ),
    );
  }
}

class _AddOverrideButton extends StatelessWidget {
  const _AddOverrideButton({
    required this.candidates,
    required this.onSelected,
  });

  final List<({String id, String label})> candidates;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = candidates.isNotEmpty;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: l10n.hostNetworksOverride,
      color: ZestTokens.surfaceRaised,
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final c in candidates)
          PopupMenuItem<String>(
            value: c.id,
            child: Text(
              c.label,
              style: TextStyle(
                  fontSize: 13, color: ZestTokens.textPrimary),
            ),
          ),
      ],
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.plus, size: 14, color: ZestTokens.brandInk),
            const SizedBox(width: 4),
            Text(
              l10n.hostNetworksOverride,
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
}

class _OverrideRow extends ConsumerWidget {
  const _OverrideRow({
    super.key,
    required this.controller,
    required this.draft,
    required this.labels,
    required this.expanded,
    required this.onToggle,
  });

  final NetworkEditController controller;
  final HostOverrideDraft draft;

  /// Host id → label in its display form (see [HostOverrideTable]).
  final Map<String, String> labels;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child:
          expanded ? _expandedBody(context, ref) : _collapsedRow(context, ref),
    );
  }

  /// Compact one-line summary - the default look. Tapping the row (any
  /// part but the remove x) expands it into the editor.
  Widget _collapsedRow(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final hostLabel = labels[draft.hostId] ?? draft.hostId;

    // Address column: "addr:port", "Unreachable", or a dim "inherits" hint.
    final Widget addressCell;
    if (draft.skip) {
      addressCell = Text(
        l10n.hostNetworksSkipShort,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: ZestTokens.statusCritical),
      );
    } else {
      final addr = draft.addressController.text.trim();
      final port = draft.portController.text.trim();
      final raw =
          addr.isEmpty && port.isEmpty ? '' : (port.isEmpty ? addr : '$addr:$port');
      // The override address is painted in its display form (recording mode).
      final summary = raw.isEmpty ? '' : Redactable.address(raw).displayIn(ref);
      addressCell = summary.isEmpty
          ? Text(
              l10n.hostNetworksStatusInherits,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: ZestTokens.textPlaceholder,
              ),
            )
          : Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
                color: ZestTokens.textPrimary,
              ),
            );
    }

    // Jump column: the single hop's name, "via N jumps", or a dim "(direct)".
    final String jumpText;
    final Color jumpColor;
    if (draft.jumpChain.isEmpty) {
      jumpText = l10n.hostNetworksJumpDirect;
      jumpColor = ZestTokens.textPlaceholder;
    } else if (draft.jumpChain.length == 1) {
      jumpText = labels[draft.jumpChain.first] ?? draft.jumpChain.first;
      jumpColor = ZestTokens.textSecondary;
    } else {
      jumpText = l10n.hostNetworksJumpBadge(draft.jumpChain.length);
      jumpColor = ZestTokens.textSecondary;
    }

    return Row(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(_kRowLeadIn, 9, 0, 9),
                child: Row(
                  children: [
                    SizedBox(
                      width: _kHostColWidth,
                      child: Text(
                        hostLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: ZestTokens.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: _kColGap),
                    Expanded(child: addressCell),
                    const SizedBox(width: _kColGap),
                    SizedBox(
                      width: _kJumpColWidth,
                      child: Text(
                        jumpText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: jumpColor),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _RemoveOverrideButton(
          tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
          onTap: () => controller.removeOverride(draft),
        ),
      ],
    );
  }

  /// The full editor (address, port, Unreachable toggle, jump-host chain),
  /// shown when the row is expanded. The header host name / chevron collapses.
  Widget _expandedBody(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final hostLabel = labels[draft.hostId] ?? draft.hostId;
    // The address field holds an identifier: masked + read-only while
    // recording (a tap runs the reveal gate).
    final recording = ref.watch(recordingModeProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: (tap to collapse) host name + skip toggle + remove.
          Row(
            children: [
              Expanded(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggle,
                    child: Row(
                      children: [
                        Icon(LucideIcons.chevronUp,
                            size: 15, color: ZestTokens.textTertiary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            hostLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: ZestTokens.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _SkipToggle(
                value: draft.skip,
                onChanged: (v) {
                  draft.skip = v;
                  controller.markDirty();
                },
              ),
              _RemoveOverrideButton(
                tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                onTap: () => controller.removeOverride(draft),
              ),
            ],
          ),
          // When reachable, the address/port/route fields.
          if (!draft.skip) ...[
            const SizedBox(height: 10),
            if (recording)
              ZestField.custom(
                label: l10n.hostNetworksAddress,
                leadingIcon: LucideIcons.globe,
                child: RecordingMaskedValue(
                  controller: draft.addressController,
                  mask: (v) => Redactable.address(v).display,
                  isMono: true,
                  placeholder: l10n.hostNetworksAddressPlaceholder(hostLabel),
                ),
              )
            else
              ZestField(
                label: l10n.hostNetworksAddress,
                leadingIcon: LucideIcons.globe,
                controller: draft.addressController,
                placeholder: l10n.hostNetworksAddressPlaceholder(hostLabel),
                isMono: true,
                onChanged: (_) => controller.markDirty(),
              ),
            const SizedBox(height: 8),
            ZestField(
              label: l10n.hostNetworksPort,
              leadingIcon: LucideIcons.hash,
              controller: draft.portController,
              placeholder: l10n.hostNetworksPortPlaceholder(hostLabel),
              isMono: true,
              onChanged: (_) => controller.markDirty(),
            ),
            const SizedBox(height: 12),
            _JumpChainEditor(
              controller: controller,
              draft: draft,
              labels: labels,
            ),
          ] else ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 23),
                Icon(LucideIcons.ban,
                    size: 12, color: ZestTokens.statusCritical),
                const SizedBox(width: 6),
                Text(
                  l10n.hostNetworksStatusUnreachable,
                  style: TextStyle(
                    fontSize: 12,
                    color: ZestTokens.statusCritical,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact remove (x) tap target used by both the collapsed and expanded rows,
/// sized to the header's remove column so the columns line up.
class _RemoveOverrideButton extends StatelessWidget {
  const _RemoveOverrideButton({required this.tooltip, required this.onTap});

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
          child: SizedBox(
            width: _kRemoveColWidth,
            height: 32,
            child: Icon(LucideIcons.x, size: 15, color: ZestTokens.textTertiary),
          ),
        ),
      ),
    );
  }
}

/// The "Unreachable from this network" toggle.
class _SkipToggle extends StatelessWidget {
  const _SkipToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.hostNetworksSkip,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: value
                ? ZestTokens.statusCritical.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: value
                  ? ZestTokens.statusCritical.withValues(alpha: 0.5)
                  : ZestTokens.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value ? LucideIcons.ban : LucideIcons.check,
                size: 12,
                color: value
                    ? ZestTokens.statusCritical
                    : ZestTokens.textTertiary,
              ),
              const SizedBox(width: 5),
              Text(
                l10n.hostNetworksSkipShort,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: value
                      ? ZestTokens.statusCritical
                      : ZestTokens.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ordered jump-host chain editor: chips for each hop (removable) plus an
/// "add another hop" menu of eligible hosts.
class _JumpChainEditor extends ConsumerWidget {
  const _JumpChainEditor({
    required this.controller,
    required this.draft,
    required this.labels,
  });

  final NetworkEditController controller;
  final HostOverrideDraft draft;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    // Jump-host routing is a Squeezed feature: lock this editor on the free
    // tier exactly as the base host's Connect Via field is locked, so a free
    // user cannot configure a chain the connect path would then not dial.
    if (!ref.watch(isProProvider)) {
      return Row(
        children: [
          Icon(LucideIcons.lock,
              size: 13, color: ZestTokens.textTertiary),
          const SizedBox(width: 6),
          Text(
            l10n.hostNetworksJumpHost,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: ZestTokens.textTertiary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.proFeature,
              style: TextStyle(
                  fontSize: 11, color: ZestTokens.textTertiary),
            ),
          ),
          TextButton(
            onPressed: () => context.push(Routes.upgrade),
            child: Text(l10n.upgrade),
          ),
        ],
      );
    }
    // Eligible hops: any host except the overridden host itself and hops
    // already in the chain.
    final candidates = <({String id, String label})>[
      for (final entry in labels.entries)
        if (entry.key != draft.hostId && !draft.jumpChain.contains(entry.key))
          (id: entry.key, label: entry.value),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.milestone,
                size: 13, color: ZestTokens.textTertiary),
            const SizedBox(width: 6),
            Text(
              l10n.hostNetworksJumpHost,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: ZestTokens.textTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (draft.jumpChain.isEmpty)
              Text(
                l10n.hostNetworksJumpDirect,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                  color: ZestTokens.textPlaceholder,
                ),
              ),
            for (var i = 0; i < draft.jumpChain.length; i++)
              _HopChip(
                index: i + 1,
                label: labels[draft.jumpChain[i]] ?? draft.jumpChain[i],
                onRemove: () {
                  draft.jumpChain.removeAt(i);
                  controller.markDirty();
                },
              ),
            _AddHopButton(
              enabled: candidates.isNotEmpty,
              candidates: candidates,
              onSelected: (id) {
                draft.jumpChain.add(id);
                controller.markDirty();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _HopChip extends StatelessWidget {
  const _HopChip({
    required this.index,
    required this.label,
    required this.onRemove,
  });

  final int index;
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$index',
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'JetBrainsMono',
              fontWeight: FontWeight.w600,
              color: ZestTokens.textTertiary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
                fontSize: 12, color: ZestTokens.textPrimary),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            child: Tooltip(
              message: l10n.hostNetworksJumpRemove,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(LucideIcons.x,
                    size: 12, color: ZestTokens.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddHopButton extends StatelessWidget {
  const _AddHopButton({
    required this.enabled,
    required this.candidates,
    required this.onSelected,
  });

  final bool enabled;
  final List<({String id, String label})> candidates;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: l10n.hostNetworksJumpAddAnother,
      color: ZestTokens.surfaceRaised,
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final c in candidates)
          PopupMenuItem<String>(
            value: c.id,
            child: Text(
              c.label,
              style: TextStyle(
                  fontSize: 13, color: ZestTokens.textPrimary),
            ),
          ),
      ],
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ZestTokens.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.plus, size: 12, color: ZestTokens.brandInk),
              const SizedBox(width: 4),
              Text(
                l10n.hostNetworksJumpAddAnother,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: ZestTokens.brandInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
