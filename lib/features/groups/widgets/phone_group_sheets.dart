import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/features/groups/widgets/group_editor_panel.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/team_write.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart' show connectionGroupsDaoProvider;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/utils/kept_from_sync.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// Groups on a phone and a tablet (3.0.1):
/// a group is made, changed and deleted without a computer. A phone
/// has sheets: New group (a name and a colour), Edit group (full height:
/// name, colour, its hosts, Delete group, Save at the bottom). A tablet has
/// side panes, as a computer: New group in a pane of its own, Edit group in
/// the computer's [GroupEditorPanel] as it is. The same writes as the
/// computer's editor ([GroupCrudNotifier], [ConnectionCrudNotifier]), so
/// nothing new syncs.

/// Whether the group sheets are a phone's (bottom sheets) rather than a
/// tablet's (side panes).
bool groupsOnPhone(BuildContext context) => MediaQuery.sizeOf(context).shortestSide < 600;

/// Whether groups may be made, changed and deleted in the space on screen:
/// always in your Tree; in a team's space, when this account may add to the
/// vault (the rule the computer's New group follows).
bool mayEditGroups(WidgetRef ref, {bool watch = true}) => mayAddScreenSpace(ref, watch: watch);

/// A group New group made: its id and its name.
typedef MadeGroup = ({String id, String name});

/// New group: a name (required, the keyboard on it) and a colour. Creates
/// the group and gives it back; null when cancelled. [forHost] names the
/// host that goes into it (the caller moves it).
Future<MadeGroup?> showNewGroupSheet(BuildContext context, {String? forHost}) {
  if (groupsOnPhone(context)) {
    return showZestSheet<MadeGroup>(context: context, child: _NewGroupForm(forHost: forHost, pane: false));
  }
  return _showSidePane<MadeGroup>(context, _NewGroupForm(forHost: forHost, pane: true));
}

/// Edit group: on a phone the full-height sheet, on a tablet the computer's
/// group editor.
Future<void> showEditGroupSheet(BuildContext context, String groupId) {
  if (!groupsOnPhone(context)) return GroupEditorPanel.showAdaptive(context, groupId: groupId);
  return showZestSheet<void>(context: context, dismissible: false, child: _EditGroupSheet(groupId: groupId));
}

/// Deletes the group [groupId] once asked (its hosts are kept, ungrouped,
/// as on a computer). True when it was deleted.
Future<bool> deleteGroupAsking(BuildContext context, String groupId) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final l10n = AppLocalizations.of(context)!;
  final count = _hostsIn(container.read(connectionsWithDetailsProvider).valueOrNull, groupId).length;
  final ok = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.zestGroupDelete,
    body: l10n.zestGroupDeleteConfirm(count),
    confirmLabel: l10n.zestGroupDelete,
  );
  if (ok != true) return false;
  // delete() clears every member's group (they drop to Ungrouped), then
  // removes the group: hosts are never deleted. A team that does not allow
  // it says so.
  if (!context.mounted) return false;
  return runTeamWrite(context, () => container.read(groupCrudProvider).delete(groupId), where: 'Group sheet: delete');
}

/// What a long press on a group (its chip, its header) offers: Edit group,
/// New group, Delete group. Gives back the id of a group New group made.
Future<String?> openGroupActions(BuildContext context, ConnectionGroup group) async {
  final action = await showZestSheet<_GroupAction>(context: context, child: _GroupActionsSheet(group: group));
  if (action == null || !context.mounted) return null;
  switch (action) {
    case _GroupAction.edit:
      await showEditGroupSheet(context, group.id);
      return null;
    case _GroupAction.create:
      return (await showNewGroupSheet(context))?.id;
    case _GroupAction.delete:
      await deleteGroupAsking(context, group.id);
      return null;
  }
}

