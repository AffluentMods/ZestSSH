import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../database/database.dart' show Connection;
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/connection_providers.dart';
import '../../../providers/network_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../ui/screens/connection/connection_edit_screen.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../../../ui/widgets/zest_empty_state.dart';
import '../models/network.dart';
import 'network_list_tile.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// Presentation-only Networks list shared by BOTH the desktop
/// `NetworksPage` (side-by-side split editor) and the mobile Networks
/// screen (full-route editor).
///
/// Renders the evaluation-order list: user-defined networks are
/// reorderable, the system Default is pinned last (non-reorderable,
/// non-deletable), each row carries its first-match ordinal, the live
/// "Matched now" pill, and the A3 override-count disclosure. Editing and
/// creating are delegated to [onEdit] so each host decides whether that
/// opens a split pane (desktop) or pushes a route (mobile).
class NetworksListView extends ConsumerWidget {
  const NetworksListView({
    super.key,
    required this.networks,
    required this.onEdit,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
    this.maxWidth = 720,
    this.alignment = Alignment.topLeft,
  });

  /// The networks to render, already in evaluation order (Default last).
  final List<Network> networks;

  /// Invoked with a network id when the user taps a row (or its pencil).
  final void Function(String networkId) onEdit;

  /// Outer list padding.
  final EdgeInsets padding;

  /// Constrains the rows to a readable width and hugs the left edge (A4).
  final double maxWidth;

  /// Where the rows' column sits: at the left on a computer (A4); a tablet
  /// centres it, as its other pages (PhonePageColumn).
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Split into reorderable (non-default) and pinned (default) so the
    // ReorderableListView only lets the user move the user-defined ones.
    final reorderable =
        networks.where((n) => !n.isFallback).toList(growable: false);
    final pinned = networks.where((n) => n.isFallback).toList(growable: false);

    final detected = ref.watch(detectedNetworkProvider).valueOrNull;
    final matchedId = detected?.id;

    // The Default fallback is always evaluated last, so it continues the
    // 1-based ordinal after the reorderable networks.
    final pinnedStart = reorderable.length;

    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          padding: padding,
          children: [
            // Evaluation-order hint - states outright that vertical order is
            // priority, which the ordinals then reinforce per row (A4).
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Row(
                children: [
                  Icon(LucideIcons.arrowDownWideNarrow,
                      size: 13, color: AppColors.v3TextTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.networksEvalOrderHint,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.v3TextTertiary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (reorderable.isNotEmpty)
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: reorderable.length,
                buildDefaultDragHandles: false,
                itemBuilder: (context, index) {
                  final net = reorderable[index];
                  return Padding(
                    key: ValueKey(net.id),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _NetworkRow(
                      network: net,
                      order: index + 1,
                      isMatched: matchedId == net.id,
                      onTap: () => onEdit(net.id),
                      onDelete: () => _confirmDelete(context, ref, net),
                      dragHandle: ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            LucideIcons.gripVertical,
                            size: 16,
                            color: AppColors.v3TextTertiary,
                          ),
                        ),
                      ),
                    ),
                  );
                },
                onReorderItem: (oldIndex, newIndex) async {
                  final ids = reorderable.map((n) => n.id).toList();
                  final id = ids.removeAt(oldIndex);
                  ids.insert(newIndex, id);
                  await ref.read(networkRepositoryProvider).reorder(ids);
                },
              ),
            if (pinned.isNotEmpty) ...[
              const SizedBox(height: 4),
              for (var i = 0; i < pinned.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _NetworkRow(
                    network: pinned[i],
                    order: pinnedStart + i + 1,
                    isMatched: matchedId == pinned[i].id,
                    onTap: () => onEdit(pinned[i].id),
                    showDragHandle: false,
                    // No onDelete on Default - the repository would refuse
                    // anyway, but suppress the affordance so the user never
                    // gets the confusing red-button-then-error flow.
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Network network,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    // State the blast radius outright: how many hosts override on this
    // network today (A3). Deleting strips those overrides - the repository
    // guarantees that, so we're only warning here, not doing extra work.
    final count = ref
            .read(overrideCountsByNetworkProvider)
            .valueOrNull?[network.id] ??
        0;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      // Built outside build: the display form is a snapshot (recording mode).
      title: l10n.networksDeleteTitle(Redactable.network(network.name).display),
      body: count > 0
          ? l10n.networksDeleteWarningCount(count)
          : l10n.networksDeleteBody,
      confirmLabel: l10n.networksDelete,
      cancelLabel: l10n.networkEditorCancel,
    );
    if (confirmed != true) return;
    await ref.read(networkRepositoryProvider).delete(network.id);
  }
}

/// Shared empty-state panel for the Networks list. The CTA is delegated via
/// [onCta] so desktop can open the split editor and mobile can push a route.
class NetworksEmptyState extends StatelessWidget {
  const NetworksEmptyState({
    super.key,
    required this.title,
    required this.description,
    this.ctaLabel,
    this.onCta,
  });

