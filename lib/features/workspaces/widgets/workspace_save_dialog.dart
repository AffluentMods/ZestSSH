import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_dialog_common.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';

/// Save the CURRENT layout as a workspace, or a layout of picked hosts.
///
/// Contract: `WorkspaceSaveDialog.show(context)` - saves what is open now, by
/// the choice at its top: This tab (the default: the tab in front, with its
/// splits), All tabs, or Choose tabs (a list by tab, each pane ticked or not);
/// `WorkspaceSaveDialog.show(context, hostIds: [...])` - saves those hosts
/// side by side (the Hosts page's Save as workspace, [workspaceOfHosts]),
/// whatever is open. Resolves true once something was saved.
///
/// A layout opened from a workspace also offers to update that workspace, with
/// the tabs that came from it as they are now, showing what that saves. What it
/// would lose of the workspace (a pane not open) is asked about, by name, never
/// dropped in silence.
///
/// Enforces the name-collision rule that produced two identically-named
/// workspaces: while the trimmed, case-insensitive name matches an existing
/// workspace, Save is disabled and the user is offered `Replace "<name>"`
/// (keeps that workspace's id / position / launch shortcut) or
/// `Save as "<name> N"` (first free integer). An empty name also disables Save.
class WorkspaceSaveDialog extends ConsumerStatefulWidget {
  const WorkspaceSaveDialog({super.key, this.hostIds});

  /// The hosts to save, in their order, instead of what is open now.
  final List<String>? hostIds;

  static Future<bool> show(BuildContext context, {List<String>? hostIds}) async {
    final dialog = GlobalKey<_WorkspaceSaveDialogState>();
    final saved = await showZestModal<bool>(
      context: context,
      size: ZestModalSize.compact,
      // Escape in the question about the panes not open goes back to the save,
      // as its Cancel does (it was a dialog over this one); elsewhere it closes.
      onDismissAttempt: () async => !(dialog.currentState?._backFromQuestion() ?? false),
      child: WorkspaceSaveDialog(key: dialog, hostIds: hostIds),
    );
    return saved == true;
  }

  @override
  ConsumerState<WorkspaceSaveDialog> createState() =>
      _WorkspaceSaveDialogState();
}

class _WorkspaceSaveDialogState extends ConsumerState<WorkspaceSaveDialog> {
  final _nameController = TextEditingController();

  /// The choice made at the top; null until one is, which is This tab with a
  /// tab in front and All tabs without.
  WorkspaceSaveScope? _pickedScope;

  /// The panes ticked under Choose tabs, by their leaf ids. Null until it is
  /// first chosen: then it starts from the tab in front.
  Set<String>? _ticked;

  /// Update asked what becomes of the saved panes that are not open: the
  /// question, in this dialog's place (3.4: it was a dialog over this one).
  ({WorkspaceView view, WorkspaceUpdatePlan plan})? _question;

