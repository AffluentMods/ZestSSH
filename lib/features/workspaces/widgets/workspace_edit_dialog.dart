import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_launch.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_dialog_common.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

const WorkspaceMemberHost _kUnresolvedFallback = WorkspaceMemberHost(
  id: '',
  name: '',
  colorValue: null,
  colorIndex: 0,
  resolvedColor: AppColors.neutralLabelColor,
  userAtAddress: '',
  resolved: false,
);

/// Edit a saved workspace, presented as a RIGHT-anchored slide-in side panel
/// for: rename, reorder panes by drag, remove a pane,
/// `Replace with current layout`, switch between saved workspaces via the
/// "All workspaces" tab, and delete.
///
/// Contract: `WorkspaceEditDialog.show(context, workspaceId: id)`.
///
/// Delete asks for a single inline confirmation, then removes the workspace
/// immediately, closes this editor, and shows a 10-second toast with an Undo
/// action that restores it to its original list position (keeping its launch
/// shortcut). Hosts are never touched.
///
/// A rename that collides with another workspace surfaces the shared rich
/// [WorkspaceCollisionCallout] (Replace / Save as N) and disables Save until it
/// is resolved, instead of a thin error line.
class WorkspaceEditDialog extends ConsumerStatefulWidget {
  const WorkspaceEditDialog({super.key, required this.workspaceId, this.onDone});

  final String workspaceId;

  /// Where given, the editor stands in a panel of the page ([WorkspacePanel]):
  /// without the sliding shell and the way to All workspaces, and it is done
  /// by this instead of closing a route.
  final VoidCallback? onDone;

