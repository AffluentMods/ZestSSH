import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/role_levels.dart';
import 'package:zestssh/features/orchards/widgets/vault_picker.dart' show vaultHostCounts;
import 'package:zestssh/features/orchards/widgets/vaults_page.dart' show vaultsInOrder;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';

// The Roles page on a computer (3.0):
// one table. A row for each role, Owner and Admin first (built in),
// then the roles the owners made, highest first; a column for what the role
// may do in the team, and one for each vault with the role's level there.
// A level is changed where it is shown: a click opens the levels, each with
// what it means, and the one picked is saved as the role's new set (the same
// role.set entry the role editor writes). A role is dragged to its place.
// 4.0: each
// level a neutral pill with a meter of four steps and its word, what a role
// may do in the team said in words (changed in the role's editor, from its
// menu's Edit), every vault head with its hosts, and under the table what
// each level allows. Only owners change roles (the record refuses anyone else's role.set): for
// anyone else the table is something to read, with nothing that looks like a
// control.

/// The widths of the table's columns, as drawn on a computer.
const double _kLead = 40;
const double _kRoleCol = 200;
const double _kTeamCol = 322;
const double _kVaultCol = 140;
const double _kMenuCol = 44;
const double _kSide = 12;

/// The Roles page's table for the Orchard [orchardId].
class OrchardRolesMatrix extends ConsumerStatefulWidget {
  const OrchardRolesMatrix({super.key, required this.orchardId});

  final String orchardId;

  @override
  ConsumerState<OrchardRolesMatrix> createState() => _OrchardRolesMatrixState();
}

class _OrchardRolesMatrixState extends ConsumerState<OrchardRolesMatrix> {
  bool _busy = false;

  /// The table's sideways scroll, its scrollbar's own: without it the
  /// scrollbar takes the page's primary controller, which this scroll view
  /// never attaches to (a debug assert on hover on a computer).
  final _sideways = ScrollController();

  @override
  void dispose() {
    _sideways.dispose();
    super.dispose();
  }

  /// The order a drag left the roles in, shown until the record has it.
  List<String>? _order;

  /// The cell whose levels are open: (role, vault).
  (String, String)? _open;

  OrchardSummary? get _orchard =>
      ref.watch(orchardSummariesProvider).valueOrNull?.where((o) => o.id == widget.orchardId).firstOrNull ??
      ref.watch(activeOrchardProvider).valueOrNull;