  /// Back from the question to the save; false where it was not asked.
  bool _backFromQuestion() {
    if (_question == null) return false;
    setState(() => _question = null);
    return true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  WorkTab? get _tabInFront {
    final tab = ref.read(workTabsProvider).activeTab;
    return tab == null || tab.pendingClose ? null : tab;
  }

  WorkspaceSaveScope get _scope =>
      _pickedScope ?? (_tabInFront == null ? WorkspaceSaveScope.allTabs : WorkspaceSaveScope.thisTab);

  /// What Save would keep: the chosen hosts, or the panes of the choice at the
  /// top. Null when that is nothing.
  WorkspaceCapture? _capture() {
    final notifier = ref.read(savedTabGroupsProvider.notifier);
    final tabs = ref.read(workTabsProvider).tabs;
    return switch (_scope) {
      WorkspaceSaveScope.thisTab => _tabInFront == null ? null : notifier.captureTabs([_tabInFront!]),
      WorkspaceSaveScope.allTabs => notifier.captureTabs(tabs),
      WorkspaceSaveScope.chosen => notifier.captureTabs(tabs, keep: _ticked ?? const {}),
    };
  }

  void _pickScope(WorkspaceSaveScope scope) {
    setState(() {
      _pickedScope = scope;
      if (scope == WorkspaceSaveScope.chosen && _ticked == null) {
        // It starts from the tab in front, or from everything without one.
        final front = _tabInFront;
        _ticked = {
          for (final tab in ref.read(openTabsForSaveProvider))
            if (front == null || tab.id == front.id) ...tab.saveable.map((p) => p.leafId),
        };
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hostIds = widget.hostIds;
    // What it shows follows what is open as well as the choice.
    ref.watch(workTabsProvider);
    final openTabs = ref.watch(openTabsForSaveProvider);
    final captured = hostIds == null ? _capture() : null;
    final preview = hostIds == null
        ? (captured == null ? null : workspaceViewOfCapture(ref, captured))
        : workspaceViewOfHosts(ref, hostIds);
    final workspaces = ref.watch(workspacesProvider);
    final notifier = ref.read(savedTabGroupsProvider.notifier);
    // A layout opened from a workspace: that workspace, to update it. With
    // nothing open that a workspace can keep, there is nothing to update it
    // with, and no button that would do nothing.
    final openedId = hostIds == null ? ref.watch(openWorkspaceIdProvider) : null;
    final updatePlan = openedId == null ? null : workspaceUpdatePlan(ref, openedId);
    final openedView = updatePlan == null ? null : workspaces.where((w) => w.id == openedId).firstOrNull;

    final trimmed = _nameController.text.trim();
    final collidedGroup =
        trimmed.isEmpty ? null : notifier.workspaceByName(trimmed);
    WorkspaceView? collided;
    if (collidedGroup != null) {
      for (final w in workspaces) {
        if (w.id == collidedGroup.id) {
          collided = w;
          break;
        }
      }
    }

    final canSave =
        preview != null && trimmed.isNotEmpty && collidedGroup == null;

    final question = _question;
    if (question != null) return _questionShell(l10n, question);

    // The footer acts (3.4: Replace, Save as and Update were buttons in the
    // body): a name taken is Replace it, in red, or Save as the next free
    // name, the side option; else Save, with Update the side option where
    // the tabs came from a workspace.
    final saveAsName = collided == null ? null : notifier.nextAvailableName(trimmed);
    final ({String label, VoidCallback? onPressed})? side = saveAsName != null
        ? (
            label: l10n.workspaceSaveAsNamed(Redactable.workspace(saveAsName).displayIn(ref)),
            onPressed: () => _saveAs(saveAsName),
          )
        : openedView != null
            ? (
                label: l10n.workspaceUpdateNamed(Redactable.workspace(openedView.name).display),
                onPressed: () => _update(openedView),
              )
            : null;

    // Enter commits via the autofocused name field's onSubmit (guarded by
    // canSave); Escape closes it (the modal's). Binding Enter to the modal too
    // would double-fire.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.layoutGrid,
      title: l10n.workspaceSaveTitle,
      subtitle: l10n.workspaceSaveSubtitle,
      onClose: _cancel,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
        if (hostIds == null) ...[
          // On one line in any language: smaller, where long words need it.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: ZestModeToggle(
              key: const ValueKey('workspace-scope'),
              segments: [
                ZestModeSegment(
                  id: WorkspaceSaveScope.thisTab.name,
                  label: l10n.workspaceScopeThisTab,
                  enabled: _tabInFront != null,
                  disabledReason: l10n.workspaceScopeNoTab,
                ),
                ZestModeSegment(id: WorkspaceSaveScope.allTabs.name, label: l10n.workspaceScopeAllTabs),
                ZestModeSegment(id: WorkspaceSaveScope.chosen.name, label: l10n.workspaceScopeChoose),
              ],
              selectedId: _scope.name,
              onChanged: (id) => _pickScope(WorkspaceSaveScope.values.byName(id)),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (openedView != null) ...[
          _UpdateOffer(plan: updatePlan!),
          const SizedBox(height: 14),
        ],
        WorkspaceNameField(
          controller: _nameController,
          label: l10n.workspaceNameLabel,
          hintText: l10n.workspaceNameHint,
          autofocus: true,
          warn: collided != null,
          onChanged: (_) => setState(() {}),
          onSubmit: canSave ? _save : null,
        ),
        if (collided != null) ...[
          const SizedBox(height: 12),
          WorkspaceCollisionCallout(existing: collided),
        ],
        const SizedBox(height: 14),
        if (hostIds == null && _scope == WorkspaceSaveScope.chosen) ...[
          _TabPanePicker(
            tabs: openTabs,
            ticked: _ticked ?? const {},
            onChanged: (ticked) => setState(() => _ticked = ticked),
          ),
          const SizedBox(height: 12),
        ],
        if (preview == null)
          const _NothingOpen()
        else
          _PreviewBox(
            view: preview,
            tag: l10n.workspacePreviewSaving,
            // Under Choose tabs the list above names every pane.
            strip: hostIds == null && _scope == WorkspaceSaveScope.chosen,
          ),
        const SizedBox(height: 12),
        Text(
          l10n.workspaceSaveReferencedNote,
          style: TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 11.5,
            height: 1.5,
            color: AppColors.v3TextTertiary,
          ),
        ),
        ],
      ),
      tertiaryKey: ValueKey(saveAsName != null ? 'workspace-save-as' : 'workspace-update'),
      tertiaryAction: side,
      secondaryAction: (label: l10n.cancel, onPressed: _cancel),
      primaryKey: ValueKey(collided != null ? 'workspace-replace' : 'workspace-save'),
      primaryDanger: collided != null,
      primaryAction: collided != null
          ? (
              label: l10n.workspaceReplaceNamed(Redactable.workspace(collided.name).displayIn(ref)),
              icon: null,
              onPressed: () => _replace(collided!.id, collided.name),
            )
          : (label: l10n.save, icon: null, onPressed: canSave ? _save : null),
    );
  }

  /// The question Update asks where saved panes are not open, named, in this
  /// dialog's place: Keep them, Remove them, or Cancel, back to the save.
  Widget _questionShell(AppLocalizations l10n, ({WorkspaceView view, WorkspaceUpdatePlan plan}) question) {
    final hosts = ref.read(hostsByIdProvider);
    final notOpen = question.plan.notOpen;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.layoutGrid,
      title: l10n.workspaceUpdateNotOpenTitle,
      subtitle: l10n.workspaceUpdateNotOpenBody,
      onClose: _backFromQuestion,
      // The keyboard stays in the dialog as it changes (the name's field,
      // which had it, is gone): Escape is the question's, back to the save.
      body: Focus(
        autofocus: true,
        child: Column(
          key: const ValueKey('workspace-update-not-open-list'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, host) in notOpen.indexed)
              WorkspacePaneRow(
                host: host,
                leading: hosts[host.id] == null ? null : HostGlyph(host: hosts[host.id]!.connection, size: 18),
                showDivider: i != notOpen.length - 1,
              ),
          ],
        ),
      ),
      tertiaryKey: const ValueKey('workspace-update-cancel'),
      tertiaryAction: (label: l10n.cancel, onPressed: _backFromQuestion),
      secondaryKey: const ValueKey('workspace-update-remove'),
      secondaryAction: (
        label: l10n.workspaceUpdateRemove,
        onPressed: () => _writeUpdate(question.view, question.plan.removing),
      ),
      primaryKey: const ValueKey('workspace-update-keep'),
      primaryAction: (
        label: l10n.workspaceUpdateKeep,
        icon: null,
        onPressed: () => _writeUpdate(question.view, question.plan.keeping),
      ),
    );
  }

  void _cancel() => Navigator.of(context).pop(false);

  /// Saves a new workspace named [name]: the picked hosts, or the panes of the
  /// choice at the top.
  String? _saveNew(String name) {
    final hostIds = widget.hostIds;
    if (hostIds != null) return saveHostsAsWorkspace(ref, name, hostIds);
    final captured = _capture();
    return captured == null ? null : ref.read(savedTabGroupsProvider.notifier).saveCaptured(name, captured);
  }

  /// Update: the tabs that came from the workspace [view], as they are now, go
  /// back into it (save back without picking again). Where that would lose a
  /// saved pane that is not open, the person says what becomes of it first,
  /// in this dialog's place.
  void _update(WorkspaceView view) {
    final plan = workspaceUpdatePlan(ref, view.id);
    if (plan == null) return;
    if (plan.notOpen.isNotEmpty) {
      setState(() => _question = (view: view, plan: plan));
      return;
    }
    _writeUpdate(view, plan.open);
  }

  /// Saves [saving] into the workspace [view], says so and closes.
  void _writeUpdate(WorkspaceView view, WorkspaceCapture saving) {
    final l10n = AppLocalizations.of(context)!;
    if (!ref.read(savedTabGroupsProvider.notifier).replaceWithCaptured(view.id, saving)) return;
    showTopSnackBar(
      context,
      l10n.workspaceUpdatedToast(Redactable.workspace(view.name).display),
      isSuccess: true,
    );
    Navigator.of(context).pop(true);
  }

  void _save() {
    final l10n = AppLocalizations.of(context)!;
    final trimmed = _nameController.text.trim();
    final notifier = ref.read(savedTabGroupsProvider.notifier);
    if (trimmed.isEmpty || notifier.workspaceByName(trimmed) != null) return;
    final id = _saveNew(trimmed);
    if (id == null) return;
    showTopSnackBar(
      context,
      l10n.workspaceSavedToast(Redactable.workspace(trimmed).display),
      isSuccess: true,
    );
    Navigator.of(context).pop(true);
  }

  void _saveAs(String freeName) {
    final l10n = AppLocalizations.of(context)!;
    final id = _saveNew(freeName);
    if (id == null) return;
    showTopSnackBar(
      context,
      l10n.workspaceSavedToast(Redactable.workspace(freeName).display),
      isSuccess: true,
    );
    Navigator.of(context).pop(true);
  }

  void _replace(String existingId, String existingName) {
    final l10n = AppLocalizations.of(context)!;
    final hostIds = widget.hostIds;
    final captured = hostIds == null ? _capture() : null;
    final ok = hostIds == null
        ? captured != null && ref.read(savedTabGroupsProvider.notifier).replaceWithCaptured(existingId, captured)
        : replaceWorkspaceWithHosts(ref, existingId, hostIds);
    if (!ok) return;
    showTopSnackBar(
      context,
      l10n.workspaceReplacedToast(Redactable.workspace(existingName).display),
      isSuccess: true,
    );
    Navigator.of(context).pop(true);
  }
}

