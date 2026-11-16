import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/vaults_page.dart' show vaultPeople, vaultPersonName;
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';

/// The Crate a host is in: its own, or the Crate new items go to while it
/// has not been placed.
String? crateOfHost(String hostId, Map<String, String> hostCrates, OrchardSummary orchard) =>
    hostCrates[hostId] ?? orchard.defaultCrateId;

/// The Crates of the Orchard on screen, as filter chips above the host list
/// (3.0). Picking a Crate shows its hosts and makes it the Crate new
/// items go to; dropping a host card on a Crate moves the host there. Shows
/// nothing while your Tree is on screen.
class CrateFilterChips extends ConsumerWidget {
  const CrateFilterChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orchard = ref.watch(activeOrchardProvider).valueOrNull;
    if (orchard == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final hostCrates = ref.watch(hostCratesProvider).valueOrNull ?? const {};
    final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];
    final selected = ref.watch(selectedCrateFilterProvider);
    final counts = <String, int>{};
    for (final h in hosts) {
      final crate = crateOfHost(h.connection.id, hostCrates, orchard);
      if (crate != null) counts[crate] = (counts[crate] ?? 0) + 1;
    }
    final defaultCrate =
        orchard.crates.where((c) => c.id == orchard.defaultCrateId).firstOrNull;
    // Who else can open each vault, as small faces on its chip (3.2).
    final people = ref.watch(teamPeopleProvider(orchard.id)).valueOrNull;
    final timed = ref.watch(timedAccessProvider(orchard.id)).valueOrNull ?? const <TimedAccess>[];
    List<String> facesOf(CrateSummary crate) => people == null
        ? const []
        : [for (final p in vaultPeople(crate, people, timed)) vaultPersonName(ref, people, p.uid)];

    Future<void> pick(CrateSummary? crate) async {
      ref.read(selectedCrateFilterProvider.notifier).state = crate?.id;
      // New items go where this account may add them.
      if (crate == null || !crate.canAdd) return;
      await ref.read(cratePlacementProvider)?.setDefaultCrate(crate.id);
      ref.read(orchardListVersionProvider.notifier).state++;
    }

    Future<void> drop(CrateSummary crate, ConnectionWithDetails host) async {
      if (!crate.canAdd || crateOfHost(host.connection.id, hostCrates, orchard) == crate.id) {
        return;
      }
      await moveHostToCrate(context, ref, host.connection.id, crate);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const OrchardStatusBanner(),
        SizedBox(
          height: 26,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _CrateChip(
                icon: LucideIcons.package,
                label: l10n.crateAll,
                count: hosts.length,
                selected: selected == null,
                onTap: () => pick(null),
              ),
              for (final crate in orchard.crates) ...[
                const SizedBox(width: 8),
                _CrateChip(
                  icon: crate.canAdd ? null : LucideIcons.lock,
                  label: crateDisplayName(crate, l10n),
                  count: counts[crate.id] ?? 0,
                  selected: selected == crate.id,
                  tooltip: crate.canAdd ? null : l10n.crateReadOnly,
                  faces: facesOf(crate),
                  onTap: () => pick(crate),
                  onAccept: crate.canAdd ? (host) => drop(crate, host) : null,
                ),
              ],
              if (orchard.canAddCrates) ...[
                const SizedBox(width: 8),
                _CrateChip(
                  icon: LucideIcons.plus,
                  label: l10n.crateNewAction,
                  muted: true,
                  selected: false,
                  onTap: () => showNewCrateDialog(context, ref, orchard.id),
                ),
              ],
            ],
          ),
        ),
        if (defaultCrate != null && orchard.crates.length > 1) ...[
          const SizedBox(height: 6),
          Text(
            l10n.crateNewItemsGoTo(crateDisplayName(defaultCrate, l10n)),
            style: TextStyle(fontSize: 11, color: ZestColors.textTertiary),
          ),
        ],
      ],
    );
  }
}

