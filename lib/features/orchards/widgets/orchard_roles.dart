import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion, newRecordKindsOn;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/role_levels.dart';
import 'package:zestssh/features/orchards/widgets/vault_picker.dart' show vaultHostCounts;
import 'package:zestssh/features/orchards/widgets/vaults_page.dart' show vaultsInOrder;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

// The owners' roles (3.0): Owner and Admin are fixed at the top;
// below them the roles the owners make, highest first, each with what it
// may do in the Orchard and the Crates it opens at a level. Rank decides who
// manages whom: people manage only those below them.

/// The Roles screen of [orchardId] (owners).
Future<void> showOrchardRoles(BuildContext context, WidgetRef ref, String orchardId) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.shieldCheck,
    title: l10n.orchardRoles,
    subtitle: l10n.orchardRolesSubtitle,
    body: OrchardRolesView(orchardId: orchardId),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

/// Makes one change to [orchardId]'s roles: after a recent sign-in where
/// the server asks for one (roles decide what people may do), with the
/// keys a role that no longer opens a Crate leaves waiting replaced, and
/// [done] said. The roles and the Orchards are read again after it. False
/// when nothing was changed (refused, or the sign-in was not given); what
/// went wrong is said.
Future<bool> runRoleChange(
  BuildContext context,
  WidgetRef ref,
  String orchardId,
  Future<void> Function(OrchardService s) change,
  String done,
) async {
  final l10n = AppLocalizations.of(context)!;
  final service = ref.read(orchardServiceProvider);
  try {
    if (!await withRecentSignIn(context, ref, () => change(service),
            summary: (what: l10n.stepUpRoles, effects: [l10n.stepUpEffectKeysIfLost])) ||
        !context.mounted) {
      return false;
    }
    // A role that no longer opens a Crate leaves its key waiting.
    var left = const <String>[];
    if (await service.keysWaiting(orchardId)) left = await service.rotateDue(orchardId);
    if (!context.mounted) return true;
    showTopSnackBar(context, done, isSuccess: true);
    if (left.isNotEmpty) showTopSnackBar(context, l10n.orchardKeysReplaceLater, isWarning: true);
    ref.invalidate(orchardRolesProvider(orchardId));
    ref.read(orchardListVersionProvider.notifier).state++;
    return true;
  } catch (e) {
    AppLogger.warning('Orchard roles: a change was not made ($e)');
    if (context.mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    return false;
  }
}

/// The role editor for [role] (null: a new one), offering every one of
/// [crates] that is not owners-only. Returns the role as saved, or null.
///
/// [onDelete], a phone's and a tablet's: the role's Delete, in its own
/// editor and not on its row in the list (3.0 quick wins); the editor closes
/// and [onDelete] asks where its members go. [deleteNote] says why it cannot
/// be deleted, where it cannot.
Future<({String name, Set<String> can, Map<String, Set<String>> crates})?> editOrchardRole(
        BuildContext context, List<CrateSummary> crates, OrchardRoleView? role,
        {OrchardRoleView? from,
        VoidCallback? onDelete,
        VoidCallback? onDuplicate,
        VoidCallback? onReset,
        String? deleteNote}) =>
    showZestModal<({String name, Set<String> can, Map<String, Set<String>> crates})>(
      context: context,
      size: ZestModalSize.standard,
      child: RoleEditor(
        role: role,
        from: from,
        onDuplicate: role == null ? null : onDuplicate,
        onReset: role == null ? null : onReset,
        crates: [
          for (final c in crates)
            if (!c.ownersOnly) c,
        ],
        onDelete: role == null ? null : onDelete,
        deleteNote: role == null ? null : deleteNote,
      ),
    );

/// Whether the Admin role can be changed yet: new kinds of team record entry
/// wait until 3.3.0 is out on every platform.
/// When not, it says so, and is false.
Future<bool> adminChangesOn(BuildContext context) async {
  if (newRecordKindsOn.value) return true;
  final l10n = AppLocalizations.of(context)!;
  await ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.info,
    icon: LucideIcons.clock,
    title: l10n.rolesAdminNotYetTitle,
    body: Text(l10n.rolesAdminNotYetBody(kNewRecordKindsVersion), key: const ValueKey('admin-not-yet')),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
  return false;
}

/// Before a change of a kind of team record entry that older versions
/// cannot read: the first in a team is an owner's, after the
/// question of what older versions do then (the server refuses anyone
/// else's). True to go on, at once once the team's [record] holds one.
Future<bool> confirmNewRecordKinds(BuildContext context, OrchardRecord record, {required bool owner}) async {
  if (record.newKindsUsed) return true;
  final l10n = AppLocalizations.of(context)!;
  if (!owner) {
    await ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.info,
      icon: LucideIcons.crown,
      title: l10n.newKindsOwnerFirstTitle,
      body: Text(l10n.newKindsOwnerFirstBody(kNewRecordKindsVersion), key: const ValueKey('new-kinds-owner-first')),
      primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
    );
    return false;
  }
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.newKindsTitle(kNewRecordKindsVersion),
    // What stops on older versions is what warns, the whole of it.
    body: '',
    warning: l10n.newKindsBody,
    confirmLabel: l10n.newKindsConfirm,
  );
  return go == true && context.mounted;
}