  Future<void> _run(Future<void> Function(OrchardService s) change, String done) async {
    setState(() => _busy = true);
    var saved = false;
    try {
      saved = await runRoleChange(context, ref, widget.orchardId, change, done);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          // Refused: back to the order the record has. Saved: kept until
          // the roles are read again with it.
          if (!saved) _order = null;
        });
      }
    }
  }

  /// The record's Admin role as this table shows it (null: as every team
  /// starts), read with the people.
  RecordAdminRole? _adminRole;

  Future<bool> _mayChangeAdmin() => mayChangeAdminRole(context, _adminRole);

  /// [role] with [crates] in place of its own: saved as its new set. Admin's
  /// is the Admin role (admin.set), asked about first the first time.
  Future<void> _save(OrchardRoleView role, {Set<String>? can, Map<String, Set<String>>? crates}) async {
    if (role.id == FixedRoles.admin) {
      if (!await _mayChangeAdmin()) return;
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      return _run(
        (s) => s.setAdminRole(widget.orchardId, can: can ?? role.can, crates: crates ?? role.crates),
        l10n.orchardRoleSaved(l10n.orchardRoleAdmin),
      );
    }
    final name = role.name!;
    return _run(
      (s) => s.saveRole(widget.orchardId, id: role.id, name: name, can: can ?? role.can, crates: crates ?? role.crates),
      AppLocalizations.of(context)!.orchardRoleSaved(name),
    );
  }

  Future<void> _setLevel(OrchardRoleView role, CrateSummary crate, CrateLevel? level) {
    final crates = {for (final e in role.crates.entries) e.key: {...e.value}};
    if (level == null) {
      crates.remove(crate.id);
    } else {
      // Agent forwarding is never in a level: kept as it was.
      final agent = crates[crate.id]?.contains(CrateSwitches.agent) ?? false;
      crates[crate.id] = {...levelSwitches(level), if (agent) CrateSwitches.agent};
    }
    return _save(role, crates: crates);
  }

  Future<void> _setAgent(OrchardRoleView role, CrateSummary crate, bool on) {
    final crates = {for (final e in role.crates.entries) e.key: {...e.value}};
    final switches = crates[crate.id];
    if (switches == null) return Future.value();
    on ? switches.add(CrateSwitches.agent) : switches.remove(CrateSwitches.agent);
    return _save(role, crates: crates);
  }

  Future<void> _edit(OrchardRoleView role, List<CrateSummary> crates) async {
    final edited = await editOrchardRole(context, crates, role);
    if (edited == null || !mounted) return;
    if (role.id == FixedRoles.admin) return _save(role, can: edited.can, crates: edited.crates);
    await _run(
      (s) => s.saveRole(widget.orchardId, id: role.id, name: edited.name, can: edited.can, crates: edited.crates),
      AppLocalizations.of(context)!.orchardRoleSaved(edited.name),
    );
  }

  /// A new role like [role]: the same vaults and what it may do, named
  /// "Name (copy)", opened in the editor first, so any
  /// role can be duplicated.
  Future<void> _duplicate(OrchardRoleView role, List<CrateSummary> crates, int count) async {
    final l10n = AppLocalizations.of(context)!;
    final edited = await duplicateOrchardRole(context, crates, role, count);
    if (edited == null || !mounted) return;
    await _run(
      (s) => s.saveRole(widget.orchardId, name: edited.name, can: edited.can, crates: edited.crates),
      l10n.orchardRoleSaved(edited.name),
    );
  }

  /// The Admin role back to every vault that is not owners-only, and
  /// everything in the team.
  Future<void> _resetAdmin() {
    final l10n = AppLocalizations.of(context)!;
    return _run((s) => s.resetAdminRole(widget.orchardId), l10n.orchardRoleSaved(l10n.orchardRoleAdmin));
  }

  Future<void> _drop(OrchardRoleView role, List<OrchardRoleView> roles) async {
    final moveTo = await askDropOrchardRole(context, role, roles);
    if (moveTo == null || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await _run((s) => s.dropRole(widget.orchardId, role.id, moveTo),
        l10n.orchardRoleDeleted(role.name ?? l10n.orchardRoleMember));
  }

  Future<void> _moveTo(List<OrchardRoleView> roles, int from, int to) async {
    if (to == from) return;
    final ids = [for (final r in roles) r.id];
    final id = ids.removeAt(from);
    ids.insert(to, id);
    setState(() => _order = ids);
    await _run((s) => s.moveRoleTo(widget.orchardId, id, to), AppLocalizations.of(context)!.orchardChangeSaved);
  }

  /// "Change in Vaults": the Vaults page, with [crate] open.
  void _openVault(CrateSummary crate) {
    ref.read(teamVaultToOpenProvider.notifier).state = crate.id;
    ref.read(teamPageProvider.notifier).state = TeamPage.crates;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = _orchard;
    final peopleAsync = ref.watch(teamPeopleProvider(widget.orchardId));
    final people = peopleAsync.valueOrNull;
    if (orchard == null) return const SizedBox.shrink();
    if (people == null) {
      if (peopleAsync.hasError) {
        return TeamLoadProblem(
          title: l10n.teamRolesLoadFailed,
          error: peopleAsync.error!,
          stack: peopleAsync.stackTrace,
          where: 'Team roles: reading them',
          onRetry: peopleAsync.isLoading ? null : () => ref.invalidate(teamPeopleProvider(widget.orchardId)),
        );
      }
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final invites = ref.watch(roleInvitesProvider(widget.orchardId)).valueOrNull ?? const <String, int>{};
    final counts = vaultHostCounts(ref, orchard);
    // Only owners change roles.
    final editable = orchard.isOwner && orchard.active;
    final crates = vaultsInOrder(orchard.crates);
    var roles = people.roles;
    final order = _order;
    if (order != null) {
      final ids = [for (final r in roles) r.id];
      if (listEquals(ids, order) || ids.length != order.length || !ids.every(order.contains)) {
        // The record has it now (or the roles changed meanwhile).
        _order = null;
      } else {
        roles = [for (final id in order) roles.firstWhere((r) => r.id == id)];
      }
    }
    int count(String role) => people.members.where((m) => m.role == role).length;
    _adminRole = people.record.adminRole;
    // Admin as a role like the others (3.3.0): what it may do and what it
    // opens, as the record has it.
    final admin = adminRoleView(people.record, crates, l10n.orchardRoleAdmin);

    // (2 for its hairline.)
    final width = 2 + _kSide * 2 + _kLead + _kRoleCol + _kTeamCol + crates.length * _kVaultCol + _kMenuCol;

    Widget row({
      required Key key,
      required Widget lead,
      required String name,
      required bool builtIn,
      required int people,
      required int waiting,
      required Widget can,
      required Widget Function(CrateSummary crate) cell,
      Widget? menu,
    }) =>
        _RoleRow(
          key: key,
          lead: lead,
          name: name,
          builtIn: builtIn,
          people: people,
          waiting: waiting,
          can: can,
          cells: [for (final c in crates) cell(c)],
          menu: menu,
        );

    // A built-in role's lead is a lock (it is there, and stays where it is),
    // a role of the team's own its drag handle: Owner and Admin alike, as
    // Admin's empty lead looked like something missing.
    //
    Widget lock(String roleId) =>
        Icon(LucideIcons.lock, key: ValueKey('role-lock-$roleId'), size: 14, color: ZestTokens.textFaint);

    Widget ownersOnly(String roleId, CrateSummary crate) => SizedBox(
          key: ValueKey('role-cell-$roleId-${crate.id}'),
          height: 32,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.lock, size: 13, color: ZestTokens.textFaint),
              const SizedBox(width: 6),
              Flexible(
                child: Text(l10n.crateOwnersOnly,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: ZestTokens.textFaint)),
              ),
            ],
          ),
        );

    // A role's level in a vault: pressed to change it where [mine].
    Widget levelCell(OrchardRoleView role, CrateSummary c, bool mine) {
      final switches = role.crates[c.id];
      final level = switches == null ? null : exactLevel(switches);
      final open = _open == (role.id, c.id);
      return _LevelCell(
        key: ValueKey('role-cell-${role.id}-${c.id}'),
        roleId: role.id,
        crate: c,
        level: level,
        custom: switches != null && level == null,
        open: open,
        title: l10n.rolesLevelIn(role.name ?? l10n.orchardRoleMember, crateDisplayName(c, l10n)),
        hosts: counts[c.id] ?? 0,
        agent: switches?.contains(CrateSwitches.agent) ?? false,
        onOpen: mine ? (on) => setState(() => _open = on ? (role.id, c.id) : null) : null,
        onLevel: (l) => _setLevel(role, c, l),
        onAgent: (on) => _setAgent(role, c, on),
        onOpenVault: () => _openVault(c),
      );
    }

    final table = Container(
      key: const ValueKey('roles-matrix'),
      width: width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeaderRow(crates: crates, counts: counts),
          Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
          row(
            key: const ValueKey('role-owner'),
            lead: lock(FixedRoles.owner),
            name: l10n.orchardRoleOwner,
            builtIn: true,
            people: count(FixedRoles.owner),
            waiting: invites[FixedRoles.owner] ?? 0,
            can: Text(l10n.rolesEverything,
                key: const ValueKey('role-can-owner-everything'),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
            // Owner's are what they are: nothing says they could change.
            cell: (c) => Center(
              key: ValueKey('role-cell-owner-${c.id}'),
              child: Semantics(
                container: true,
                label: '${l10n.rolesLevelIn(l10n.orchardRoleOwner, crateDisplayName(c, l10n))}: ${l10n.crateLevelManage}',
                excludeSemantics: true,
                child: const RoleLevelPill(level: CrateLevel.manage),
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
          row(
            key: const ValueKey('role-admin'),
            lead: lock(FixedRoles.admin),
            name: l10n.orchardRoleAdmin,
            builtIn: true,
            people: count(FixedRoles.admin),
            waiting: invites[FixedRoles.admin] ?? 0,
            can: _CanWords(roleId: FixedRoles.admin, can: admin.can),
            cell: (c) => c.ownersOnly ? ownersOnly(FixedRoles.admin, c) : levelCell(admin, c, editable && !_busy),
            menu: editable
                ? _RoleMenu(
                    roleId: FixedRoles.admin,
                    enabled: !_busy,
                    onEdit: () => _edit(admin, crates),
                    onDuplicate: () => _duplicate(admin, crates, roles.length),
                    onUp: null,
                    onDown: null,
                    onDelete: null,
                    onReset: _adminRole == null ? null : _resetAdmin,
                  )
                : null,
          ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: roles.length,
            onReorderItem: (from, to) => _moveTo(roles, from, to),
            proxyDecorator: (child, _, _) => Material(
              color: ZestTokens.surfaceRaisedAlt,
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              child: child,
            ),
            itemBuilder: (context, i) {
              final role = roles[i];
              // A role whose name did not open here cannot be saved again.
              final mine = editable && role.name != null && !_busy;
              return Column(
                key: ValueKey('role-${role.id}'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                  row(
                    key: ValueKey('role-row-${role.id}'),
                    lead: editable && roles.length > 1
                        ? ReorderableDragStartListener(
                            key: ValueKey('role-drag-${role.id}'),
                            index: i,
                            enabled: !_busy,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.grab,
                              child: Tooltip(
                                message: l10n.rolesHintDrag,
                                child: Icon(LucideIcons.gripVertical, size: 15, color: ZestTokens.textFaint),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                    name: role.name ?? l10n.orchardRoleMember,
                    builtIn: false,
                    people: count(role.id),
                    waiting: invites[role.id] ?? 0,
                    can: _CanWords(roleId: role.id, can: role.can),
                    cell: (c) => c.ownersOnly ? ownersOnly(role.id, c) : levelCell(role, c, mine),
                    menu: editable
                        ? _RoleMenu(
                            roleId: role.id,
                            enabled: !_busy,
                            onEdit: role.name == null ? null : () => _edit(role, crates),
                            onDuplicate: role.name == null ? null : () => _duplicate(role, crates, roles.length),
                            onUp: i == 0 ? null : () => _moveTo(roles, i, i - 1),
                            onDown: i == roles.length - 1 ? null : () => _moveTo(roles, i, i + 1),
                            onDelete: roles.length > 1 ? () => _drop(role, roles) : null,
                            deleteNote: roles.length > 1 ? null : l10n.orchardRoleDeleteLast,
                          )
                        : null,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );

    final hints = <(IconData, String)>[
      if (editable && roles.length > 1) (LucideIcons.gripVertical, l10n.rolesHintDrag),
      if (editable) (LucideIcons.pencil, l10n.rolesHintClick),
      if (crates.any((c) => c.ownersOnly)) (LucideIcons.lock, l10n.vaultsOwnersOnlyNote),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
        const SizedBox(height: 6),
        // Wider than the page where there are many vaults: it scrolls
        // sideways, the role's name and what it may do with it.
        LayoutBuilder(
          builder: (context, box) => width <= box.maxWidth
              ? Align(alignment: AlignmentDirectional.centerStart, child: table)
              : Scrollbar(
                  controller: _sideways,
                  child: SingleChildScrollView(
                    controller: _sideways,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(bottom: 10),
                    child: table,
                  ),
                ),
        ),
        // What each level allows, as wide as the table (or the page, where
        // the table scrolls sideways).
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: width), child: const RoleLevelsStrip()),
        ),
        if (hints.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            key: const ValueKey('roles-hints'),
            spacing: 22,
            runSpacing: 8,
            children: [
              for (final (icon, text) in hints)
                // A hint longer than the page is wide wraps its words.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(icon, size: 13, color: ZestTokens.textTertiary),
                    ),
                    const SizedBox(width: 7),
                    Flexible(child: Text(text, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary))),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The column heads: Role, In the team, and each vault with its hosts
/// (an owners-only one's hosts too, and that it is owners only).
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.crates, required this.counts});

  final List<CrateSummary> crates;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final head = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.1,
      height: 1,
      color: ZestTokens.textTertiary,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 62),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _kSide, vertical: 12),
        child: Row(
          children: [
            const SizedBox(width: _kLead),
            SizedBox(width: _kRoleCol, child: Text(l10n.rolesColumnRole.toUpperCase(), style: head)),
            SizedBox(width: _kTeamCol, child: Text(l10n.rolesColumnInTeam.toUpperCase(), style: head)),
            for (final c in crates)
              SizedBox(
                key: ValueKey('roles-head-${c.id}'),
                width: _kVaultCol,
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(c.ownersOnly ? LucideIcons.lock : LucideIcons.package, size: 13, color: ZestTokens.textFaint),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(crateDisplayName(c, l10n).toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: head.copyWith(color: ZestTokens.textSecondary)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        l10n.hostsMetaHostCount(counts[c.id] ?? 0),
                        if (c.ownersOnly) l10n.crateOwnersOnly,
                      ].join(' · '),
                      key: ValueKey('roles-head-count-${c.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1, color: ZestTokens.textFaint),
                    ),
                  ],
                ),
              ),
            const SizedBox(width: _kMenuCol),
          ],
        ),
      ),
    );
  }
}

