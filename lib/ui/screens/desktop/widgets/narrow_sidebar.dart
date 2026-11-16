import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/utils/help_links.dart' show kZestDiscordUrl;
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart'
    show AccountAttentionDot;
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show signInFromAnywhere;
import 'package:zestssh/ui/screens/profile/account_switch.dart' show openAccountRow;
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show PlanChip;
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/widgets/profile_avatar.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Narrow 200px sidebar for the v1.5 desktop layout.
///
/// ```
/// +--------------------+
/// |                    |  16px top padding
/// |  [server] Hosts    |  <-- active: orange accent bg + left border
/// |  [key] Keys        |
/// |  [swap] Port Fwd   |
/// |  [code] Snippets   |
/// |  [play] Automation |
/// |                    |
/// |  --separator--     |
/// |  [gear] Settings   |
/// |                    |
/// |  ......[grow]....  |  <-- flex-grow spacer
/// |                    |
/// |  --separator--     |
/// |  [A] Alex         |  <-- profile area
/// |      Pro           |
/// +--------------------+
/// ```
class NarrowSidebar extends ConsumerWidget {
  /// The nav section currently shown in the content area, or `null` when a
  /// terminal tab is active (the content area shows the terminal, not a section
  /// page). A null value highlights NO item - you're in a terminal, not on any
  /// of these pages; the pill-bar tab strip indicates the active terminal.
  final NavSection? activeSection;
  final ValueChanged<NavSection> onSectionChanged;

  /// Whether the Hosts drawer is on screen beside this rail (see
  /// [hostsDrawerShown]). The rail is icon-only then, to make room for it.
  final bool hostsPanelShown;

  /// A tablet held upright (4.0): a slim
  /// rail of icons, each with its name under it, touch sized; Settings and
  /// the account at its foot.
  final bool labelledRail;

  const NarrowSidebar({
    super.key,
    required this.activeSection,
    required this.onSectionChanged,
    this.hostsPanelShown = false,
    this.labelledRail = false,
  });

  /// The full rail and the icon-only strip.
  static const double expandedWidth = 200;
  static const double collapsedWidth = 56;

  /// The full rail where the controls are touch sized (a tablet held
  /// sideways, 4.0): its rows 48 high, its words a size up.
  static const double touchExpandedWidth = 240;