// ── Preview box ────────────────────────────────────────────────────

class _PreviewBox extends ConsumerWidget {
  const _PreviewBox({super.key, required this.view, required this.tag, this.strip = false});

  final WorkspaceView view;
  final String tag;

  /// Its head alone, with the thumbnail and the counts.
  final bool strip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final paneColors = view.memberHosts.map((h) => h.resolvedColor).toList();
    final hosts = ref.watch(hostsByIdProvider);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            child: Row(
              children: [
                WorkspaceThumbnail(paneColors: paneColors),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tag.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.9,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  workspaceCountLabel(l10n, view.tabCount, view.paneCount),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10.5,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (!strip) ...[
            Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle),
            for (var i = 0; i < view.memberHosts.length; i++)
              WorkspacePaneRow(
                host: view.memberHosts[i],
                leading: hosts[view.memberHosts[i].id] == null
                    ? null
                    : HostGlyph(host: hosts[view.memberHosts[i].id]!.connection, size: 18),
                showDivider: i != view.memberHosts.length - 1,
              ),
          ],
        ],
      ),
    );
  }
}

/// "This layout was opened from it": the workspace, what Update saves into it,
/// what is not open of it, and the way to save its tabs back into it.
class _UpdateOffer extends ConsumerWidget {
  const _UpdateOffer({required this.plan});