/// One role's row: its mark (a lock, or the handle it is dragged by), its
/// name and who has it, what it may do in the team, its level in each vault,
/// and its menu.
class _RoleRow extends StatelessWidget {
  const _RoleRow({
    super.key,
    required this.lead,
    required this.name,
    required this.builtIn,
    required this.people,
    required this.waiting,
    required this.can,
    required this.cells,
    this.menu,
  });

  final Widget lead;
  final String name;
  final bool builtIn;
  final int people;
  final int waiting;
  final Widget can;
  final List<Widget> cells;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 76),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _kSide, vertical: 12),
        child: Row(
          children: [
            SizedBox(width: _kLead, child: Center(child: lead)),
            SizedBox(
              width: _kRoleCol,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      ),
                      if (builtIn) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: ZestTokens.surfaceChip,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(l10n.rolesBuiltIn,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: ZestTokens.textSecondary)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      l10n.rolesPeopleCount(people),
                      if (waiting > 0) l10n.rolesWaitingToJoin(waiting),
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: ZestTokens.textFaint),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: _kTeamCol,
              child: Padding(padding: const EdgeInsetsDirectional.only(end: 12), child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: can,
              )),
            ),
            for (final c in cells)
              SizedBox(width: _kVaultCol, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 7), child: c)),
            SizedBox(width: _kMenuCol, child: Center(child: menu ?? const SizedBox.shrink())),
          ],
        ),
      ),
    );
  }
}