  static Future<void> show(
    BuildContext context, {
    required String workspaceId,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel:
          MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) =>
          WorkspaceEditDialog(workspaceId: workspaceId),
      transitionBuilder: (context, animation, secondary, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return Align(
          alignment: Alignment.centerRight,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  ConsumerState<WorkspaceEditDialog> createState() =>
      _WorkspaceEditDialogState();
}

class _EditPane {
  _EditPane({required this.leaf, required this.member});
  final PaneLeaf leaf;
  final WorkspaceMemberHost member;
}

class _WorkspaceEditDialogState extends ConsumerState<WorkspaceEditDialog> {
  final _nameController = TextEditingController();

  /// The workspace currently being edited. Starts at the id passed to `show`
  /// but the "All workspaces" screen can point the editor at a different one.
  late String _activeId = widget.workspaceId;

  SavedTabGroup? _group;
  List<_EditPane> _panes = [];

  /// The sheet has two SCREENS, not tabs: the single-workspace editor (the
  /// default) and the "All workspaces" list, reached from the editor's
  /// back-link. The editor is scoped to one workspace; managing the set is a
  /// separate screen so the scope never jumps inside what reads as a settings
  /// panel for one item.
  bool _showingList = false;

  /// The delete affordance is a two-step inline confirm inside the panel.
  bool _confirmingDelete = false;

  @override
  void initState() {
    super.initState();
    _loadFromStore();
    _nameController.text = _group?.name ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// (Re)read the active workspace + its members from the store into the
  /// editable draft. Never touches the name field so an in-progress rename
  /// survives a `Replace with current layout`.
  void _loadFromStore() {
    final group = ref.read(savedTabGroupsProvider.notifier).byId(_activeId);
    _group = group;
    if (group == null) {
      _panes = [];
      return;
    }
    final leaves = flattenWorkspaceLeaves(group);
    WorkspaceView? view;
    for (final v in ref.read(workspacesProvider)) {
      if (v.id == group.id) {
        view = v;
        break;
      }
    }
    final members = view?.memberHosts ?? const <WorkspaceMemberHost>[];
    _panes = [
      for (var i = 0; i < leaves.length; i++)
        _EditPane(
          leaf: leaves[i],
          member: i < members.length ? members[i] : _kUnresolvedFallback,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // The workspace can vanish (deleted elsewhere) - resolve its live view.
    final workspaces = ref.watch(workspacesProvider);
    WorkspaceView? view;
    for (final v in workspaces) {
      if (v.id == _activeId) {
        view = v;
        break;
      }
    }

    final body = (_group == null || view == null)
        ? _MissingBody(onClose: _cancel, message: l10n.workspaceNotFound)
        : _buildEditor(l10n, view, workspaces);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: widget.onDone == null ? _PanelShell(child: body) : body,
    );
  }

  Widget _buildEditor(
    AppLocalizations l10n,
    WorkspaceView view,
    List<WorkspaceView> workspaces,
  ) {
    final preview = ref.watch(currentLayoutPreviewProvider);
    final canReplace = preview != null;

    final notifier = ref.read(savedTabGroupsProvider.notifier);
    final trimmed = _nameController.text.trim();
    final collisionGroup =
        notifier.workspaceByName(trimmed, excludingId: _activeId);
    WorkspaceView? collision;
    if (collisionGroup != null) {
      for (final v in workspaces) {
        if (v.id == collisionGroup.id) {
          collision = v;
          break;
        }
      }
    }
    final canSave =
        trimmed.isNotEmpty && collision == null && _panes.isNotEmpty;

    final subtitle = workspaceCountLabel(l10n, view.tabCount, view.paneCount);
    final openId = ref.watch(openWorkspaceIdProvider);

    // "All workspaces" is its own screen inside the sheet (reached from the
    // back-link), never a tab inside this one-workspace editor.
    if (_showingList) return _buildListScreen(l10n, workspaces, openId);

    // The column sizes to its content (the shell caps it to the viewport and
    // the body scrolls only then), so Cancel / Save sit in a footer directly
    // under the last real element instead of a fixed position with dead
    // space above them.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Navigation to the list, above the header: not a tab in the editor.
        // (Beside the page, its cards are the list.)
        if (widget.onDone == null)
          _BackLink(
            label: l10n.workspaceEditTabAll,
            onTap: () => setState(() => _showingList = true),
          ),
        WorkspaceDialogHeader(
          title: Redactable.workspace(view.name).displayIn(ref),
          subtitle: subtitle,
          onClose: _cancel,
          // Same icon rule as the card: brand only for the open workspace.
          accent: view.id == openId,
        ),
        Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: _workspaceTab(l10n, preview, canReplace, collision, trimmed),
          ),
        ),
        Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              const Spacer(),
              // (No room for the keys' hints in the page's narrower panel.)
              if (widget.onDone == null) ...[
                const WorkspaceKbd('Esc'),
                const SizedBox(width: 8),
              ],
              WorkspaceOutlineButton(label: l10n.cancel, onPressed: _cancel),
              const SizedBox(width: 8),
              WorkspacePrimaryButton(
                  label: l10n.save, onPressed: canSave ? _save : null),
              if (widget.onDone == null) ...[
                const SizedBox(width: 8),
                const WorkspaceKbd('Enter', accent: true),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The "All workspaces" management screen: every saved workspace as a row
  /// with Edit / Open / Delete. The workspace that is open right now drops
  /// "Open" (it cannot be re-opened) and carries the brand icon, the same
  /// available-action logic the tmux menus use.
  Widget _buildListScreen(
    AppLocalizations l10n,
    List<WorkspaceView> workspaces,
    String? openId,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspaceDialogHeader(
          title: l10n.workspaceEditTabAll,
          onClose: _cancel,
        ),
        Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: _AllWorkspacesList(
              workspaces: workspaces,
              activeId: _activeId,
              openId: openId,
              onEdit: (id) {
                _selectWorkspace(id);
                setState(() => _showingList = false);
              },
              onOpen: (id) {
                // Launch, then close the sheet; the launch reports any
                // deleted hosts itself, and asks about a Telnet host, over
                // the app's context, which is still there when this closes.
                final appContext = Navigator.of(context, rootNavigator: true).context;
                unawaited(launchWorkspaceFromSurface(appContext, ref, id));
                _cancel();
              },
              onDelete: (id) {
                // Route through the editor's two-step confirm + 10s undo so a
                // delete from the list is exactly as safe as one from the
                // editor.
                _selectWorkspace(id);
                setState(() {
                  _showingList = false;
                  _confirmingDelete = true;
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _workspaceTab(
    AppLocalizations l10n,
    WorkspaceView? preview,
    bool canReplace,
    WorkspaceView? collision,
    String trimmed,
  ) {
    final notifier = ref.read(savedTabGroupsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WorkspaceNameField(
          controller: _nameController,
          label: l10n.workspaceNameLabel,
          hintText: l10n.workspaceNameHint,
          autofocus: true,
          warn: collision != null,
          onChanged: (_) => setState(() {}),
          onSubmit: () {
            // Guarded: onSubmit only commits when the current draft is valid.
            if (collision == null &&
                trimmed.isNotEmpty &&
                _panes.isNotEmpty) {
              _save();
            }
          },
        ),
        if (collision != null) ...[
          const SizedBox(height: 12),
          WorkspaceCollisionCallout(
            existing: collision,
            saveAsName: notifier.nextAvailableName(trimmed),
            onReplace: () => _replaceColliding(collision),
            onSaveAs: () => _saveAsFree(notifier.nextAvailableName(trimmed)),
          ),
        ],
        const SizedBox(height: 14),
        _PanesEditor(
          panes: _panes,
          onReorder: _onReorder,
          onRemove: _removePane,
          onAddHost: _addHost,
        ),
        const SizedBox(height: 14),
        _ReplaceRow(
          enabled: canReplace,
          // The caption is honest that Replace is destructive (it discards the
          // saved panes) instead of reading like a no-op; when nothing is open
          // it states the enable condition.
          liveLabel: canReplace
              ? l10n.workspaceReplaceDiscards
              : l10n.workspaceReplaceWithCurrentDisabled,
          onReplace: _replaceWithCurrent,
        ),
        const SizedBox(height: 16),
        _DeleteSection(
          confirming: _confirmingDelete,
          onRequest: () => setState(() => _confirmingDelete = true),
          onCancel: () => setState(() => _confirmingDelete = false),
          onConfirm: _delete,
        ),
      ],
    );
  }

  void _cancel() {
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Point the editor at a different saved workspace (from the "All
  /// workspaces" screen), reloading its draft and resetting transient UI
  /// state. The caller flips back to the editor screen.
  void _selectWorkspace(String id) {
    if (id == _activeId) return;
    setState(() {
      _activeId = id;
      _confirmingDelete = false;
      _loadFromStore();
      _nameController.text = _group?.name ?? '';
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final p = _panes.removeAt(oldIndex);
      _panes.insert(newIndex, p);
    });
  }

  void _removePane(int index) {
    if (_panes.length <= 1) return; // keep at least one pane
    setState(() => _panes.removeAt(index));
  }

  /// Add a host to this saved workspace: the shared connection picker, then a
  /// new pane APPENDED to the draft (the existing panes are untouched). Saved
  /// on Save like any other edit; rebuildWorkspaceTabs folds the new leaf into
  /// the last tab.
  Future<void> _addHost() async {
    final l10n = AppLocalizations.of(context)!;
    final res = await ConnectionPickerDialog.show(
      context,
      title: l10n.workspaceAddHostToThis,
    );
    final cwd = res.connection;
    if (cwd == null || !mounted) return;
    setState(() {
      _panes.add(_EditPane(
        leaf: PaneLeaf.single(sessionId: cwd.connection.id),
        member: workspaceMemberForConnection(cwd),
      ));
    });
  }

  void _save() {
    final l10n = AppLocalizations.of(context)!;
    final group = _group;
    if (group == null) return;
    final trimmed = _nameController.text.trim();
    final notifier = ref.read(savedTabGroupsProvider.notifier);
    if (trimmed.isEmpty ||
        _panes.isEmpty ||
        notifier.workspaceByName(trimmed, excludingId: group.id) != null) {
      return;
    }
    final rebuilt = rebuildWorkspaceTabs(
      original: group,
      orderedLeaves: _panes.map((p) => p.leaf).toList(),
    );
    notifier.updateWorkspace(group.id, name: trimmed, tabs: rebuilt);
    showTopSnackBar(
      context,
      l10n.workspaceSavedToast(Redactable.workspace(trimmed).display),
      isSuccess: true,
    );
    _cancel();
  }

  /// Resolution when the typed name matches another workspace [other]: write
  /// this workspace's edited panes into [other]'s slot (keeping its name,
  /// position and launch shortcut) and drop this now-duplicate one. This is the
  /// "two identical Main" consolidation, chosen deliberately by the user, so it
  /// is not the undoable soft-delete path.
  void _replaceColliding(WorkspaceView other) {
    final l10n = AppLocalizations.of(context)!;
    final group = _group;
    if (group == null) return;
    final notifier = ref.read(savedTabGroupsProvider.notifier);
    final rebuilt = rebuildWorkspaceTabs(
      original: group,
      orderedLeaves: _panes.map((p) => p.leaf).toList(),
    );
    notifier.updateWorkspace(
      other.id,
      name: other.name,
      tabs: rebuilt,
      hostNames: group.hostNames,
    );
    notifier.delete(_activeId);
    showTopSnackBar(
      context,
      l10n.workspaceReplacedToast(Redactable.workspace(other.name).display),
      isSuccess: true,
    );
    _cancel();
  }

  /// Resolution: keep both workspaces by renaming this one to the first free
  /// `"<name> N"`, then save the edited panes under it.
  void _saveAsFree(String freeName) {
    _nameController.text = freeName;
    _save();
  }

  void _replaceWithCurrent() {
    final l10n = AppLocalizations.of(context)!;
    final ok = ref
        .read(savedTabGroupsProvider.notifier)
        .replaceWithCurrentLayout(_activeId);
    if (!ok) return;
    setState(_loadFromStore);
    showTopSnackBar(
      context,
      l10n.workspaceReplacedToast(
        Redactable.workspace(_group?.name ?? _nameController.text.trim())
            .display,
      ),
      isSuccess: true,
    );
  }

  void _delete() {
    final l10n = AppLocalizations.of(context)!;
    final name = _group?.name ?? _nameController.text.trim();
    // Capture the container so Undo works after this dialog is disposed.
    final container = ProviderScope.containerOf(context, listen: false);
    final record = container
        .read(savedTabGroupsProvider.notifier)
        .softDelete(_activeId);
    if (record == null) {
      _cancel();
      return;
    }
    showTopSnackBar(
      context,
      l10n.workspaceDeletedToast(Redactable.workspace(name).display),
      isWarning: true,
      duration: const Duration(seconds: 10),
      actionLabel: l10n.workspaceUndo,
      onAction: () => container
          .read(savedTabGroupsProvider.notifier)
          .restoreDeleted(record),
    );
    _cancel();
  }
}

// ── Panel shell (right-anchored, full-height slide-in) ──────────────

class _PanelShell extends StatelessWidget {
  const _PanelShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Sized to its content, capped to the viewport (the body scrolls only
    // then), instead of stretching to full height and leaving a dead region
    // between the last element and a footer pinned to the bottom edge. It
    // still slides in flush to the right edge, so the right corners stay
    // square and the left ones rounded.
    final maxHeight = MediaQuery.of(context).size.height;
    return SizedBox(
      width: 480,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.v3Elevated,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                bottomLeft: Radius.circular(16),
              ),
              border: Border(
                left: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 40,
                  spreadRadius: -8,
                  offset: const Offset(-14, 0),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ),
      ),
    );
  }
}

// ── Back-link to the "All workspaces" screen ───────────────────────

/// "‹ All workspaces" above the editor header. It is NAVIGATION (leaves this
/// one-workspace editor for the list screen), which is why it sits above the
/// header rather than as a tab inside it.
class _BackLink extends StatefulWidget {
  const _BackLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_BackLink> createState() => _BackLinkState();
}

class _BackLinkState extends State<_BackLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover
        ? AppColors.v3AccentInk
        : AppColors.v3AccentPrimary.withValues(alpha: 0.85);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.chevronLeft, size: 14, color: color),
                const SizedBox(width: 2),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
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

// ── "All workspaces" list screen ───────────────────────────────────

class _AllWorkspacesList extends StatelessWidget {
  const _AllWorkspacesList({
    required this.workspaces,
    required this.activeId,
    required this.openId,
    required this.onEdit,
    required this.onOpen,
    required this.onDelete,
  });

  final List<WorkspaceView> workspaces;

  /// The workspace the editor was on (subtly highlighted for orientation).
  final String activeId;

  /// The workspace that is open right now, or null: it gets the brand icon
  /// and loses the Open action.
  final String? openId;
  final void Function(String id) onEdit;
  final void Function(String id) onOpen;
  final void Function(String id) onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final w in workspaces) ...[
          _AllWorkspacesRow(
            view: w,
            active: w.id == activeId,
            isOpen: w.id == openId,
            onEdit: () => onEdit(w.id),
            onOpen: () => onOpen(w.id),
            onDelete: () => onDelete(w.id),
          ),
          const SizedBox(height: 4),
        ],
        if (workspaces.length <= 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              l10n.workspaceEditAllHint,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 11.5,
                height: 1.5,
                color: AppColors.v3TextTertiary,
              ),
            ),
          ),
      ],
    );
  }
}

/// One row of the list: a neutral icon (brand when open now), name, a mono
/// meta line ("3 panes · 19d ago" / "1 pane · open now") and the row actions.
class _AllWorkspacesRow extends StatefulWidget {
  const _AllWorkspacesRow({
    required this.view,
    required this.active,
    required this.isOpen,
    required this.onEdit,
    required this.onOpen,
    required this.onDelete,
  });

  final WorkspaceView view;
  final bool active;
  final bool isOpen;
  final VoidCallback onEdit;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  State<_AllWorkspacesRow> createState() => _AllWorkspacesRowState();
}

class _AllWorkspacesRowState extends State<_AllWorkspacesRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final view = widget.view;
    final accent = AppColors.v3AccentPrimary;
    final opened = widget.isOpen
        ? l10n.workspaceOpenNow
        : workspaceOpenedLabel(l10n, view.lastOpened);
    final meta =
        '${workspaceCountLabel(l10n, view.tabCount, view.paneCount)} · $opened';

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
        decoration: BoxDecoration(
          color: _hover ? AppColors.v3Surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: widget.active
                ? AppColors.v3BorderSubtle
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            // Neutral icon box; brand only for the workspace open right now.
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: widget.isOpen
                    ? accent.withValues(alpha: 0.14)
                    : AppColors.v3Surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: widget.isOpen
                      ? accent.withValues(alpha: 0.32)
                      : AppColors.v3BorderSubtle,
                ),
              ),
              child: Icon(
                LucideIcons.layoutGrid,
                size: 12,
                color: widget.isOpen ? AppColors.v3AccentInk : AppColors.v3TextTertiary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RedactedText(
                    Redactable.workspace(view.name),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.v3TextPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _RowAction(label: l10n.edit, onTap: widget.onEdit),
            // The open workspace cannot be re-opened, so it drops Open.
            if (!widget.isOpen) ...[
              _RowActionDot(),
              _RowAction(label: l10n.workspaceOpen, onTap: widget.onOpen),
            ],
            _RowActionDot(),
            _RowAction(
              label: l10n.delete,
              onTap: widget.onDelete,
              destructive: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// A quiet text action in a list row ("Edit", "Open", "Delete").
class _RowAction extends StatefulWidget {
  const _RowAction({
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  State<_RowAction> createState() => _RowActionState();
}

class _RowActionState extends State<_RowAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rest = AppColors.v3TextTertiary;
    final hot = widget.destructive ? AppColors.v3Error : AppColors.v3TextPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Text(
            widget.label,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _hover ? hot : rest,
            ),
          ),
        ),
      ),
    );
  }
}

