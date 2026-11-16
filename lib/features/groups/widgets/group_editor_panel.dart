import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/database/daos/connections_dao.dart'
    show ConnectionWithDetails;
import 'package:zestssh/features/hosts/data/folder_icon_catalog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/host_icon_names.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/orchards/team_write.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/kept_from_sync.dart';
import 'package:zestssh/providers/core_providers.dart' show connectionGroupsDaoProvider;

/// The user's choice from the unsaved-changes prompt.
enum _DiscardChoice { save, discard, cancel }

/// §6 - the two-tab **Group editor** side panel.
///
/// A right-aligned slide-in sheet (NOT a shell-mounted dock) that is the single
/// entry point for editing a connection group. Tab ONE edits the selected group
/// (name, accent colour, membership, delete); Tab TWO reorders all groups and
/// hops between them. Colour inheritance (a host with no explicit colour label
/// inherits its group's accent) finally has a UI here - picking a group colour
/// flows through every host that inherits it.
///
/// Entry-point contract used by the Hosts surfaces:
/// `GroupEditorPanel.showAdaptive(context, groupId: id)` edits an existing
/// group; a null `groupId` opens the New-group flow.
class GroupEditorPanel extends ConsumerStatefulWidget {
  const GroupEditorPanel._({this.groupId});

  /// The group to open on Tab One. Null opens the New-group flow.
  final String? groupId;

  /// Open the group editor as a right-aligned slide-in sheet.
  ///
  /// [groupId] null starts the New-group flow (Tab One with empty fields).
  static Future<void> showAdaptive(
    BuildContext context, {
    String? groupId,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: gl10n.groupEditorBarrierLabel,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => Align(
        alignment: Alignment.centerRight,
        child: GroupEditorPanel._(groupId: groupId),
      ),
      transitionBuilder: (_, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  @override
  ConsumerState<GroupEditorPanel> createState() => _GroupEditorPanelState();
}

class _GroupEditorPanelState extends ConsumerState<GroupEditorPanel> {
  // ── One window: the groups on top, the group being edited below ───
  final _scroll = ScrollController();

  /// Where the group being made or changed starts, to scroll it into view.
  final _editorKey = GlobalKey();

  /// The name field of the group being made or changed.
  final _nameFocus = FocusNode();

  /// The new group's section lit for a moment: New group pressed while it
  /// is already open did nothing that showed (it looked
  /// broken).
  bool _flash = false;

  /// The cursor into the name, and the section lit for a moment.
  void _focusNewGroup() {
    setState(() => _flash = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  /// Brings the group being made or changed into view.
  void _showEditor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final at = _editorKey.currentContext;
      if (at == null) {
        // Below a long list of groups the editor is not built yet (the body
        // builds what is near the view): go to the end, where it is, and
        // bring its top into view from there.
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final built = _editorKey.currentContext;
          if (built != null && mounted) Scrollable.ensureVisible(built);
        });
        return;
      }
      Scrollable.ensureVisible(at,
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic);
    });
  }

  // ── Tab One working state (the group being edited) ────────────────
  final TextEditingController _nameController = TextEditingController();
  String? _currentGroupId; // null = New-group flow
  int? _colorIndex;
  int? _colorValue;
  int? _iconCodePoint;

  // Baseline for the Tab One dirty check.
  String _baseName = '';

  /// The group as the editor read it, for Save to keep what a sync changed
  /// meanwhile in the fields the person did not touch.
  ConnectionGroup? _loadedGroup;
  int? _baseColorIndex;
  int? _baseColorValue;
  int? _baseIconCodePoint;

  /// Whether Tab One has been seeded from the initial [GroupEditorPanel.groupId]
  /// (deferred until the groups stream first delivers data).
  bool _seeded = false;

  // ── Tab Two working state (the reorder) ───────────────────────────
  List<String> _order = <String>[];
  List<String> _baseOrder = <String>[];
  bool _orderInitialized = false;

  // Latest snapshots pulled in build() so the async handlers can read them.
  List<ConnectionGroup> _groups = const [];
  List<ConnectionWithDetails> _conns = const [];