/// What a role may do in the team, in words: "Invite, remove, change roles,
/// add vaults", as much as it may, or None. It is changed in the role's
/// editor (its menu's Edit), which has the same four boxes.
class _CanWords extends StatelessWidget {
  const _CanWords({required this.roleId, required this.can});

  final String roleId;
  final Set<String> can;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      roleCanWords(can, l10n),
      key: ValueKey('role-can-$roleId'),
      style: TextStyle(
        fontSize: 13,
        height: 1.4,
        color: can.isEmpty ? ZestTokens.textTertiary : ZestTokens.textSecondary,
      ),
    );
  }
}

/// A level as the table shows it ([RoleLevelPill]); with [onTap] a button
/// (a click, or Enter or Space once Tab reached it) with a chevron that says
/// so. [label] is what a screen reader says of it.
class _LevelPill extends StatefulWidget {
  const _LevelPill({
    super.key,
    required this.level,
    required this.label,
    this.custom = false,
    this.onTap,
    this.open = false,
  });

  final CrateLevel? level;
  final String label;
  final bool custom;
  final VoidCallback? onTap;
  final bool open;

  @override
  State<_LevelPill> createState() => _LevelPillState();
}

class _LevelPillState extends State<_LevelPill> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final pill = ExcludeSemantics(
      child: RoleLevelPill(
        level: widget.level,
        custom: widget.custom,
        chevron: onTap != null,
        open: widget.open,
        hover: _hover && onTap != null,
        focused: _focus,
      ),
    );
    if (onTap == null) {
      return Semantics(container: true, label: widget.label, child: pill);
    }
    return Semantics(
      button: true,
      expanded: widget.open,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            onTap();
            return null;
          }),
        },
        child: GestureDetector(onTap: onTap, child: pill),
      ),
    );
  }
}