/// Before the first change to the Admin role (3.3.0): what admins keep, and
/// that everyone then needs 3.3.0 or newer. True to go on; true at once when
/// [admin] (the record's Admin role) was changed before. False while the
/// change is not on yet ([adminChangesOn]).
Future<bool> mayChangeAdminRole(BuildContext context, RecordAdminRole? admin) async {
  if (!await adminChangesOn(context) || !context.mounted) return false;
  if (admin != null) return true;
  final l10n = AppLocalizations.of(context)!;
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.rolesAdminChangeTitle,
    body: l10n.rolesAdminChangeLead,
    warning: l10n.rolesAdminChangeWarning(kNewRecordKindsVersion),
    confirmLabel: l10n.rolesAdminChangeConfirm,
  );
  return go == true && context.mounted;
}

/// The Admin role of [record] as a role view: what it may do and the Crates
/// of [crates] it opens, as the record has it (named [name]).
OrchardRoleView adminRoleView(OrchardRecord record, Iterable<CrateSummary> crates, String name) => OrchardRoleView(
      id: FixedRoles.admin,
      name: name,
      rank: kAdminRank,
      can: {...(record.adminRole?.can ?? RoleCan.all)},
      crates: {
        for (final c in crates)
          if (adminSwitches(record.adminRole, crateId: c.id, ownersOnly: c.ownersOnly) case final s when s.isNotEmpty)
            c.id: s,
      },
    );

/// Duplicate: the editor on a new role filled in from [role] (its vaults,
/// what it may do, and "Name (copy)"), or the limit said when the team
/// already has [count] of [kMaxOrchardRoles]. Returns the role to save, or
/// null.
Future<({String name, Set<String> can, Map<String, Set<String>> crates})?> duplicateOrchardRole(
    BuildContext context, List<CrateSummary> crates, OrchardRoleView role, int count) async {
  final l10n = AppLocalizations.of(context)!;
  if (count >= kMaxOrchardRoles) {
    showTopSnackBar(context, l10n.orchardRoleLimit(kMaxOrchardRoles), isWarning: true);
    return null;
  }
  final from = OrchardRoleView(
    id: '',
    name: l10n.orchardRoleCopyName(role.name ?? l10n.orchardRoleMember),
    rank: role.rank,
    can: role.can,
    crates: role.crates,
  );
  return editOrchardRole(context, crates, null, from: from);
}

