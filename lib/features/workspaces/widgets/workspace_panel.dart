import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/hosts/widgets/host_panel.dart' show kHostPanelWidth;
import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_dialog_common.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_edit_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// A workspace's panel on the Hosts page, in the shape of the host panel (before,
/// a click on a card connected everything at
/// once, and editing it was a pop-up unlike the rest). Its name, when it was
/// last opened, its tabs and panes with their hosts' icons, and Open workspace
/// at the foot. Edit swaps the same place for the editor: rename, reorder, add
/// a host, replace with the current layout, delete with an undo.
class WorkspacePanel extends ConsumerStatefulWidget {
  const WorkspacePanel({
    super.key,
    required this.workspace,
    required this.onClose,
    required this.onOpen,
    this.startEditing = false,
  });

  final WorkspaceView workspace;
  final VoidCallback onClose;

  /// Open workspace: every pane it can.
  final VoidCallback onOpen;

  /// Opens on the editor (the card's pencil, a right click).
  final bool startEditing;

  @override
  ConsumerState<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends ConsumerState<WorkspacePanel> {
  late bool _editing = widget.startEditing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final w = widget.workspace;
    return Container(
      key: const ValueKey('workspace-panel'),
      width: kHostPanelWidth,
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(left: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: _editing
          ? WorkspaceEditDialog(
              key: ValueKey('workspace-panel-edit-${w.id}'),
              workspaceId: w.id,
              onDone: () {
                if (mounted) setState(() => _editing = false);
              },
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(l10n, w),
                Divider(height: 1, color: ZestColors.borderDefault),
                Expanded(child: _panes(l10n, w)),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: ZestColors.borderDefault)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: ZestButton(
                          key: const ValueKey('workspace-panel-open'),
                          label: l10n.workspacePanelOpen,
                          icon: LucideIcons.play,
                          variant: ZestButtonVariant.primary,
                          size: ZestButtonSize.large,
                          onPressed: widget.onOpen,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _header(AppLocalizations l10n, WorkspaceView w) {
    final isOpen = ref.watch(openWorkspaceIdProvider) == w.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isOpen ? ZestColors.accentPrimary.withValues(alpha: 0.10) : ZestColors.bgSurface,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              LucideIcons.layoutGrid,
              size: 18,
              color: isOpen ? ZestColors.accentInk : ZestColors.textTertiary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RedactedText(
                  Redactable.workspace(w.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  key: const ValueKey('workspace-panel-meta'),
                  '${workspaceCountLabel(l10n, w.tabCount, w.paneCount)} · ${workspaceOpenedLabel(l10n, w.lastOpened)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: ZestColors.textTertiary),
                ),
                if (isOpen) ...[
                  const SizedBox(height: 3),
                  Text(l10n.workspaceOpenNow, style: TextStyle(fontSize: 11.5, color: ZestColors.accentInk)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          ZestButton(
            key: const ValueKey('workspace-panel-edit'),
            label: l10n.edit,
            icon: LucideIcons.pencil,
            onPressed: () => setState(() => _editing = true),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('workspace-panel-close'),
            icon: const Icon(LucideIcons.x, size: 15),
            color: ZestColors.textTertiary,
            tooltip: l10n.sessionDetailsClosePanel,
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// Each tab with its panes, in the order the workspace opens them.
  Widget _panes(AppLocalizations l10n, WorkspaceView w) {
    final group = ref.read(savedTabGroupsProvider.notifier).byId(w.id);
    final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final byId = {for (final c in hosts) c.connection.id: c};
    var at = 0;
    final rows = <Widget>[];
    for (var t = 0; t < w.panePreview.length; t++) {
      final count = w.panePreview[t].paneColors.length;
      final name = group != null && t < group.tabs.length ? group.tabs[t].customName : null;
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: name == null || name.isEmpty
            ? Text(l10n.workspacePickTabNumber(t + 1), style: _tabStyle)
            : RedactedText(Redactable.freeText(name), maxLines: 1, overflow: TextOverflow.ellipsis, style: _tabStyle),
      ));
      for (var i = 0; i < count && at < w.memberHosts.length; i++, at++) {
        final member = w.memberHosts[at];
        final host = byId[member.id];
        rows.add(host == null
            // A host gone, or an empty place: what the row says of it, with no
            // host to draw.
            ? WorkspacePaneRow(
                key: ValueKey('workspace-panel-pane-$at'),
                host: member,
                leading: SizedBox(
                  width: 22,
                  height: 22,
                  child: Icon(LucideIcons.serverOff, size: 14, color: ZestColors.textTertiary),
                ),
                showDivider: i != count - 1,
              )
            : HostRow(
                key: ValueKey('workspace-panel-pane-$at'),
                host: host.connection,
                group: host.group,
                user: host.identity?.username,
                under: true,
                hovers: false,
              ));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ZestSectionHeader(label: l10n.workspacePanelTabsAndPanes),
        ),
        ...rows,
      ],
    );
  }

  TextStyle get _tabStyle => TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZestColors.textSecondary);
}
