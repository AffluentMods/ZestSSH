import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../providers/network_providers.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_button.dart';
import '../../../ui/widgets/zest_status.dart';
import '../engine/network_detector.dart';
import '../models/network.dart';
import '../state/network_controller.dart';
import 'network_rule_words.dart';
import 'trigger_summary.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// The left-hand side of the computer's Networks page:
/// the page's header (title, New network, the
/// filter); ACTIVE NOW, with why and a way to make a network for where this
/// device is; then the networks in the order they are checked, numbered,
/// to drag, a network being made marked "Not saved yet", and Default pinned
/// last.
class NetworkListPane extends ConsumerStatefulWidget {
  const NetworkListPane({
    super.key,
    required this.selectedId,
    required this.onSelect,
    required this.onNew,
    this.draft,
    this.onMakeFor,
  });

  /// Currently-open network id (or the new-network sentinel), for highlight.
  final String? selectedId;

  /// Select a network row.
  final ValueChanged<String> onSelect;

  /// Create a brand-new network.
  final VoidCallback onNew;

  /// The editor: while it makes a new network with something in it, that
  /// network has a card of its own, not saved yet.
  final NetworkEditController? draft;

  /// Make a network for where this device is (ACTIVE NOW's button).
  final ValueChanged<CurrentNetworkSuggestion>? onMakeFor;

  @override
  ConsumerState<NetworkListPane> createState() => _NetworkListPaneState();
}

class _NetworkListPaneState extends ConsumerState<NetworkListPane> {
  String _query = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final networksAsync = ref.watch(allNetworksProvider);
    final matchedId = ref.watch(detectedNetworkProvider).valueOrNull?.id;
    final counts = ref.watch(overrideCountsByNetworkProvider).valueOrNull ?? const {};