/// "New role", from the Roles page's header: the editor, then the role
/// saved below every other one. At the limit it says so instead.
Future<void> newOrchardRole(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final roles = ref.read(orchardRolesProvider(orchard.id)).valueOrNull;
  if (roles != null && roles.length >= kMaxOrchardRoles) {
    showTopSnackBar(context, l10n.orchardRoleLimit(kMaxOrchardRoles), isWarning: true);
    return;
  }
  final edited = await editOrchardRole(context, orchard.crates, null);
  if (edited == null || !context.mounted) return;
  await runRoleChange(
    context,
    ref,
    orchard.id,
    (s) => s.saveRole(orchard.id, name: edited.name, can: edited.can, crates: edited.crates),
    l10n.orchardRoleSaved(edited.name),
  );
}

class OrchardRolesView extends ConsumerStatefulWidget {
  const OrchardRolesView({super.key, required this.orchardId});

  final String orchardId;

  @override
  ConsumerState<OrchardRolesView> createState() => _OrchardRolesViewState();
}

class _OrchardRolesViewState extends ConsumerState<OrchardRolesView> {
  OrchardPeople? _people;

  /// Why the roles could not be read; null while they are, or could be.
  ({Object error, StackTrace stack})? _failed;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final people = await ref.read(orchardServiceProvider).people(widget.orchardId);
      if (mounted) {
        setState(() {
          _people = people;
          _failed = null;
        });
      }
    } catch (e, st) {
      AppLogger.warning('Orchard roles: $e');
      if (mounted) setState(() => _failed = (error: e, stack: st));
    }
  }

  /// The team as the list shows it. Watched, with the team on screen as the
  /// fallback: read once before the teams were, every vault was "Unnamed
  /// vault" on a phone.
  OrchardSummary? _orchard({bool watch = false}) {
    final summaries = watch ? ref.watch(orchardSummariesProvider) : ref.read(orchardSummariesProvider);
    final active = watch ? ref.watch(activeOrchardProvider) : ref.read(activeOrchardProvider);
    final shown = active.valueOrNull;
    return summaries.valueOrNull?.where((o) => o.id == widget.orchardId).firstOrNull ??
        (shown?.id == widget.orchardId ? shown : null);
  }

  List<CrateSummary> get _crates => vaultsInOrder(_orchard()?.crates ?? const []);

  Future<void> _run(Future<void> Function(OrchardService s) change, String done) async {
    setState(() => _busy = true);
    try {
      if (await runRoleChange(context, ref, widget.orchardId, change, done) && mounted) await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(OrchardRoleView? role, {OrchardPeople? people}) async {
    final l10n = AppLocalizations.of(context)!;
    // A phone's and a tablet's Delete is in the role's own editor (3.0 quick
    // wins: never on a list row); it closes the editor, then asks.
    var delete = false;
    var duplicate = false;
    var reset = false;
    final roles = people?.roles ?? const <OrchardRoleView>[];
    final isAdmin = role?.id == FixedRoles.admin;
    // Said before the editor opens, not after the changes are made.
    if (isAdmin && (!await adminChangesOn(context) || !mounted)) return;
    final canDelete = isTouchLayout && role != null && !isAdmin && people != null && roles.length > 1;
    final edited = await editOrchardRole(
      context,
      _crates,
      role,
      onDelete: canDelete ? () => delete = true : null,
      onDuplicate: isTouchLayout && role?.name != null ? () => duplicate = true : null,
      onReset: isAdmin && people?.record.adminRole != null ? () => reset = true : null,
      deleteNote: isTouchLayout && role != null && !isAdmin && !canDelete ? l10n.orchardRoleDeleteLast : null,
    );
    if (!mounted) return;
    if (reset) {
      await _run((s) => s.resetAdminRole(widget.orchardId), l10n.orchardRoleSaved(l10n.orchardRoleAdmin));
      return;
    }
    if (delete) {
      await _drop(role!, people!);
      return;
    }
    if (duplicate) {
      final made = await duplicateOrchardRole(context, _crates, role!, roles.length);
      if (made == null || !mounted) return;
      await _run((s) => s.saveRole(widget.orchardId, name: made.name, can: made.can, crates: made.crates),
          AppLocalizations.of(context)!.orchardRoleSaved(made.name));
      return;
    }
    if (edited == null) return;
    if (isAdmin) {
      if (!await mayChangeAdminRole(context, people?.record.adminRole) || !mounted) return;
      await _run((s) => s.setAdminRole(widget.orchardId, can: edited.can, crates: edited.crates),
          AppLocalizations.of(context)!.orchardRoleSaved(l10n.orchardRoleAdmin));
      return;
    }
    await _run(
      (s) => s.saveRole(widget.orchardId, id: role?.id, name: edited.name, can: edited.can, crates: edited.crates),
      AppLocalizations.of(context)!.orchardRoleSaved(edited.name),
    );
  }

  Future<void> _drop(OrchardRoleView role, OrchardPeople people) async {
    final moveTo = await askDropOrchardRole(context, role, people.roles);
    if (moveTo == null || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    await _run((s) => s.dropRole(widget.orchardId, role.id, moveTo),
        l10n.orchardRoleDeleted(role.name ?? l10n.orchardRoleMember));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final people = _people;
    final failed = _failed;
    if (failed != null && people == null) {
      return TeamLoadProblem(
        title: l10n.teamRolesLoadFailed,
        error: failed.error,
        stack: failed.stack,
        where: 'Team roles: reading them',
        onRetry: _load,
      );
    }
    if (people == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final orchard = _orchard(watch: true);
    final crates = vaultsInOrder(orchard?.crates ?? const []);
    final counts = orchard == null ? const <String, int>{} : vaultHostCounts(ref, orchard);
    final invites = ref.watch(roleInvitesProvider(widget.orchardId)).valueOrNull ?? const <String, int>{};
    int count(String role) => people.members.where((m) => m.role == role).length;
    final roles = people.roles;
    final admin = adminRoleView(people.record, crates, l10n.orchardRoleAdmin);
    // Each vault and the role's level there: Owner's Manage everywhere; an
    // owners-only vault no other role reaches.
    List<_VaultLevel> levels(OrchardRoleView? role) => [
          for (final c in crates)
            (
              crate: c,
              hosts: counts[c.id] ?? 0,
              ownersOnly: role != null && c.ownersOnly,
              switches: role == null ? levelSwitches(CrateLevel.manage) : role.crates[c.id],
            ),
        ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RoleCard(
          key: const ValueKey('role-owner'),
          roleId: FixedRoles.owner,
          name: l10n.orchardRoleOwner,
          builtIn: true,
          people: count(FixedRoles.owner),
          waiting: invites[FixedRoles.owner] ?? 0,
          inTeam: l10n.rolesEverything,
          everything: true,
          vaults: levels(null),
          fixed: true,
        ),
        _RoleCard(
          key: const ValueKey('role-admin'),
          roleId: FixedRoles.admin,
          name: l10n.orchardRoleAdmin,
          builtIn: true,
          people: count(FixedRoles.admin),
          waiting: invites[FixedRoles.admin] ?? 0,
          inTeam: roleCanWords(admin.can, l10n),
          noneInTeam: admin.can.isEmpty,
          vaults: levels(admin),
          // An owner changes it like any role, but it never moves.
          fixed: !people.isOwner,
          moves: false,
          // Never deleted: the card opens its editor.
          deleteOnRow: false,
          busy: _busy,
          onEdit: () => _edit(admin, people: people),
        ),
        for (var i = 0; i < roles.length; i++)
          _RoleCard(
            key: ValueKey('role-${roles[i].id}'),
            roleId: roles[i].id,
            name: roles[i].name ?? l10n.orchardRoleMember,
            people: count(roles[i].id),
            waiting: invites[roles[i].id] ?? 0,
            inTeam: roleCanWords(roles[i].can, l10n),
            noneInTeam: roles[i].can.isEmpty,
            vaults: levels(roles[i]),
            busy: _busy,
            onUp: i == 0 ? null : () => _run((s) => s.moveRole(widget.orchardId, roles[i].id, up: true), l10n.orchardChangeSaved),
            onDown: i == roles.length - 1
                ? null
                : () => _run((s) => s.moveRole(widget.orchardId, roles[i].id, up: false), l10n.orchardChangeSaved),
            onEdit: () => _edit(roles[i], people: people),
            onDelete: roles.length > 1 ? () => _drop(roles[i], people) : null,
            deleteTooltip: roles.length > 1 ? l10n.delete : l10n.orchardRoleDeleteLast,
            // A phone's and a tablet's Delete is in the role's editor (tap
            // the card or its pencil), not on the card.
            deleteOnRow: !isTouchLayout,
          ),
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: _maybeTooltip(
            roles.length >= kMaxOrchardRoles ? l10n.orchardRoleLimit(kMaxOrchardRoles) : null,
            TextButton.icon(
              key: const ValueKey('role-new'),
              onPressed: _busy || roles.length >= kMaxOrchardRoles ? null : () => _edit(null),
              icon: const Icon(LucideIcons.plus, size: 14),
              label: Text(l10n.orchardRoleNew),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // What each level allows: on a phone there is no other place that
        // says it before a level is picked.
        const RoleLevelsStrip(),
      ],
    );
  }
}

/// A vault on a role's card: the vault, its hosts, whether only owners
/// reach it, and the role's switches there (null: none).
typedef _VaultLevel = ({CrateSummary crate, int hosts, bool ownersOnly, Set<String>? switches});

/// One role on a phone's and a tablet's Roles page (4.0,
/// as a card): its name and who has it, what it may do in the
/// team in words, and its level in each vault as the table's pill. A tap
/// opens its editor (where its Delete and Duplicate are on a phone); Up and
/// Down move it.
class _RoleCard extends StatelessWidget {
  const _RoleCard({
    super.key,
    required this.roleId,
    required this.name,
    required this.people,
    required this.inTeam,
    required this.vaults,
    this.builtIn = false,
    this.waiting = 0,
    this.everything = false,
    this.noneInTeam = false,
    this.fixed = false,
    this.moves = true,
    this.busy = false,
    this.onUp,
    this.onDown,
    this.onEdit,
    this.onDelete,
    this.deleteTooltip,
    this.deleteOnRow = true,
  });

  final String roleId;
  final String name;
  final bool builtIn;
  final int people;
  final int waiting;
  final String inTeam;

  /// Owner's: may do everything, said in bold.
  final bool everything;

  /// May do nothing in the team: said quieter.
  final bool noneInTeam;
  final List<_VaultLevel> vaults;
  final bool fixed;

  /// Up and Down on the card (Admin's has neither).
  final bool moves;
  final bool busy;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final String? deleteTooltip;

  /// Whether Delete is a button on the card (a computer's dialog). A phone
  /// and a tablet have it in the role's editor, which a tap on the card
  /// opens (3.0 quick wins).
  final bool deleteOnRow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final touch = isTouchLayout;
    Widget button(String key, IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
          key: ValueKey(key),
          icon: Icon(icon, size: 16),
          tooltip: tooltip,
          // 48 by 48 on a phone and a tablet.
          visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
          onPressed: busy ? null : onPressed,
        );
    final head = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                  if (builtIn)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: ZestTokens.surfaceChip, borderRadius: BorderRadius.circular(5)),
                      child: Text(l10n.rolesBuiltIn,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: ZestTokens.textSecondary)),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                [l10n.rolesPeopleCount(people), if (waiting > 0) l10n.rolesWaitingToJoin(waiting)].join(' · '),
                style: TextStyle(fontSize: 12, color: ZestTokens.textFaint),
              ),
            ],
          ),
        ),
        if (!fixed) ...[
          if (moves) ...[
            button('up', LucideIcons.arrowUp, l10n.orchardRoleMoveUp, onUp),
            button('down', LucideIcons.arrowDown, l10n.orchardRoleMoveDown, onDown),
          ],
          button('edit', LucideIcons.pencil, l10n.edit, onEdit),
          if (deleteOnRow) button('delete', LucideIcons.trash2, deleteTooltip ?? l10n.delete, onDelete),
        ],
      ],
    );
    final label = TextStyle(fontSize: 12, color: ZestTokens.textTertiary);
    final body = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(14, fixed ? 12 : 4, fixed ? 14 : 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          const SizedBox(height: 10),
          Padding(
            padding: EdgeInsetsDirectional.only(end: fixed ? 0 : 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.rolesColumnInTeam, style: label),
                const SizedBox(height: 3),
                Text(
                  inTeam,
                  key: ValueKey('role-can-$roleId'),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: everything ? FontWeight.w600 : FontWeight.w400,
                    color: everything
                        ? ZestTokens.textPrimary
                        : noneInTeam
                            ? ZestTokens.textTertiary
                            : ZestTokens.textSecondary,
                  ),
                ),
                for (final v in vaults) ...[
                  const SizedBox(height: 8),
                  _VaultLevelLine(roleId: roleId, roleName: name, vault: v),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    final card = Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZestTokens.border),
      ),
      child: body,
    );
    // Without Delete on the card, the card itself opens the role's editor.
    if (deleteOnRow || fixed) return card;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: ZestTokens.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: ZestTokens.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: busy ? null : onEdit, child: body),
      ),
    );
  }
}

