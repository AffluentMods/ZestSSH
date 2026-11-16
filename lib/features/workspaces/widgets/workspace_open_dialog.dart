import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_dialog_common.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_launch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The command palette's Load workspace (3.0 docs check):
/// the saved workspaces the Hosts page shows, from the one store they are
/// kept in ([workspacesProvider]), each opened by a click as a card of the
/// Hosts page opens it ([launchWorkspaceFromSurface]). The palette had a
/// store of its own, in plain preferences, that nothing else showed.
/// With none saved, it says so.
Future<void> showWorkspaceOpenDialog(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final workspaces = ref.read(workspacesProvider);
  if (workspaces.isEmpty) {
    return ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.desktopShellLoadWorkspace,
      body: l10n.desktopShellNoSavedWorkspaces,
      confirmLabel: l10n.desktopGotIt,
      showCancel: false,
    ).then((_) {});
  }
  // The app's context, still there when the dialog has closed.
  final appContext = Navigator.of(context, rootNavigator: true).context;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.layoutGrid,
    title: l10n.desktopShellLoadWorkspace,
    subtitle: l10n.docCheckWorkspaceOpenSubtitle,
    body: _WorkspaceList(
      onOpen: (id) {
        Navigator.of(appContext).pop();
        launchWorkspaceFromSurface(appContext, ref, id);
      },
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(appContext).pop()),
  );
}

/// "Add this tab to a workspace" from a tab's right-click menu:
/// the tab [tabId] joins the workspace picked,
/// after its other tabs, and that is said; a tab with no pane of a saved host
/// says why it cannot.
Future<void> showAddTabToWorkspaceDialog(BuildContext context, WidgetRef ref, String tabId) {
  final l10n = AppLocalizations.of(context)!;
  final appContext = Navigator.of(context, rootNavigator: true).context;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.layoutGrid,
    title: l10n.pillAddTabToWorkspace,
    subtitle: l10n.workspaceAddTabSubtitle,
    body: _WorkspaceList(
      onOpen: (id) {
        Navigator.of(appContext).pop();
        final name = ref.read(workspacesProvider).where((w) => w.id == id).firstOrNull?.name ?? '';
        final added = ref.read(savedTabGroupsProvider.notifier).addTabToWorkspace(id, tabId);
        showTopSnackBar(
          appContext,
          added ? l10n.workspaceAddedTabToast(Redactable.workspace(name).display) : l10n.workspaceAddTabNoHost,
          isSuccess: added,
          isWarning: !added,
        );
      },
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(appContext).pop()),
  );
}

class _WorkspaceList extends ConsumerWidget {
  const _WorkspaceList({required this.onOpen});

  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspaces = ref.watch(workspacesProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final w in workspaces) _WorkspaceRow(key: ValueKey('workspace-open-${w.id}'), workspace: w, onOpen: onOpen),
      ],
    );
  }
}

class _WorkspaceRow extends StatefulWidget {
  const _WorkspaceRow({super.key, required this.workspace, required this.onOpen});

  final WorkspaceView workspace;
  final ValueChanged<String> onOpen;

  @override
  State<_WorkspaceRow> createState() => _WorkspaceRowState();
}

class _WorkspaceRowState extends State<_WorkspaceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final w = widget.workspace;
    final colors = [for (final p in w.panePreview) ...p.paneColors];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onOpen(w.id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _hover ? AppColors.v3Elevated : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.layoutGrid, size: 16, color: AppColors.v3TextSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(
                        Redactable.workspace(w.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${workspaceCountLabel(l10n, w.tabCount, w.paneCount)} · ${workspaceOpenedLabel(l10n, w.lastOpened)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                WorkspaceThumbnail(paneColors: colors),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
