import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_access_view.dart' show endTimedAccess;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/line_breaks.dart';

// The Vaults page on a computer (3.0):
// the team's vaults as a list, each card saying how many hosts it
// holds, who can open it and what is on in it; a click opens the vault's
// pane on the right, with who can open it, what its hosts allow, its
// certificates, its protection, its records, and the rest of what it has.
// The pane's controls are those of the vault's card on a phone (the same
// record entries, the same checks of who may change what).

/// How wide a vault's pane is.
const double kVaultPaneWidth = 420;

/// [crates] in the order the Vaults and Roles pages list them: as the app
/// lists vaults (by name), those only owners open last.
List<CrateSummary> vaultsInOrder(List<CrateSummary> crates) => [
      for (final c in crates)
        if (!c.ownersOnly) c,
      for (final c in crates)
        if (c.ownersOnly) c,
    ];

/// What [crate]'s card and pane say of who can open it.
class VaultAccess {
  const VaultAccess({required this.roles, required this.timed});

  /// Each role that opens it, highest first, with its level (null for a
  /// set made by hand), and how many people have the role; roles that do
  /// not open it are listed with no level.
  final List<({String id, String name, CrateLevel? level, bool opens, int people})> roles;

  /// Who holds it until a set time, soonest to end first.
  final List<TimedAccess> timed;

  int get opening => roles.where((r) => r.opens).length;

  static VaultAccess of(CrateSummary crate, OrchardPeople people, List<TimedAccess> timed, AppLocalizations l10n) {
    // Those of the role who open it: not one with No access set for them
    // there.
    int count(String role) => people.members.where((m) => m.role == role && !heldOutOf(m, crate.id)).length;
    // What the Admin role gives here, as an owner set it (Manage until then).
    final admin = adminSwitches(people.record.adminRole, crateId: crate.id, ownersOnly: crate.ownersOnly);
    final adminLevel = admin.isEmpty ? null : exactLevel(admin);
    return VaultAccess(
      roles: [
        (id: FixedRoles.owner, name: l10n.orchardRoleOwner, level: CrateLevel.manage, opens: true, people: count(FixedRoles.owner)),
        // Nobody else reaches an owners-only vault.
        if (!crate.ownersOnly) ...[
          (
            id: FixedRoles.admin,
            name: l10n.orchardRoleAdmin,
            level: adminLevel,
            opens: adminLevel != null,
            people: count(FixedRoles.admin),
          ),
          for (final r in people.roles)
            (
              id: r.id,
              name: r.name ?? l10n.orchardRoleMember,
              level: r.crates[crate.id] == null ? null : exactLevel(r.crates[crate.id]!),
              opens: r.crates[crate.id] != null,
              people: count(r.id),
            ),
        ],
      ],
      timed: [
        for (final t in timed)
          if (t.crateId == crate.id) t,
      ],
    );
  }
}

/// The other people who can open [crate], as the vault switcher shows them
/// (3.2): owners always; nobody else
/// for a vault only owners open; otherwise admins, the roles that open it,
/// extra grants and access for a set time. Active members only, this
/// account left out, in the record's order.
List<OrchardPerson> vaultPeople(CrateSummary crate, OrchardPeople people, List<TimedAccess> timed) {
  bool opens(OrchardPerson m) {
    if (m.role == FixedRoles.owner) return true;
    // No access set for them there: whatever their role gives,
    // unless given it until a set time since.
    if (heldOutOf(m, crate.id)) return timed.any((t) => t.crateId == crate.id && t.uid == m.uid);
    if (crate.ownersOnly) return false;
    // Admins: what the Admin role opens (every vault but owners-only ones
    // until an owner changes it); never an extra vault of their own.
    if (m.role == FixedRoles.admin) {
      return adminSwitches(people.record.adminRole, crateId: crate.id, ownersOnly: crate.ownersOnly).isNotEmpty;
    }
    if (people.roles.where((r) => r.id == m.role).firstOrNull?.crates[crate.id] != null) return true;
    if (m.grants.containsKey(crate.id)) return true;
    return timed.any((t) => t.crateId == crate.id && t.uid == m.uid);
  }

  return [
    for (final m in people.members)
      if (!m.isMe && m.status == MemberStatus.active && opens(m)) m,
  ];
}

/// Whether [m] has No access set for them in [crateId]: an
/// empty limit there. Owners and admins have none.
bool heldOutOf(OrchardPerson m, String crateId) =>
    m.role != FixedRoles.owner && m.role != FixedRoles.admin && (m.limits[crateId]?.isEmpty ?? false);

/// The start of an account id, for a member whose address is not known.
String _shortId(String uid) => uid.length > 10 ? '${uid.substring(0, 10)}…' : uid;