/// A role's level in a vault, which a click opens to change.
class _LevelCell extends StatefulWidget {
  const _LevelCell({
    super.key,
    required this.roleId,
    required this.crate,
    required this.level,
    required this.custom,
    required this.open,
    required this.title,
    required this.hosts,
    required this.agent,
    required this.onOpen,
    required this.onLevel,
    required this.onAgent,
    required this.onOpenVault,
  });

  final String roleId;
  final CrateSummary crate;
  final CrateLevel? level;
  final bool custom;
  final bool open;
  final String title;
  final int hosts;
  final bool agent;

  /// Opens (true) or closes the levels; null where it is not to be changed.
  final ValueChanged<bool>? onOpen;
  final ValueChanged<CrateLevel?> onLevel;
  final ValueChanged<bool> onAgent;
  final VoidCallback onOpenVault;

  @override
  State<_LevelCell> createState() => _LevelCellState();
}

class _LevelCellState extends State<_LevelCell> {
  final _portal = OverlayPortalController();

  /// Where the cell is on the overlay, when the levels opened.
  Rect _target = Rect.zero;

  static const double _width = 340;

  void _show() {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (box != null) {
      _target = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    }
    _portal.show();
    widget.onOpen?.call(true);
  }

  void _hide() {
    if (_portal.isShowing) _portal.hide();
    widget.onOpen?.call(false);
  }