/// The " · " separator between row actions.
class _RowActionDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '·',
        style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary),
      ),
    );
  }
}

// ── Panes editor ───────────────────────────────────────────────────

class _PanesEditor extends StatelessWidget {
  const _PanesEditor({
    required this.panes,
    required this.onReorder,
    required this.onRemove,
    required this.onAddHost,
  });

  final List<_EditPane> panes;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index) onRemove;

  /// Opens the shared host picker and APPENDS a pane, leaving the saved panes
  /// untouched (the only other way to add a host used to be "Replace with
  /// current layout", which discards everything).
  final VoidCallback onAddHost;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Neutral thumbnail, like the card and the header: pane count only, no
    // colour labels (red means unreachable, and only on a host dot).
    final paneColors = [for (final _ in panes) AppColors.v3TextTertiary];
    final canRemove = panes.length > 1;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            child: Row(
              children: [
                WorkspaceThumbnail(paneColors: paneColors),
                const SizedBox(width: 10),
                Text(
                  l10n.workspacePreviewPanes.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
                const SizedBox(width: 10),
                // Gives way where a language's words are long (Russian, in the
                // panel's width, ran over by 6 pixels).
                Expanded(
                  child: Text(
                    l10n.workspacePreviewReorderHint,
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 10.5,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: panes.length,
            onReorderItem: onReorder,
            itemBuilder: (context, i) {
              final pane = panes[i];
              return WorkspacePaneRow(
                key: ValueKey(pane.leaf.id),
                host: pane.member,
                showDivider: i != panes.length - 1,
                leading: ReorderableDragStartListener(
                  index: i,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Icon(
                      LucideIcons.gripVertical,
                      size: 14,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ),
                trailing: _RemoveButton(
                  enabled: canRemove,
                  tooltip: l10n.workspaceRemovePane,
                  onPressed: () => onRemove(i),
                ),
              );
            },
          ),
          // "+ Add host to this workspace": an ACTION row, not a pane row, so
          // it reads differently (dashed, brand wash) and appends via the same
          // host picker used elsewhere in the app.
          _AddHostRow(label: l10n.workspaceAddHostToThis, onTap: onAddHost),
        ],
      ),
    );
  }
}