/// The Hosts tab's +: New host, or New group.
Future<void> showNewHostOrGroupSheet(
  BuildContext context, {
  required VoidCallback onNewHost,
  ValueChanged<MadeGroup>? onGroupMade,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final picked = await showZestSheet<String>(
    context: context,
    child: ZestSheetFrame(
      child: Builder(
        builder: (sheet) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ActionRow(
                key: const ValueKey('phone-new-menu-host'),
                icon: LucideIcons.server,
                label: l10n.hostsNewMenuHost,
                onTap: () => Navigator.of(sheet).pop('host'),
              ),
              _ActionRow(
                key: const ValueKey('phone-new-menu-group'),
                icon: LucideIcons.folderPlus,
                label: l10n.hostsNewMenuGroup,
                onTap: () => Navigator.of(sheet).pop('group'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  switch (picked) {
    case 'host':
      onNewHost();
    case 'group':
      final made = await showNewGroupSheet(context);
      if (made != null) onGroupMade?.call(made);
  }
}

List<ConnectionWithDetails> _hostsIn(List<ConnectionWithDetails>? hosts, String groupId) =>
    [for (final c in hosts ?? const <ConnectionWithDetails>[]) if (c.connection.groupId == groupId) c];

/// A tablet's pane at the right, sliding in as the computer's group editor.
Future<T?> _showSidePane<T>(BuildContext context, Widget child) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => Align(alignment: Alignment.centerRight, child: child),
    transitionBuilder: (_, anim, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  );
}

// ── New group ─────────────────────────────────────────────────────────────

class _NewGroupForm extends ConsumerStatefulWidget {
  const _NewGroupForm({required this.forHost, required this.pane});

  final String? forHost;

  /// A tablet's side pane (else a phone's sheet).
  final bool pane;

  @override
  ConsumerState<_NewGroupForm> createState() => _NewGroupFormState();
}

class _NewGroupFormState extends ConsumerState<_NewGroupForm> {
  final _name = TextEditingController();
  int? _colorIndex;
  int? _colorValue;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // A colour picked already: the next of the palette, so groups made one
    // after another differ.
    final groups = ref.read(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[];
    _colorIndex = groups.length % AppColors.labelPalette.length;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _name.text.trim().isNotEmpty && !_busy;

  Future<void> _create() async {
    if (!_ready) return;
    setState(() => _busy = true);
    final name = _name.text.trim();
    final groups = ref.read(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[];
    // As the computer's New group: appended at the end of the order.
    final id = await ref.read(groupCrudProvider).create(
          name: name,
          colorIndex: _colorIndex,
          colorValue: _colorValue,
          sortOrder: groups.length,
        );
    if (!mounted) return;
    Navigator.of(context).pop<MadeGroup>((id: id, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final body = Column(
      key: const ValueKey('group-new-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SheetTitle(
          title: l10n.zestGroupNewGroup,
          subtitle: widget.forHost == null ? null : l10n.phoneGroupsGoesInto(Redactable.host(widget.forHost!).displayIn(ref)),
        ),
        const SizedBox(height: 14),
        _NameField(
          controller: _name,
          autofocus: true,
          onChanged: () => setState(() {}),
          onSubmitted: _create,
        ),
        const SizedBox(height: 16),
        _FieldLabel(l10n.zestGroupColor),
        _Swatches(
          colorIndex: _colorIndex,
          colorValue: _colorValue,
          onPick: (i) => setState(() {
            _colorIndex = i;
            _colorValue = null;
          }),
        ),
        const SizedBox(height: 22),
        _SheetButtons(
          primaryKey: const ValueKey('group-new-create'),
          primaryLabel: l10n.create,
          onPrimary: _ready ? _create : null,
          onCancel: () => Navigator.of(context).pop(),
        ),
      ],
    );
    if (!widget.pane) {
      return ZestSheetFrame(
        child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 14), child: body),
      );
    }
    return _PaneFrame(child: body);
  }
}

/// A tablet's side pane: the computer's group editor's frame.
class _PaneFrame extends StatelessWidget {
  const _PaneFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width < 520 ? MediaQuery.sizeOf(context).width : 460.0;
    return Material(
      key: const ValueKey('group-side-pane'),
      color: ZestTokens.surfaceBase,
      child: Container(
        width: width,
        height: double.infinity,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: ZestTokens.border)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 32, offset: const Offset(-8, 0))],
        ),
        child: SafeArea(
          left: false,
          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 20), child: child),
        ),
      ),
    );
  }
}

// ── Edit group (a phone's full-height sheet) ─────────────────────────────

class _EditGroupSheet extends ConsumerStatefulWidget {
  const _EditGroupSheet({required this.groupId});
  final String groupId;

  @override
  ConsumerState<_EditGroupSheet> createState() => _EditGroupSheetState();
}

class _EditGroupSheetState extends ConsumerState<_EditGroupSheet> {
  final _name = TextEditingController();
  ConnectionGroup? _group;
  int? _colorIndex;
  int? _colorValue;
  String _baseName = '';
  int? _baseColorIndex;
  int? _baseColorValue;