/// A vault on a role's card: its name and hosts, and the role's level there
/// as the table's pill (nothing to press: the card opens the editor), or
/// "Owners only".
class _VaultLevelLine extends StatelessWidget {
  const _VaultLevelLine({required this.roleId, required this.roleName, required this.vault});

  final String roleId;
  final String roleName;
  final _VaultLevel vault;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final crate = vault.crate;
    final switches = vault.switches;
    final level = switches == null ? null : exactLevel(switches);
    final custom = switches != null && level == null;
    final vaultName = crateDisplayName(crate, l10n);
    final word = custom
        ? l10n.crateLevelCustom
        : level == null
            ? l10n.crateLevelNone
            : crateLevelName(level, l10n);
    return Semantics(
      label: vault.ownersOnly
          ? '$vaultName, ${l10n.hostsMetaHostCount(vault.hosts)}: ${l10n.crateOwnersOnly}'
          : '${l10n.rolesLevelIn(roleName, vaultName)}, ${l10n.hostsMetaHostCount(vault.hosts)}: $word',
      excludeSemantics: true,
      child: Row(
        key: ValueKey('role-cell-$roleId-${crate.id}'),
        children: [
          Icon(crate.ownersOnly ? LucideIcons.lock : LucideIcons.package, size: 14, color: ZestTokens.textFaint),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: vaultName, style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
                TextSpan(
                  text: '  ${l10n.hostsMetaHostCount(vault.hosts)}',
                  style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                ),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (vault.ownersOnly)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.lock, size: 13, color: ZestTokens.textFaint),
                const SizedBox(width: 6),
                Text(l10n.crateOwnersOnly, style: TextStyle(fontSize: 12.5, color: ZestTokens.textFaint)),
              ],
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 112),
              child: RoleLevelPill(level: level, custom: custom, width: null),
            ),
        ],
      ),
    );
  }
}

