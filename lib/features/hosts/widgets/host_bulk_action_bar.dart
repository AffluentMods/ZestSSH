import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show Connection, ConnectionGroup;
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show showMoveCopyDialog, transferOffer;
import 'package:zestssh/features/selection/item_selection.dart' show deleteSelection, mayDeleteAnyOf;
import 'package:zestssh/features/workspaces/widgets/workspace_save_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/connection_tags_providers.dart';
import 'package:zestssh/providers/pinned_hosts_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../../../core/theme/group_color.dart';
import '../../../core/theme/zest_colors.dart';
import '../bulk/host_bulk_edit.dart' show BulkField;
import '../open_many_hosts.dart';
import '../open_selected_hosts.dart';
import '../state/host_multi_select.dart';
import 'hosts_band.dart' show BandMenuRow;
import 'package:zestssh/features/orchards/team_write.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/features/orchards/guardrails.dart';

/// Floating bar shown at the bottom of [HostsHomePage] while the user is
/// in multi-select mode. Modeled on macOS Finder / file-manager bulk-edit
/// chrome - pill-shaped, dim background, action buttons, dismiss.
///
/// Lives in a [Stack] above the host grid; the page is responsible for
/// mounting / unmounting it when [hostMultiSelectProvider] flips.
class HostBulkActionBar extends ConsumerStatefulWidget {
  const HostBulkActionBar({
    super.key,
    required this.groups,
    this.onCreateGroup,
    this.shownOrder = const [],
    this.compact = false,
    this.onEdit,
  });

  /// Opens the bulk editor of the selection (the page's panel), on [focus]
  /// where given: Edit…, and Tags and Move to group, which open it with that
  /// field ready. Null (the drawer):
  /// Tags and Move to group ask in their own small dialogs, as before.
  final void Function(BulkField? focus)? onEdit;

  /// The narrow form, for the foot of the Hosts drawer: the count and Done,
  /// then Open, Move to group and Pin, and the rest (Add tag, Color label,
  /// Icon color, Save as workspace, Delete) behind its ⋯.
  final bool compact;

  /// The hosts in the order the page shows them: Open and Save as workspace
  /// take the selected ones in this order (a selection itself has none).
  final List<String> shownOrder;

  /// All groups the user could move selected hosts into. Sourced from
  /// `connectionGroupsProvider` upstream so the bar doesn't have to
  /// re-fetch.
  final List<ConnectionGroup> groups;

  /// Optional hook for the "+ New group" action. When null the action
  /// is hidden. The callback receives no args; the parent is expected
  /// to prompt for a name and create the group, then move the
  /// currently-selected hosts into it.
  final Future<void> Function()? onCreateGroup;

  @override
  ConsumerState<HostBulkActionBar> createState() => HostBulkActionBarState();
}

/// The bar's state: [deleteSelected] is what the page's Delete key does.
class HostBulkActionBarState extends ConsumerState<HostBulkActionBar> {
  bool _busy = false;

  /// The selected hosts, in the order shown (any the page no longer shows
  /// after them, in the order they were saved).
  List<ConnectionWithDetails> _selectedInOrder() {
    final selected = ref.read(hostMultiSelectProvider).selected;
    final all = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final byId = {for (final c in all) c.connection.id: c};
    final ids = [
      for (final id in widget.shownOrder)
        if (selected.contains(id)) id,
      for (final c in all)
        if (selected.contains(c.connection.id) && !widget.shownOrder.contains(c.connection.id)) c.connection.id,
    ];
    return [for (final id in ids) ?byId[id]];
  }