  @override
  void initState() {
    super.initState();
    _currentGroupId = widget.groupId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── Dirty tracking ────────────────────────────────────────────────
  bool get _isNew => _currentGroupId == null;
  bool get _nameEmpty => _nameController.text.trim().isEmpty;

  bool get _groupDirty {
    if (_nameController.text.trim() != _baseName.trim()) return true;
    if (_colorIndex != _baseColorIndex) return true;
    if (_colorValue != _baseColorValue) return true;
    if (_iconCodePoint != _baseIconCodePoint) return true;
    return false;
  }

  bool get _orderDirty => !_listEquals(_order, _baseOrder);
  bool get _anyDirty => _groupDirty || _orderDirty;

  /// Save is armed when there is something to save AND, if the group fields are
  /// what changed, the name is non-empty (never persist a nameless group).
  bool get _canSave => _anyDirty && !(_groupDirty && _nameEmpty);

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── Loading / seeding ─────────────────────────────────────────────
  ConnectionGroup? _groupById(String? id) {
    if (id == null) return null;
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Seed the Tab One fields + baseline from [g] (null = New-group defaults).
  void _loadGroup(ConnectionGroup? g) {
    _loadedGroup = g;
    _currentGroupId = g?.id;
    _nameController.text = g?.name ?? '';
    _colorIndex = g?.colorIndex;
    _colorValue = g?.colorValue;
    _iconCodePoint = g?.iconCodePoint;
    _baseName = _nameController.text;
    _baseColorIndex = _colorIndex;
    _baseColorValue = _colorValue;
    _baseIconCodePoint = _iconCodePoint;
  }

  /// Keep [_order] in step with the live group set without clobbering a pending
  /// reorder: drop deleted ids, append ids created elsewhere.
  void _reconcileOrder(List<ConnectionGroup> groups) {
    final liveIds = groups.map((g) => g.id).toList();
    if (!_orderInitialized) {
      _order = List<String>.of(liveIds);
      _baseOrder = List<String>.of(liveIds);
      _orderInitialized = true;
      return;
    }
    _order.removeWhere((id) => !liveIds.contains(id));
    _baseOrder.removeWhere((id) => !liveIds.contains(id));
    for (final id in liveIds) {
      if (!_order.contains(id)) {
        _order.add(id);
        _baseOrder.add(id);
      }
    }
  }

  int _memberCount(String? groupId) {
    if (groupId == null) return 0;
    var n = 0;
    for (final c in _conns) {
      if (c.connection.groupId == groupId) n++;
    }
    return n;
  }

  List<ConnectionWithDetails> _members(String? groupId) {
    if (groupId == null) return const [];
    return _conns
        .where((c) => c.connection.groupId == groupId)
        .toList(growable: false);
  }

  /// The concrete accent the current Tab One state resolves to.
  Color _resolvedGroupColor() => resolveGroupColor(
        colorValue: _colorValue,
        colorIndex: _colorIndex,
        name: _nameController.text,
      );

  // ── Commit ────────────────────────────────────────────────────────
  /// Persist any pending changes. When [close] is true the panel pops after.
  Future<void> _save({bool close = true}) async {
    if (!_canSave) return;
    // In a team, a change the role does not allow is refused by the team's
    // database: said, and the panel stays open with the change in it.
    //
    if (!await runTeamWrite(context, () => _write(), where: 'Group editor: save')) return;

    if (!mounted) return;
    if (close) {
      Navigator.of(context).pop();
    } else {
      setState(() {});
    }
  }

  /// What [_save] writes.
  Future<void> _write() async {
    final crud = ref.read(groupCrudProvider);

    if (_orderDirty) {
      await crud.reorderGroups(_order);
      _baseOrder = List<String>.of(_order);
    }

    if (_groupDirty && !_nameEmpty) {
      final name = _nameController.text.trim();
      if (_isNew) {
        // Append the new group at the end of the ordering.
        final newId = await crud.create(
          name: name,
          colorIndex: _colorIndex,
          colorValue: _colorValue,
          iconCodePoint: _iconCodePoint,
          sortOrder: _order.length,
        );
        _currentGroupId = newId;
      } else {
        // A field the person did not touch keeps what a sync wrote while the
        // editor was open.
        final now = await ref.read(connectionGroupsDaoProvider).getById(_currentGroupId!);
        final keep = keptSince<ConnectionGroup>(
            _loadedGroup?.id == _currentGroupId ? _loadedGroup : null, now, (g) => g.updatedAt);
        await crud.updateFolder(
          id: _currentGroupId!,
          name: keep(name, (g) => g.name),
          colorIndex: keep(_colorIndex, (g) => g.colorIndex),
          colorValue: keep(_colorValue, (g) => g.colorValue),
          iconCodePoint: keep(_iconCodePoint, (g) => g.iconCodePoint),
        );
      }
      _baseName = name;
      _baseColorIndex = _colorIndex;
      _baseColorValue = _colorValue;
      _baseIconCodePoint = _iconCodePoint;
    }
  }

  // ── Close / discard ───────────────────────────────────────────────
  Future<void> _attemptClose() async {
    if (!_anyDirty) {
      Navigator.of(context).pop();
      return;
    }
    final choice = await _promptDiscard();
    if (!mounted || choice == null) return;
    switch (choice) {
      case _DiscardChoice.save:
        await _save();
      case _DiscardChoice.discard:
        if (mounted) Navigator.of(context).pop();
      case _DiscardChoice.cancel:
        break;
    }
  }

  /// Load [id] into Tab One (null = New-group flow), prompting first when the
  /// current group has unsaved field edits.
  Future<void> _attemptLoadGroup(String? id) async {
    if (id == _currentGroupId) {
      _showEditor();
      if (id == null) _focusNewGroup();
      return;
    }
    if (_groupDirty) {
      final choice = await _promptDiscard();
      if (!mounted || choice == null) return;
      switch (choice) {
        case _DiscardChoice.save:
          await _save(close: false);
        case _DiscardChoice.discard:
          break; // proceed, dropping the field edits
        case _DiscardChoice.cancel:
          return; // stay on the current group
      }
    }
    setState(() => _loadGroup(_groupById(id)));
    _showEditor();
    if (id == null) _focusNewGroup();
  }

  Future<_DiscardChoice?> _promptDiscard() {
    final l10n = AppLocalizations.of(context)!;
    final typed = _nameController.text.trim();
    // Painted in the prompt: masked by the group rule in recording mode.
    final name = typed.isEmpty
        ? l10n.zestGroupNewGroup
        : Redactable.group(typed).display;
    return showZestModal<_DiscardChoice>(
      context: context,
      size: ZestModalSize.compact,
      child: _DiscardDialog(
        title: l10n.zestGroupDiscardTitle,
        body: l10n.zestGroupDiscardBody(name),
      ),
    );
  }

  Future<void> _deleteCurrentGroup() async {
    final l10n = AppLocalizations.of(context)!;
    final id = _currentGroupId;
    if (id == null) return;
    final count = _memberCount(id);
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.zestGroupDelete,
      body: l10n.zestGroupDeleteConfirm(count),
      confirmLabel: l10n.zestGroupDelete,
    );
    if (ok != true || !mounted) return;
    // delete() clears every member's groupId (hosts drop to Ungrouped) then
    // removes the group - hosts are never deleted.
    if (!await runTeamWrite(context, () => ref.read(groupCrudProvider).delete(id), where: 'Group editor: delete')) {
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _removeHost(String connectionId) async {
    // Immediate, direct manipulation (like dragging a host out): clear its
    // groupId so it drops to Ungrouped. The Hosts list is live, so it updates.
    await runTeamWrite(context, () => ref.read(connectionCrudProvider).update(id: connectionId, clearGroupId: true),
        where: 'Group editor: remove a host');
  }

  Future<void> _pickIcon() async {
    final picked = await showZestModal<_IconPick>(
      context: context,
      size: ZestModalSize.compact,
      child: _IconPickerDialog(
        selected: _iconCodePoint,
        accent: _resolvedGroupColor(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _iconCodePoint = picked.codePoint);
  }

  // ── Build ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final width = media.width < 520.0 ? media.width : 460.0;

    final groupsAsync = ref.watch(connectionGroupsProvider);
    _groups = groupsAsync.valueOrNull ?? const [];
    _conns = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];

    // Absorb the live group set once it arrives (seed + keep order in step).
    if (groupsAsync.hasValue) {
      _reconcileOrder(_groups);
      if (!_seeded) {
        _loadGroup(_groupById(_currentGroupId));
        _seeded = true;
        // Opened to make one: straight to its name and colour, every group
        // still in view above.
        if (_isNew) _showEditor();
      }
    }

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _attemptClose();
      },
      child: SafeArea(
        left: false,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: width,
            height: double.infinity,
            decoration: BoxDecoration(
              color: ZestTokens.surfaceBase,
              border: Border(
                left: BorderSide(color: ZestTokens.border, width: 1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 32,
                  offset: const Offset(-8, 0),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTopBar(),
                // One scrollable for the whole body, the groups' list a sliver
                // of it: a group dragged to the visible edge scrolls it on.
                // (A shrink-wrapped list that could not scroll, inside a
                // scroll view, stopped a drag at the edge.)
                Expanded(
                  child: CustomScrollView(
                    controller: _scroll,
                    slivers: [
                      ..._buildAllGroupsTab(),
                      SliverToBoxAdapter(
                        child: KeyedSubtree(
                          key: _editorKey,
                          child: AnimatedContainer(
                            key: const ValueKey('group-editor-section'),
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 250),
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: _flash ? ZestTokens.brandSubtle : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: _buildGroupTab(),
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Top bar: segmented tabs + dirty dot + close ───────────────────
  Widget _buildTopBar() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ZestTokens.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              l10n.hostsSectionGroups,
              style: TextStyle(color: ZestTokens.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          if (_anyDirty)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: ZestTokens.brand,
                shape: BoxShape.circle,
              ),
            ),
          _IconTapButton(
            icon: LucideIcons.x,
            tooltip: l10n.cancel,
            onTap: _attemptClose,
          ),
        ],
      ),
    );
  }

  // ── Tab One: the selected group ───────────────────────────────────
  Widget _buildGroupTab() {
    final l10n = AppLocalizations.of(context)!;
    final accent = _resolvedGroupColor();
    final members = _members(_currentGroupId);
    final total = members.length;
    final overridden = members
        .where((c) => AppColors.hasExplicitConnectionLabel(
              c.connection.colorValue,
              c.connection.colorIndex,
            ))
        .length;
    final using = total - overridden;
    final noneSelected = _colorIndex == null && _colorValue == null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The section's header says what this is; under it the folder's
        // icon (a click picks another) beside the name. (A big tile and the
        // title "New group" stood under a header that said the same.)
        ZestSectionHeader(label: _isNew ? l10n.zestGroupNewGroup : l10n.hostsGroupEdit),
        const SizedBox(height: 4),
        Row(
          children: [
            _GroupIconTile(
              icon: folderIconFor(_iconCodePoint),
              onTap: _pickIcon,
            ),
            const SizedBox(width: 10),
            // Name. Editor rule: a group name is an identifier, so while
            // recording mode is on the field shows the masked value,
            // read-only behind the reveal gate; the controller keeps the
            // real text.
            Expanded(
              child: ref.watch(recordingModeProvider)
                  ? ZestField.custom(
                      label: l10n.zestGroupName,
                      child: RecordingMaskedValue(
                        controller: _nameController,
                        mask: (raw) => Redactable.group(raw).display,
                      ),
                    )
                  : ZestField(
                      label: l10n.zestGroupName,
                      controller: _nameController,
                      focusNode: _nameFocus,
                      onChanged: (_) => setState(() {}),
                      onSubmit: _canSave ? () => _save() : null,
                    ),
            ),
          ],
        ),
        const SizedBox(height: 22),

        // Colour
        ZestSectionHeader(label: l10n.zestGroupColor),
        ZestColorPicker(
          presets: AppColors.labelPalette,
          allowNone: true,
          allowCustom: true,
          noneSelected: noneSelected,
          selected: accent,
          onNoneSelected: () => setState(() {
            _colorIndex = null;
            _colorValue = null;
          }),
          onChanged: (c) => setState(() {
            final i = AppColors.labelPalette.indexOf(c);
            if (i >= 0) {
              _colorIndex = i;
              _colorValue = null;
            } else {
              _colorValue = c.toARGB32();
              _colorIndex = null;
            }
          }),
        ),
        if (total > 0) ...[
          const SizedBox(height: 10),
          Text(
            l10n.zestGroupInheritCount(using, total, overridden),
            style: TextStyle(
              color: ZestTokens.textTertiary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
        const SizedBox(height: 22),

        // Hosts (a group being made has none yet: no empty section).
        if (!_isNew) ...[
          ZestSectionHeader(label: l10n.zestGroupHosts, count: total),
          const SizedBox(height: 10),
        ],
        for (final m in members)
          _MemberRow(
            // Painted only; removal keys on the connection id.
            host: m.connection,
            name: Redactable.host(m.connection.label).displayIn(ref),
            color: AppColors.resolveConnectionLabelColorOrNull(
                  connColorValue: m.connection.colorValue,
                  connColorIndex: m.connection.colorIndex,
                  inheritedGroupColor: accent,
                ) ??
                accent,
            removeTooltip: l10n.zestGroupRemoveHost,
            onRemove: () => _removeHost(m.connection.id),
          ),

        // Delete group - red text action at the bottom of the body.
        if (!_isNew) ...[
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: _DangerTextAction(
              icon: LucideIcons.trash2,
              label: l10n.zestGroupDelete,
              onTap: _deleteCurrentGroup,
            ),
          ),
        ],
      ],
      ),
    );
  }

  // ── Tab Two: all groups (reorder + hop) ───────────────────────────
  /// The slivers of every group: the hint, the groups in order (dragged by
  /// their handle), New group and Ungrouped.
  List<Widget> _buildAllGroupsTab() {
    final l10n = AppLocalizations.of(context)!;
    final ungrouped =
        _conns.where((c) => c.connection.groupId == null).length;

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Text(
            l10n.zestGroupReorderHint,
            style: TextStyle(
              color: ZestTokens.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        sliver: SliverReorderableList(
          itemCount: _order.length,
          itemBuilder: (context, i) => _buildReorderRow(i, l10n),
          // The row being dragged, lifted, on a Material of its own (it is
          // drawn in the overlay, away from the panel's).
          proxyDecorator: (child, index, animation) => AnimatedBuilder(
            animation: animation,
            builder: (context, child) => Material(
              type: MaterialType.transparency,
              elevation: 6 * Curves.easeInOut.transform(animation.value),
              shadowColor: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
              child: child,
            ),
            child: child,
          ),
          onReorderItem: (oldIndex, newIndex) {
            setState(() {
              final id = _order.removeAt(oldIndex);
              _order.insert(newIndex, id);
            });
          },
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              _NewGroupRow(
                key: const ValueKey('group-new-row'),
                label: l10n.zestGroupNewGroup,
                onTap: () => _attemptLoadGroup(null),
              ),
              const SizedBox(height: 14),
              // Ungrouped - pinned below, dimmed, not editable.
              Divider(height: 1, color: ZestTokens.border),
              const SizedBox(height: 10),
              _UngroupedRow(
                label: l10n.zestGroupUngrouped,
                note: l10n.zestGroupUngroupedNote,
                count: ungrouped,
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildReorderRow(int index, AppLocalizations l10n) {
    final id = _order[index];
    final g = _groupById(id);
    if (g == null) {
      // Should not happen (reconciled), but keep the list total stable.
      return SizedBox.shrink(key: ValueKey('missing-$id'));
    }
    final color = resolveGroupColor(
      colorValue: g.colorValue,
      colorIndex: g.colorIndex,
      name: g.name,
    );
    return _ReorderRow(
      key: ValueKey(id),
      index: index,
      position: index + 1,
      color: color,
      // Painted only; the colour above hashes the real name.
      name: Redactable.group(g.name).displayIn(ref),
      hostCount: _memberCount(id),
      selected: id == _currentGroupId,
      onTap: () => _attemptLoadGroup(id),
    );
  }

  // ── Footer: Cancel + Save ─────────────────────────────────────────
  Widget _buildFooter() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: ZestTokens.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Cancel always closes, asking first when something changed
          // (it was off until something did).
          ZestButton(
            key: const ValueKey('group-editor-cancel'),
            label: l10n.cancel,
            size: ZestButtonSize.large,
            variant: ZestButtonVariant.secondary,
            onPressed: _attemptClose,
          ),
          const SizedBox(width: ZestSizing.buttonGap),
          ZestButton(
            label: l10n.save,
            size: ZestButtonSize.large,
            variant: ZestButtonVariant.primary,
            onPressed: _canSave ? () => _save() : null,
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Tab One pieces
// ════════════════════════════════════════════════════════════════════

/// The group's folder icon beside its name, in a neutral tile as tall as
/// the field. Tapping it opens the icon picker.
class _GroupIconTile extends StatelessWidget {
  const _GroupIconTile({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(message: AppLocalizations.of(context)!.hostIconPickerTitle, child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: ZestTokens.surfaceChip,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.border),
        ),
        child: Icon(icon, color: ZestTokens.textSecondary, size: 18),
      ),
    ));
  }
}

/// A member-host row in the Hosts section: resolved-colour rail + name + a
/// remove control that drops the host to Ungrouped.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.host,
    required this.name,
    required this.color,
    required this.removeTooltip,
    required this.onRemove,
  });

  final Connection host;
  final String name;
  final Color color;
  final String removeTooltip;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      height: 40,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          HostGlyph(host: host, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ZestTokens.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
          _IconTapButton(
            icon: LucideIcons.x,
            tooltip: removeTooltip,
            size: 15,
            onTap: onRemove,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// Red text button (icon + label) for the bottom-of-body Delete action.
class _DangerTextAction extends StatelessWidget {
  const _DangerTextAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: ZestTokens.statusCritical),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: ZestTokens.statusCritical,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Tab Two pieces
// ════════════════════════════════════════════════════════════════════

/// A reorderable group row: drag handle + position + colour dot + name + count.
/// The handle drags; tapping the rest loads the group into Tab One.
class _ReorderRow extends StatefulWidget {
  const _ReorderRow({
    super.key,
    required this.index,
    required this.position,
    required this.color,
    required this.name,
    required this.hostCount,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final int position;
  final Color color;
  final String name;
  final int hostCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ReorderRow> createState() => _ReorderRowState();
}

class _ReorderRowState extends State<_ReorderRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: widget.selected
                ? ZestTokens.brandSubtle
                : (_hover ? ZestTokens.surfaceHover : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected ? ZestTokens.brandBorder : ZestTokens.border,
            ),
          ),
          child: Row(
            children: [
              // Drag handle - the ONLY drag affordance (row tap loads instead).
              ReorderableDragStartListener(
                index: widget.index,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(
                      LucideIcons.gripVertical,
                      size: 16,
                      color: ZestTokens.textTertiary,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 20,
                child: Text(
                  '${widget.position}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ZestTokens.textTertiary,
                    fontSize: 12,
                    fontFamily: 'JetBrainsMono',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: widget.onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ZestTokens.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.hostCount}',
                style: TextStyle(
                  color: ZestTokens.textTertiary,
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
              const SizedBox(width: 14),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "+ New group" row at the bottom of the reorderable list.
class _NewGroupRow extends StatelessWidget {
  const _NewGroupRow({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: ZestTokens.border,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(LucideIcons.plus, size: 16, color: ZestTokens.textSecondary),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: ZestTokens.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pinned, dimmed, non-editable "Ungrouped" row below the reorderable list.
class _UngroupedRow extends StatelessWidget {
  const _UngroupedRow({
    required this.label,
    required this.note,
    required this.count,
  });

  final String label;
  final String note;
  final int count;

  @override
  Widget build(BuildContext context) {
    // Its words in the muted ink that reads (the whole row was faded to
    // 55%, its note at 2.3:1).
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            // Neutral dot in the ungrouped/neutral colour.
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: ZestTokens.textTertiary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: ZestTokens.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    note,
                    style: TextStyle(
                      color: ZestTokens.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                color: ZestTokens.textTertiary,
                fontSize: 12,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ],
        ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Shared small widgets + dialogs
// ════════════════════════════════════════════════════════════════════

/// A small square hover-highlighting icon button (close, remove).
class _IconTapButton extends StatefulWidget {
  const _IconTapButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 16,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  State<_IconTapButton> createState() => _IconTapButtonState();
}

class _IconTapButtonState extends State<_IconTapButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? ZestTokens.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: widget.size,
              color: _hover ? ZestTokens.textPrimary : ZestTokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Result wrapper so the icon picker can distinguish "chose default (null)"
/// from "dismissed (no result)".
class _IconPick {
  const _IconPick(this.codePoint);
  final int? codePoint;
}

/// Compact folder-icon chooser. Preserves the icon-editing capability the old
/// FolderEditDialog offered, reached from the Tab One header tile.
class _IconPickerDialog extends StatelessWidget {
  const _IconPickerDialog({required this.selected, required this.accent});

  final int? selected;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The app's dialog (3.4): a cell chooses, Cancel is in the footer.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      // (Not the folder: that is the first of the icons to choose.)
      icon: LucideIcons.shapes,
      title: l10n.hostIconPickerTitle,
      body: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _IconCell(
            icon: defaultFolderIcon,
            name: folderIconName(defaultFolderIcon, l10n),
            selected: selected == null || selected == defaultFolderIcon.codePoint,
            accent: accent,
            onTap: () => Navigator.of(context).pop(const _IconPick(null)),
          ),
          for (final icon in folderIconChoices)
            // The folder is the default's cell: it is not drawn twice.
            if (icon != defaultFolderIcon)
              _IconCell(
                icon: icon,
                name: folderIconName(icon, l10n),
                selected: icon.codePoint == selected,
                accent: accent,
                onTap: () => Navigator.of(context).pop(_IconPick(icon.codePoint)),
              ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.icon,
    required this.name,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;

  /// The icon's name, on hover and to a screen reader.
  final String name;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(message: name, child: Semantics(selected: selected, child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.18) : ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? accent : ZestTokens.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: selected ? accent : ZestTokens.textSecondary,
        ),
      ),
    )));
  }
}

/// The three-way unsaved-changes prompt (Save / Discard / Cancel).
class _DiscardDialog extends StatelessWidget {
  const _DiscardDialog({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The app's dialog (3.4): Cancel and Save in the footer, Discard the side
    // option at its left, in red.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.fileEdit,
      title: title,
      autofocusPrimary: true,
      onClose: () => Navigator.of(context).pop(_DiscardChoice.cancel),
      body: Text(
        body,
        style: TextStyle(
          color: ZestTokens.textSecondary,
          fontSize: 13.5,
          height: 1.5,
        ),
      ),
      tertiaryKey: const ValueKey('group-discard-discard'),
      tertiaryDanger: true,
      tertiaryAction: (label: l10n.zestCommonDiscard, onPressed: () => Navigator.of(context).pop(_DiscardChoice.discard)),
      secondaryKey: const ValueKey('group-discard-cancel'),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(_DiscardChoice.cancel)),
      primaryKey: const ValueKey('group-discard-save'),
      primaryAction: (label: l10n.save, icon: null, onPressed: () => Navigator.of(context).pop(_DiscardChoice.save)),
    );
  }
}