  @override
  void didUpdateWidget(covariant _LevelCell old) {
    super.didUpdateWidget(old);
    // Closed from outside (a change saved, another cell opened).
    if (!widget.open && _portal.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.open && _portal.isShowing) _portal.hide();
      });
    }
  }

  String _levelWord(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final level = widget.level;
    if (widget.custom) return l10n.crateLevelCustom;
    return level == null ? l10n.crateLevelNone : crateLevelName(level, l10n);
  }

  @override
  Widget build(BuildContext context) {
    final onOpen = widget.onOpen;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => Stack(
        children: [
          // A click anywhere else closes it, and so does a scroll (the
          // cell moves away from under it).
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: (_) => _hide(),
              child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _hide),
            ),
          ),
          // Under the cell, or over it where there is no room below;
          // within the window either way.
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _PopoverLayout(_target),
              child: _LevelPopover(
                key: ValueKey('role-levels-${widget.roleId}-${widget.crate.id}'),
                width: _width,
                title: widget.title,
                hosts: widget.hosts,
                level: widget.level,
                custom: widget.custom,
                agent: widget.agent,
                agentAllowed: widget.crate.allow.contains(CrateSwitches.agent),
                keyPart: '${widget.roleId}-${widget.crate.id}',
                onClose: _hide,
                onLevel: (l) {
                  _hide();
                  if (l != widget.level || widget.custom) widget.onLevel(l);
                },
                onAgent: (on) {
                  _hide();
                  widget.onAgent(on);
                },
                onOpenVault: () {
                  _hide();
                  widget.onOpenVault();
                },
              ),
            ),
          ),
        ],
      ),
      child: _LevelPill(
        key: onOpen == null ? null : ValueKey('role-level-${widget.roleId}-${widget.crate.id}'),
        label: '${widget.title}: ${_levelWord(context)}',
        level: widget.level,
        custom: widget.custom,
        open: widget.open,
        onTap: onOpen == null ? null : () => _portal.isShowing ? _hide() : _show(),
      ),
    );
  }
}