/// Makes or edits a role: its name, what it may do in the Orchard, and a
/// level (with agent forwarding apart) for each Crate it opens. Returns the
/// role as saved, or null when closed.
class RoleEditor extends StatefulWidget {
  const RoleEditor(
      {super.key,
      required this.role,
      required this.crates,
      this.from,
      this.onDelete,
      this.onDuplicate,
      this.onReset,
      this.deleteNote});

  /// Null for a new role.
  final OrchardRoleView? role;

  /// A new role's starting point (Duplicate): its name, vaults and what it
  /// may do filled in; saved as a role of its own.
  final OrchardRoleView? from;

  /// The role's Duplicate, on a phone and a tablet: the editor closes, then a
  /// new one opens filled in from this role.
  final VoidCallback? onDuplicate;

  /// Admin's, once an owner changed it: back to every vault that is not
  /// owners-only and everything in the team. The editor closes, then it
  /// runs.
  final VoidCallback? onReset;

  /// The Crates a role may open: every one that is not owners-only.
  final List<CrateSummary> crates;

  /// The role's Delete, on a phone and a tablet (see [editOrchardRole]): the
  /// editor closes, then it runs.
  final VoidCallback? onDelete;

  /// Why the role cannot be deleted, where it cannot (a phone's and a
  /// tablet's, under the form).
  final String? deleteNote;