    return Container(
      color: ZestTokens.surfaceBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            search: ZestListSearchField(
              controller: _search,
              focusNode: _searchFocus,
              hintText: l10n.netPageFilterHint,
              onChanged: (q) => setState(() => _query = q),
            ),
            onNew: widget.onNew,
          ),
          Expanded(
            child: networksAsync.when(
              // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
              skipLoadingOnReload: true,
              loading: () => Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.brand),
                ),
              ),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(l10n.networksOverrideListLoadError, style: TextStyle(color: ZestTokens.statusCritical)),
                ),
              ),
              data: (networks) => _list(context, networks, matchedId, counts),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, List<Network> networks, String? matchedId, Map<String, int> counts) {
    final l10n = AppLocalizations.of(context)!;
    final q = _query.trim().toLowerCase();
    bool shown(Network n) =>
        q.isEmpty ||
        n.name.toLowerCase().contains(q) ||
        summariseTriggers(context, n.triggers).toLowerCase().contains(q) ||
        networkWhenWords(l10n, n.triggers).toLowerCase().contains(q);
    final filtered = networks.where(shown).toList();
    final reorderable = filtered.where((n) => !n.isFallback).toList(growable: false);
    final pinned = filtered.where((n) => n.isFallback).toList(growable: false);
    // Reorder only makes sense on the full, unfiltered set.
    final canReorder = q.isEmpty;
    // Dead-config detection runs against the FULL evaluation order so a network
    // hidden by the filter is still judged against the rules above it.
    final dead = shadowedNetworkIds(networks);
    final draft = widget.draft;
    final drafting = draft != null && draft.isCreating && draft.isDirty && q.isEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 2, 24, 24),
      children: [
        _ActiveNow(onMakeFor: widget.onMakeFor),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 10),
          child: Row(
            children: [
              Icon(LucideIcons.arrowDownWideNarrow, size: 13, color: ZestTokens.textTertiary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.netPageEvalHint,
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textTertiary),
                ),
              ),
            ],
          ),
        ),
        if (reorderable.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: reorderable.length,
            onReorderItem: (oldIndex, newIndex) async {
              final ids = reorderable.map((n) => n.id).toList();
              final id = ids.removeAt(oldIndex);
              ids.insert(newIndex, id);
              await ref.read(networkRepositoryProvider).reorder(ids);
            },
            itemBuilder: (context, index) {
              final net = reorderable[index];
              return _NetworkCard(
                key: ValueKey(net.id),
                network: net,
                order: index + 1,
                selected: widget.selectedId == net.id,
                matched: matchedId == net.id,
                dead: dead.contains(net.id),
                overrideCount: counts[net.id] ?? 0,
                onTap: () => widget.onSelect(net.id),
                leading: canReorder
                    ? ReorderableDragStartListener(
                        index: index,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(LucideIcons.gripVertical, size: 15, color: ZestTokens.textTertiary),
                          ),
                        ),
                      )
                    : null,
              );
            },
          ),
        if (drafting)
          _DraftCard(controller: draft, order: networks.where((n) => !n.isFallback).length + 1),
        for (final net in pinned)
          _NetworkCard(
            key: ValueKey(net.id),
            network: net,
            order: null,
            selected: widget.selectedId == net.id,
            matched: matchedId == net.id,
            dead: false,
            overrideCount: counts[net.id] ?? 0,
            onTap: () => widget.onSelect(net.id),
            leading: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(LucideIcons.lock, size: 14, color: ZestTokens.textTertiary),
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Header
// ══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  const _Header({required this.search, required this.onNew});

  final Widget search;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = GuideTitle(
      feature: 'networks',
      title: Text(
        l10n.zestNetworkTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary, height: 1.2),
      ),
    );
    final newNetwork = ZestButton(
      key: const ValueKey('network-new'),
      label: l10n.zestNetworkNewLabel,
      icon: LucideIcons.plus,
      variant: ZestButtonVariant.primary,
      onPressed: onNew,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth < 560
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [Expanded(child: title), const SizedBox(width: 12), newNetwork]),
                  const SizedBox(height: 12),
                  search,
                ],
              )
            : Row(
                children: [
                  Flexible(child: title),
                  const SizedBox(width: 18),
                  newNetwork,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: search),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Active now
// ══════════════════════════════════════════════════════════════════

/// The network in use, why, and where this device is (the Wi-Fi's name
/// where it is read, and the subnet); a way to make a network for it where
/// nothing else matched, and to detect again.
class _ActiveNow extends ConsumerWidget {
  const _ActiveNow({required this.onMakeFor});

  final ValueChanged<CurrentNetworkSuggestion>? onMakeFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final networks = ref.watch(allNetworksProvider).valueOrNull;
    final effective = ref.watch(effectiveNetworkProvider).valueOrNull;
    if (networks == null || effective == null) return const SizedBox.shrink();

    final overrideId = ref.watch(manualNetworkOverrideIdProvider);
    final isForced = overrideId != null && networks.any((n) => n.id == overrideId);
    final reason = ref.watch(detectedNetworkMatchProvider).valueOrNull?.reason;
    final state = ref.watch(currentNetworkStateProvider).valueOrNull;
    final here = state == null ? null : suggestCurrentNetwork(state);

    final why = isForced
        ? l10n.networkBannerForcedReason
        : effective.isFallback || reason == null
            ? l10n.netPageWhyDefault
            : l10n.netPageWhyMatched(networkRuleWords(l10n, reason, ref: ref));
    final where = here == null
        ? null
        : here.hasSsid && here.hasSubnet
            ? l10n.netPageOnWifi(Redactable.network(here.ssid!).displayIn(ref), maskedCidr(here.subnetCidr!, ref))
            : here.hasSubnet
                ? l10n.netPageOnSubnet(maskedCidr(here.subnetCidr!, ref))
                : null;
    final canMake = onMakeFor != null && effective.isFallback && !isForced && here != null && !here.isEmpty;
    final color = effective.effectiveColor;
    final eyebrowStyle = TextStyle(
      fontSize: 10,
      fontFamily: 'JetBrainsMono',
      fontWeight: FontWeight.w600,
      letterSpacing: 1.2,
      color: ZestTokens.textTertiary,
    );
    final makeButton = !canMake
        ? null
        : ZestButton(
            key: const ValueKey('network-make-for-here'),
            label: here.hasSsid ? l10n.netPageMakeForWifi : l10n.netPageMakeForSubnet,
            icon: LucideIcons.plus,
            variant: ZestButtonVariant.secondary,
            onPressed: () => onMakeFor!(here),
          );

    return Container(
      key: const ValueKey('network-active-now'),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.border),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        // "Make a network for this Wi-Fi" stands beside the words where it
        // leaves them room, else under them: beside them in a narrow list or
        // at a larger text size it left the words a sliver ("ACTIF
        // MAINTENANT" broke inside a word in French at 1.25 times).
        var buttonUnder = false;
        if (makeButton != null) {
          final scaler = MediaQuery.textScalerOf(context);
          final direction = Directionality.of(context);
          double widthOf(String text, TextStyle style) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: direction,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final w = painter.width;
            painter.dispose();
            return w;
          }

          final label = DefaultTextStyle.of(context).style.merge(
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.0),
              );
          // The button: its padding, its icon and the gap, and its label.
          final button = 2 * ZestSizing.buttonMediumPaddingX + 16 + ZestSizing.buttonGap + 2 +
              widthOf(makeButton.label, label);
          // The icon and its gap, the gaps either side of the button, and the redetect button.
          final words = constraints.maxWidth - 36 - 14 - 12 - button - 6 - 48;
          final eyebrow = widthOf(l10n.zestNetworkActiveEyebrow.toUpperCase(), eyebrowStyle);
          buttonUnder = words < eyebrow;
        }
        return Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: effective.isFallback ? ZestTokens.surfaceChip : color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(effective.icon, size: 17, color: effective.isFallback ? ZestTokens.textSecondary : color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.zestNetworkActiveEyebrow.toUpperCase(), style: eyebrowStyle),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: RedactedText(
                          Redactable.network(effective.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                        ),
                      ),
                      if (isForced) ...[
                        const SizedBox(width: 6),
                        Icon(LucideIcons.pin, size: 11, color: ZestTokens.brandInk),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [why, ?where].join(' '),
                    key: const ValueKey('network-active-why'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary),
                  ),
                  if (makeButton != null && buttonUnder) ...[
                    const SizedBox(height: 10),
                    makeButton,
                  ],
                ],
              ),
            ),
            if (makeButton != null && !buttonUnder) ...[
              const SizedBox(width: 12),
              makeButton,
            ],
            const SizedBox(width: 6),
            IconButton(
              key: const ValueKey('network-redetect'),
              icon: const Icon(LucideIcons.refreshCw, size: 15),
              color: ZestTokens.textSecondary,
              splashRadius: 16,
              tooltip: l10n.zestNetworkRedetect,
              onPressed: () {
                ref.invalidate(detectedNetworkProvider);
                ref.invalidate(detectedNetworkMatchProvider);
                ref.invalidate(currentNetworkStateProvider);
              },
            ),
          ],
        );
      }),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// A network's card
