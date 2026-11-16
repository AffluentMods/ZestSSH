import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show kRecoveryWaitStatus;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/join_team.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/ui/screens/sync/sync_failing_text.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/space_menu.dart';
import 'package:zestssh/ui/screens/profile/account_switch.dart' show confirmAndSignOut;
import 'package:zestssh/ui/screens/tree/manage_tree_screen.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/providers/profile_providers.dart';

/// Tree selector pill for the pill bar's left zone.
///
/// Shows the user's Tree name and active Crate with a host count.
/// Clicking opens a dropdown to switch crates or access tree management.
class TreeSelector extends ConsumerWidget {
  const TreeSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final hostCount = connectionsAsync.valueOrNull?.length ?? 0;

    // A name given with "Rename tree" wins; otherwise derive it from the
    // user's profile, falling back to "My Tree" when signed out.
    final treeName = treeDisplayName(ref, l10n);

    // Orchards (3.0): watched here so the menu has the list the
    // moment it opens. One on screen shows its name, paired with "Team".
    if (kOrchardsEnabled) ref.watch(orchardSummariesProvider);
    final orchard = kOrchardsEnabled ? ref.watch(activeOrchardProvider).valueOrNull : null;
    if (orchard != null) {
      return _TreeSelectorPill(
        treeName: treeName,
        spaceName: orchardDisplayName(orchard.name, l10n),
        crateName: l10n.orchardTeam,
        hostCount: hostCount,
        isOrchard: true,
        sync: _orchardSync(orchard, l10n),
      );
    }

    return _TreeSelectorPill(
      treeName: treeName,
      spaceName: treeName,
      crateName: l10n.treeSelectorPersonal,
      hostCount: hostCount,
      sync: _treeSync(ref.watch(syncHealthProvider), l10n),
    );
  }

  /// The Tree's sync, as the status bar reads it. A Tree that does not sync
  /// shows no glyph here: that is a choice, not a fault, and the status bar
  /// already says "Not syncing".
  static _SpaceSync? _treeSync(SyncHealthState h, AppLocalizations l10n) =>
      switch (h.health) {
        SyncHealth.off => null,
        SyncHealth.syncing =>
          _SpaceSync(LucideIcons.refreshCw, _Tone.muted, l10n.statusBarSyncing),
        SyncHealth.failing => _SpaceSync(LucideIcons.cloudOff, _Tone.stop,
            syncFailingText(h, l10n, unknown: l10n.statusBarSyncError)),
        SyncHealth.behind =>
          _SpaceSync(LucideIcons.cloud, _Tone.wait, l10n.statusBarSyncBehind),
        SyncHealth.paused =>
          _SpaceSync(LucideIcons.pauseCircle, _Tone.wait, l10n.statusBarSyncPaused),
        SyncHealth.upToDate =>
          _SpaceSync(LucideIcons.cloud, _Tone.ok, l10n.statusBarSynced),
      };

  /// An Orchard's sync: held back by a rule, stopped, keys waiting to be
  /// replaced, or in step.
  static _SpaceSync _orchardSync(OrchardSummary o, AppLocalizations l10n) {
    if (o.status == 'rules') {
      return _SpaceSync(LucideIcons.cloudOff, _Tone.stop, l10n.spaceSyncHeldByRule);
    }
    if (o.status == kRecoveryWaitStatus) {
      return _SpaceSync(LucideIcons.lifeBuoy, _Tone.wait, l10n.spaceSyncWaitingRecovery);
    }
    if (!o.active) {
      return _SpaceSync(LucideIcons.cloudOff, _Tone.stop, l10n.spaceSyncStopped);
    }
    if (o.keysWaiting) {
      return _SpaceSync(LucideIcons.cloud, _Tone.wait, l10n.spaceSyncKeysWaiting);
    }
    return _SpaceSync(LucideIcons.cloud, _Tone.ok, l10n.statusBarSynced);
  }
}

enum _Tone { ok, wait, stop, muted }

/// The small sync glyph after the space's host count, and what it means.
class _SpaceSync {
  const _SpaceSync(this.icon, this.tone, this.meaning);

  final IconData icon;
  final _Tone tone;
  final String meaning;

  Color get color => switch (tone) {
        _Tone.ok => AppColors.v3Success,
        _Tone.wait => AppColors.v3Warning,
        _Tone.stop => AppColors.v3Error,
        _Tone.muted => AppColors.v3TextTertiary,
      };
}

// ======================================================================
// Pill widget - 32px tall, hover + click behaviour
// ======================================================================

class _TreeSelectorPill extends ConsumerStatefulWidget {
  final String treeName;

  /// What the pill is showing: the Tree's name, or the Orchard's.
  final String spaceName;
  final String crateName;
  final int hostCount;
  final bool isOrchard;

