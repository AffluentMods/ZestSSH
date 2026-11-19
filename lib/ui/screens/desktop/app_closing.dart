import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/providers/workspace_providers.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/multi_window_service.dart';
import 'package:zestssh/services/session_persistence_service.dart';
import 'package:zestssh/services/window_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/utils/logger.dart';

/// The longest the open tabs are waited for as the app closes: they are saved
/// into the app's database, where a sync's writes come first (19 October
/// 2026: closing sometimes took about ten seconds with nothing on screen, and
/// looked like a freeze).
const kClosingSaveLimit = Duration(seconds: 3);

/// The longest the other windows (a session popped out) are waited for: one
/// that did not answer was waited for without end.
const kClosingWindowsLimit = Duration(seconds: 2);

/// One step of closing the app on a computer: its words while it runs, its
/// work, and the longest it is waited for (none: it keeps a limit of its own).
class ClosingStep {
  const ClosingStep(this.name, this.work, {this.limit});

  final String name;
  final FutureOr<void> Function() work;
  final Duration? limit;
}

/// Closes the app step by step, saying each step in [step] while it runs (the
/// shell shows it, [ClosingPanel]). A step that does not finish within its
/// limit, or fails, is left and the next one runs: the app always closes.
Future<void> runClosingSteps(ValueNotifier<String?> step, List<ClosingStep> steps) async {
  for (final s in steps) {
    step.value = s.name;
    try {
      final done = Future<void>.sync(s.work);
      final limit = s.limit;
      await (limit == null ? done : done.timeout(limit));
    } catch (_) {
      // Left behind: the app closes anyway.
    }
  }
}

/// The open tabs saved for the next start, after the question (it was
/// before it: a close answered no saved them for nothing).
Future<void> saveOpenTabs(WidgetRef ref, Map<String, SessionState> sessions) async {
  // Save sessions for restoration. Two persistence layers:
  //  1) Group-aware: walk WorkTabs and snapshot each tab's pane tree
  //     (with connection ids in place of session ids). This preserves
  //     groups, splits, and duplicates of the same connection within
  //     the same tab.
  //  2) Legacy flat list: kept as a fallback for users with the old
  //     persisted format on disk and for code paths that still consume
  //     it. Both are cleared on a successful group-aware restore.
  final prefs = ref.read(sharedPreferencesProvider);
  final persistence = SessionPersistenceService(
      prefs, ref.read(localStateStoreProvider));
  // An X program's tab (4.0) is not brought back: its program ended
  // with the app, and its host's id would open the host's terminal instead.
  // Nor is a Proxmox console's: it is a session of its machine's own host,
  // and that id would open an SSH terminal to the machine.
  final notifier = ref.read(activeSessionsProvider.notifier);
  bool xProgram(String sessionId) => notifier.isXProgram(sessionId) || notifier.isConsole(sessionId);

  // (1) Group-aware tab snapshots.
  final workTabsState = ref.read(workTabsProvider);
  final panePaths = ref.read(sftpPanePathsProvider);
  final tabSnapshots = <TabSnapshot>[];
  for (final tab in workTabsState.tabs) {
    final snapTree = mapPaneTreeIds(tab.paneTree, (sid) {
      final s = sessions[sid];
      if (s == null || s.connectionId == null || xProgram(sid)) return null;
      // Only persist connections in connected state - connecting/error
      // sessions get dropped from the snapshot.
      if (s.status != SessionStatus.connected) return null;
      return s.connectionId;
    }, keepIds: true);
    if (snapTree == null) continue;
    tabSnapshots.add(TabSnapshot(
      customName: tab.customName,
      colorIndex: tab.colorIndex,
      paneTreeOfConnIds: snapTree,
      // Where every SFTP pane was (remember-last-folder spec): this is
      // what makes "reopen SFTP panes exactly as you left them" true.
      panePaths: collectPanePaths(tab.paneTree, (sid) => panePaths[sid]),
    ));
  }
  final activeTabIndex = workTabsState.activeTabId == null
      ? null
      : workTabsState.indexOf(workTabsState.activeTabId!);
  await persistence.saveTabSnapshots(
    tabSnapshots,
    activeTabIndex: (activeTabIndex != null && activeTabIndex >= 0)
        ? activeTabIndex
        : null,
  );

  // (2) Legacy flat list - still useful for users without WorkTab data.
  final toSave = sessions.entries
      .where((e) =>
          e.value.status == SessionStatus.connected &&
          e.value.connectionId != null &&
          !xProgram(e.key))
      .map((e) => PersistedSession(
            connectionId: e.value.connectionId!,
            label: e.value.connectionLabel,
            host: '',
            port: 22,
            username: '',
          ))
      .toList();
  await persistence.saveOpenSessions(toSave);
}