// ══════════════════════════════════════════════════════════════════

class _NetworkCard extends ConsumerStatefulWidget {
  const _NetworkCard({
    super.key,
    required this.network,
    required this.selected,
    required this.matched,
    required this.dead,
    required this.overrideCount,
    required this.onTap,
    this.order,
    this.leading,
  });

  final Network network;
  final bool selected;
  final bool matched;
  final bool dead;
  final int overrideCount;
  final VoidCallback onTap;

  /// Its place in the order the networks are checked; null for Default.
  final int? order;

  /// The drag handle, or Default's lock.
  final Widget? leading;

  @override
  ConsumerState<_NetworkCard> createState() => _NetworkCardState();
}

class _NetworkCardState extends ConsumerState<_NetworkCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final net = widget.network;
    final selected = widget.selected;
    final when = net.isFallback ? l10n.zestNetworkFallbackWhen : networkWhenWords(l10n, net.triggers, ref: ref);
    final subtitle = [when, ..._effect(l10n)].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // Reached with Tab, opened with Enter, said as a button and whether it
      // is the one open (4.0, the accessibility pass: it was a bare tap).
      child: ZestPressable(
          onTap: widget.onTap,
          onHover: (h) => setState(() => _hover = h),
          selected: selected,
          minSize: 0,
          borderRadius: 10,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.fromLTRB(10, 12, 16, 12),
            decoration: BoxDecoration(
              color: selected
                  ? ZestTokens.brandSubtle
                  : _hover
                      ? ZestTokens.surfaceRaisedAlt
                      : ZestTokens.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? ZestTokens.brandBorder : ZestTokens.border),
            ),
            child: Row(
              children: [
                SizedBox(width: 24, child: Center(child: widget.leading)),
                const SizedBox(width: 6),
                SizedBox(
                  width: 18,
                  child: Text(
                    widget.order == null ? '' : '${widget.order}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'JetBrainsMono',
                      fontWeight: FontWeight.w600,
                      color: ZestTokens.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _NetworkTile(network: net),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RedactedText(
                        Redactable.network(net.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: widget.dead ? ZestTokens.textSecondary : ZestTokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (widget.dead) ...[
                  const SizedBox(width: 8),
                  _NeverMatchesBadge(hint: l10n.zestNetworkNeverMatchesHint),
                ] else if (widget.matched && !net.isFallback) ...[
                  const SizedBox(width: 8),
                  _MatchedPill(label: l10n.networksMatchedNow),
                ],
                if (net.isFallback) ...[
                  const SizedBox(width: 8),
                  Text(l10n.netPageAlwaysLast, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary)),
                ],
              ],
            ),
          ),
      ),
    );
  }

  /// What hosts do on it: through its jump host or directly, and how many
  /// hosts have a rule of their own.
  List<String> _effect(AppLocalizations l10n) {
    final via = hostById(ref, widget.network.bringUpVpn);
    return [
      via == null ? l10n.netPageDirect : l10n.netPageThrough(hostNameShown(ref, via)),
      if (widget.overrideCount > 0) l10n.netPageHostRules(widget.overrideCount),
    ];
  }
}