/// A member's name as this device has it: their address (hidden while
/// recording), or the start of their account id.
String vaultPersonName(WidgetRef ref, OrchardPeople people, String uid) {
  final email = people.members.where((m) => m.uid == uid).firstOrNull?.email;
  return Redactable.account(email ?? _shortId(uid)).displayIn(ref);
}

/// The line under a vault's name: its hosts, and who can open it.
String vaultCardLine(
  CrateSummary crate, {
  required int hosts,
  required VaultAccess? access,
  required String Function(String uid) nameOf,
  required AppLocalizations l10n,
}) {
  final parts = <String>[
    if (crate.ownersOnly) l10n.crateOwnersOnly,
    l10n.hostsMetaHostCount(hosts),
  ];
  if (access != null && !crate.ownersOnly) {
    final roles = l10n.vaultsRoleCount(access.opening);
    final timed = access.timed;
    parts.add(switch (timed.length) {
      0 => l10n.vaultsCanOpenIt(access.opening),
      1 => l10n.vaultsPlusTimedOne(roles, nameOf(timed.single.uid), accessTimeText(timed.single.until, l10n)),
      _ => l10n.vaultsPlusTimedMany(roles, timed.length),
    });
  }
  return parts.join(' · ');
}

/// A small mark on a vault's card of what is on in it.
class VaultMark extends StatelessWidget {
  const VaultMark({super.key, required this.label, this.icon, this.strong = false});

  final String label;
  final IconData? icon;

  /// In the accent: what protects the most (certificates).
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final brand = ZestTokens.brand;
    final fg = strong ? ZestTokens.brandInk : ZestTokens.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: strong ? brand.withValues(alpha: 0.12) : ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: strong ? brand.withValues(alpha: 0.35) : ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 5)],
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg)),
        ],
      ),
    );
  }
}

/// A vault in the Vaults page's list: its mark, name, one line of what it
/// holds and who opens it, and what is on in it. [selected] while its pane
/// is open.
class VaultCard extends StatefulWidget {
  const VaultCard({
    super.key,
    required this.crate,
    required this.line,
    required this.marks,
    required this.selected,
    required this.onTap,
    this.status,
  });

  final CrateSummary crate;
  final String line;
  final List<Widget> marks;
  final bool selected;
  final VoidCallback onTap;

  /// Its one status where it has one (closed here, closing soon, a pass).
  final (ZestStatusKind, String)? status;

  @override
  State<VaultCard> createState() => _VaultCardState();
}