/// Held remote deletes made as the app quits, with a hard 5s limit so a stalled
/// server can never hang the quit (delete safety spec §3). What does not finish
/// is noted for a notice at the next start, and is never tried again unasked.
Future<void> commitHeldDeletes(WidgetRef ref) async {
  final failures = await ref.read(sftpDeleteHoldProvider).commitAllReporting(const Duration(seconds: 5));
  if (failures.isEmpty) return;
  final prefs = ref.read(sharedPreferencesProvider);
  final byHost = <String, int>{};
  for (final f in failures) {
    byHost[f.hostLabel] = (byHost[f.hostLabel] ?? 0) + f.count;
  }
  final existing = prefs.getStringList('sftp_delete_failures') ?? [];
  await prefs.setStringList('sftp_delete_failures', [
    ...existing,
    for (final e in byHost.entries) '${e.value}|${e.key}',
  ]);
}

/// Closes the app from where the shell is not: the lock screen, after the app
/// locked or where it started locked (the shell goes with the lock). It ends as
/// the shell ends it (close-to-tray, the question where sessions are open, the
/// tabs saved, the other windows closed, held deletes made, the sessions ended),
/// and whatever fails is left: the window goes all the same. With the app locked
/// nothing else is asked or shown, and the question says only how many sessions.
/// [quit] is the tray's Quit, which goes straight on as it does in the shell.
Future<void> closeWithoutShell(
  WidgetRef ref, {
  required ValueNotifier<String?> step,
  required AppLocalizations l10n,
  required BuildContext? Function() question,
  bool quit = false,
  Future<void> Function() hide = _hideWindow,
  Future<void> Function() destroy = destroyAppWindow,
  Future<bool> Function(BuildContext context, int count) ask = confirmCloseWithSessions,
}) async {
  try {
    if (!quit && ref.read(desktopMinimizeToTrayProvider)) {
      try {
        await hide();
        return;
      } catch (e) {
        // Close for real, so that a broken hide can still be closed.
        AppLogger.warning('Hide-to-tray failed: $e');
      }
    }
    final sessions = ref.read(activeSessionsProvider);
    final open = openSessionCount(sessions);
    if (!quit && open > 0 && ref.read(desktopConfirmCloseWithSessionsProvider)) {
      final context = question();
      if (context != null && context.mounted && !await ask(context, open)) return;
    }
    await runClosingSteps(step, [
      if (open > 0)
        ClosingStep(l10n.desktopClosingSaving, () async {
          await saveOpenTabs(ref, sessions);
          await autoSaveLastSession(ref);
        }, limit: kClosingSaveLimit),
      ClosingStep(l10n.desktopClosingWindows, MultiWindowService.instance.closeAllWindows, limit: kClosingWindowsLimit),
      ClosingStep(l10n.desktopClosingSessions, () => commitHeldDeletes(ref)),
      ClosingStep(l10n.desktopClosingSessions, () async {
        unawaited(ref.read(activeSessionsProvider.notifier).endAllSessions());
      }),
    ]);
  } catch (e) {
    AppLogger.warning('Closing without the shell: $e');
  }
  await destroy();
}

Future<void> _hideWindow() => windowManager.hide();

/// While the app closes, over the whole window: that it is closing and the
/// step it is at, so a close that takes a few seconds is not taken for a
/// freeze. Nothing while [step] is null.
class ClosingPanel extends StatelessWidget {
  const ClosingPanel({super.key, required this.step});

  final ValueListenable<String?> step;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: step,
      builder: (context, now, _) {
        if (now == null) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context)!;
        return AbsorbPointer(
          key: const ValueKey('app-closing'),
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.55),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 360),
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.fromLTRB(20, 18, 24, 18),
                decoration: BoxDecoration(
                  color: AppColors.v3Surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.v3BorderSubtle),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.accentInk),
                    ),
                    const SizedBox(width: 16),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.desktopClosingTitle,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            now,
                            key: const ValueKey('app-closing-step'),
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