  /// The slim rail with names ([labelledRail]).
  static const double labelledRailWidth = 80;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Icon-only when the user pushed the rail in (the arrow at its top, or the
    // Toggle sidebar shortcut) and while the Hosts drawer is on screen, so the
    // drawer can sit beside it without stealing the session area (A1).
    // Nothing becomes unreachable - every destination stays a (tooltipped)
    // icon.
    final collapsed = ref.watch(sidebarCollapsedProvider);
    // The slim rail with names is icons too: its groups are held apart by
    // hairlines, its foot is the strip's.
    final iconOnly = collapsed || hostsPanelShown || labelledRail;
    final dividerPad = iconOnly ? 10.0 : 16.0;
    final touch = touchSizedAt(context);
    final width = labelledRail
        ? labelledRailWidth
        : iconOnly
            ? collapsedWidth
            : (touch ? touchExpandedWidth : expandedWidth);

    // The rail slides between the two widths. Its contents are laid out at the
    // width it is heading to (less the 1px border) and clipped on the way, so
    // nothing reflows or overflows mid-slide.
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: width,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        border: Border(
          right: BorderSide(color: AppColors.v3BorderSubtle, width: 1),
        ),
      ),
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: width - 1,
        maxWidth: width - 1,
        child: Column(
          children: [
            // Push the rail in to icons, or pull it back out. Not offered while
            // the Hosts drawer holds it icon-only: closing the drawer brings the
            // rail back.
            SizedBox(
              height: labelledRail ? 8 : 30,
              child: hostsPanelShown || labelledRail
                  ? null
                  : Align(
                      alignment: iconOnly
                          ? Alignment.center
                          : Alignment.centerRight,
                      // Same right margin as the nav items, so the arrow
                      // lines up with their icons in the collapsed strip.
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _RailToggle(collapsed: collapsed),
                      ),
                    ),
            ),

            // The sections scroll where the window is too low for them all,
            // so the account at the rail's foot is always in reach (the rail
            // was one column: in a low window its foot was cut off).
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('rail-sections'),
                child: Column(
                  children: [
            // ── The team on screen comes first (3.0: the
            // team is the main thing), with its vaults right under it. ──
            if (kOrchardsEnabled)
              if (ref.watch(activeOrchardProvider).valueOrNull
                  case final orchard?) ...[
                _GroupHeader(
                  label: l10n.railGroupOrchard,
                  iconOnly: iconOnly,
                  first: true,
                ),
                _NavItem(
                  key: const ValueKey('rail-team'),
                  icon: LucideIcons.users,
                  label: l10n.orchardTeam,
                  group: l10n.railGroupOrchard,
                  iconOnly: iconOnly,
                  labelled: labelledRail,
                  // People wait to be added, or keys to be replaced.
                  attention: orchard.invitesWaiting > 0 || orchard.keysWaiting,
                  isActive: activeSection == NavSection.team &&
                      ref.watch(teamPageProvider) != TeamPage.crates,
                  onTap: () {
                    if (ref.read(teamPageProvider) == TeamPage.crates) {
                      ref.read(teamPageProvider.notifier).state = TeamPage.overview;
                    }
                    onSectionChanged(NavSection.team);
                  },
                ),
                _NavItem(
                  key: const ValueKey('rail-vaults'),
                  icon: LucideIcons.package,
                  label: l10n.orchardCrates,
                  group: l10n.railGroupOrchard,
                  iconOnly: iconOnly,
                  labelled: labelledRail,
                  isActive: activeSection == NavSection.team &&
                      ref.watch(teamPageProvider) == TeamPage.crates,
                  onTap: () {
                    ref.read(teamPageProvider.notifier).state = TeamPage.crates;
                    onSectionChanged(NavSection.team);
                  },
                ),
              ],

            // ── Manage: hosts, identities and the network plumbing ───────
            // Grouping is header-based when expanded and divider-based when
            // collapsed, so the same three clusters survive icon-only mode; the
            // group name folds into each item's tooltip there.
            _GroupHeader(
              label: l10n.narrowSidebarGroupManage,
              iconOnly: iconOnly,
              first: !kOrchardsEnabled || ref.watch(activeOrchardProvider).valueOrNull == null,
            ),
            // Hosts nav opens the full-screen Hosts GRID page, exactly like
            // every other nav item. It is a DISTINCT control from the pill-bar
            // "Hosts" chip, which is the ONLY thing that toggles the
            // fast-connect slide-out panel.
            _NavItem(
              icon: LucideIcons.server,
              label: l10n.narrowSidebarHosts,
              group: l10n.narrowSidebarGroupManage,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.hosts,
              onTap: () => onSectionChanged(NavSection.hosts),
            ),
            _NavItem(
              icon: LucideIcons.key,
              label: l10n.narrowSidebarKeys,
              group: l10n.narrowSidebarGroupManage,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.keys,
              onTap: () => onSectionChanged(NavSection.keys),
            ),
            _NavItem(
              icon: LucideIcons.arrowRightLeft,
              label: l10n.narrowSidebarPortForwarding,
              group: l10n.narrowSidebarGroupManage,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.portForwarding,
              onTap: () => onSectionChanged(NavSection.portForwarding),
            ),
            _NavItem(
              icon: LucideIcons.network,
              label: l10n.narrowSidebarNetworks,
              group: l10n.narrowSidebarGroupManage,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.networks,
              onTap: () => onSectionChanged(NavSection.networks),
            ),

            // ── Utilities: snippets, triggers, history, automation, monitor ──
            _GroupHeader(
              label: l10n.narrowSidebarGroupUtilities,
              iconOnly: iconOnly,
            ),
            _NavItem(
              icon: LucideIcons.braces,
              label: l10n.narrowSidebarSnippets,
              group: l10n.narrowSidebarGroupUtilities,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.snippets,
              onTap: () => onSectionChanged(NavSection.snippets),
            ),
            _NavItem(
              icon: LucideIcons.bellRing,
              label: l10n.narrowSidebarTriggers,
              group: l10n.narrowSidebarGroupUtilities,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.triggers,
              onTap: () => onSectionChanged(NavSection.triggers),
            ),
            _NavItem(
              icon: LucideIcons.history,
              label: l10n.narrowSidebarHistory,
              group: l10n.narrowSidebarGroupUtilities,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.commandHistory,
              onTap: () => onSectionChanged(NavSection.commandHistory),
            ),
            _NavItem(
              icon: LucideIcons.play,
              label: l10n.narrowSidebarAutomation,
              group: l10n.narrowSidebarGroupUtilities,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.automation,
              onTap: () => onSectionChanged(NavSection.automation),
            ),
            _NavItem(
              icon: LucideIcons.activity,
              label: l10n.desktopServerMonitor,
              group: l10n.narrowSidebarGroupUtilities,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.monitor,
              onTap: () => onSectionChanged(NavSection.monitor),
            ),

                  ],
                ),
              ),
            ),

            // Settings stays out of the scrolling part, always in reach: in a
            // low window it sat half under the footer (found in a design
            // audit).
            // -- Divider between the groups and Settings --
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: dividerPad,
                vertical: 10,
              ),
              child: Divider(
                height: 1,
                thickness: 1,
                color: AppColors.v3BorderSubtle,
              ),
            ),

            _NavItem(
              icon: LucideIcons.settings,
              label: l10n.narrowSidebarSettings,
              iconOnly: iconOnly,
              labelled: labelledRail,
              isActive: activeSection == NavSection.settings,
              onTap: () => onSectionChanged(NavSection.settings),
            ),

            // -- Divider above profile --
            Padding(
              padding: EdgeInsets.symmetric(horizontal: dividerPad),
              child: Divider(
                height: 1,
                thickness: 1,
                color: AppColors.v3BorderSubtle,
              ),
            ),
            const SizedBox(height: 8),

            // -- A guest's Sign in, a row of its own, in the accent (before,
            // nothing said how to sign in) --
            // (Not in a build with no account service: nobody signs in there.)
            if (zestHasCloud && ref.watch(currentUserProvider) == null) ...[
              _RailRow(
                key: const ValueKey('rail-sign-in'),
                iconOnly: iconOnly,
                icon: LucideIcons.logIn,
                label: l10n.profileSignIn,
                accent: true,
                onTap: () => signInFromAnywhere(context, ref),
              ),
              const SizedBox(height: 6),
            ],

            // -- Upgrade, a row of its own (it
            // was a word under the name inside the account's row, so a click a
            // little low on the name opened pricing) --
            if (ref.watch(currentUserProvider) != null && !ref.watch(isProProvider) && !ref.watch(isCloudSyncProvider)) ...[
              _RailRow(
                key: const ValueKey('rail-upgrade'),
                iconOnly: iconOnly,
                icon: LucideIcons.sparkles,
                label: l10n.narrowSidebarUpgradeRow,
                accent: true,
                onTap: () => PricingModal.show(context),
              ),
              const SizedBox(height: 6),
            ],

            // -- Join Discord, in the icon-only strip: above the account. (The
            // full rail has it as a small icon beside the account;
            // it was a row of its own.) --
            if (iconOnly && kZestDiscordUrl != '') ...[
              _RailRow(
                key: const ValueKey('rail-discord'),
                iconOnly: true,
                icon: Icons.discord,
                iconSize: 15,
                label: l10n.narrowSidebarJoinDiscord,
                hoverIconColor: AppColors.brandDiscord,
                onTap: _openDiscord,
              ),
              const SizedBox(height: 8),
            ],

            // -- Profile area --
            _ProfileArea(iconOnly: iconOnly),

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// The ZestSSH Discord, in the browser.
void _openDiscord() {
  if (kZestDiscordUrl == '') return;
  unawaited(launchUrl(Uri.parse(kZestDiscordUrl), mode: LaunchMode.externalApplication));
}