  final WorkspaceUpdatePlan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final said = TextStyle(fontFamily: 'GeistSans', fontSize: 11.5, height: 1.4, color: AppColors.v3TextSecondary);
    return Container(
      key: const ValueKey('workspace-update-offer'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.workspaceUpdateBody, style: said),
          const SizedBox(height: 8),
          _PreviewBox(
            key: const ValueKey('workspace-update-preview'),
            view: workspaceViewOfCapture(ref, plan.open),
            tag: l10n.workspaceUpdateSaves,
          ),
          if (plan.notOpen.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              l10n.workspaceUpdateNotOpen(
                plan.notOpen.map((h) => workspaceMemberLabel(l10n, h).displayIn(ref)).join(', '),
              ),
              key: const ValueKey('workspace-update-not-open'),
              style: said,
            ),
          ],
        ],
      ),
    );
  }
}

/// Choose tabs: a list by tab, the tab's box ticking its panes, each pane with
/// its own, and quick ways to tick all, none, or a group's panes.
class _TabPanePicker extends ConsumerWidget {
  const _TabPanePicker({required this.tabs, required this.ticked, required this.onChanged});

  final List<WorkspaceSaveTab> tabs;
  final Set<String> ticked;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final all = {for (final t in tabs) ...t.saveable.map((p) => p.leafId)};
    // The groups the panes open are in, each with its panes, in the order met.
    final groups = <String, ({String name, Set<String> panes})>{};
    for (final t in tabs) {
      for (final p in t.saveable) {
        final id = p.groupId;
        if (id == null) continue;
        groups.putIfAbsent(id, () => (name: p.groupName ?? '', panes: <String>{})).panes.add(p.leafId);
      }
    }
    return Container(
      key: const ValueKey('workspace-pane-picker'),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _QuickPick(key: const ValueKey('workspace-pick-all'), label: l10n.workspacePickAll, onTap: () => onChanged(all)),
                _QuickPick(key: const ValueKey('workspace-pick-none'), label: l10n.workspacePickNone, onTap: () => onChanged(const {})),
                if (groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, right: 2),
                    child: Text(
                      l10n.workspacePickByGroup,
                      style: TextStyle(fontFamily: 'GeistSans', fontSize: 11, color: AppColors.v3TextTertiary),
                    ),
                  ),
                for (final e in groups.entries)
                  _QuickPick(
                    key: ValueKey('workspace-pick-group-${e.key}'),
                    label: '${Redactable.group(e.value.name).displayIn(ref)} (${e.value.panes.length})',
                    active: ticked.containsAll(e.value.panes),
                    // A tap ticks the group's panes; again, it unticks them.
                    onTap: () => onChanged(ticked.containsAll(e.value.panes)
                        ? ticked.difference(e.value.panes)
                        : ticked.union(e.value.panes)),
                  ),
              ],
            ),
          ),
          for (var i = 0; i < tabs.length; i++) ...[
            Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle),
            _tabRow(l10n, tabs[i], i),
            for (final p in tabs[i].panes) _paneRow(l10n, ref, p),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _tabRow(AppLocalizations l10n, WorkspaceSaveTab tab, int index) {
    final panes = tab.saveable.map((p) => p.leafId).toSet();
    final some = panes.intersection(ticked).isNotEmpty;
    final every = panes.isNotEmpty && ticked.containsAll(panes);
    final name = tab.customName;
    return _PickRow(
      key: ValueKey('workspace-pick-tab-${tab.id}'),
      value: every ? true : (some ? null : false),
      onTap: panes.isEmpty ? null : () => onChanged(every ? ticked.difference(panes) : ticked.union(panes)),
      child: Row(
        children: [
          Flexible(
            child: name == null || name.isEmpty
                ? Text(
                    l10n.workspacePickTabNumber(index + 1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _tabStyle,
                  )
                : RedactedText(
                    Redactable.freeText(name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _tabStyle,
                  ),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.workspacePaneCountLabel(tab.panes.length),
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, color: AppColors.v3TextTertiary),
          ),
        ],
      ),
    );
  }

  TextStyle get _tabStyle =>
      TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.v3TextSecondary);

  Widget _paneRow(AppLocalizations l10n, WidgetRef ref, WorkspaceSavePane pane) {
    final host = pane.host;
    return _PickRow(
      key: ValueKey('workspace-pick-pane-${pane.leafId}'),
      indent: 22,
      value: ticked.contains(pane.leafId),
      // A pane with no saved host has nothing for a workspace to keep.
      onTap: host == null
          ? null
          : () => onChanged(ticked.contains(pane.leafId)
              ? ticked.difference({pane.leafId})
              : ticked.union({pane.leafId})),
      child: Row(
        children: [
          if (host != null) ...[
            HostGlyph(host: host.connection, group: host.group, size: 18),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: RedactedText(
              Redactable.host(host?.connection.label ?? pane.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12.5,
                color: host == null ? AppColors.v3TextTertiary : AppColors.v3TextPrimary,
              ),
            ),
          ),
          if (pane.isSftp) ...[
            const SizedBox(width: 6),
            Text(l10n.pillSftp, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: AppColors.v3TextTertiary)),
          ],
          if (host == null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.workspacePickNotSaved,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'GeistSans', fontSize: 11, color: AppColors.v3TextTertiary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A row of the picker with its box: the whole row is the target. A null
/// [value] is the mark of a tab with some of its panes ticked.
class _PickRow extends StatelessWidget {
  const _PickRow({super.key, required this.value, required this.onTap, required this.child, this.indent = 0});

  final bool? value;
  final VoidCallback? onTap;
  final Widget child;
  final double indent;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(11 + indent, 7, 11, 7),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: Checkbox(
                  value: value,
                  tristate: true,
                  onChanged: onTap == null ? null : (_) => onTap!(),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeColor: AppColors.brandOrange,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// Select all, Select none, a group's panes: small words in an outline, lit
/// where all of what they tick is ticked.
class _QuickPick extends StatelessWidget {
  const _QuickPick({super.key, required this.label, required this.onTap, this.active = false});

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: active ? AppColors.v3AccentPrimary.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? AppColors.v3AccentPrimary : AppColors.v3BorderSubtle),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 11.5,
              color: active ? AppColors.v3AccentInk : AppColors.v3TextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _NothingOpen extends StatelessWidget {
  const _NothingOpen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: AppColors.v3BorderSubtle,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        children: [
          Text(
            l10n.workspaceSaveEmptyTitle,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.v3TextSecondary,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            l10n.workspaceSaveEmptyHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 11.5,
              height: 1.5,
              color: AppColors.v3TextTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