/// A network's icon in its colour (Default's neutral).
class _NetworkTile extends StatelessWidget {
  const _NetworkTile({required this.network, this.icon, this.color});

  final Network? network;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fallback = network?.isFallback ?? false;
    final c = color ?? network?.effectiveColor ?? ZestTokens.textSecondary;
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fallback ? ZestTokens.surfaceChip : c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon ?? network?.icon, size: 16, color: fallback ? ZestTokens.textSecondary : c),
    );
  }
}

/// The network being made, before it is saved: its place, its look, its
/// name as typed, "Not saved yet", in the accent.
class _DraftCard extends ConsumerWidget {
  const _DraftCard({required this.controller, required this.order});

  final NetworkEditController controller;
  final int order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final name = controller.nameController.text.trim();
    final color = controller.colorValue != null ? Color(controller.colorValue!) : controller.color.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        key: const ValueKey('network-draft-card'),
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.fromLTRB(10, 12, 16, 12),
        decoration: BoxDecoration(
          color: ZestTokens.brandSubtle,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.brandBorder),
        ),
        child: Row(
          children: [
            const SizedBox(width: 30),
            SizedBox(
              width: 18,
              child: Text(
                '$order',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                  fontWeight: FontWeight.w600,
                  color: ZestTokens.brandInk,
                ),
              ),
            ),
            const SizedBox(width: 12),
            _NetworkTile(network: null, icon: controller.icon, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name.isEmpty ? l10n.zestNetworkNewLabel : Redactable.network(name).displayIn(ref),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                  ),
                  const SizedBox(height: 3),
                  Text(l10n.netPageNotSaved, style: TextStyle(fontSize: 12.5, color: ZestTokens.brandInk)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The network that matches now: the app's status pill.
class _MatchedPill extends StatelessWidget {
  const _MatchedPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => ZestStatusPill(kind: ZestStatusKind.healthy, label: label);
}

/// The dead-config badge (§3.5): a network that can never match because a
/// broader rule above it always wins first (or it has no trigger at all).
class _NeverMatchesBadge extends StatelessWidget {
  const _NeverMatchesBadge({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: hint,
        child: ZestStatusPill(
          kind: ZestStatusKind.warning,
          label: AppLocalizations.of(context)!.zestNetworkNeverMatches,
          icon: LucideIcons.alertTriangle,
        ),
      );
}