// ======================================================================
// Rail toggle -- the arrow that pushes the rail in or pulls it back out
// ======================================================================

class _RailToggle extends ConsumerWidget {
  const _RailToggle({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final label = collapsed
        ? l10n.desktopExpandSidebar
        : l10n.desktopCollapseSidebar;
    // The live binding (Ctrl+B unless rebound); a cleared binding shows none.
    final accel = ref.watch(
      shortcutBindingProvider(ShortcutAction.toggleSidebar),
    );
    return IconButton(
      key: const ValueKey('sidebar-rail-toggle'),
      tooltip: accel == null ? label : '$label ($accel)',
      onPressed: () =>
          ref.read(desktopSettingsUpdaterProvider).toggleSidebarCollapsed(),
      icon: Icon(
        collapsed ? LucideIcons.chevronsRight : LucideIcons.chevronsLeft,
      ),
      iconSize: 15,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      style: IconButton.styleFrom(
        foregroundColor: AppColors.v3TextTertiary,
        hoverColor: AppColors.v3Hover,
        highlightColor: AppColors.v3Hover,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}

// ======================================================================
// Navigation item -- 44px tall, icon + label, flush left active border
// ======================================================================

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool iconOnly;
  final VoidCallback onTap;

  /// The group this item belongs to (Manage / Utilities). Shown before the
  /// label in the collapsed rail's tooltip ("Manage · Identities"), since the
  /// group headers are hidden when the rail is icon-only.
  final String? group;

  /// A small dot: something on the page waits for this account.
  final bool attention;

  /// The slim rail's item (a tablet held upright, 4.0): the icon with the
  /// name under it.
  final bool labelled;

  const _NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.iconOnly = false,
    this.group,
    this.attention = false,
    this.labelled = false,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final Color itemColor;
    final Color bgColor;

    if (widget.isActive) {
      itemColor = AppColors.v3AccentInk;
      bgColor = AppColors.v3AccentPrimary.withValues(alpha: 0.08);
    } else if (_hovering) {
      itemColor = AppColors.v3TextPrimary;
      bgColor = AppColors.v3Hover;
    } else {
      itemColor = AppColors.v3TextSecondary;
      bgColor = Colors.transparent;
    }

    if (widget.labelled) return _labelled(itemColor);
    final touch = touchSizedAt(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          // At least the rail's height; taller where a language's words
          // need it (Arabic at 1.25 times the text size).
          constraints: BoxConstraints(minHeight: touch ? 48 : DesktopDimensions.sidebarNavItemHeight),
          alignment: AlignmentDirectional.centerStart,
          margin: const EdgeInsets.only(right: 8, top: 1, bottom: 1),
          decoration: BoxDecoration(
            color: bgColor,
            // No radius on left side (border flush left), radius-md on right
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(8),
              bottomRight: Radius.circular(8),
            ),
            // 3px accent left border when active
            border: widget.isActive
                ? Border(
                    left: BorderSide(
                      color: AppColors.v3AccentPrimary,
                      width: 3,
                    ),
                  )
                : null,
          ),
          child: widget.iconOnly
              ? Tooltip(
                  message: widget.group == null
                      ? widget.label
                      : '${widget.group} · ${widget.label}',
                  waitDuration: const Duration(milliseconds: 400),
                  child: Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(widget.icon, size: 16, color: itemColor),
                        if (widget.attention)
                          const Positioned(
                            top: -2,
                            right: -3,
                            child: _AttentionDot(key: ValueKey('rail-attention')),
                          ),
                      ],
                    ),
                  ),
                )
              : Padding(
                  padding: EdgeInsets.only(left: widget.isActive ? 11 : 14, top: 3, bottom: 3),
                  child: Row(
                    children: [
                      Icon(widget.icon, size: touch ? 18 : 16, color: itemColor),
                      SizedBox(width: touch ? 14 : 11),
                      Expanded(
                        child: Text(
                          widget.label,
                          style: TextStyle(
                            fontSize: touch ? 15 : 13,
                            fontWeight: widget.isActive
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: itemColor,
                          ),
                        ),
                      ),
                      if (widget.attention)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: _AttentionDot(key: ValueKey('rail-attention')),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

extension on _NavItemState {
  /// The slim rail's item: the icon in a pill (lit when its page is shown),
  /// the name under it, 64 high, one target for a finger and one node for a
  /// screen reader (a button, selected when its page is shown).
  Widget _labelled(Color itemColor) {
    final active = widget.isActive;
    return Semantics(
      button: true,
      selected: active,
      label: widget.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 52,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: active ? AppColors.v3AccentPrimary.withValues(alpha: 0.14) : Colors.transparent,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Icon(widget.icon, size: 20, color: itemColor),
                    ),
                    if (widget.attention)
                      const Positioned(
                        top: 2,
                        right: 8,
                        child: _AttentionDot(key: ValueKey('rail-attention')),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.15,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    color: itemColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The accent dot on a rail item whose page waits for this account.
class _AttentionDot extends StatelessWidget {
  const _AttentionDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: AppColors.v3AccentPrimary,
        shape: BoxShape.circle,
      ),
    );
  }
}

// ======================================================================
// Group header -- a mono label when expanded, a hairline when collapsed
// ======================================================================

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.iconOnly,
    this.first = false,
  });

  final String label;
  final bool iconOnly;

  /// The first group has nothing above it, so it gets no divider / a smaller
  /// top gap.
  final bool first;

  @override
  Widget build(BuildContext context) {
    if (iconOnly) {
      // Collapsed: a hairline holds the clusters apart (a small gap suffices
      // for the top group). The name + group live in each item's tooltip.
      if (first) return const SizedBox(height: 6);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Divider(
          height: 1,
          thickness: 1,
          color: AppColors.v3BorderSubtle,
        ),
      );
    }
    // Expanded: a mono uppercase header above the group's items, at the
    // rail's left edge as the Blueprint has it (it sat in the middle).
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, first ? 2 : 14, 18, 6),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 10,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w600,
            color: ZestColors.textMuted,
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Profile area at bottom of sidebar
// ======================================================================

class _ProfileArea extends ConsumerWidget {
  const _ProfileArea({this.iconOnly = false});
  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(currentUserProvider);