/// The dashed add-a-pane row that closes the pane list.
class _AddHostRow extends StatefulWidget {
  const _AddHostRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_AddHostRow> createState() => _AddHostRowState();
}

class _AddHostRowState extends State<_AddHostRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.v3AccentPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: _hover ? 0.11 : 0.07),
            border: Border(
              top: BorderSide(color: AppColors.v3BorderSubtle),
            ),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.plus, size: 14, color: AppColors.v3AccentInk),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.v3AccentInk,
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

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // A trash can, not an X: this deletes the pane from the saved workspace.
    final child = Icon(
      LucideIcons.trash2,
      size: 13,
      color: enabled
          ? AppColors.v3TextTertiary
          : AppColors.v3TextTertiary.withValues(alpha: 0.3),
    );
    if (!enabled) return Padding(padding: const EdgeInsets.all(4), child: child);
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onPressed,
          child: Padding(padding: const EdgeInsets.all(4), child: child),
        ),
      ),
    );
  }
}

// ── Replace row ────────────────────────────────────────────────────

class _ReplaceRow extends StatelessWidget {
  const _ReplaceRow({
    required this.enabled,
    required this.liveLabel,
    required this.onReplace,
  });

  final bool enabled;
  final String liveLabel;
  final VoidCallback onReplace;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The words go under the button where they do not fit beside it (the
    // page's panel is narrower than the sliding one).
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        WorkspaceOutlineButton(
          label: l10n.workspaceReplaceWithCurrent,
          icon: LucideIcons.refreshCw,
          shrink: true,
          onPressed: enabled ? onReplace : null,
        ),
        Text(
          liveLabel,
          style: TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 11,
            color: AppColors.v3TextTertiary,
          ),
        ),
      ],
    );
  }
}