/// Places the levels under [target], centred on it, or over it where the
/// window has no room below; always inside the window (on a window too
/// short for either, as low as it goes: the level picked is marked in it).
class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout(this.target);

  final Rect target;

  static const double _gap = 6;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
      Size(constraints.maxWidth - _margin * 2, constraints.maxHeight - _margin * 2));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (target.center.dx - child.width / 2).clamp(_margin, size.width - child.width - _margin);
    final below = size.height - target.bottom - _gap - _margin;
    final above = target.top - _gap - _margin;
    final double y;
    if (child.height <= below) {
      y = target.bottom + _gap;
    } else if (child.height <= above) {
      y = target.top - _gap - child.height;
    } else {
      y = (size.height - child.height - _margin).clamp(_margin, size.height);
    }
    return Offset(x.toDouble(), y);
  }

  @override
  bool shouldRelayout(_PopoverLayout old) => old.target != target;
}

/// The levels of a role in a vault, each with what it means; agent
/// forwarding under them.
class _LevelPopover extends StatelessWidget {
  const _LevelPopover({
    super.key,
    required this.width,
    required this.title,
    required this.hosts,
    required this.level,
    required this.custom,
    required this.agent,
    required this.agentAllowed,
    required this.keyPart,
    required this.onClose,
    required this.onLevel,
    required this.onAgent,
    required this.onOpenVault,
  });

  final double width;
  final String title;
  final int hosts;
  final CrateLevel? level;
  final bool custom;
  final bool agent;
  final bool agentAllowed;
  final String keyPart;
  final VoidCallback onClose;
  final ValueChanged<CrateLevel?> onLevel;
  final ValueChanged<bool> onAgent;
  final VoidCallback onOpenVault;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = <(CrateLevel?, String, String)>[
      (null, l10n.crateLevelNone, l10n.rolesLevelNoneHelp),
      (CrateLevel.connect, l10n.crateLevelConnect, l10n.rolesLevelConnectHelp),
      (CrateLevel.use, l10n.crateLevelUse, l10n.rolesLevelUseHelp),
      (CrateLevel.edit, l10n.crateLevelEdit, l10n.rolesLevelEditHelp),
      (CrateLevel.manage, l10n.crateLevelManage, l10n.rolesLevelManageHelp),
    ];
    int valueOf(CrateLevel? l) => l == null ? -1 : l.index;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: width,
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceRaisedAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ZestTokens.borderStrong),
              boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 40, offset: Offset(0, 18), spreadRadius: -10)],
            ),
            child: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      ),
                      const SizedBox(width: 10),
                      Text(l10n.hostsMetaHostCount(hosts), style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
                    ],
                  ),
                ),
                RadioGroup<int>(
                  // A set made by hand matches no level: none is picked.
                  groupValue: custom ? null : valueOf(level),
                  onChanged: (v) {
                    if (v == null) return;
                    onLevel(v < 0 ? null : CrateLevel.values[v]);
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (l, name, help) in options)
                        _LevelOption(
                          key: ValueKey('role-pick-$keyPart-${l?.name ?? 'none'}'),
                          value: valueOf(l),
                          selected: !custom && valueOf(l) == valueOf(level),
                          name: name,
                          help: help,
                        ),
                    ],
                  ),
                ),
                if (!agentAllowed || level != null || custom) ...[
                  const SizedBox(height: 6),
                  Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (agentAllowed)
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: Checkbox(
                              key: ValueKey('role-agent-$keyPart'),
                              value: agent,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              onChanged: (v) => onAgent(v ?? false),
                            ),
                          )
                        else
                          // Not a control: the vault itself does not allow it.
                          Container(
                            width: 16,
                            height: 16,
                            margin: const EdgeInsets.only(top: 1),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: ZestTokens.borderStrong),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l10n.crateAllowAgent,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: agentAllowed ? ZestTokens.textPrimary : ZestTokens.textTertiary)),
                              const SizedBox(height: 2),
                              if (agentAllowed)
                                Text(l10n.vaultsAllowAgentHelp,
                                    style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary))
                              else
                                Text.rich(
                                  TextSpan(children: [
                                    TextSpan(text: l10n.rolesAgentOffHere),
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.baseline,
                                      baseline: TextBaseline.alphabetic,
                                      // Apart by a gap, not a space (none
                                      // follows a full-width stop).
                                      child: Padding(
                                        padding: const EdgeInsetsDirectional.only(start: 4),
                                        child: GestureDetector(
                                        key: ValueKey('role-agent-vaults-$keyPart'),
                                        onTap: onOpenVault,
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: Text(l10n.rolesChangeInVaults,
                                              style: TextStyle(
                                                  fontSize: 12, fontWeight: FontWeight.w500, color: ZestTokens.brandInk)),
                                        ),
                                      ),
                                      ),
                                    ),
                                  ]),
                                  style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),)
          ),
        ),
      ),
    );
  }
}