    // The signed-in name is an identifier (painted in the tile and the
    // icon-only tooltip); the signed-out fallback is not.
    final rawName = user?.displayName ?? user?.email?.split('@').first;
    final displayName = rawName == null
        ? l10n.narrowSidebarGuest
        : Redactable.account(rawName).displayIn(ref);

    final signedIn = user != null;

    // Icon-only rail: a compact avatar that still opens the account popover,
    // so the profile stays reachable without overflowing the 56px strip.
    if (iconOnly) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          child: Tooltip(
            message: displayName,
            child: InkWell(
              // A computer's list of accounts; elsewhere Profile & Sync directly,
              // with no intermediate popover.
              onTap: () => openAccountRow(context, ref),
              borderRadius: BorderRadius.circular(14),
              child: const AccountAttentionDot(child: ProfileAvatar(size: 28)),
            ),
          ),
        ),
      );
    }

    // The avatar, the name and under it the plan's chip, which says what the
    // plan is when clicked (4.0; it was
    // the plan's name in grey, explaining nothing); and Discord as a small
    // icon at the end (it was a row of its own above).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: _ProfileTile(
              displayName: displayName,
              // A guest's line says where their things are: on this device
              // only.
              tier: signedIn
                  ? Align(
                      alignment: AlignmentDirectional.centerStart,
                      // Its popover beside the rail, pointing at the chip's
                      // line, not over the rail.
                      child: PlanChip(anchorOf: (chip) => _toRailEdge(context, chip)),
                    )
                  : Text(
                      l10n.railGuestLocal,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: AppColors.v3TextTertiary),
                    ),
              // A computer's list of accounts (to-do 60), which has Manage
              // account; elsewhere Profile & Sync directly (the redesigned
              // master/detail).
              onTap: () => openAccountRow(context, ref),
            ),
          ),
          if (kZestDiscordUrl != '') ...[
            const SizedBox(width: 2),
            const _DiscordButton(),
          ],
        ],
      ),
    );
  }

  /// [chip]'s rectangle reaching the rail's right edge (this area spans the
  /// rail).
  static Rect _toRailEdge(BuildContext context, Rect chip) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return chip;
    final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
    return Rect.fromLTRB(chip.left, chip.top, math.max(chip.right, right), chip.bottom);
  }
}