// ── Delete section (two-step inline confirm) ───────────────────────

class _DeleteSection extends StatelessWidget {
  const _DeleteSection({
    required this.confirming,
    required this.onRequest,
    required this.onCancel,
    required this.onConfirm,
  });

  final bool confirming;
  final VoidCallback onRequest;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: confirming
          ? _confirmRow(l10n)
          : _triggerRow(l10n),
    );
  }

  Widget _triggerRow(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onRequest,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.trash2, size: 14, color: AppColors.v3Error),
                const SizedBox(width: 7),
                Text(
                  l10n.workspaceDeleteHeading,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.v3Error,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          l10n.workspaceDeleteHint,
          style: TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 11,
            height: 1.5,
            color: AppColors.v3TextTertiary,
          ),
        ),
      ],
    );
  }

  Widget _confirmRow(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.workspaceDeleteConfirmQuestion,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.v3TextPrimary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        WorkspaceOutlineButton(label: l10n.cancel, onPressed: onCancel),
        const SizedBox(width: 8),
        _DangerButton(label: l10n.delete, onPressed: onConfirm),
      ],
    );
  }
}

/// Small red filled confirm button for the inline delete step.
class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.v3Error,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Missing-workspace fallback body ────────────────────────────────

class _MissingBody extends StatelessWidget {
  const _MissingBody({required this.onClose, required this.message});

  final VoidCallback onClose;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13,
              color: AppColors.v3TextSecondary,
            ),
          ),
          const SizedBox(height: 16),
          WorkspaceOutlineButton(
            label: AppLocalizations.of(context)!.close,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
