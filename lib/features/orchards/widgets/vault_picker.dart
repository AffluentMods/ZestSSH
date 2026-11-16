import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/hosts/widgets/hosts_band.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/crate_filter_chips.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Shows [crate]'s hosts on the Hosts page (null: every vault's), and makes
/// it the vault new items go to where this account may add there.
Future<void> pickVault(WidgetRef ref, CrateSummary? crate) async {
  ref.read(selectedCrateFilterProvider.notifier).state = crate?.id;
  if (crate == null || !crate.canAdd) return;
  await ref.read(cratePlacementProvider)?.setDefaultCrate(crate.id);
  ref.read(orchardListVersionProvider.notifier).state++;
}

/// Shows [crate]'s hosts on the Hosts page and nothing more: the vault new
/// items go to stays the one it was (a vault's Show hosts, Team > Vaults,
/// is a look at it, not a choice of where new hosts go).
void showVaultHosts(WidgetRef ref, CrateSummary crate) =>
    ref.read(selectedCrateFilterProvider.notifier).state = crate.id;

/// How many hosts each vault of [orchard] holds.
Map<String, int> vaultHostCounts(WidgetRef ref, OrchardSummary orchard) {
  final hostCrates = ref.watch(hostCratesProvider).valueOrNull ?? const {};
  final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];
  final counts = <String, int>{};
  for (final h in hosts) {
    final crate = crateOfHost(h.connection.id, hostCrates, orchard);
    if (crate != null) counts[crate] = (counts[crate] ?? 0) + 1;
  }
  return counts;
}

/// The vault the Hosts page shows, as one button of its band with a list
/// under it (3.0: a row of chips does not
/// hold thirty vaults; the vaults themselves, with what each allows, are
/// Team > Vaults, where the list ends).
class VaultPickerButton extends ConsumerWidget {
  const VaultPickerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orchard = ref.watch(activeOrchardProvider).valueOrNull;
    if (orchard == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final selectedId = ref.watch(selectedCrateFilterProvider);
    final selected = orchard.crates.where((c) => c.id == selectedId).firstOrNull;
    final defaultCrate = orchard.crates.where((c) => c.id == orchard.defaultCrateId).firstOrNull;
    return Builder(
      builder: (anchor) => BandButton(
        key: const ValueKey('hosts-vault'),
        icon: LucideIcons.package,
        label: selected == null ? l10n.crateAll : crateDisplayName(selected, l10n),
        trailingIcon: LucideIcons.chevronDown,
        tooltip: defaultCrate != null && orchard.crates.length > 1
            ? l10n.crateNewItemsGoTo(crateDisplayName(defaultCrate, l10n))
            : null,
        onPressed: () => _open(anchor, ref, orchard),
      ),
    );
  }

  Future<void> _open(BuildContext anchor, WidgetRef ref, OrchardSummary orchard) async {
    final box = anchor.findRenderObject();
    if (box is! RenderBox) return;
    final origin = box.localToGlobal(Offset.zero);
    await showDialog<void>(
      context: anchor,
      barrierColor: Colors.transparent,
      builder: (dialogContext) => Stack(
        children: [
          Positioned(
            top: origin.dy + box.size.height + 6,
            left: origin.dx,
            child: Material(
              color: Colors.transparent,
              child: _VaultList(
                orchardId: orchard.id,
                onPick: (crate) {
                  Navigator.of(dialogContext).pop();
                  pickVault(ref, crate);
                },
                onManage: () {
                  Navigator.of(dialogContext).pop();
                  openTeamPage(ref, TeamPage.crates);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VaultList extends ConsumerStatefulWidget {
  const _VaultList({required this.orchardId, required this.onPick, required this.onManage});
  final String orchardId;
  final ValueChanged<CrateSummary?> onPick;
  final VoidCallback onManage;

  @override
  ConsumerState<_VaultList> createState() => _VaultListState();
}

class _VaultListState extends ConsumerState<_VaultList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = ref
        .watch(orchardSummariesProvider)
        .valueOrNull
        ?.where((o) => o.id == widget.orchardId)
        .firstOrNull;
    if (orchard == null) return const SizedBox.shrink();
    final counts = vaultHostCounts(ref, orchard);
    final selectedId = ref.watch(selectedCrateFilterProvider);
    final q = _query.trim().toLowerCase();
    final crates = [
      for (final c in orchard.crates)
        if (q.isEmpty || crateDisplayName(c, l10n).toLowerCase().contains(q)) c,
    ];
    return Container(
      key: const ValueKey('hosts-vault-list'),
      width: 290,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderStrong),
        boxShadow: const [BoxShadow(color: Color(0xA6000000), blurRadius: 60, offset: Offset(0, 24), spreadRadius: -12)],
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A search where there are more vaults than a glance takes in.
          if (orchard.crates.length > 7)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
              child: SizedBox(
                height: 32,
                child: TextField(
                  key: const ValueKey('hosts-vault-search'),
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(fontSize: 12.5, color: ZestTokens.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.vaultPickerSearch,
                    hintStyle: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
                    prefixIcon: Icon(LucideIcons.search, size: 14, color: ZestTokens.textTertiary),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    filled: true,
                    fillColor: ZestTokens.surfaceSunken,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(7),
                      borderSide: BorderSide(color: ZestTokens.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(7),
                      borderSide: BorderSide(color: ZestTokens.border),
                    ),
                  ),
                ),
              ),
            ),
          if (q.isEmpty)
            _Row(
              key: const ValueKey('vault-row-all'),
              icon: LucideIcons.layers,
              label: l10n.crateAll,
              count: counts.values.fold<int>(0, (a, b) => a + b),
              selected: selectedId == null,
              onTap: () => widget.onPick(null),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final c in crates)
                  _Row(
                    key: ValueKey('vault-row-${c.id}'),
                    icon: c.ownersOnly ? LucideIcons.lock : LucideIcons.package,
                    label: crateDisplayName(c, l10n),
                    redact: true,
                    count: counts[c.id] ?? 0,
                    note: c.canAdd ? null : l10n.crateReadOnly,
                    selected: selectedId == c.id,
                    onTap: () => widget.onPick(c),
                  ),
              ],
            ),
          ),
          Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 4), color: ZestTokens.border),
          _Row(
            key: const ValueKey('vault-row-manage'),
            icon: LucideIcons.settings2,
            label: l10n.vaultPickerManage,
            onTap: widget.onManage,
          ),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.count,
    this.note,
    this.selected = false,
    this.redact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int? count;
  final String? note;
  final bool selected;
  final bool redact;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12.5,
      color: ZestTokens.textPrimary,
      fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? ZestTokens.brand.withValues(alpha: 0.08)
                : (_hover ? ZestTokens.surfaceHover : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: widget.selected ? ZestTokens.brandInk : ZestTokens.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                child: widget.redact
                    ? RedactedText(Redactable.freeText(widget.label), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)
                    : Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ),
              if (widget.note != null) ...[
                Text(widget.note!, style: TextStyle(fontSize: 11, color: ZestTokens.textTertiary)),
                const SizedBox(width: 8),
              ],
              if (widget.count != null)
                Text(
                  '${widget.count}',
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: ZestTokens.textTertiary),
                ),
              if (widget.selected) ...[
                const SizedBox(width: 8),
                Icon(LucideIcons.check, size: 14, color: ZestTokens.brandInk),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