class _VaultCardState extends State<VaultCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final crate = widget.crate;
    final brand = ZestTokens.brand;
    final status = widget.status;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              decoration: BoxDecoration(
                color: _hover && !widget.selected ? ZestTokens.surfaceRaisedAlt : ZestTokens.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.selected ? brand.withValues(alpha: 0.75) : ZestTokens.borderSubtle,
                  width: widget.selected ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  VaultTile(crate: crate),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: crateDisplayName(crate, l10n),
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                            ),
                            const TextSpan(text: '   '),
                            TextSpan(
                              text: widget.line,
                              style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
                            ),
                          ]),
                          key: ValueKey('vault-line-${crate.id}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.marks.isNotEmpty || status != null) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (status != null)
                                ZestStatusPill(key: ValueKey('crate-status-${crate.id}'), kind: status.$1, label: status.$2),
                              ...widget.marks,
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(LucideIcons.chevronRight, size: 16, color: ZestTokens.textTertiary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A vault's mark: a box, or a lock where only owners open it.
class VaultTile extends StatelessWidget {
  const VaultTile({super.key, required this.crate, this.size = 36});

  final CrateSummary crate;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: ZestTokens.surfaceChipStrong,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Icon(crate.ownersOnly ? LucideIcons.lock : LucideIcons.package, size: 16, color: ZestTokens.textSecondary),
      );
}

/// What a vault's pane can change, each null where this account may not.
class VaultPaneActions {
  const VaultPaneActions({
    this.onRename,
    this.onAllow,
    this.onConfirmReveal,
    this.onOpenUp,
    this.onEditRoles,
  });

  final VoidCallback? onRename;
  final ValueChanged<Set<String>>? onAllow;
  final ValueChanged<bool>? onConfirmReveal;
  final VoidCallback? onOpenUp;

  /// The Roles page (owners): where each role's level is changed.
  final VoidCallback? onEditRoles;
}

/// A vault's pane on the Vaults page.
class VaultPane extends ConsumerWidget {
  const VaultPane({
    super.key,
    required this.orchard,
    required this.crate,
    required this.hosts,
    required this.people,
    required this.access,
    required this.actions,
    required this.busy,
    required this.watched,
    required this.onClose,
    required this.onShowHosts,
    this.callout,
    this.certificates,
    this.offlineLimit,
    this.sessionLogs,
    this.records,
    this.watchedLine,
  });

  final OrchardSummary orchard;
  final CrateSummary crate;
  final int hosts;
  final OrchardPeople? people;
  final VaultAccess? access;
  final VaultPaneActions actions;
  final bool busy;

  /// Its sessions are watched: it allows the terminal only.
  final bool watched;
  final VoidCallback onClose;
  final VoidCallback onShowHosts;

  /// What closed it here, when it closes, until when a pass holds it.
  final Widget? callout;
  final Widget? certificates;
  final Widget? offlineLimit;
  final Widget? sessionLogs;
  final Widget? records;
  final Widget? watchedLine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final level = levelOf(crate.switches);
    // A line ends only between its parts: "Manage" was left alone on a line
    // before.
    final subtitle = breakAtDots([
      l10n.hostsMetaHostCount(hosts),
      if (crate.closedOffline)
        l10n.orchardClosedOfflineShort
      else
        l10n.crateYourAccess(level == null ? l10n.crateLevelCustom : crateLevelName(level, l10n)),
    ].join(' · '));
    final onRename = actions.onRename;
    return Container(
      key: ValueKey('vault-pane-${crate.id}'),
      // As wide as its place: [kVaultPaneWidth] beside the list, the page
      // where the page has no room for both (TeamListAndPanel).
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        border: Border(left: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 10, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VaultTile(crate: crate, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(crateDisplayName(crate, l10n),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      const SizedBox(height: 3),
                      Text(subtitle, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: ValueKey('crate-show-hosts-${crate.id}'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed: onShowHosts,
                  icon: const Icon(LucideIcons.server, size: 14),
                  label: Text(l10n.vaultShowHosts, style: const TextStyle(fontSize: 12.5)),
                ),
                if (onRename != null)
                  IconButton(
                    key: ValueKey('crate-rename-${crate.id}'),
                    icon: Icon(LucideIcons.pencil, size: 15, color: ZestTokens.textSecondary),
                    tooltip: l10n.crateRenameConfirm,
                    constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                    padding: EdgeInsets.zero,
                    onPressed: busy ? null : onRename,
                  ),
                IconButton(
                  key: const ValueKey('vault-pane-close'),
                  icon: Icon(LucideIcons.x, size: 16, color: ZestTokens.textSecondary),
                  tooltip: l10n.close,
                  constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                  padding: EdgeInsets.zero,
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                if (callout != null) ...[const SizedBox(height: 16), callout!],
                if (access != null && people != null) _whoCanOpen(context, ref, l10n),
                _allowed(context, l10n),
                ?certificates,
                VaultSettingGroup(
                  title: l10n.keysUiSectionProtection,
                  rows: [
                    VaultSettingRow(
                      label: l10n.crateConfirmReveal,
                      helper: l10n.crateConfirmRevealBody,
                      compact: true,
                      control: actions.onConfirmReveal == null
                          ? ZestStatusPill(
                              key: ValueKey('vault-confirm-reveal-state-${crate.id}'),
                              kind: crate.confirmReveal ? ZestStatusKind.healthy : ZestStatusKind.neutral,
                              label: crate.confirmReveal ? l10n.vaultUiStateOn : l10n.vaultUiStateOff,
                            )
                          : ZestSwitch(
                              key: ValueKey('crate-confirm-reveal-${crate.id}'),
                              value: crate.confirmReveal,
                              onChanged: busy ? null : actions.onConfirmReveal,
                            ),
                    ),
                  ],
                  more: [?watchedLine],
                ),
                ?offlineLimit,
                ?sessionLogs,
                ?records,
                if (actions.onOpenUp case final onOpenUp?)
                  VaultSettingGroup(
                    title: l10n.vaultUiGroupDanger,
                    rows: [
                      VaultSettingRow(
                        label: l10n.crateOpenToAll,
                        helper: l10n.crateOpenToAllBody,
                        control: vaultButton(
                          context,
                          key: ValueKey('crate-open-${crate.id}'),
                          label: l10n.vaultUiOpenUp,
                          icon: LucideIcons.unlock,
                          variant: ZestButtonVariant.danger,
                          onPressed: busy ? null : onOpenUp,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Who can open it: each role with its level, then whoever holds it for
  /// a set time, with the way to end that.
  Widget _whoCanOpen(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final access = this.access!;
    final people = this.people!;
    final onEditRoles = actions.onEditRoles;
    return VaultSettingGroup(
      key: ValueKey('vault-who-${crate.id}'),
      title: l10n.vaultsWhoCanOpen,
      trailing: onEditRoles == null
          ? null
          : VaultHeaderLink(key: const ValueKey('vault-edit-roles'), label: l10n.vaultsEditInRoles, onTap: onEditRoles),
      rows: [
        for (final r in access.roles)
          Row(
            key: ValueKey('vault-role-${r.id}'),
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: r.name,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: r.opens ? ZestTokens.textPrimary : ZestTokens.textTertiary),
                    ),
                    TextSpan(
                      text: '  ${l10n.rolesPeopleCount(r.people)}',
                      style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                    ),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                !r.opens
                    ? l10n.crateLevelNone
                    : r.level == null
                        ? l10n.crateLevelCustom
                        : crateLevelName(r.level!, l10n),
                key: ValueKey('vault-role-level-${r.id}'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: r.opens ? FontWeight.w600 : FontWeight.w400,
                  color: r.opens ? ZestTokens.textPrimary : ZestTokens.textTertiary,
                ),
              ),
            ],
          ),
        for (final t in access.timed) _timedRow(context, ref, l10n, people, t),
        if (crate.ownersOnly)
          Text(l10n.vaultsOwnersOnlyNote, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
      ],
    );
  }

  Widget _timedRow(BuildContext context, WidgetRef ref, AppLocalizations l10n, OrchardPeople people, TimedAccess t) {
    final email = people.members.where((m) => m.uid == t.uid).firstOrNull?.email;
    final shown = Redactable.account(email ?? _shortId(t.uid));
    final name = shown.displayIn(ref);
    final mine = t.uid == people.me;
    final initials = (email ?? t.uid).replaceAll(RegExp(r'[^A-Za-z]'), '');
    return Row(
      key: ValueKey('vault-timed-${t.uid}'),
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: ZestTokens.surfaceChipStrong, shape: BoxShape.circle),
          child: RedactedText(
            Redactable.account(initials.isEmpty ? '?' : initials.substring(0, initials.length < 2 ? 1 : 2).toUpperCase()),
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: mine ? l10n.orchardMemberYou : name,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
              ),
              // Its time whole on its line ("until 2:16" over "PM" before).
              TextSpan(
                text: breakAtDots(' · ${l10n.accessUntil(accessTimeText(t.until, l10n))}'),
                style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
              ),
            ]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        // End now before the level, so the level stands at the end of the row
        // as each role's does.
        if (t.canEnd) ...[
          TextButton(
            key: ValueKey('vault-timed-end-${t.uid}'),
            // Red: it ends someone's access.
            style: TextButton.styleFrom(
              foregroundColor: ZestTokens.statusCritical,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 30),
            ),
            onPressed: () => endTimedAccess(context, ref, orchard, t, name: name, mine: mine),
            child: Text(mine ? l10n.accessGiveUp : l10n.accessEndNow, style: const TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
        ],
        Text(crateLevelName(t.level, l10n),
            key: ValueKey('vault-timed-level-${t.uid}'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
      ],
    );
  }

  /// What its hosts allow besides the terminal: a box to tick for whoever
  /// manages it, a mark for everyone else.
  Widget _allowed(BuildContext context, AppLocalizations l10n) {
    final onAllow = actions.onAllow;
    final items = [
      (CrateSwitches.sftp, l10n.crateAllowSftp, l10n.vaultsAllowSftpHelp),
      (CrateSwitches.forward, l10n.crateAllowForward, l10n.vaultsAllowForwardHelp),
      (CrateSwitches.agent, l10n.crateAllowAgent, l10n.vaultsAllowAgentHelp),
    ];
    // While a change is made its boxes wait; nobody else's are boxes.
    final change = onAllow != null && !watched;
    return VaultSettingGroup(
      title: l10n.vaultsAllowedOnHosts,
      rows: [
        if (watched)
          Text(l10n.crateWatchedTerminalOnly,
              key: ValueKey('crate-terminal-only-${crate.id}'),
              style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary)),
        for (final (what, label, help) in items)
          Builder(builder: (context) {
            final on = crate.allow.contains(what) && !watched;
            final words = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(help, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
              ],
            );
            final Widget mark = change
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      key: ValueKey('vault-allow-${crate.id}-$what'),
                      value: on,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onChanged: busy
                          ? null
                          : (v) => onAllow({
                                ...crate.allow.where((s) => s != what),
                                if (v ?? false) what,
                              }),
                    ),
                  )
                : SizedBox(
                    width: 20,
                    height: 20,
                    child: Icon(
                      on ? LucideIcons.check : LucideIcons.minus,
                      key: ValueKey('vault-allowed-${crate.id}-$what-${on ? 'on' : 'off'}'),
                      size: 15,
                      color: on ? ZestTokens.brandInk : ZestTokens.textTertiary,
                    ),
                  );
            final row = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: mark),
                const SizedBox(width: 12),
                Expanded(child: words),
              ],
            );
            if (!change) return row;
            return InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: busy
                  ? null
                  : () => onAllow({
                        ...crate.allow.where((s) => s != what),
                        if (!on) what,
                      }),
              child: row,
            );
          }),
      ],
    );
  }
}