class _CrateChip extends StatefulWidget {
  const _CrateChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.count,
    this.muted = false,
    this.tooltip,
    this.onAccept,
    this.faces = const [],
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final int? count;
  final bool muted;
  final String? tooltip;
  final void Function(ConnectionWithDetails host)? onAccept;

  /// The names of the other people who can open the vault, drawn as faces.
  final List<String> faces;

  @override
  State<_CrateChip> createState() => _CrateChipState();
}

class _CrateChipState extends State<_CrateChip> {
  bool _dropHover = false;

  @override
  Widget build(BuildContext context) {
    final onAccept = widget.onAccept;
    Widget chip = onAccept == null
        ? _chip()
        : DragTarget<ConnectionWithDetails>(
            onWillAcceptWithDetails: (_) {
              setState(() => _dropHover = true);
              return true;
            },
            onLeave: (_) => setState(() => _dropHover = false),
            onAcceptWithDetails: (details) {
              setState(() => _dropHover = false);
              onAccept(details.data);
            },
            builder: (_, _, _) => _chip(),
          );
    final tooltip = widget.tooltip;
    if (tooltip != null) chip = Tooltip(message: tooltip, child: chip);
    return chip;
  }

  Widget _chip() {
    final bg = _dropHover
        ? ZestColors.accentPrimary.withValues(alpha: 0.18)
        : (widget.selected ? ZestColors.textPrimary : ZestColors.bgSurface);
    final fg = _dropHover
        ? ZestColors.accentInk
        : (widget.selected
            ? ZestColors.bgContent
            : (widget.muted ? ZestColors.textTertiary : ZestColors.textPrimary));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(13),
            border: _dropHover
                ? Border.all(color: ZestColors.accentPrimary.withValues(alpha: 0.65))
                : (widget.selected
                    ? null
                    : Border.all(color: ZestColors.borderDefault, width: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 12, color: fg),
                const SizedBox(width: 4),
              ],
              Text(
                widget.label,
                style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w500),
              ),
              if (widget.count != null) ...[
                const SizedBox(width: 6),
                Text(
                  '${widget.count}',
                  style: TextStyle(
                    color: _dropHover || widget.selected ? fg : ZestColors.textTertiary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (widget.faces.isNotEmpty) ...[
                const SizedBox(width: 6),
                VaultFaces(names: widget.faces, ring: bg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The other people who can open a vault, as overlapping circles with their
/// first letter (three at most, then how many more), their names on a hover
/// or a long press (3.2).
class VaultFaces extends StatelessWidget {
  const VaultFaces({super.key, required this.names, required this.ring, this.size = 16});

  final List<String> names;

  /// The colour behind them, drawn as a ring so overlapping faces part.
  final Color ring;
  final double size;

  static const _shown = 3;

  @override
  Widget build(BuildContext context) {
    final shown = names.take(_shown).toList();
    final more = names.length - shown.length;
    final step = size * 0.62;
    return Tooltip(
      message: names.join('\n'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size + step * (shown.length - 1),
            height: size,
            child: Stack(
              children: [
                for (var i = 0; i < shown.length; i++)
                  Positioned(
                    left: step * i,
                    child: Container(
                      key: ValueKey('vault-face-$i'),
                      width: size,
                      height: size,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: ZestColors.bgSurface,
                        shape: BoxShape.circle,
                        border: Border.all(color: ring, width: 1.5),
                      ),
                      child: Text(
                        _letter(shown[i]),
                        style: TextStyle(
                          fontSize: size * 0.5,
                          fontWeight: FontWeight.w700,
                          color: ZestColors.textSecondary,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (more > 0) ...[
            const SizedBox(width: 3),
            Text('+$more', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: ZestColors.textTertiary)),
          ],
        ],
      ),
    );
  }

  static String _letter(String name) {
    final n = name.trim();
    return n.isEmpty ? '?' : n.characters.first.toUpperCase();
  }
}