  final String title;
  final String description;
  final String? ctaLabel;
  final VoidCallback? onCta;

  @override
  Widget build(BuildContext context) {
    return ZestEmptyState(
      icon: LucideIcons.network,
      title: title,
      message: description,
      actionLabel: ctaLabel,
      onAction: onCta,
    );
  }
}

// ── Network row (tile + A3 override visibility) ─────────────────────

/// One network row: the [NetworkListTile] plus the A3 override-count badge
/// and the inline, expandable list of hosts overriding on this network.
class _NetworkRow extends ConsumerStatefulWidget {
  const _NetworkRow({
    required this.network,
    required this.isMatched,
    required this.onTap,
    this.order,
    this.showDragHandle = true,
    this.onDelete,
    this.dragHandle,
  });

  final Network network;
  final int? order;
  final bool isMatched;
  final VoidCallback onTap;
  final bool showDragHandle;
  final VoidCallback? onDelete;
  final Widget? dragHandle;

  @override
  ConsumerState<_NetworkRow> createState() => _NetworkRowState();
}

class _NetworkRowState extends ConsumerState<_NetworkRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final count = ref
            .watch(overrideCountsByNetworkProvider)
            .valueOrNull?[widget.network.id] ??
        0;

    // The badge only appears when at least one host overrides here - which
    // also keeps it off the Default fallback unless it genuinely has
    // overrides (A3). Never render the expanded list without a badge.
    final expanded = _expanded && count > 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        NetworkListTile(
          network: widget.network,
          order: widget.order,
          isMatched: widget.isMatched,
          onTap: widget.onTap,
          showDragHandle: widget.showDragHandle,
          onDelete: widget.onDelete,
          dragHandle: widget.dragHandle,
          overrideBadge: count > 0
              ? _OverrideCountBadge(
                  count: count,
                  expanded: expanded,
                  onTap: () => setState(() => _expanded = !_expanded),
                )
              : null,
        ),
        if (expanded) _OverrideHostList(networkId: widget.network.id),
      ],
    );
  }
}

/// The muted, tappable "{n} host overrides" disclosure badge (A3).
class _OverrideCountBadge extends StatelessWidget {
  const _OverrideCountBadge({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.v3Elevated,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.v3BorderDefault, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.networksOverrideCount(count),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.v3TextSecondary,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 12,
                color: AppColors.v3TextTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline, indented list of the hosts overriding on [networkId] (A3).
class _OverrideHostList extends ConsumerWidget {
  const _OverrideHostList({required this.networkId});

  final String networkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final overridesAsync =
        ref.watch(hostOverridesForNetworkProvider(networkId));

    return Container(
      margin: const EdgeInsets.only(top: 6, left: 28, right: 4, bottom: 2),
      decoration: BoxDecoration(
        color: AppColors.v3Surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: overridesAsync.when(
        loading: () => Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.v3AccentPrimary,
              ),
            ),
          ),
        ),
        error: (_, _) => Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            l10n.networksOverrideListLoadError,
            style: TextStyle(fontSize: 12, color: AppColors.v3Error),
          ),
        ),
        data: (overrides) {
          if (overrides.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                l10n.networksOverrideListEmpty,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.v3TextTertiary,
                ),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                child: Text(
                  l10n.networksOverrideListHeader,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ),
              for (final o in overrides) _OverrideHostTile(hostId: o.hostId),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }
}

/// A single clickable host in the expanded override list. Resolves the
/// host's label from the live connections list and, on tap, opens that
/// connection's editor (its Networks section is where the override lives).
class _OverrideHostTile extends ConsumerWidget {
  const _OverrideHostTile({required this.hostId});

  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connections =
        ref.watch(connectionsWithDetailsProvider).valueOrNull;

    // Connections still loading - hold a slot rather than flashing an empty
    // label; the stream is almost always already warm on this screen.
    if (connections == null) {
      return const SizedBox(height: 36);
    }

    Connection? conn;
    for (final c in connections) {
      if (c.connection.id == hostId) {
        conn = c.connection;
        break;
      }
    }
    // Orphaned override (host deleted): the count/list providers key off the
    // override rows, so a stale host id can slip through - drop the row.
    if (conn == null) return const SizedBox.shrink();

    final resolved = conn;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => ConnectionEditScreen.showAdaptive(
          context,
          connectionId: hostId,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: HostRow(
                  host: resolved,
                  under: true,
                  iconSize: 20,
                  nameStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.v3TextPrimary,
                  ),
                  padding: EdgeInsets.zero,
                  margin: EdgeInsets.zero,
                  hovers: false,
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: l10n.networksOverrideOpenHost,
                child: Icon(
                  LucideIcons.chevronRight,
                  size: 15,
                  color: AppColors.v3TextTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