  /// The space's sync glyph; null shows none.
  final _SpaceSync? sync;

  const _TreeSelectorPill({
    required this.treeName,
    required this.spaceName,
    required this.crateName,
    required this.hostCount,
    this.isOrchard = false,
    this.sync,
  });

  @override
  ConsumerState<_TreeSelectorPill> createState() =>
      _TreeSelectorPillState();
}

class _TreeSelectorPillState extends ConsumerState<_TreeSelectorPill> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final attention = spacesNeedAttention(ref);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => _showDropdown(context),
        // The space pill: the space's mark in a brand tile, its
        // name, and under it what is in it and how it syncs.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          // A finger's 48 where the controls are touch sized (4.0).
          height: touchSizedAt(context) ? 48 : 36,
          padding: const EdgeInsets.only(left: 5, right: 10),
          decoration: BoxDecoration(
            color: _hovering
                ? _lighten(AppColors.v3ChromeElevated, 0.10)
                : AppColors.v3ChromeElevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The space's mark (several people for an Orchard)
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: AppColors.v3AccentPrimary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: AppColors.v3AccentPrimary.withValues(alpha: 0.32)),
                ),
                child: Icon(
                  widget.isOrchard ? LucideIcons.users : LucideIcons.user,
                  size: 14,
                  color: AppColors.v3AccentInk,
                ),
              ),
              const SizedBox(width: 9),

              // Two-line label
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RedactedText(
                    Redactable.account(widget.spaceName),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3TextPrimary,
                      height: 1.2,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        // The kind of space once: a space named as its kind
                        // (Personal) does not say it again ("Personal ·
                        // 12 hosts" under "Personal").
                        widget.crateName.trim().toLowerCase() == widget.spaceName.trim().toLowerCase()
                            ? l10n.treeSelectorHostCount(widget.hostCount)
                            : l10n.treeSelectorCrateHostSummary(widget.crateName, widget.hostCount),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppColors.v3TextTertiary,
                          height: 1.2,
                        ),
                      ),
                      if (widget.sync case final sync?) ...[
                        const SizedBox(width: 5),
                        Tooltip(
                          message: sync.meaning,
                          child: Icon(
                            sync.icon,
                            key: const ValueKey('space-sync-glyph'),
                            size: 11,
                            color: sync.color,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),

              const SizedBox(width: 6),

              // An invitation to answer, or someone to add.
              if (attention) ...[
                const SpacesAttentionDot(key: ValueKey('tree-selector-attention')),
                const SizedBox(width: 6),
              ],

              // Chevron
              Icon(
                LucideIcons.chevronDown,
                size: 10,
                color: AppColors.v3TextSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Dropdown ──────────────────────────────────────────────────

  void _showDropdown(BuildContext context) {
    // A computer's: the accounts above, the spaces below.
    if (ref.read(profileControllerProvider).on) {
      unawaited(showSpaceMenu(context, ref, treeName: widget.treeName, hostCount: widget.hostCount));
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final offset = box.localToGlobal(Offset.zero);
    final overlayState = Navigator.of(context).overlay;
    if (overlayState == null) return;
    final RenderBox? overlay =
        overlayState.context.findRenderObject() as RenderBox?;
    if (overlay == null || !overlay.hasSize) return;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy + box.size.height + 4, 280, 0),
        Offset.zero & overlay.size,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: AppColors.v3Surface,
      constraints: const BoxConstraints(minWidth: 280),
      items: [
        // Without teams: the Tree's name, with a one-line definition so a new
        // user can tell it apart from a Workspace at the point of choice.
        // With them, the groups below name themselves: a head naming the
        // space on screen put Personal under a team's name.
        if (!kOrchardsEnabled) PopupMenuItem<String>(
          enabled: false,
          height: 54,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RedactedText(
                Redactable.account(widget.spaceName),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.v3TextPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.isOrchard
                    ? l10n.orchardSpaceDescription
                    : l10n.containerTreeDescription,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.25,
                  color: AppColors.v3TextTertiary,
                ),
              ),
            ],
          ),
        ),
        if (!kOrchardsEnabled) const PopupMenuDivider(),

        if (kOrchardsEnabled) ..._spaceItems(l10n) else
        // Personal crate (only one for now) - carries the Crate definition
        // so the concept is distinguishable from the Tree above it.
        PopupMenuItem<String>(
          value: 'personal',
          height: 54,
          child: Row(
            children: [
              Icon(LucideIcons.check,
                  size: 14, color: AppColors.v3AccentInk),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      l10n.treeSelectorPersonal,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.v3TextPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.containerCrateDescription,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.25,
                        color: AppColors.v3TextTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                l10n.treeSelectorHostCount(widget.hostCount),
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.v3TextTertiary,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),

        // (§7d) The standalone "Workspaces…" browse modal was removed -
        // workspaces now live in the Hosts drawer, the Hosts page, and the
        // Split-tab empty state, so this account dropdown no longer opens it.

        // Manage Tree
        PopupMenuItem<String>(
          value: 'manage',
          height: 36,
          child: _DropdownRow(
            icon: LucideIcons.settings,
            label: l10n.treeSelectorManageTree,
          ),
        ),

        // Sign Out
        PopupMenuItem<String>(
          value: 'signout',
          height: 36,
          child: _DropdownRow(
            icon: LucideIcons.logOut,
            label: l10n.treeSelectorSignOut,
          ),
        ),
      ],
    ).then((value) {
      if (value == null || !context.mounted) return;
      if (value.startsWith('orchard:')) {
        switchToSpace(context, ref, OrchardSpace(value.substring(8)));
        return;
      }
      switch (value) {
        case 'personal':
          // Your Tree (a no-op while it is already on screen).
          if (kOrchardsEnabled) switchToSpace(context, ref, const TreeSpace());
        case 'createorchard':
          showCreateOrchardDialog(context, ref);
        case 'invitations':
          showMyInvitations(context);
        case 'jointeam':
          showJoinTeam(context);
        case 'syncorchards':
          syncOrchardsNow(context, ref);
        case 'manage':
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const ManageTreeScreen(),
          ));
        case 'signout':
          confirmAndSignOut(context, ref);
      }
    });
  }

  /// Your Tree and your Orchards (3.0), each paired with plain
  /// words, the one on screen checked; then making an Orchard, your
  /// invitations, and syncing. The menu only switches spaces: running an
  /// Orchard is the Team page's (3.0 UI).
  List<PopupMenuEntry<String>> _spaceItems(AppLocalizations l10n) {
    final space = ref.read(activeSpaceProvider);
    final orchards = ref.read(orchardSummariesProvider).valueOrNull ?? const [];
    final invitations = ref.read(myInvitesProvider);
    PopupMenuItem<String> row({
      required String value,
      required IconData icon,
      required String title,
      required String subtitle,
      required bool selected,
    }) =>
        PopupMenuItem<String>(
          value: value,
          height: 48,
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: selected
                    ? Icon(LucideIcons.check, size: 14, color: AppColors.v3AccentInk)
                    : null,
              ),
              const SizedBox(width: 8),
              Icon(icon, size: 14, color: AppColors.v3TextSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RedactedText(
                      Redactable.account(title),
                      style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 10, height: 1.25, color: AppColors.v3TextTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
    PopupMenuItem<String> head(String label) => PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: AppColors.v3TextTertiary,
            ),
          ),
        );
    return [
      head(l10n.treeSelectorPersonal),
      row(
        value: 'personal',
        icon: LucideIcons.user,
        title: widget.treeName,
        subtitle: l10n.containerCrateDescription,
        selected: space is TreeSpace,
      ),
      if (orchards.isNotEmpty) ...[
        const PopupMenuDivider(),
        head(l10n.spaceSwitcherTeams),
      ],
      for (final o in orchards)
        row(
          value: 'orchard:${o.id}',
          icon: LucideIcons.users,
          title: orchardDisplayName(o.name, l10n),
          subtitle: orchardSubtitle(o, ref, l10n),
          selected: space is OrchardSpace && space.orchardId == o.id,
        ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: 'createorchard',
        height: 36,
        child: _DropdownRow(icon: LucideIcons.plus, label: l10n.orchardCreateAction),
      ),
      // Always there: opening it asks the server, so someone just invited
      // need not wait for the next sync.
      PopupMenuItem<String>(
        value: 'invitations',
        height: 36,
        child: _DropdownRow(
          icon: LucideIcons.mail,
          label: invitations.isEmpty
              ? l10n.myInvitationsTitle
              : l10n.myInvitationsAction(invitations.length),
        ),
      ),
      // With an invite code (typed or pasted).
      PopupMenuItem<String>(
        key: const ValueKey('space-join-team'),
        value: 'jointeam',
        height: 36,
        child: _DropdownRow(icon: LucideIcons.qrCode, label: l10n.joinTeamTitle),
      ),
      if (orchards.isNotEmpty)
        PopupMenuItem<String>(
          value: 'syncorchards',
          height: 36,
          child: _DropdownRow(icon: LucideIcons.refreshCw, label: l10n.orchardSyncNow),
        ),
    ];
  }
}

// ======================================================================
// Dropdown row helper
// ======================================================================

class _DropdownRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _DropdownRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.v3TextSecondary),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: AppColors.v3TextPrimary,
          ),
        ),
      ],
    );
  }
}

// ======================================================================
// Helpers
// ======================================================================

/// Lightens a color by mixing it towards white by [amount] (0.0 to 1.0).
Color _lighten(Color color, double amount) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
      .toColor();
}