  @override
  State<RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends State<RoleEditor> {
  late final _start = widget.role ?? widget.from;
  late final _name = TextEditingController(text: _start?.name ?? '');
  late final Set<String> _can = {...?_start?.can};
  late final Map<String, Set<String>> _crates = {
    for (final e in (_start?.crates ?? const <String, Set<String>>{}).entries) e.key: {...e.value},
  };
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Admin's editor: its name is Admin's, not typed.
  bool get _fixedName => widget.role?.id == FixedRoles.admin;

  void _save() {
    final l10n = AppLocalizations.of(context)!;
    final name = _fixedName ? l10n.orchardRoleAdmin : _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.orchardRoleNameRequired);
      return;
    }
    Navigator.of(context).pop((name: name, can: {..._can}, crates: {..._crates}));
  }

  void _setLevel(CrateSummary crate, CrateLevel? level) => setState(() {
        if (level == null) {
          _crates.remove(crate.id);
          return;
        }
        final agent = _crates[crate.id]?.contains(CrateSwitches.agent) ?? false;
        _crates[crate.id] = {...levelSwitches(level), if (agent) CrateSwitches.agent};
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary);
    final help = TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.v3TextTertiary);
    final role = widget.role;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.shieldCheck,
      title: role == null ? l10n.orchardRoleNew : l10n.orchardRoleEditTitle(role.name ?? l10n.orchardRoleMember),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_fixedName) ...[
            ZestTextField(
              key: const ValueKey('role-name'),
              controller: _name,
              label: l10n.orchardRoleNameLabel,
              hintText: l10n.orchardRoleNameHint,
              errorText: _error,
              maxLength: 50,
              onSubmit: _save,
            ),
            const SizedBox(height: 12),
          ],
          Text(l10n.orchardRoleCanLabel, style: label),
          for (final (what, text) in [
            (RoleCan.invite, l10n.orchardRoleCanInvite),
            (RoleCan.remove, l10n.orchardRoleCanRemove),
            (RoleCan.changeRoles, l10n.orchardRoleCanChangeRoles),
            (RoleCan.createCrates, l10n.orchardRoleCanCreateCrates),
          ])
            CheckboxListTile(
              key: ValueKey('role-can-$what'),
              value: _can.contains(what),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(text, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
              onChanged: (v) => setState(() => v == true ? _can.add(what) : _can.remove(what)),
            ),
          const SizedBox(height: 8),
          Text(l10n.orchardRoleCratesLabel, style: label),
          const SizedBox(height: 4),
          for (final crate in widget.crates) _crateRow(crate, l10n),
          const SizedBox(height: 6),
          Text(l10n.orchardLevelsHelp, style: help),
          Text(l10n.orchardRoleOwnersOnlyNote, style: help),
          // Why this role cannot be deleted (its Delete is here on a phone
          // and a tablet, not on its row).
          if (widget.deleteNote != null) ...[
            const SizedBox(height: 6),
            Text(widget.deleteNote!, key: const ValueKey('role-delete-note'), style: help),
          ],
          if (widget.onReset != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('role-admin-reset'),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onReset!();
                },
                icon: const Icon(LucideIcons.rotateCcw, size: 15),
                label: Text(l10n.rolesAdminReset),
              ),
            ),
          ],
          if (widget.onDuplicate != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('role-duplicate'),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onDuplicate!();
                },
                icon: const Icon(LucideIcons.copy, size: 15),
                label: Text(l10n.orchardRoleDuplicate),
              ),
            ),
          ],
        ],
      ),
      primaryAction: (label: l10n.save, onPressed: _save, icon: LucideIcons.check),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      // The role's Delete, on a phone and a tablet: the editor closes, then
      // where its members go is asked.
      tertiaryAction: widget.onDelete == null
          ? null
          : (
              label: l10n.delete,
              onPressed: () {
                Navigator.of(context).pop();
                widget.onDelete!();
              },
            ),
      tertiaryKey: widget.onDelete == null ? null : const ValueKey('role-delete'),
      tertiaryDanger: true,
    );
  }

  Widget _crateRow(CrateSummary crate, AppLocalizations l10n) {
    final switches = _crates[crate.id];
    final level = switches == null ? null : exactLevel(switches);
    final custom = switches != null && level == null;
    final agentAllowed = crate.allow.contains(CrateSwitches.agent);
    return Row(
      key: ValueKey('role-crate-${crate.id}'),
      children: [
        Expanded(
          child: Text(crateDisplayName(crate, l10n),
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
        ),
        _maybeTooltip(
          agentAllowed ? null : l10n.orchardRoleAgentOff,
          Row(
            children: [
              Checkbox(
                key: ValueKey('role-agent-${crate.id}'),
                value: switches?.contains(CrateSwitches.agent) ?? false,
                onChanged: switches == null || !agentAllowed
                    ? null
                    : (v) => setState(() =>
                        v == true ? switches.add(CrateSwitches.agent) : switches.remove(CrateSwitches.agent)),
              ),
              Text(l10n.orchardRoleAgent, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        // The app's select (it was a Material dropdown, its filled triangle
        // among the app's icons).
        ZestSelect<Object>(
          key: ValueKey('role-level-${crate.id}'),
          value: custom ? 'custom' : (level ?? 'none'),
          width: 140,
          items: [
            ZestSelectItem<Object>('none', l10n.crateLevelNone),
            for (final l in CrateLevel.values) ZestSelectItem<Object>(l, crateLevelName(l, l10n)),
            if (custom) ZestSelectItem<Object>('custom', l10n.crateLevelCustom),
          ],
          onChanged: (v) {
            if (v == 'custom') return;
            _setLevel(crate, v is CrateLevel ? v : null);
          },
        ),
      ],
    );
  }
}

Widget _maybeTooltip(String? message, Widget child) =>
    message == null ? child : Tooltip(message: message, child: child);

/// Asks before [role] is deleted, and where its members go: one of [roles]
/// (the owners' roles) other than it. The role picked, or null.
Future<String?> askDropOrchardRole(BuildContext context, OrchardRoleView role, List<OrchardRoleView> roles) async {
  final l10n = AppLocalizations.of(context)!;
  final others = roles.where((r) => r.id != role.id).toList();
  if (others.isEmpty) return null;
  return showZestModal<String>(
    context: context,
    size: ZestModalSize.standard,
    child: _DropRoleDialog(name: role.name ?? l10n.orchardRoleMember, others: others),
  );
}

class _DropRoleDialog extends StatefulWidget {
  const _DropRoleDialog({required this.name, required this.others});

  final String name;
  final List<OrchardRoleView> others;

  @override
  State<_DropRoleDialog> createState() => _DropRoleDialogState();
}

class _DropRoleDialogState extends State<_DropRoleDialog> {
  late String _moveTo = widget.others.first.id;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.destructive,
      icon: LucideIcons.trash2,
      title: l10n.orchardRoleDeleteTitle(widget.name),
      subtitle: l10n.orchardRoleDeleteBody,
      body: Row(
        children: [
          Text(l10n.orchardRoleDeleteMoveTo, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
          const SizedBox(width: 12),
          Expanded(
            child: ZestSelect<String>(
              key: const ValueKey('role-move-to'),
              value: _moveTo,
              items: [for (final r in widget.others) ZestSelectItem(r.id, r.name ?? l10n.orchardRoleMember)],
              onChanged: (v) => setState(() => _moveTo = v),
            ),
          ),
        ],
      ),
      primaryAction: (
        label: l10n.orchardRoleDeleteConfirm,
        onPressed: () => Navigator.of(context).pop(_moveTo),
        icon: LucideIcons.trash2,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
