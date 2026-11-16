import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/utils/foreground_ticker.dart';
import 'package:zestssh/ui/screens/editor/editor_workspace.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart' show showEditorTabs;
import 'package:zestssh/ui/screens/editor/widgets/editor_chrome.dart' show EditorMinimizedChip;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/core/latency_format.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/ui/screens/sync/sync_failing_text.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/update_check_now.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/network_providers.dart' show effectiveNetworkProvider;
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/cloud_reach_banner.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/utils/number_in_phrase.dart';

/// Bottom status bar.
///
/// LEFT:  sessions and their dots │ online │ sync │ recording
/// RIGHT: user@host │ 02:34:15 │ latency │ UTF-8 │ font
class DesktopStatusBar extends ConsumerStatefulWidget {
  const DesktopStatusBar({super.key});

  @override
  ConsumerState<DesktopStatusBar> createState() => _DesktopStatusBarState();
}

class _DesktopStatusBarState extends ConsumerState<DesktopStatusBar> {
  ForegroundTicker? _durationTimer;

  /// Whether the bar ticks: once a second while it shows something that
  /// counts (a session's time, the sync vault's minutes left) and the window
  /// is not minimised ([ForegroundTicker]), and not at all otherwise. It
  /// ticked for as long as the window lived, with no session open and
  /// minimised, one wake and one frame a second (found in a code audit).
  @visibleForTesting
  bool get ticking => _durationTimer?.ticking ?? false;

  void _tickWhile(bool counting) {
    if (counting) {
      _durationTimer ??= ForegroundTicker(const Duration(seconds: 1), () {
        if (mounted) setState(() {});
      });
    } else {
      _durationTimer?.dispose();
      _durationTimer = null;
    }
  }

  @override
  void dispose() {
    _durationTimer?.dispose();
    super.dispose();
  }