  /// The hosts taken out and put in, written at Save.
  final _removed = <String>{};
  final _added = <String>{};
  bool _busy = false;
  bool _closing = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _fieldsDirty =>
      _name.text.trim() != _baseName.trim() || _colorIndex != _baseColorIndex || _colorValue != _baseColorValue;
  bool get _dirty => _fieldsDirty || _removed.isNotEmpty || _added.isNotEmpty;
  bool get _canSave => _dirty && _name.text.trim().isNotEmpty && !_busy;

  void _seed(ConnectionGroup g) {
    _group = g;
    _name.text = g.name;
    _colorIndex = g.colorIndex;
    _colorValue = g.colorValue;
    _baseName = g.name;
    _baseColorIndex = g.colorIndex;
    _baseColorValue = g.colorValue;
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _busy = true);
    final id = widget.groupId;
    // A change the team does not allow is said, and the sheet stays to be
    // changed or left (Save went dead, with nothing said).
    final saved = await runTeamWrite(context, () async {
      if (_fieldsDirty) {
        // A field the person did not touch keeps what a sync wrote while the
        // sheet was open.
        final now = await ref.read(connectionGroupsDaoProvider).getById(id);
        final keep = keptSince<ConnectionGroup>(_group, now, (g) => g.updatedAt);
        await ref.read(groupCrudProvider).updateFolder(
              id: id,
              name: keep(_name.text.trim(), (g) => g.name),
              colorIndex: keep(_colorIndex, (g) => g.colorIndex),
              colorValue: keep(_colorValue, (g) => g.colorValue),
              iconCodePoint: now?.iconCodePoint ?? _group?.iconCodePoint,
            );
      }
      final hosts = ref.read(connectionCrudProvider);
      for (final c in _removed) {
        await hosts.update(id: c, clearGroupId: true);
      }
      for (final c in _added) {
        await hosts.update(id: c, groupId: id);
      }
    }, where: 'Group sheet: save');
    if (!mounted) return;
    if (!saved) {
      setState(() => _busy = false);
      return;
    }
    Navigator.of(context).pop();
  }

  /// A back gesture with changes: asked first, as the computer's editor.
  Future<void> _askDiscard() async {
    final l10n = AppLocalizations.of(context)!;
    final typed = _name.text.trim();
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.zestGroupDiscardTitle,
      body: l10n.zestGroupDiscardBody(typed.isEmpty ? l10n.zestGroupNewGroup : Redactable.group(typed).display),
      confirmLabel: l10n.zestCommonDiscard,
    );
    if (ok == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    if (await deleteGroupAsking(context, widget.groupId) && mounted) {
      _closing = true;
      Navigator.of(context).pop();
    }
  }

  Future<void> _addHosts(List<ConnectionWithDetails> candidates) async {
    final picked = await showZestSheet<Set<String>>(context: context, child: _HostPicker(hosts: candidates));
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() {
      for (final id in picked) {
        if (!_removed.remove(id)) _added.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = ref.watch(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[];
    final conns = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final group = groups.where((g) => g.id == widget.groupId).firstOrNull;
    if (group != null && _group == null) _seed(group);
    if (group == null) {
      // Deleted (here or on another device): nothing left to edit.
      if (_group != null && !_closing) {
        _closing = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
      return const ZestSheetFrame(child: SizedBox(height: 120));
    }

    final members = [
      for (final c in conns)
        if ((c.connection.groupId == widget.groupId && !_removed.contains(c.connection.id)) ||
            _added.contains(c.connection.id))
          c,
    ];
    final memberIds = {for (final m in members) m.connection.id};
    final candidates = [
      for (final c in conns)
        if (!memberIds.contains(c.connection.id) && mayChangeItem(ref, 'host', c.connection.id)) c,
    ];

    return PopScope<void>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _askDiscard();
      },
      child: ZestSheetFrame(
        child: Column(
          key: const ValueKey('group-edit-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                children: [
                  _SheetTitle(title: l10n.hostsGroupEdit, subtitle: l10n.phoneGroupsEditNote),
                  const SizedBox(height: 14),
                  _NameField(controller: _name, onChanged: () => setState(() {}), onSubmitted: _save),
                  const SizedBox(height: 16),
                  _FieldLabel(l10n.zestGroupColor),
                  _Swatches(
                    colorIndex: _colorIndex,
                    colorValue: _colorValue,
                    onPick: (i) => setState(() {
                      _colorIndex = i;
                      _colorValue = null;
                    }),
                  ),
                  const SizedBox(height: 22),
                  ZestSectionHeader(label: l10n.phoneGroupsHostsIn, count: members.length),
                  const SizedBox(height: 8),
                  _Card(
                    children: [
                      if (members.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                          child: Text(l10n.phoneGroupsEmpty,
                              style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
                        ),
                      for (final m in members)
                        _MemberRow(
                          key: ValueKey('group-edit-member-${m.connection.id}'),
                          host: m,
                          onRemove: mayChangeItem(ref, 'host', m.connection.id)
                              ? () => setState(() {
                                    if (!_added.remove(m.connection.id)) _removed.add(m.connection.id);
                                  })
                              : null,
                        ),
                      InkWell(
                        key: const ValueKey('group-edit-add-hosts'),
                        onTap: () => _addHosts(candidates),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                Icon(LucideIcons.plus, size: 17, color: ZestTokens.brandInk),
                                const SizedBox(width: 10),
                                Text(l10n.phoneGroupsAddHosts,
                                    style: TextStyle(
                                        fontSize: 14.5, fontWeight: FontWeight.w600, color: ZestTokens.brandInk)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  // Delete group: inside the sheet, never on a row; it asks.
                  InkWell(
                    key: const ValueKey('group-edit-delete'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: _delete,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 46),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Row(
                          children: [
                            Icon(LucideIcons.trash2, size: 17, color: ZestTokens.statusCritical),
                            const SizedBox(width: 10),
                            Text(l10n.zestGroupDelete,
                                style: TextStyle(
                                    fontSize: 14.5, fontWeight: FontWeight.w600, color: ZestTokens.statusCritical)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(l10n.phoneGroupsDeleteKeeps,
                        style: TextStyle(fontSize: 12, height: 1.35, color: ZestTokens.textTertiary)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: _SheetButtons(
                primaryKey: const ValueKey('group-edit-save'),
                primaryLabel: l10n.save,
                onPrimary: _canSave ? _save : null,
                onCancel: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A host in Edit group: its name and address, and a remove control.
class _MemberRow extends ConsumerWidget {
  const _MemberRow({super.key, required this.host, required this.onRemove});

  final ConnectionWithDetails host;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = host.connection;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: HostRow(
              host: c,
              user: host.identity?.username,
              group: host.group,
              under: true,
              iconSize: 28,
              nameStyle: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
              padding: EdgeInsets.zero,
              margin: EdgeInsets.zero,
              hovers: false,
            ),
          ),
          if (onRemove != null)
            IconButton(
              key: ValueKey('group-edit-remove-${c.id}'),
              icon: Icon(LucideIcons.minusCircle, size: 19, color: ZestTokens.textTertiary),
              tooltip: AppLocalizations.of(context)!.zestGroupRemoveHost,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// Add hosts: the hosts not in the group, ticked to be added.
class _HostPicker extends ConsumerStatefulWidget {
  const _HostPicker({required this.hosts});
  final List<ConnectionWithDetails> hosts;

  @override
  ConsumerState<_HostPicker> createState() => _HostPickerState();
}

class _HostPickerState extends ConsumerState<_HostPicker> {
  final _picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestSheetFrame(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
        child: Column(
          key: const ValueKey('group-host-picker'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetTitle(title: l10n.phoneGroupsAddHosts),
            const SizedBox(height: 8),
            if (widget.hosts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(l10n.phoneGroupsNoHostsToAdd,
                    style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final h in widget.hosts)
                      CheckboxListTile(
                        key: ValueKey('group-pick-${h.connection.id}'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        value: _picked.contains(h.connection.id),
                        activeColor: ZestTokens.brand,
                        onChanged: (on) => setState(() {
                          if (on == true) {
                            _picked.add(h.connection.id);
                          } else {
                            _picked.remove(h.connection.id);
                          }
                        }),
                        secondary: HostGlyph(host: h.connection, group: h.group, size: 28),
                        title: RedactedText(
                          Redactable.host(h.connection.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
                        ),
                        subtitle: Text(
                          Redactable.address(hostWithPort(h.connection.host, h.connection.port)).displayIn(ref),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textTertiary),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            _SheetButtons(
              primaryKey: const ValueKey('group-pick-add'),
              primaryLabel: l10n.commonAdd,
              onPrimary: _picked.isEmpty ? null : () => Navigator.of(context).pop(Set<String>.of(_picked)),
              onCancel: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── A group's long press ──────────────────────────────────────────────────

enum _GroupAction { edit, create, delete }

class _GroupActionsSheet extends ConsumerWidget {
  const _GroupActionsSheet({required this.group});
  final ConnectionGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final count = _hostsIn(ref.watch(connectionsWithDetailsProvider).valueOrNull, group.id).length;
    void pick(_GroupAction a) => Navigator.of(context).pop(a);
    return ZestSheetFrame(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          key: const ValueKey('group-actions-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RedactedText(
                    Redactable.group(group.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: ZestTokens.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(l10n.hostsSelDragCount(count), style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary)),
                ],
              ),
            ),
            _ActionRow(
              key: const ValueKey('group-action-edit'),
              icon: LucideIcons.pencil,
              label: l10n.hostsGroupEdit,
              onTap: () => pick(_GroupAction.edit),
            ),
            _ActionRow(
              key: const ValueKey('group-action-new'),
              icon: LucideIcons.folderPlus,
              label: l10n.zestGroupNewGroup,
              onTap: () => pick(_GroupAction.create),
            ),
            _ActionRow(
              key: const ValueKey('group-action-delete'),
              icon: LucideIcons.trash2,
              label: l10n.phoneGroupsDeleteMore,
              destructive: true,
              onTap: () => pick(_GroupAction.delete),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: ZestTokens.textPrimary)),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(subtitle!, style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textTertiary)),
        ],
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: ZestTokens.textSecondary)),
      );
}

/// The group's name. A group's name is an identifier: in recording mode the
/// field shows it masked behind the reveal gate, as the computer's editor.
class _NameField extends ConsumerWidget {
  const _NameField({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final VoidCallback onChanged;
  final VoidCallback onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final radius = BorderRadius.circular(11);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _FieldLabel(l10n.hostsHomeGroupNameLabel),
        if (ref.watch(recordingModeProvider))
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceRaised,
              borderRadius: radius,
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: RecordingMaskedValue(controller: controller, mask: (raw) => Redactable.group(raw).display),
          )
        else
          TextField(
            key: const ValueKey('group-name-field'),
            controller: controller,
            autofocus: autofocus,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onChanged: (_) => onChanged(),
            onSubmitted: (_) => onSubmitted(),
            style: TextStyle(fontSize: 15, color: ZestTokens.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: ZestTokens.surfaceRaised,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: ZestTokens.borderSubtle)),
              focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: ZestTokens.brand, width: 1.4)),
            ),
          ),
      ],
    );
  }
}

/// The group colours (the computer's palette), as swatches. A custom colour
/// the group has from a computer shows first, picked.
class _Swatches extends StatelessWidget {
  const _Swatches({required this.colorIndex, required this.colorValue, required this.onPick});

  final int? colorIndex;
  final int? colorValue;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    const palette = AppColors.labelPalette;
    final value = colorValue;
    final paletteAt = value == null ? -1 : palette.indexWhere((c) => c.toARGB32() == value);
    final custom = value != null && paletteAt < 0 ? Color(value) : null;
    final picked = value != null ? paletteAt : colorIndex;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (custom != null) _Swatch(key: const ValueKey('group-swatch-custom'), color: custom, selected: true),
        for (var i = 0; i < palette.length; i++)
          _Swatch(
            key: ValueKey('group-swatch-$i'),
            color: palette[i],
            selected: custom == null && picked == i,
            onTap: () => onPick(i),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({super.key, required this.color, required this.selected, this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Container(
              width: 34,
              height: 34,
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: selected ? ZestTokens.textPrimary : Colors.transparent, width: 2),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZestTokens.borderSubtle, width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 0.6, thickness: 0.6, color: ZestTokens.borderSubtle),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Cancel and the sheet's own action, across the width.
class _SheetButtons extends StatelessWidget {
  const _SheetButtons({
    required this.primaryKey,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onCancel,
  });

  final Key primaryKey;
  final String primaryLabel;
  final VoidCallback? onPrimary;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(child: _Button(label: l10n.cancel, onTap: onCancel)),
        const SizedBox(width: 10),
        Expanded(child: _Button(key: primaryKey, label: primaryLabel, onTap: onPrimary, filled: true)),
      ],
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({super.key, required this.label, required this.onTap, this.filled = false});

  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: filled ? BorderSide.none : BorderSide(color: ZestTokens.borderSubtle),
    );
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Material(
        color: filled ? ZestTokens.brand : ZestTokens.surfaceRaised,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: SizedBox(
            height: 46,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: filled ? ZestTokens.onBrand : ZestTokens.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({super.key, required this.icon, required this.label, required this.onTap, this.destructive = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? ZestTokens.statusCritical : ZestTokens.textPrimary;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 50),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: destructive ? fg : ZestTokens.textTertiary),
              const SizedBox(width: 14),
              Expanded(child: Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: fg))),
            ],
          ),
        ),
      ),
    );
  }
}