/// One level to pick: its radio, its name and what it means; the whole row
/// is the target.
class _LevelOption extends StatelessWidget {
  const _LevelOption({super.key, required this.value, required this.selected, required this.name, required this.help});

  final int value;
  final bool selected;
  final String name;
  final String help;

  @override
  Widget build(BuildContext context) {
    final group = RadioGroup.maybeOf<int>(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? ZestTokens.surfaceChip : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => group?.onChanged(value),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Radio<int>(
                    value: value,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      const SizedBox(height: 2),
                      Text(help, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
                    ],
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

/// A role's menu: edit it, move it, delete it.
class _RoleMenu extends StatelessWidget {
  const _RoleMenu({
    required this.roleId,
    required this.enabled,
    required this.onEdit,
    this.onDuplicate,
    required this.onUp,
    required this.onDown,
    required this.onDelete,
    this.deleteNote,
    this.onReset,
  });

  final String roleId;
  final bool enabled;
  final VoidCallback? onEdit;
  final VoidCallback? onDuplicate;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onDelete;

  /// Why it cannot be deleted, where it cannot.
  final String? deleteNote;

  /// Admin's, once an owner changed it: back to all of it.
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    MenuItemButton item(String key, IconData icon, String label, VoidCallback? onPressed, {bool danger = false}) =>
        MenuItemButton(
          key: ValueKey('role-menu-$key-$roleId'),
          leadingIcon: Icon(icon, size: 15, color: danger ? ZestTokens.statusCritical : null),
          onPressed: onPressed,
          child: Text(label, style: danger ? TextStyle(color: ZestTokens.statusCritical) : null),
        );
    return MenuAnchor(
      alignmentOffset: const Offset(-150, 4),
      menuChildren: [
        if (onEdit != null) item('edit', LucideIcons.pencil, l10n.edit, onEdit),
        if (onDuplicate != null) item('duplicate', LucideIcons.copy, l10n.orchardRoleDuplicate, onDuplicate),
        if (onUp != null) item('up', LucideIcons.arrowUp, l10n.orchardRoleMoveUp, onUp),
        if (onDown != null) item('down', LucideIcons.arrowDown, l10n.orchardRoleMoveDown, onDown),
        if (onReset != null) item('reset', LucideIcons.rotateCcw, l10n.rolesAdminReset, onReset),
        if (onDelete != null)
          item('delete', LucideIcons.trash2, l10n.delete, onDelete, danger: true)
        else if (deleteNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(deleteNote!, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
            ),
          ),
      ],
      builder: (context, menu, _) => IconButton(
        key: ValueKey('role-more-$roleId'),
        icon: Icon(LucideIcons.moreHorizontal, size: 16, color: ZestTokens.textTertiary),
        tooltip: l10n.vaultUiMore,
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? () => menu.isOpen ? menu.close() : menu.open() : null,
      ),
    );
  }
}