  /// Pin: pins every selected host; where all of them are pinned already,
  /// it is Unpin and unpins them.
  Future<void> _togglePinned(bool allPinned) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final pins = ref.read(pinnedHostsProvider.notifier);
      for (final id in ref.read(hostMultiSelectProvider).selected) {
        if (allPinned) {
          await pins.unpin(id);
        } else {
          await pins.pin(id);
        }
      }
      if (!mounted) return;
      ref.read(hostMultiSelectProvider.notifier).exit();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Open: asks how (a tab each, or side by side in one), then opens them.
  Future<void> _showOpenMenu(BuildContext anchorContext) async {
    final hosts = <Connection>[for (final c in _selectedInOrder()) c.connection];
    if (hosts.isEmpty) return;
    // Past a few, "Open 42 sessions?" asks how instead.
    if (hosts.length > kOpenManyAskOver) {
      final opened = await openManyHostsFlow(context, ref, hosts);
      if (opened && mounted) ref.read(hostMultiSelectProvider.notifier).exit();
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final box = anchorContext.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    // Above the bar: it sits at the foot of the page.
    final how = await showMenu<OpenSelectedAs>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 320),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: selectionMenuAt(box, overlay),
      items: [
        PopupMenuItem(
          key: const ValueKey('bulk-open-tabs'),
          value: OpenSelectedAs.tabs,
          height: 48,
          child: BandMenuRow(icon: LucideIcons.copy, label: l10n.hostsSelOpenInTabs, sub: l10n.hostsSelOpenInTabsSub),
        ),
        PopupMenuItem(
          key: const ValueKey('bulk-open-panes'),
          value: OpenSelectedAs.splitPanes,
          height: 48,
          child: BandMenuRow(
            icon: LucideIcons.layoutGrid,
            label: l10n.hostsSelOpenInPanes,
            sub: l10n.hostsSelOpenInPanesSub(kHostsSplitMaxPanes),
          ),
        ),
      ],
    );
    if (how == null || !mounted) return;
    await openSelected(how);
  }

  /// Opens the selected hosts [how] (the bar's Open, and a selected host's
  /// right-click menu), in the order shown; the selection is done once any
  /// opened.
  Future<void> openSelected(OpenSelectedAs how) async {
    final hosts = <Connection>[for (final c in _selectedInOrder()) c.connection];
    if (hosts.isEmpty) return;
    final opened = await openSelectedHostsFlow(context, ref, hosts, how);
    if (opened && mounted) ref.read(hostMultiSelectProvider.notifier).exit();
  }

  /// Pin, or Unpin where every selected host is pinned (as the bar's).
  Future<void> togglePinnedSelected() {
    final state = ref.read(hostMultiSelectProvider);
    final pinned = ref.read(pinnedHostsProvider);
    return _togglePinned(state.count > 0 && state.selected.every(pinned.contains));
  }

  /// Save as workspace (as the bar's).
  Future<void> saveSelectedAsWorkspace() => _saveAsWorkspace();

  /// Moves the selected hosts into [groupId] (none: out of their groups).
  Future<void> moveSelectedTo(String? groupId) => _moveToGroup(groupId);

  /// Add tag (as the bar's).
  Future<void> tagSelected() => _showAddTagDialog();

  /// Move to... or Copy to... ([mode]) for the selected hosts: Personal, or
  /// a team's vault (3.4). The selection ends once any went.
  Future<void> transferSelected(TransferMode mode) async {
    final ids = [for (final c in _selectedInOrder()) c.connection.id];
    if (ids.isEmpty) return;
    final result = await showMoveCopyDialog(context, ref, kind: TransferKinds.host, keys: ids, mode: mode);
    if (result != null && result.done > 0 && mounted) ref.read(hostMultiSelectProvider.notifier).exit();
  }

  /// Save as workspace: the save dialog, with the selected hosts side by side
  /// as the layout to save; the person names it.
  Future<void> _saveAsWorkspace() async {
    final ids = [for (final c in _selectedInOrder()) c.connection.id];
    if (ids.isEmpty) return;
    final saved = await WorkspaceSaveDialog.show(context, hostIds: ids);
    if (saved && mounted) ref.read(hostMultiSelectProvider.notifier).exit();
  }

  Future<void> _moveToGroup(String? groupId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final state = ref.read(hostMultiSelectProvider);
      final crud = ref.read(connectionCrudProvider);
      // In a team's vault, only the hosts the role may change move (as a
      // drag moves them); the rest stay and that is said. One the database
      // still refuses is said too (it left the handler with nothing said
      // before).
      final ids = [
        for (final id in state.selected)
          if (mayChangeItem(ref, 'host', id, watch: false)) id,
      ];
      if (ids.length < state.selected.length) {
        showTopSnackBar(context, AppLocalizations.of(context)!.orchardWriteNotAllowed, isWarning: true);
      }
      final moved = await runTeamWrite(context, () async {
        for (final id in ids) {
          await crud.update(
            id: id,
            groupId: groupId,
            clearGroupId: groupId == null,
          );
        }
      }, where: 'Move to group');
      if (moved && ids.isNotEmpty) ref.read(hostMultiSelectProvider.notifier).exit();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Delete (the bar's Delete, the selection's menu, and the Delete key on
  /// the Hosts page while hosts are selected): one question for the batch,
  /// then each selected host as its single delete may, as every list's
  /// selection deletes ([deleteSelection]). In a team's vault only those its
  /// role may delete go, the rest said in the question; what could not be
  /// deleted stays selected and is named.
  Future<void> deleteSelected() async {
    if (_busy) return;
    final selected = ref.read(hostMultiSelectProvider).selected;
    final ids = [
      for (final id in widget.shownOrder)
        if (selected.contains(id)) id,
      for (final id in selected)
        if (!widget.shownOrder.contains(id)) id,
    ];
    if (ids.isEmpty) return;
    setState(() => _busy = true);
    try {
      await deleteSelection(context, ref, TransferKinds.host, ids);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(hostMultiSelectProvider);
    if (!state.active) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final n = state.count;
    final on = n > 0 && !_busy;
    final pinned = ref.watch(pinnedHostsProvider);
    // Kept alive while the bar shows: Open and Save as workspace read it.
    ref.watch(connectionsWithDetailsProvider);
    final allPinned = n > 0 && state.selected.every(pinned.contains);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final toggleKey = mac ? 'Cmd' : 'Ctrl';

    // The drawer's actions (its compact bar), and those of the page's bar's
    // ⋯ (Pin, Save as workspace, Icon color).
    final open = SelectionBarItem(
      key: const ValueKey('bulk-open'),
      icon: LucideIcons.play,
      label: l10n.hostsSelOpen,
      trailing: LucideIcons.chevronDown,
      enabled: on,
      onAnchoredTap: _showOpenMenu,
    );
    final saveWs = SelectionBarItem(
      key: const ValueKey('bulk-save-workspace'),
      icon: LucideIcons.layoutDashboard,
      label: l10n.hostsSelSaveWorkspace,
      enabled: on,
      onTap: _saveAsWorkspace,
    );
    final move = SelectionBarItem(
      key: const ValueKey('bulk-move'),
      icon: LucideIcons.folder,
      label: l10n.hostBulkActionMoveToGroup,
      enabled: on,
      onTap: _showGroupPicker,
    );
    // Add tag applies a single tag to every selected host. Removing tags
    // happens per host in the editor, where the person sees which one.
    final tag = SelectionBarItem(
      key: const ValueKey('bulk-tag'),
      icon: LucideIcons.tag,
      label: l10n.hostBulkActionAddTag,
      enabled: on,
      onTap: _showAddTagDialog,
    );
    // Colour label: one label colour (or None, which re-inherits the group
    // colour) for every selected host, named as the host editor names it.
    final color = SelectionBarItem(
      key: const ValueKey('bulk-color'),
      icon: LucideIcons.palette,
      label: l10n.zestHostFieldColor,
      enabled: on,
      onTap: _showSetColor,
    );
    // Icon colour: each icon's own colour, its label's or group's, or one
    // colour for all of them.
    final iconColor = SelectionBarItem(
      key: const ValueKey('bulk-icon-color'),
      icon: LucideIcons.paintBucket,
      label: l10n.hostIconColorLabel,
      enabled: on,
      onTap: _showSetIconColor,
    );
    // Move to... and Copy to...: Personal, or a team's vault (3.4).
    final offer = transferOffer(ref, TransferKinds.host, state.selected.toList());
    final moveTo = SelectionBarItem(
      key: const ValueKey('bulk-move-to'),
      icon: LucideIcons.folderInput,
      label: l10n.transferMoveTo,
      enabled: on,
      onTap: () => transferSelected(TransferMode.move),
    );
    final copyTo = SelectionBarItem(
      key: const ValueKey('bulk-copy-to'),
      icon: LucideIcons.copyPlus,
      label: l10n.transferCopyTo,
      enabled: on,
      onTap: () => transferSelected(TransferMode.copy),
    );
    final pin = SelectionBarItem(
      key: const ValueKey('bulk-pin'),
      icon: allPinned ? LucideIcons.pinOff : LucideIcons.pin,
      label: allPinned ? l10n.hostsHomeMenuUnpin : l10n.hostsHomeMenuPin,
      enabled: on,
      onTap: () => _togglePinned(allPinned),
    );
    // Delete is on where the role may delete any of them (as every list's).
    final mayDelete = on && mayDeleteAnyOf(ref, TransferKinds.host, state.selected.toList(), watch: true);
    final delete = SelectionBarItem(
      key: const ValueKey('bulk-delete'),
      icon: LucideIcons.trash2,
      label: l10n.delete,
      enabled: mayDelete,
      destructive: true,
      shortcut: mac ? '⌫' : 'Del',
      onTap: deleteSelected,
    );
    // Done ends selection mode without changes.
    final done = SelectionBarItem(
      key: const ValueKey('bulk-done'),
      icon: LucideIcons.x,
      label: l10n.done,
      enabled: !_busy,
      shortcut: 'Esc',
      onTap: () => ref.read(hostMultiSelectProvider.notifier).exit(),
    );
    final count = SelectionCountLabel(
      label: l10n.hostBulkActionSelectedCount(n),
      tooltip: '${l10n.hostsSelSelectAll(widget.shownOrder.length)} ($toggleKey+A)',
      onTap: _showCountMenu,
    );
    if (widget.compact) {
      return Container(
        key: const ValueKey('host-bulk-actions-compact'),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: ZestColors.bgElevated,
          border: Border(top: BorderSide(color: ZestColors.borderSubtle)),
        ),
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [count, const Spacer(), done]),
              const SizedBox(height: 6),
              Wrap(
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  open,
                  move,
                  pin,
                  SelectionMoreButton(
                    enabled: on,
                    tooltip: l10n.hostsSelMore,
                    items: [
                      tag,
                      color,
                      iconColor,
                      saveWs,
                      if (offer.move) moveTo,
                      if (offer.copy) copyTo,
                      delete,
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    // The page's bar: the count,
    // Edit… (the editor of every field), Open…, Tags, Move to group, the
    // rest behind ⋯, Delete and the close. Tags and Move open the editor at
    // their field; without one (no page to dock it), their own dialogs.
    final edit = SelectionBarItem(
      key: const ValueKey('bulk-edit'),
      icon: LucideIcons.pencil,
      label: l10n.bulkEdit,
      enabled: on,
      primary: true,
      onTap: () => widget.onEdit?.call(null),
    );
    final openMany = SelectionBarItem(
      key: const ValueKey('bulk-open'),
      icon: LucideIcons.play,
      label: l10n.bulkOpen,
      enabled: on,
      onAnchoredTap: _showOpenMenu,
    );
    final tags = SelectionBarItem(
      key: const ValueKey('bulk-tag'),
      icon: LucideIcons.tag,
      label: l10n.bulkTags,
      enabled: on,
      onTap: widget.onEdit == null ? _showAddTagDialog : () => widget.onEdit!(BulkField.tags),
    );
    final moveToGroup = SelectionBarItem(
      key: const ValueKey('bulk-move'),
      icon: LucideIcons.folder,
      label: l10n.hostBulkActionMoveToGroup,
      enabled: on,
      onTap: widget.onEdit == null ? _showGroupPicker : () => widget.onEdit!(BulkField.group),
    );
    final close = SelectionBarItem(
      key: const ValueKey('bulk-done'),
      icon: LucideIcons.x,
      label: l10n.done,
      iconOnly: true,
      enabled: !_busy,
      shortcut: 'Esc',
      onTap: () => ref.read(hostMultiSelectProvider.notifier).exit(),
    );
    final deleteText = SelectionBarItem(
      key: const ValueKey('bulk-delete'),
      icon: LucideIcons.trash2,
      label: l10n.delete,
      enabled: mayDelete,
      destructive: true,
      showIcon: false,
      shortcut: mac ? '⌫' : 'Del',
      onTap: deleteSelected,
    );
    // Behind ⋯: what the bar has no room for and the editor has no
    // field of (the colour label is the editor's, where there is one).
    final more = [
      pin,
      saveWs,
      iconColor,
      if (widget.onEdit == null) color,
      if (offer.move) moveTo,
      if (offer.copy) copyTo,
    ];
    // The shared frame (every list's selection bar): the hints over the
    // pill, the page fading out under both.
    return SelectionBarFrame(
      barKey: const ValueKey('host-bulk-actions'),
      hints: SelectionHints(
        key: const ValueKey('host-bulk-hint'),
        toggleKey: toggleKey,
        extra: widget.onEdit != null ? l10n.bulkHintFields : null,
      ),
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, end: 10),
          child: SelectionCountLabel(
            label: l10n.hostBulkActionSelectedCount(n),
            tooltip: '${l10n.hostsSelSelectAll(widget.shownOrder.length)} ($toggleKey+A)',
            onTap: _showCountMenu,
          ),
        ),
        if (widget.onEdit != null) edit,
        openMany,
        tags,
        moveToGroup,
        SelectionMoreButton(enabled: on, tooltip: l10n.hostsSelMore, items: more),
        Row(mainAxisSize: MainAxisSize.min, children: [const SelectionBarDivider(), deleteText]),
        close,
      ],
    );
  }

  /// The count's menu: every host shown, or none (selection mode stays).
  Future<void> _showCountMenu(BuildContext anchor) async {
    final l10n = AppLocalizations.of(context)!;
    final box = anchor.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final pick = await showMenu<String>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: selectionMenuAt(box, overlay),
      items: [
        PopupMenuItem(
          key: const ValueKey('bulk-select-all'),
          value: 'all',
          height: 38,
          child: BandMenuRow(icon: LucideIcons.checkSquare, label: l10n.hostsSelSelectAll(widget.shownOrder.length)),
        ),
        PopupMenuItem(
          key: const ValueKey('bulk-select-none'),
          value: 'none',
          height: 38,
          child: BandMenuRow(icon: LucideIcons.square, label: l10n.hostsSelSelectNone),
        ),
      ],
    );
    if (!mounted) return;
    final notifier = ref.read(hostMultiSelectProvider.notifier);
    if (pick == 'all') notifier.selectAll(widget.shownOrder);
    if (pick == 'none') notifier.clearSelection();
  }

  Future<void> _showAddTagDialog() async {
    final selectedIds = ref.read(hostMultiSelectProvider).selected.toList();
    if (selectedIds.isEmpty) return;

    final allTags =
        ref.read(allTagsProvider).valueOrNull ?? const <String>[];

    final tag = await showZestModal<String>(
      context: context,
      size: ZestModalSize.compact,
      child: _AddTagDialog(
        availableTags: allTags,
        selectedCount: selectedIds.length,
      ),
    );
    if (tag == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(tagsCrudProvider).addTagToMany(selectedIds, tag);
      if (!mounted) return;
      ref.read(hostMultiSelectProvider.notifier).exit();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Bulk "Set colour": opens the shared [ZestColorPicker] (presets + None)
  /// and applies the chosen colour label to every selected host. Choosing None
  /// clears the override so the hosts re-inherit their group colour.
  Future<void> _showSetColor() async {
    final selectedIds = ref.read(hostMultiSelectProvider).selected.toList();
    if (selectedIds.isEmpty) return;

    final choice = await showZestModal<_ColorChoice>(
      context: context,
      size: ZestModalSize.compact,
      child: _SetColorDialog(selectedCount: selectedIds.length),
    );
    if (choice == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final crud = ref.read(connectionCrudProvider);
      for (final id in selectedIds) {
        if (choice.isNone) {
          // None → drop any custom value AND reset the palette index to 0 so
          // the host re-inherits from its group.
          await crud.update(id: id, colorIndex: 0, clearColorValue: true);
        } else {
          await crud.update(
            id: id,
            colorValue: choice.color!.toARGB32(),
            colorIndex: 0,
          );
        }
      }
      if (!mounted) return;
      ref.read(hostMultiSelectProvider.notifier).exit();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Bulk "Icon colour": what colours the icon of every selected host (see
  /// [HostIconColor]). One tap applies, as for the colour label.
  Future<void> _showSetIconColor() async {
    final selectedIds = ref.read(hostMultiSelectProvider).selected.toList();
    if (selectedIds.isEmpty) return;

    final choice = await showZestModal<_IconColorChoice>(
      context: context,
      size: ZestModalSize.compact,
      child: _SetIconColorDialog(selectedCount: selectedIds.length),
    );
    if (choice == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final crud = ref.read(connectionCrudProvider);
      for (final id in selectedIds) {
        await crud.update(id: id, iconColor: choice.stored, setIconColor: true);
      }
      if (!mounted) return;
      ref.read(hostMultiSelectProvider.notifier).exit();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showGroupPicker() async {
    final selectedCount = ref.read(hostMultiSelectProvider).count;
    if (selectedCount == 0) return;
    final groups = widget.groups;

    // The shell (the dialog rules of 3.4): the groups as rows, a tap moves
    // the hosts there, Cancel in the footer.
    await showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => _GroupPickerDialog(
          groups: groups,
          selectedCount: selectedCount,
          onCreateGroup: widget.onCreateGroup,
          onPick: (groupId) async {
            Navigator.of(ctx).pop();
            await _moveToGroup(groupId);
          },
        ),
      ),
    );
  }
}

/// The dialog listing every group plus an "Ungrouped" / "+ New group" option,
/// in the shell (the dialog rules of 3.4: Cancel in its footer). Designed to
/// feel quick - no descriptions, just labels with a coloured dot prefix to
/// match each group's chip colour.
class _GroupPickerDialog extends ConsumerWidget {
  const _GroupPickerDialog({
    required this.groups,
    required this.selectedCount,
    required this.onPick,
    this.onCreateGroup,
  });

  final List<ConnectionGroup> groups;
  final int selectedCount;
  final ValueChanged<String?> onPick;
  final Future<void> Function()? onCreateGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // The shell scrolls a long list of groups in its body.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.folderInput,
      title: l10n.hostBulkActionMoveHostsTo(selectedCount),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onCreateGroup != null)
            _SheetItem(
              leading: Icon(
                LucideIcons.folderPlus,
                color: ZestColors.accentInk,
                size: 20,
              ),
              label: l10n.hostBulkActionNewGroup,
              emphasized: true,
              onTap: () async {
                Navigator.of(context).pop();
                await onCreateGroup!();
              },
            ),
          _SheetItem(
            leading: Icon(
              LucideIcons.folderX,
              color: ZestColors.textTertiary,
              size: 20,
            ),
            label: l10n.hostBulkActionUngrouped,
            onTap: () => onPick(null),
          ),
          if (groups.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Text(
                l10n.hostBulkActionExistingGroups,
                style: TextStyle(
                  color: ZestColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            for (final g in groups)
              _SheetItem(
                leading: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: _colorForGroupName(g.name),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                // Painted only; the pick still carries g.id.
                label: Redactable.group(g.name).displayIn(ref),
                onTap: () => onPick(g.id),
              ),
          ],
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }

  /// Same hash-based palette mapping the chip and host card use, so the
  /// dot in this list visually matches what the user sees elsewhere. Uses
  /// the canonical [GroupColor] token set (identical expression to
  /// hosts_home_page) instead of a divergent inline hex palette.
  Color _colorForGroupName(String name) {
    return GroupColor
        .values[name.hashCode.abs() % GroupColor.values.length].value;
  }
}

/// Tiny dialog asking for one tag, with autocomplete from the existing
/// vocabulary. Returns the canonical-form tag (or null if cancelled).
class _AddTagDialog extends StatefulWidget {
  const _AddTagDialog({
    required this.availableTags,
    required this.selectedCount,
  });
  final List<String> availableTags;
  final int selectedCount;

  @override
  State<_AddTagDialog> createState() => _AddTagDialogState();
}

class _AddTagDialogState extends State<_AddTagDialog> {
  // The Autocomplete owns its TextEditingController; we capture that ONE
  // instance on the first fieldViewBuilder call instead of mirroring it into a
  // second controller. The old mirror re-added a listener on every rebuild
  // (a growing listener leak) and assigned `controller.text = …` each build,
  // which snapped the caret to the end mid-typing.
  TextEditingController? _fieldController;

  void _commit() {
    final canonical =
        ConnectionTagsDao.normalize(_fieldController?.text ?? '');
    if (canonical == null) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(canonical);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final n = widget.selectedCount;
    // The shell (the dialog rules of 3.4): Cancel and Add in its footer.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.tag,
      title: l10n.hostBulkActionTagHostsTitle(n),
      body: SizedBox(
        width: 320,
        child: Autocomplete<String>(
          optionsBuilder: (textEditingValue) {
            final query = textEditingValue.text.trim().toLowerCase();
            if (query.isEmpty) return widget.availableTags;
            return widget.availableTags.where((t) => t.contains(query));
          },
          fieldViewBuilder:
              (context, controller, focusNode, onFieldSubmitted) {
            // Capture the Autocomplete's own controller once so _commit can
            // read the text without a mirror controller (no per-build listener,
            // no caret reset).
            _fieldController ??= controller;
            return TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              maxLength: ConnectionTagsDao.maxLength,
              decoration: InputDecoration(
                hintText: l10n.hostBulkActionTagHint,
                counterText: '',
              ),
              onSubmitted: (_) => _commit(),
            );
          },
        ),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      primaryAction: (label: l10n.hostBulkActionAddTagButton(n), icon: null, onPressed: _commit),
    );
  }
}

class _SheetItem extends StatefulWidget {
  const _SheetItem({
    required this.leading,
    required this.label,
    required this.onTap,
    this.emphasized = false,
  });

  final Widget leading;
  final String label;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  State<_SheetItem> createState() => _SheetItemState();
}

class _SheetItemState extends State<_SheetItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: _hovering
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              SizedBox(width: 22, height: 22, child: Center(child: widget.leading)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.emphasized
                        ? ZestColors.accentInk
                        : ZestColors.textPrimary,
                    fontSize: 14,
                    fontWeight: widget.emphasized
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the bulk "Icon colour" dialog was closed with: the choice as a host
/// stores it. A class of its own because null is a choice (the icon's own
/// colour) and the dialog also closes with nothing chosen.
class _IconColorChoice {
  const _IconColorChoice(this.stored);
  final int? stored;
}

/// The bulk "Icon colour" dialog: the icon's own colour, the colour of each
/// host's label or group, or one of the label colours for all of them. A tap
/// closes it with the choice.
class _SetIconColorDialog extends StatelessWidget {
  const _SetIconColorDialog({required this.selectedCount});
  final int selectedCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    void close(int? stored) => Navigator.of(context).pop(_IconColorChoice(stored));
    // The shell (the dialog rules of 3.4): a tap on a choice applies it,
    // Cancel in the footer.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.palette,
      title: l10n.hostIconColorBulkTitle(selectedCount),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ZestButton(
                key: const ValueKey('bulk-icon-color-own'),
                label: l10n.hostIconColorOwn,
                onPressed: () => close(null),
              ),
              ZestButton(
                key: const ValueKey('bulk-icon-color-group'),
                label: l10n.hostIconColorGroup,
                onPressed: () => close(HostIconColor.followsLabel),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.hostIconColorBulkGroupHint,
            style: TextStyle(color: ZestColors.textSecondary, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.hostIconColorBulkOr,
            style: TextStyle(color: ZestColors.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          ZestColorPicker(
            presets: AppColors.labelPalette,
            // Nothing is common to a selection of several hosts, so no
            // swatch starts out marked.
            selected: const Color(0x00000000),
            // As for the colour label: a custom pick opens a dialog of
            // its own, and closing this one from under it would close
            // the wrong one.
            allowCustom: false,
            onChanged: (c) => close(HostIconColor.custom(c)),
          ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// Result of the bulk "Set colour" dialog: either a concrete colour, or None
/// (which clears the override so hosts re-inherit their group colour).
class _ColorChoice {
  const _ColorChoice.color(this.color) : isNone = false;
  const _ColorChoice.none()
      : color = null,
        isNone = true;
  final Color? color;
  final bool isNone;
}

/// Small centred dialog wrapping the shared [ZestColorPicker] for the bulk
/// "Set colour" action. Picking a preset (or None) immediately resolves the
/// dialog with the choice - a one-tap apply, matching the rest of the bar.
class _SetColorDialog extends StatelessWidget {
  const _SetColorDialog({required this.selectedCount});
  final int selectedCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The shell (the dialog rules of 3.4): a tap on a colour applies it,
    // Cancel in the footer.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.palette,
      title: selectedCount == 1 ? l10n.zestHostFieldColor : '${l10n.zestHostFieldColor} · $selectedCount',
      body: ZestColorPicker(
        presets: AppColors.labelPalette,
        // No shared current colour across a multi-selection, so start
        // with nothing highlighted (transparent matches no preset and
        // None isn't pre-selected).
        selected: const Color(0x00000000),
        // Custom picking would open a nested dialog whose commit pops
        // the wrong route - presets + None is the clean bulk contract.
        allowCustom: false,
        allowNone: true,
        onNoneSelected: () => Navigator.of(context).pop(const _ColorChoice.none()),
        onChanged: (c) => Navigator.of(context).pop(_ColorChoice.color(c)),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