/// Join Discord at the end of the rail's foot: a small icon in the muted
/// ink, Discord's own colour under the pointer, its name in a tooltip and to
/// a screen reader.
class _DiscordButton extends StatefulWidget {
  const _DiscordButton();

  @override
  State<_DiscordButton> createState() => _DiscordButtonState();
}

class _DiscordButtonState extends State<_DiscordButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context)!.narrowSidebarJoinDiscord;
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: _openDiscord,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('rail-discord'),
              borderRadius: BorderRadius.circular(8),
              onTap: _openDiscord,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(
                  Icons.discord,
                  size: 18,
                  color: _hovering ? AppColors.brandDiscord : ZestColors.textTertiary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// A row above the account: a guest's Sign in and Upgrade (in the accent,
// rows of their own), and in the icon-only strip Join
// Discord (3.0: it was a blurple slab, the loudest thing on every screen;
// Discord's colour only on hover; the full rail has it beside the account
// since 4.0)
// ======================================================================

class _RailRow extends StatefulWidget {
  const _RailRow({
    super.key,
    required this.iconOnly,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconSize = 16,
    this.hoverIconColor,
    this.accent = false,
  });

  final bool iconOnly;
  final IconData icon;
  final double iconSize;
  final String label;
  final VoidCallback onTap;

  /// The icon's colour under the pointer (Discord's own); the text's otherwise.
  final Color? hoverIconColor;

  /// In the accent, on its soft fill (Upgrade).
  final bool accent;

  @override
  State<_RailRow> createState() => _RailRowState();
}

class _RailRowState extends State<_RailRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final bg = accent
        ? AppColors.v3AccentPrimary.withValues(alpha: _hovering ? 0.18 : 0.10)
        : (_hovering ? ZestColors.textPrimary.withValues(alpha: 0.06) : Colors.transparent);
    final ink = accent ? AppColors.v3AccentInk : (_hovering ? ZestColors.textPrimary : ZestColors.textTertiary);
    final iconInk = accent ? AppColors.v3AccentInk : (_hovering ? (widget.hoverIconColor ?? ink) : ZestColors.textTertiary);
    final border = accent ? AppColors.v3AccentPrimary.withValues(alpha: 0.35) : ZestColors.borderSubtle;

    if (widget.iconOnly) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: Tooltip(
              message: widget.label,
              child: GestureDetector(
                onTap: widget.onTap,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                  alignment: Alignment.center,
                  child: Icon(widget.icon, size: 16, color: iconInk),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 32,
            padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border),
            ),
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              children: [
                Icon(widget.icon, size: widget.iconSize, color: iconInk),
                const SizedBox(width: 8),
                // A little smaller where the rail is narrower than the words
                // (in Russian they ran out of it).
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      widget.label,
                      style: TextStyle(fontSize: 12.5, fontWeight: accent ? FontWeight.w600 : FontWeight.w500, color: ink),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileTile extends StatefulWidget {
  final String displayName;

  /// Under the name: the plan's chip, or a guest's line.
  final Widget tier;
  final VoidCallback onTap;

  const _ProfileTile({
    required this.displayName,
    required this.tier,
    required this.onTap,
  });

  @override
  State<_ProfileTile> createState() => _ProfileTileState();
}

class _ProfileTileState extends State<_ProfileTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        key: const ValueKey('rail-profile'),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _hovering ? AppColors.v3Hover : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // 28x28 avatar circle
              const AccountAttentionDot(child: ProfileAvatar(size: 28)),
              const SizedBox(width: 9),

              // Name + its plan (a guest: where their things are)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.v3TextPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    widget.tier,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