  /// Whole minutes left on the sync vault, ceil'd so a fresh 30-min session
  /// reads "30m" and never shows 0 while still unlocked. The bar's existing
  /// 1-second tick drives the countdown.
  int _vaultRemainingMinutes(VaultSessionState s) {
    final r = s.remaining;
    if (r == null) return 0;
    final mins = (r.inSeconds / 60).ceil();
    return mins < 1 ? 1 : mins;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final vaultSession = ref.watch(vaultSessionProvider);
    final sessions = ref.watch(activeSessionsProvider);
    final activeSessions = sessions.entries
        .where((e) =>
            e.value.status == SessionStatus.connected ||
            e.value.status == SessionStatus.connecting)
        .toList();
    final activeCount = activeSessions.length;
    final fontSize = ref.watch(terminalFontSizeProvider);
    final fontFamily = ref.watch(terminalFontFamilyProvider);

    // In the file browser the terminal-context readouts - host, duration,
    // latency, UTF-8, font - mean nothing, and latency already lives in the
    // SFTP picker. So the whole terminal group drops out here, leaving the
    // strip with only the global left-side readouts.
    // SFTP is "in view" as the FOCUSED pane in the tree (an SFTP browser
    // docked from a terminal). It drops the terminal chrome
    // (host / latency / UTF-8 / font): it means nothing in a file browser and
    // only duplicates the rail picker's latency.
    var viewingSftp = false;
    final tree = ref.watch(paneTreeProvider);
    final focusedLeafId = ref.watch(focusedPaneProvider);
    if (tree != null && focusedLeafId != null) {
      viewingSftp = tree.findLeaf(focusedLeafId)?.type == 'sftp';
    }

    // Resolve the FOCUSED session, not merely the selected tab index.
    //
    // Previously this indexed activeSessions by desktopSelectedTabProvider (a
    // tab index), so the address + timer (a) never tracked focus changes
    // between panes within a split layout, and (b) kept showing a stale
    // session after the user navigated to a non-session view. Now: with no
    // active work tab (a non-session view) the fields clear; otherwise we
    // prefer the FOCUSED pane's session, falling back to the selected tab for
    // the single-pane view where there is no pane tree.
    final selectedTab = ref.watch(desktopSelectedTabProvider);
    String? currentSessionId;
    final activeTab = ref.watch(workTabsProvider).activeTab;
    if (activeTab != null) {
      final tree = ref.watch(paneTreeProvider);
      final focusedLeafId = ref.watch(focusedPaneProvider);
      if (tree != null && focusedLeafId != null) {
        final sid = tree.findLeaf(focusedLeafId)?.sessionIdOrNull;
        if (sid != null && sessions.containsKey(sid)) {
          currentSessionId = sid;
        }
      }
      // The session of the tab in front, by its id: the selected index
      // counts every session that is not hidden, so read against the
      // connected ones it named a neighbour as soon as one of them had
      // dropped (a screen tab in front said the SSH tab's user and address).
      final frontId = ref.watch(v3ActiveSessionTabProvider);
      if (currentSessionId == null && frontId != null && sessions.containsKey(frontId)) {
        currentSessionId = frontId;
      }
      if (currentSessionId == null &&
          activeSessions.isNotEmpty &&
          selectedTab < activeSessions.length) {
        currentSessionId = activeSessions[selectedTab].key;
      }
    }
    final currentSession =
        currentSessionId == null ? null : sessions[currentSessionId];
    // A remote screen in front (4.0): its address and port and no user, and
    // none of a terminal's readouts (the encoding, the font).
    final viewingScreen = currentSessionId != null &&
        ref.read(activeSessionsProvider.notifier).isScreen(currentSessionId);

    // The latency of the session in front: the round trip on its own
    // connection (wireReachabilityChecks), which is what is kept for a host a
    // session is connected to.
    final healthMap = ref.watch(connectionHealthProvider);
    final connId = currentSession?.connectionId;
    final currentLatencyMs = (connId != null &&
            healthMap.containsKey(connId) &&
            healthMap[connId]!.status == ConnectionHealth.online)
        ? healthMap[connId]!.latencyMs
        : null;

    // ── LEFT-region aggregate readouts (§8) ───────────────────────────
    // Aggregate connection health across every monitored connection: how many
    // of the health-probed hosts are currently reachable. This is the TCP-ping
    // reachability signal, distinct from the per-session SSH status dots.
    // Only where hosts are checked (Settings): reachableHostsCount.
    final counted = reachableHostsCount(healthMap, checksOn: ref.watch(healthChecksEnabledProvider));
    final onlineHosts = counted.online;
    final trackedHosts = counted.tracked;
    final offlineHosts = trackedHosts - onlineHosts;
    final healthDotColor = offlineHosts == 0
        ? AppColors.v3Success
        : onlineHosts == 0
            ? AppColors.v3Error
            : AppColors.v3Warning;

    // App version (package_info via appVersionProvider). Hidden until resolved.
    final appVersion = ref.watch(appVersionProvider).valueOrNull;

    _tickWhile((!viewingSftp && currentSession?.session?.startedAt != null) || vaultSession.isUnlocked);

    return Container(
      height: DesktopDimensions.statusBarHeight,
      decoration: BoxDecoration(
        color: AppColors.v3ChromeBg,
        border: Border(
          top: BorderSide(color: AppColors.v3BorderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // Where the window is narrow (the app's smallest is 800 wide) the
      // left readouts give way: what does not fit is left out whole, from
      // the end (the version first), and the focused session's user@host
      // shortens; nothing is drawn past the bar's edge.
      child: LayoutBuilder(
        builder: (context, box) => Row(
        children: [
          Expanded(
            child: _FitStrip(
              children: [
          // ══════════════════════════════════════════════════════
          // LEFT SECTION: Session count + status dots
          // ══════════════════════════════════════════════════════

          // Session count with status dot
          Semantics(
            label: l10n.desktopStatusActiveSessions(activeCount),
            child: Tooltip(
              message: l10n.desktopStatusActiveSessions(activeCount),
              child: _HoverableItem(
                // One phrase in the language's order ("3 sessions", "세션
                // 3개"), the number in the terminal's font: the word was a
                // piece glued after the number (found in a code audit).
                child: Text.rich(
                  numberInPhrase(
                    l10n.desktopStatusSessions(activeCount),
                    '$activeCount',
                    number: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      color: activeCount > 0 ? AppColors.v3TextPrimary : AppColors.v3TextSecondary,
                    ),
                  ),
                  key: const ValueKey('status-sessions'),
                  style: TextStyle(
                    fontSize: DesktopDimensions.statusBarFontSize,
                    fontFamily: 'GeistSans',
                    fontWeight: FontWeight.w400,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ),
            ),
          ),

          // Session status dots (one per active session, max 8)
          if (activeSessions.isNotEmpty) ...[
            const SizedBox(width: 8),
            ...activeSessions.take(8).indexed.map((indexed) {
              final (i, e) = indexed;
              final isSelected = i == selectedTab;
              final dotColor = e.value.status == SessionStatus.connected
                  ? AppColors.v3Success
                  : e.value.status == SessionStatus.connecting
                      ? AppColors.v3Warning
                      : AppColors.v3Error;
              return Tooltip(
                message:
                    Redactable.host(e.value.connectionLabel).displayIn(ref),
                child: Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Container(
                    width: isSelected ? 8 : 6,
                    height: isSelected ? 8 : 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(
                              color: Colors.white.withValues(alpha: 0.5),
                              width: 1,
                            )
                          : null,
                    ),
                  ),
                ),
              );
            }),
            if (activeSessions.length > 8)
              Text(
                '+${activeSessions.length - 8}',
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.v3TextSecondary,
                ),
              ),
          ],

          // ══════════════════════════════════════════════════════
          // LEFT aggregate readouts (§8): health · sync · version
          // ══════════════════════════════════════════════════════

          // Aggregate connection health (dot + "n online"). Only shown once at
          // least one host has a definite reachable/unreachable probe result.
          // (Each readout with the separator before it, so that one left
          // out takes its separator along.)
          if (trackedHosts > 0)
            _sepThen(Semantics(
              label:
                  l10n.statusBarHostsOnlineTooltip(onlineHosts, trackedHosts),
              child: Tooltip(
                message:
                    l10n.statusBarHostsOnlineTooltip(onlineHosts, trackedHosts),
                child: _HoverableItem(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: healthDotColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        l10n.statusBarHostsOnline(onlineHosts),
                        style: TextStyle(
                          fontSize: DesktopDimensions.statusBarFontSize,
                          fontFamily: 'GeistSans',
                          fontWeight: FontWeight.w400,
                          color: AppColors.v3TextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )),

          // Cloud sync status. Icon carries the state color; label stays neutral.
          _sepThen(const StatusBarSyncItem()),

          // ZestSSH Cloud, only while something is in the way of it.
          const StatusBarCloudItem(),

          // Recording indicator (contextual - only while transcribing).
          // Before the version, so that the version is the first left out
          // where the bar is short of room.
          if (currentSessionId != null &&
              SessionTranscriptService.isRecording(currentSessionId))
            _sepThen(Tooltip(
              message: l10n.desktopStatusRecordingTooltip,
              child: _HoverableItem(
                child: _StatusItem(
                  icon: LucideIcons.circle,
                  label: l10n.desktopStatusRecordingLabel,
                  color: AppColors.v3Error,
                ),
              ),
            )),

          // App version (mono): a click checks for updates, or opens the
          // download page when a newer release is already known.
          if (appVersion != null) _sepThen(const StatusBarVersionItem()),
              ],
            ),
          ),

          // Broadcasting shows in the title bar; arranging panes lives in
          // the session header's Layout popover (3.0).
          const SizedBox(width: 8),
          ConstrainedBox(
            // The right readouts keep room for the session count at least.
            constraints: BoxConstraints(
              maxWidth: (box.maxWidth - _kStatusLeftMin).clamp(0.0, double.infinity),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [

          // ══════════════════════════════════════════════════════
          // RIGHT SECTION: Focused session info, duration, font, secure
          // ══════════════════════════════════════════════════════

          // The file editor minimized (3.4.1): a click shows it again.
          if (ref.watch(editorWorkspaceProvider).minimized) ...[
            EditorMinimizedChip(onShow: () => showEditorTabs(context)),
            const SizedBox(width: 8),
          ],

          // Focused session: user@host
          if (!viewingSftp &&
              currentSession != null &&
              currentSession.host != null) ...[
            // The one readout here that shortens (a long host name).
            Flexible(
              child: Tooltip(
                message: _formatUserHostPort(currentSession),
                child: _HoverableItem(
                  child: Text(
                    viewingScreen ? _formatUserHostPort(currentSession) : _formatUserHost(currentSession),
                    key: const ValueKey('status-user-host'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: DesktopDimensions.statusBarFontSize,
                      fontFamily: 'JetBrainsMono',
                      color: AppColors.v3TextPrimary,
                    ),
                  ),
                ),
              ),
            ),
            // (A remote screen that ended has nothing after its address.)
            if (!viewingScreen ||
                currentSession.session?.startedAt != null ||
                currentLatencyMs != null ||
                vaultSession.isUnlocked)
              const _Separator(),
          ],

          // Connection duration
          if (!viewingSftp && currentSession?.session?.startedAt != null) ...[
            Tooltip(
              message: l10n.desktopStatusConnectionDuration,
              child: _HoverableItem(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.timer,
                      size: DesktopDimensions.statusBarIconSize,
                      color: AppColors.v3TextSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatDuration(
                        DateTime.now().difference(
                          currentSession!.session!.startedAt,
                        ),
                      ),
                      style: TextStyle(
                        fontSize: DesktopDimensions.statusBarFontSize,
                        fontFamily: 'JetBrainsMono',
                        color: AppColors.v3TextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // (Nothing follows it for a remote screen with no latency read
            // and no vault open: no line at the bar's end.)
            if (!viewingScreen || currentLatencyMs != null || vaultSession.isUnlocked) const _Separator(),
          ],

          // The session's own round trip to its host
          if (!viewingSftp && currentLatencyMs != null) ...[
            Tooltip(
              message: l10n.desktopStatusConnectionLatency,
              child: _HoverableItem(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.gauge,
                      size: DesktopDimensions.statusBarIconSize,
                      color: _latencyColor(currentLatencyMs),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${latencyText(currentLatencyMs)}ms',
                      style: TextStyle(
                        fontSize: DesktopDimensions.statusBarFontSize,
                        fontFamily: 'JetBrainsMono',
                        color: _latencyColor(currentLatencyMs),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!viewingScreen || vaultSession.isUnlocked) const _Separator(),
          ],

          // Sync vault unlocked (S2) - click to lock the vault immediately.
          if (vaultSession.isUnlocked) ...[
            Tooltip(
              message: l10n.vaultLockNowTooltip,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () =>
                      ref.read(vaultSessionProvider.notifier).lock(),
                  child: _HoverableItem(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.unlock,
                          size: DesktopDimensions.statusBarIconSize,
                          color: AppColors.v3Success,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l10n.vaultUnlockedChip(
                              _vaultRemainingMinutes(vaultSession)),
                          style: TextStyle(
                            fontSize: DesktopDimensions.statusBarFontSize,
                            fontFamily: 'GeistSans',
                            color: AppColors.v3Success,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const _Separator(),
          ],

          // What the page in front shows of its own (as
          // designed): the forwards running on Port forwarding.
          if (activeTab == null) ..._pageItems(context),

          // UTF-8 + font are terminal chrome - they mean nothing in the file
          // browser, so the whole trailing group drops out there,
          // nor on a page with no session in front.
          if (!viewingSftp && !viewingScreen && activeTab != null) ...[
            Tooltip(
              message: l10n.desktopStatusEncodingTooltip,
              child: _HoverableItem(
                child: Text(
                  'UTF-8',
                  style: TextStyle(
                    fontSize: DesktopDimensions.statusBarFontSize,
                    fontFamily: 'GeistSans',
                    fontWeight: FontWeight.w400,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ),
            ),
            const _Separator(),
            // Font info
            _FontStatusButton(
              fontFamily: fontFamily,
              fontSize: fontSize,
              ref: ref,
            ),
          ],
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// The page in front's own readout, where it has one.
  List<Widget> _pageItems(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final style = TextStyle(
      fontSize: DesktopDimensions.statusBarFontSize,
      fontFamily: 'JetBrainsMono',
      color: AppColors.v3TextSecondary,
    );
    switch (ref.watch(activeSidebarNavProvider)) {
      case NavSection.portForwarding:
        final running = ref.watch(activeForwardIdsProvider).length;
        return [
          _HoverableItem(
            child: Text(l10n.pfStatusRunning(running), key: const ValueKey('status-forwards-running'), style: style),
          ),
        ];
      case NavSection.networks:
        // The network in use, its name in its display form (recording mode).
        final network = ref.watch(effectiveNetworkProvider).valueOrNull;
        if (network == null) return const [];
        return [
          _HoverableItem(
            child: Text(
              l10n.netStatusNetwork(Redactable.network(network.name).displayIn(ref)),
              key: const ValueKey('status-network'),
              style: style,
            ),
          ),
        ];
      // (The Server monitor said its warning limits here too, beside the
      // table's own footer, twice on one page. The
      // footer keeps them, next to what they explain.)
      default:
        return const [];
    }
  }

  // Recording mode: the focused session's user and host paint in their
  // display forms; the tooltip variant carries the port too.
  String _formatUserHost(SessionState session) {
    final user = session.username ?? '';
    final host = Redactable.address(session.host ?? '').displayIn(ref);
    if (user.isNotEmpty) {
      return '${Redactable.username(user).displayIn(ref)}@$host';
    }
    return host;
  }

  String _formatUserHostPort(SessionState session) {
    final user = session.username ?? '';
    final hostPort =
        Redactable.address('${session.host ?? ''}:${session.port ?? 22}')
            .displayIn(ref);
    // (A session with no user, a remote screen's, said "@localhost:5900".)
    return user.isEmpty ? hostPort : '${Redactable.username(user).displayIn(ref)}@$hostPort';
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  /// Color-code latency: green < 100ms, yellow < 300ms, red >= 300ms.
  Color _latencyColor(int ms) {
    if (ms < 100) return AppColors.v3Success;
    if (ms < 300) return AppColors.v3Warning;
    return AppColors.v3Error;
  }

}

/// Cloud sync in the status bar ([syncHealthProvider], shared with the
/// Account screen). Always shown: a device that is not syncing says so with a
/// red cloud, so nobody mistakes it for one that is, and one that is behind
/// shows amber. A click opens the Account screen's Sync card.
class StatusBarSyncItem extends ConsumerWidget {
  const StatusBarSyncItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final health = ref.watch(syncHealthProvider);
    final IconData icon;
    final String label;
    final Color color;
    final String tooltip;
    switch (health.health) {
      // Never set up here: a choice, not a fault, so neutral (a guest saw it
      // in red). Set up and failing is the red one.
      case SyncHealth.off:
        icon = LucideIcons.cloudOff;
        label = l10n.statusBarSyncOff;
        color = AppColors.v3TextTertiary;
        tooltip = l10n.statusBarNotSyncingTooltip;
      case SyncHealth.syncing:
        icon = LucideIcons.refreshCw;
        label = l10n.statusBarSyncing;
        color = AppColors.v3TextSecondary;
        tooltip = l10n.statusBarSyncing;
      case SyncHealth.failing:
        icon = LucideIcons.refreshCwOff;
        label = l10n.statusBarSyncError;
        color = AppColors.v3Error;
        tooltip = syncFailingText(health, l10n, unknown: l10n.statusBarSyncPausedTooltip);
      case SyncHealth.behind:
        final at = health.confirmedAt;
        icon = LucideIcons.uploadCloud;
        label = l10n.statusBarSyncBehind;
        color = AppColors.v3Warning;
        tooltip = health.waiting || at == null
            ? l10n.statusBarSyncWaitingTooltip
            : l10n.statusBarSyncStaleTooltip(timeAgoInSentence(l10n, at));
      case SyncHealth.paused:
        // Paused by its person (3.0): chosen, and amber all the same, since
        // nothing leaves until it ends.
        final until = health.pause?.until;
        icon = LucideIcons.pauseCircle;
        label = l10n.statusBarSyncPaused;
        color = AppColors.v3Warning;
        tooltip = until == null
            ? l10n.statusBarSyncPausedIndefinitelyTooltip
            : l10n.statusBarSyncPausedUntilTooltip(syncPausedUntilText(until, l10n.localeName));
      case SyncHealth.upToDate:
        final at = health.confirmedAt!;
        final hh = at.hour.toString().padLeft(2, '0');
        final mm = at.minute.toString().padLeft(2, '0');
        icon = LucideIcons.cloud;
        label = l10n.statusBarSynced;
        color = AppColors.v3Success;
        tooltip = l10n.statusBarSyncedTooltip('$hh:$mm');
    }

    return Tooltip(
      message: tooltip,
      constraints: kStatusBarProseTooltip,
      padding: kStatusBarProseTooltipPadding,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('status-bar-sync'),
          onTap: () => ProfileScreen.openAccount(context, ref),
          child: _HoverableItem(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: DesktopDimensions.statusBarIconSize,
                  color: color,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: DesktopDimensions.statusBarFontSize,
                    fontFamily: 'GeistSans',
                    fontWeight: FontWeight.w400,
                    color: AppColors.v3TextSecondary,
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

/// The size of a status bar tooltip that says a sentence or more (what is
/// wrong with sync, how ZestSSH Cloud stands): wrapped at a width a line can
/// be read at, where the default is one line as wide as the window.
const BoxConstraints kStatusBarProseTooltip = BoxConstraints(minHeight: 24, maxWidth: 440);
const EdgeInsets kStatusBarProseTooltipPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 7);

/// How ZestSSH Cloud stands, in the status bar, while something is in the
/// way of it ([cloudReachStateProvider]): the service down, not responding
/// or answering with a fault (red: ours), and the device offline, on a
/// network that blocks the service, reaching nothing, or shown something
/// that cannot be verified (amber: on this side). Nothing shows while all is
/// well, or while nothing on this device uses the service.
///
/// What it says on hovering is the whole of it: what is wrong, that what is
/// on the device is not affected, its code, and since when. A click asks the
/// service again, there and then, and says what came of it.
class StatusBarCloudItem extends ConsumerWidget {
  const StatusBarCloudItem({super.key});

  /// Since when, as it is said under the message: the time of day, and the
  /// day with it when that was not today. For an outage that is proven it is
  /// since when the service has been down, which may be long before this
  /// device noticed.
  /// (The phone's banner says the same: [cloudSinceText].)
  static String? sinceText(CloudReachState state, String locale, {DateTime? now}) =>
      cloudSinceText(state, locale, now: now);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudReachStateProvider).valueOrNull ?? const CloudReachState.unknown();
    final failure = cloudFailureOfReach(state);
    if (failure == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final label = failure.label(l10n);
    // Its sign, red where the service fails and amber where what is in the
    // way is on this side: the same on a phone's banner.
    final (icon, color) = cloudFailureMark(failure);
    final at = sinceText(state, Localizations.localeOf(context).toString());
    final said = failure.message(l10n);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Separator(),
        Tooltip(
          constraints: kStatusBarProseTooltip,
          padding: kStatusBarProseTooltipPadding,
          message: at == null ? said : '$said\n${l10n.cloudChipSince(at)}',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey('status-bar-cloud'),
              onTap: () => checkCloudAgain(context, ref),
              child: _HoverableItem(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: DesktopDimensions.statusBarIconSize, color: color),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: DesktopDimensions.statusBarFontSize,
                        fontFamily: 'GeistSans',
                        fontWeight: FontWeight.w400,
                        color: AppColors.v3TextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The app version in the status bar (mono). With a newer release known it
/// is an accent "update available" chip that opens the update's dialog (the
/// download page on a build that does not update itself);
/// otherwise a click checks for updates now and says what it found (desktop
/// builds, which update from the website; store builds only show it).
class StatusBarVersionItem extends ConsumerStatefulWidget {
  const StatusBarVersionItem({super.key});

  @override
  ConsumerState<StatusBarVersionItem> createState() =>
      _StatusBarVersionItemState();
}

class _StatusBarVersionItemState extends ConsumerState<StatusBarVersionItem> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await checkForUpdatesNow(context, ref);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appVersion = ref.watch(appVersionProvider).valueOrNull;
    if (appVersion == null) return const SizedBox.shrink();
    // A newer release, if one is known (persists past banner dismissal).
    final update = ref.watch(availableUpdateProvider);

    if (update != null) {
      final accent =
          update.critical ? AppColors.v3Warning : AppColors.v3AccentInk;
      return Tooltip(
        message: update.critical
            ? l10n.desktopStatusUpdateCriticalTooltip(update.version)
            : l10n.desktopStatusUpdateAvailableTooltip(update.version),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('status-bar-version'),
            onTap: () => openUpdate(context, ref, update),
            child: _HoverableItem(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    update.critical
                        ? LucideIcons.shield
                        : LucideIcons.arrowUpCircle,
                    size: DesktopDimensions.statusBarIconSize,
                    color: accent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'v$appVersion',
                    style: TextStyle(
                      fontSize: DesktopDimensions.statusBarFontSize,
                      fontFamily: 'JetBrainsMono',
                      fontWeight: FontWeight.w600,
                      color: accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final version = Text(
      'v$appVersion',
      style: TextStyle(
        fontSize: DesktopDimensions.statusBarFontSize,
        fontFamily: 'JetBrainsMono',
        color: AppColors.v3TextDisabled,
      ),
    );
    if (!UpdateCheckService.manualCheckSupported) {
      return Tooltip(
        message: l10n.statusBarVersionTooltip,
        child: _HoverableItem(child: version),
      );
    }
    return Tooltip(
      message: _checking
          ? l10n.updateCheckChecking
          : l10n.statusBarVersionCheckTooltip,
      child: MouseRegion(
        cursor: _checking ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('status-bar-version'),
          onTap: _checking ? null : _check,
          child: _HoverableItem(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_checking) ...[
                  SizedBox(
                    key: const ValueKey('status-bar-version-checking'),
                    width: 9,
                    height: 9,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.4,
                      color: AppColors.v3TextSecondary,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                version,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverableItem extends StatefulWidget {
  final Widget child;

  const _HoverableItem({required this.child});

  @override
  State<_HoverableItem> createState() => _HoverableItemState();
}

class _HoverableItemState extends State<_HoverableItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: _hovering
              ? AppColors.v3BorderSubtle.withValues(alpha: 0.3)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
        ),
        child: widget.child,
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _StatusItem({
    required this.icon,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.v3TextSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: DesktopDimensions.statusBarIconSize, color: c),
        const SizedBox(width: 4),
        Text(
          label,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: TextStyle(
            fontSize: DesktopDimensions.statusBarFontSize,
            fontFamily: 'GeistSans',
            fontWeight: FontWeight.w400,
            color: c,
          ),
        ),
      ],
    );
  }
}

/// What the right readouts leave the left ones at least (the session count
/// and a few of its dots).
const double _kStatusLeftMin = 150;

/// [item] with the separator before it, as one: left out together.
Widget _sepThen(Widget item) => Row(mainAxisSize: MainAxisSize.min, children: [const _Separator(), item]);

/// A row of the status bar's readouts that leaves out, whole, the ones that
/// do not fit its width, from the end; each is centred in the bar's height.
/// (A one-line [Wrap] in a box of that height: what would go to a second
/// line is clipped away, and takes no clicks.)
class _FitStrip extends StatelessWidget {
  const _FitStrip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final h = box.maxHeight.isFinite ? box.maxHeight : DesktopDimensions.statusBarHeight - 1;
          return SizedBox(
            height: h,
            child: Wrap(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final c in children) SizedBox(height: h, child: Center(widthFactor: 1, child: c)),
              ],
            ),
          );
        },
      );
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 1,
        height: 12,
        color: AppColors.v3TextDisabled,
      ),
    );
  }
}

class _FontStatusButton extends StatelessWidget {
  final TerminalFontFamily fontFamily;
  final double fontSize;
  final WidgetRef ref;

  const _FontStatusButton({
    required this.fontFamily,
    required this.fontSize,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      onTap: () {
        final box = context.findRenderObject() as RenderBox;
        final offset = box.localToGlobal(Offset.zero);
        showMenu<void>(
          context: context,
          position: RelativeRect.fromLTRB(
            offset.dx - 40,
            offset.dy - 280,
            offset.dx + 200,
            offset.dy,
          ),
          items: [
            // Font size section
            PopupMenuItem<void>(
              enabled: false,
              height: 36,
              child: Text(
                l10n.desktopStatusFontSize,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.v3TextSecondary,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            PopupMenuItem<void>(
              height: 44,
              child: StatefulBuilder(
                builder: (context, setLocalState) {
                  final currentSize = ref.read(terminalFontSizeProvider);
                  return Row(
                    children: [
                      IconButton(
                        tooltip: AppLocalizations.of(context)!.shortcutNameZoomOut,
                        icon: const Icon(LucideIcons.minus, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: () {
                          final newSize = clampTerminalFontSize(currentSize - 1);
                          ref.read(terminalFontSizeProvider.notifier).state = newSize;
                          ref.read(settingsServiceProvider).setTerminalFontSize(newSize);
                          setLocalState(() {});
                        },
                      ),
                      Expanded(
                        child: Text(
                          '${currentSize.toInt()}px',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            fontFamily: 'JetBrainsMono',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: AppLocalizations.of(context)!.shortcutNameZoomIn,
                        icon: const Icon(LucideIcons.plus, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: () {
                          final newSize = clampTerminalFontSize(currentSize + 1);
                          ref.read(terminalFontSizeProvider.notifier).state = newSize;
                          ref.read(settingsServiceProvider).setTerminalFontSize(newSize);
                          setLocalState(() {});
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
            const PopupMenuDivider(),
            // Font family section
            PopupMenuItem<void>(
              enabled: false,
              height: 36,
              child: Text(
                l10n.desktopStatusFontFamily,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.v3TextSecondary,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            for (final family in TerminalFontFamily.values)
              PopupMenuItem<void>(
                height: 36,
                onTap: () {
                  ref.read(terminalFontFamilyProvider.notifier).state = family;
                  ref.read(settingsServiceProvider).setTerminalFontFamily(family);
                },
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        family.nameIn(l10n),
                        style: TextStyle(
                          fontSize: 13,
                          fontFamily: family.fontFamily,
                        ),
                      ),
                    ),
                    if (family == fontFamily)
                      Icon(LucideIcons.check, size: 16, color: AppColors.v3AccentInk),
                  ],
                ),
              ),
          ],
        );
      },
      child: Tooltip(
        message: l10n.desktopStatusFontTooltip,
        child: _HoverableItem(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.type,
                  size: DesktopDimensions.statusBarIconSize,
                  color: AppColors.v3TextSecondary),
              const SizedBox(width: 4),
              Text(
                '${fontFamily.nameIn(l10n)} ${fontSize.toInt()}px',
                style: TextStyle(
                  fontSize: DesktopDimensions.statusBarFontSize,
                  fontFamily: 'JetBrainsMono',
                  color: AppColors.v3TextPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
