import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/latency_format.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/ui/widgets/hit_area.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show ZestPressable;
import 'package:zestssh/ui/widgets/session_status_mark.dart';
import 'package:zestssh/features/broadcast/broadcast_controls.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/terminal/terminal_dictation.dart';
import 'package:zestssh/features/terminal/terminal_reader.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/widgets/team_logged_indicator.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/transcript_actions.dart';
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/ui/screens/sharing/share_session_dialog.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/screens/tmux/tmux_workspace.dart';
import 'package:zestssh/ui/widgets/drag_ghost.dart';
import 'package:zestssh/ui/widgets/layout_preset_picker.dart';
import 'package:zestssh/ui/widgets/name_first_row.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// Height of the one header over a session tab.
const double kSessionHeaderHeight = 44;

/// Height of a pane's own slim header when the tab is split.
const double kPaneHeaderHeight = 30;

/// The one header over a session tab (3.0). It names the session that has
/// focus (name, then address), carries one status chip that also opens the
/// session's menu, and ends in tmux, SFTP, Layout, Broadcast and Inspector.
///
/// It replaces the bar that every pane used to draw for itself, with its red
/// power button: disconnecting now lives in the status chip's menu, on a
/// split pane's own header, and on the tab (close or right-click).
/// About how wide the status chip is with its round trip and its host key
/// check ("Connected 24ms, Host key known").
const double _kStatusChipRoom = 270;

/// The header's five buttons as icons alone, with their gaps and the
/// chevrons of Layout and Broadcast.
const double _kToolbarIconsRoom = 5 * 29 + 4 * 4 + 2 * 15;

/// Speech to text's button, where it is shown: an icon alone, and its gap.
const double _kDictationRoom = 29 + 4;

class SessionHeaderBar extends ConsumerWidget {
  const SessionHeaderBar({
    super.key,
    required this.sessionId,
    required this.sessionState,
    required this.onToggleSftp,
    required this.onApplyLayout,
  });

  final String sessionId;
  final SessionState sessionState;

  /// Opens SFTP for [sessionId], or closes it when it is already open.
  final ValueChanged<String> onToggleSftp;

  /// Applies a layout preset to the active tab.
  /// An arrangement was chosen; null for the automatic one.
  final ValueChanged<LayoutPreset?> onApplyLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final hostPort = sessionHostPort(sessionState);
    final tree = ref.watch(paneTreeProvider);
    // tmux and SFTP run over SSH: a tab with no SSH session has neither, and
    // one with a local pane in front acts on its SSH session, named in the
    // tooltip (they led to a full page
    // saying tmux needs a live SSH session, and a toast saying SFTP does).
    final tab = ref.watch(workTabsProvider).activeTab;
    final lastSsh = ref.watch(lastSshSessionOfTabProvider);
    if (tab != null && sessionState.speaksSsh) lastSsh[tab.id] = sessionId;
    final sshSession = tab == null
        ? (sessionState.speaksSsh ? sessionId : null)
        : sshToolsSessionOf(tab, ref.watch(activeSessionsProvider), focused: sessionId, lastInFront: lastSsh[tab.id]);
    // The host they act on, where it is not the one named on the left.
    final otherHost = sshSession == null || sshSession == sessionId
        ? null
        : Redactable.host(ref.watch(activeSessionsProvider)[sshSession]?.connectionLabel ?? '').displayIn(ref);
    final sftpOpen = tree?.allLeaves
            .any((l) => l.type == 'sftp' && l.sessionId == sshSession) ??
        false;
    final inspectorOpen = ref.watch(sessionSlidePanelVisibleProvider);
    final recordingTranscript = SessionTranscriptService.isRecording(sessionId);
    // A session that is files only: its files are its pane, and it has no
    // terminal for tmux. It says SFTP where a terminal says nothing more.
    final filesOnly = ref.read(activeSessionsProvider.notifier).isFilesOnly(sessionId);
    // A remote screen (4.0): VNC where a terminal says nothing more, and none
    // of a terminal's tools (tmux, SFTP, the Inspector's snippets and look).
    final screen = ref.read(activeSessionsProvider.notifier).isScreen(sessionId);
    // Speech to text (4.0, not on Linux) is started from the Inspector's
    // Tools tab, its key or the command palette: the header of the session it
    // types into has its microphone only while it listens, the sign that it
    // is on there and the way to stop it.
    final dictation = !filesOnly &&
        !screen &&
        ref.watch(voiceInputSupportedProvider) &&
        ref.watch(dictationProvider.select((s) => s.listening && s.sessionId == sessionId));

    return Container(
      // A finger's room for its tools where the controls are touch sized
      // (a tablet, 4.0).
      height: touchSizedAt(context) ? 56 : kSessionHeaderHeight,
      padding: const EdgeInsets.only(left: 16, right: 12),
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(bottom: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        // The buttons keep their words only where the host's name and at
        // least 15 characters of its address fit beside them as well; else
        // they are icons with their names as tooltips (with the Inspector
        // open the address was cut to "192.16..." while the words stood).
        // A narrower pane still drops the address.
        double width(String text, TextStyle style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final w = painter.width;
          painter.dispose();
          return w;
        }

        final shownHost = Redactable.host(sessionState.connectionLabel).displayIn(ref);
        final shownAddress = Redactable.address(hostPort).displayIn(ref);
        final left = width(shownHost, const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)) +
            (hostPort.isEmpty
                ? 0
                : 10 + width(shownAddress.length > 15 ? shownAddress.substring(0, 15) : shownAddress,
                        const TextStyle(fontSize: 11.5, fontFamily: 'JetBrainsMono'))) +
            10 +
            _kStatusChipRoom;
        const label = TextStyle(fontSize: 12);
        final labels = [
          l10n.sessionInfoTmux,
          l10n.pillSftp,
          l10n.sessionHeaderLayout,
          l10n.terminalBroadcast,
          l10n.sessionHeaderInspector,
        ].fold<double>(0, (sum, s) => sum + width(s, label) + 6 + 20 - 14);
        final roomy =
            constraints.maxWidth >= left + 12 + _kToolbarIconsRoom + (dictation ? _kDictationRoom : 0) + labels;
        final showAddress = constraints.maxWidth >= 560 && hostPort.isNotEmpty;
        return Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: RedactedText(
                      Redactable.host(sessionState.connectionLabel),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ZestColors.textPrimary,
                      ),
                    ),
                  ),
                  if (showAddress) ...[
                    const SizedBox(width: 10),
                    Flexible(
                      child: RedactedText(
                        Redactable.address(hostPort),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'JetBrainsMono',
                          color: ZestColors.textTertiary,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  SessionStatusChip(
                      sessionId: sessionId, sessionState: sessionState),
                  if (filesOnly) ...[
                    const SizedBox(width: 8),
                    FilesOnlyTag(key: ValueKey('session-files-only-$sessionId'), sessionId: sessionId),
                  ],
                  if (screen) ...[
                    const SizedBox(width: 8),
                    ScreenTag(key: ValueKey('session-screen-$sessionId'), sessionId: sessionId),
                  ],
                  SessionRebootChip(connectionId: sessionState.connectionId),
                  if (recordingTranscript) ...[
                    const SizedBox(width: 8),
                    _TranscriptChip(sessionId: sessionId),
                  ],
                  // Logged for its team (3.0): shown the whole
                  // time it is.
                  TeamLoggedChip(
                    sessionId: sessionId,
                    // A remote screen's log holds how it went, never its picture.
                    screen: !screen
                        ? null
                        : ref.read(activeSessionsProvider.notifier).isRdpScreen(sessionId)
                            ? LoggedScreen.rdp
                            : LoggedScreen.vnc,
                  ),
                  // Shared with teammates (3.0): how, and with how many
                  // there now; a click opens who they are.
                  SessionShareChip(sessionId: sessionId),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (!filesOnly && !screen && sshSession != null) ...[
              SessionTmuxButton(
                key: const ValueKey('session-header-tmux'),
                sessionId: sshSession,
                showLabel: roomy,
                otherHost: otherHost,
              ),
              const SizedBox(width: 4),
              HeaderButton(
                key: const ValueKey('session-header-sftp'),
                icon: LucideIcons.folderOpen,
                label: l10n.pillSftp,
                showLabel: roomy,
                on: sftpOpen,
                isToggle: true,
                tooltip: otherHost == null ? l10n.sessionHeaderSftpTooltip : l10n.sessionHeaderToolOn(l10n.pillSftp, otherHost),
                onTap: () => onToggleSftp(sshSession),
              ),
              const SizedBox(width: 4),
            ],
            _LayoutButton(showLabel: roomy, onApply: onApplyLayout),
            const SizedBox(width: 4),
            // Typing into every terminal of the tab (3.0): a button of its
            // own, where it is seen and stopped.
            BroadcastButton(showLabel: roomy),
            if (dictation) ...[
              const SizedBox(width: 4),
              DictationButton(key: const ValueKey('session-header-dictate'), sessionId: sessionId),
            ],
            if (!screen) ...[
              const SizedBox(width: 4),
              HeaderButton(
                icon: LucideIcons.panelRight,
                label: l10n.sessionHeaderInspector,
                showLabel: roomy,
                on: inspectorOpen,
                isToggle: true,
                // Open, it is outlined in the accent: the panel beside it is
                // what it opened.
                onBorder: ZestColors.accentPrimary,
                tooltip: l10n.sessionHeaderInspectorTooltip,
                onTap: () => ref
                    .read(sessionSlidePanelVisibleProvider.notifier)
                    .state = !inspectorOpen,
              ),
            ],
          ],
        );
      }),
    );
  }
}

/// Speech to text (4.0) for [sessionId]'s terminal while it listens: an icon
/// alone, raised and in the accent, the sign that the microphone is on while
/// the Inspector is closed; a click (or its key, Ctrl+Shift+Space unless
/// changed) stops it. It is started from the Inspector's Tools tab, which has
/// the rest (what it hears, the language), its key or the command palette.
class DictationButton extends ConsumerWidget {
  const DictationButton({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final listening = ref.watch(dictationProvider.select((s) => s.listening));
    final shortcut = ref.watch(shortcutBindingProvider(ShortcutAction.dictate));
    final name = listening ? l10n.softKbMicStop : l10n.softKbMicStart;
    return HeaderButton(
      icon: LucideIcons.mic,
      label: name,
      showLabel: false,
      on: listening,
      isToggle: true,
      color: listening ? ZestColors.accentPrimary : null,
      onBorder: ZestColors.accentPrimary,
      // 29 by 28 drawn, as the header's other icons; a mouse's 32 square
      // to point at (the 4.0 accessibility pass).
      grow: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      semanticLabel: name,
      tooltip: shortcut == null ? name : '$name ($shortcut)',
      onTap: () => toggleDictation(context, ref, sessionId),
    );
  }
}

/// "Reboot needed" beside the status chip while the host's latest Server
/// monitor reading says it asks for a restart (Debian and Ubuntu write
/// /var/run/reboot-required after updates that need one). It only says so:
/// nothing in the app restarts a host (a reboot from the UI
/// could lead to accidents), so it has no tap and no menu.
class SessionRebootChip extends ConsumerWidget {
  const SessionRebootChip({super.key, required this.connectionId});

  final String? connectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = connectionId;
    if (id == null) return const SizedBox.shrink();
    final needed =
        ref.watch(serverStatsProvider.select((m) => m[id]?.restartRequired == true));
    if (!needed) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: l10n.monitorTableRebootTip,
        child: ZestStatusPill(
          key: const ValueKey('session-reboot-needed'),
          kind: ZestStatusKind.warning,
          label: l10n.hostRebootNeeded,
          icon: LucideIcons.rotateCcw,
        ),
      ),
    );
  }
}

/// "SFTP" in a quiet outline, beside the name of a session that is files only
/// (an SFTP-only host; "FTPS" for an FTPS host's): its header and its tab say
/// it, where a terminal says nothing more. [compact] for a tab's narrow room.
class FilesOnlyTag extends ConsumerWidget {
  const FilesOnlyTag({super.key, required this.sessionId, this.compact = false});

  final String sessionId;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final ftps = ref.read(activeSessionsProvider.notifier).isFtps(sessionId);
    return Tooltip(
      message: ftps ? l10n.sessionFilesOnlyLineFtps : l10n.sessionFilesOnlyLine,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6, vertical: compact ? 0 : 1),
        decoration: BoxDecoration(
          border: Border.all(color: ZestColors.borderDefault),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          ftps ? ConnectionProtocol.ftps.nameIn(l10n) : l10n.pillSftp,
          style: TextStyle(
            fontSize: compact ? 9 : 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: ZestColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// "VNC" or "RDP" in a quiet outline with a monitor, beside the name of a
/// remote screen's session (4.0): its header and its tab say it, where a
/// terminal says nothing more. [compact] for a tab's narrow room.
class ScreenTag extends ConsumerWidget {
  const ScreenTag({super.key, required this.sessionId, this.compact = false});

  final String sessionId;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final rdp = ref.read(activeSessionsProvider.notifier).isRdpScreen(sessionId);
    final says = rdp ? l10n.screenTagTooltipRdp : l10n.screenTagTooltip;
    // One thing to a screen reader, said in words ("A remote screen (RDP)"),
    // not a picture and three letters.
    return Semantics(
      label: says,
      excludeSemantics: true,
      child: Tooltip(
        message: says,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6, vertical: compact ? 0 : 1),
          decoration: BoxDecoration(
            border: Border.all(color: ZestColors.borderDefault),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.monitor, size: compact ? 9 : 10, color: ZestColors.textSecondary),
              const SizedBox(width: 3),
              Text(
                (rdp ? ConnectionProtocol.rdp : ConnectionProtocol.vnc).nameIn(l10n),
                style: TextStyle(
                  fontSize: compact ? 9 : 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: ZestColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `host` or `host:port` (the port only when it is not 22), unmasked. Masking
/// happens where it is painted, so every screen shows the same fake.
String sessionHostPort(SessionState s) {
  final host = s.host;
  if (host == null || host.isEmpty) return '';
  final port = s.port;
  return port != null && port != 22 ? hostWithPort(host, port) : host;
}

/// One status chip: a dot and word for the connection, the round trip once it
/// is up, and what was checked about the host's key. A click opens the
/// session's menu (reconnect, copy, transcript, save as host, disconnect).
class SessionStatusChip extends ConsumerWidget {
  const SessionStatusChip({
    super.key,
    required this.sessionId,
    required this.sessionState,
  });

  final String sessionId;
  final SessionState sessionState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final status = sessionState.status;
    final connected = status == SessionStatus.connected;
    final connId = sessionState.connectionId;
    final health = connId == null
        ? null
        : ref.watch(connectionHealthProvider.select((m) => m[connId]));
    final latency = connected &&
            health != null &&
            health.status == ConnectionHealth.online
        ? health.latencyMs
        : null;
    final (dot, word) = switch (status) {
      SessionStatus.connected => (
          ZestColors.statusSuccess,
          l10n.sessionInfoStatusConnected
        ),
      SessionStatus.connecting => (
          ZestColors.statusWarning,
          sessionState.isReconnecting
              ? l10n.sessionHeaderReconnecting(
                  sessionState.reconnectAttempt, sessionState.maxRetries)
              : l10n.sessionInfoStatusConnecting
        ),
      SessionStatus.disconnected => (
          ZestColors.statusError,
          l10n.sessionInfoStatusDisconnected
        ),
      SessionStatus.error => (
          ZestColors.statusError,
          l10n.sessionInfoStatusError
        ),
    };
    // A live SSH shell means the host's key was checked against the known
    // hosts of the session's space: it matched, or the person accepted it and
    // it was saved. Telnet, serial and local shells have no host key.
    final sshChecked =
        connected && (sessionState.session?.shell.isEncryptedSsh ?? false);

    return _HoverBox(
      tooltip: l10n.sessionHeaderStatusTooltip,
      radius: 13,
      onTap: (box) =>
          _showSessionMenu(context, ref, box, sessionId, sessionState),
      builder: (hover) => Container(
        height: touchSizedAt(context) ? 40 : 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: hover ? ZestColors.surfaceRaisedAlt : ZestColors.chromeElevated,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: ZestColors.borderDefault),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              word,
              style: TextStyle(fontSize: 11.5, color: ZestColors.textSecondary),
            ),
            if (latency != null) ...[
              const SizedBox(width: 7),
              Text(
                l10n.sessionInfoLatencyMs(latencyText(latency)),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'JetBrainsMono',
                  color: ZestColors.textTertiary,
                ),
              ),
            ],
            if (sshChecked) ...[
              Container(
                width: 1,
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: ZestColors.borderDefault,
              ),
              Icon(LucideIcons.shieldCheck, size: 12, color: ZestColors.textTertiary),
              const SizedBox(width: 4),
              Text(
                l10n.sessionHeaderHostKeyKnown,
                style:
                    TextStyle(fontSize: 11.5, color: ZestColors.textTertiary),
              ),
            ],
            const SizedBox(width: 5),
            Icon(LucideIcons.chevronDown,
                size: 12, color: ZestColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// The session's menu, opened from its status chip.
Future<void> _showSessionMenu(
  BuildContext context,
  WidgetRef ref,
  RenderBox box,
  String sessionId,
  SessionState s,
) async {
  final l10n = AppLocalizations.of(context)!;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  final recording = SessionTranscriptService.isRecording(sessionId);
  final canEdit = s.connectionId?.isNotEmpty ?? false;
  // A session that is files only has no terminal to keep a transcript of
  // or to share.
  // A remote screen (4.0) neither: its picture is not shared in step 1.
  final filesOnly = ref.read(activeSessionsProvider.notifier).isFilesOnly(sessionId) ||
      ref.read(activeSessionsProvider.notifier).isScreen(sessionId);
  // Sharing a session with teammates (3.0): a connected session, with
  // Orchards on. What it takes (a host in a Crate) is said when it opens.
  final canShare = kOrchardsEnabled && s.status == SessionStatus.connected && !filesOnly;
  final shared = SessionShares.of(sessionId) != null;
  final picked = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + box.size.height + 4,
      overlay.size.width - origin.dx - box.size.width,
      0,
    ),
    color: ZestColors.chromeElevated,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: ZestColors.borderDefault),
    ),
    // Room for longer languages; a row that still does not fit ellipsizes.
    constraints: const BoxConstraints(minWidth: 220, maxWidth: 360),
    items: [
      _menuItem('reconnect', LucideIcons.refreshCw, l10n.sessionInfoReconnect),
      const PopupMenuDivider(height: 1),
      _menuItem('copy_label', LucideIcons.copy, l10n.sessionInfoCopyLabel),
      _menuItem('copy_ip', LucideIcons.copy, l10n.sessionInfoCopyIp),
      _menuItem('copy_ip_port', LucideIcons.copy, l10n.sessionInfoCopyIpPort),
      if (!filesOnly) ...[
        const PopupMenuDivider(height: 1),
        _menuItem('read_screen', LucideIcons.scrollText, l10n.terminalReadScreen),
        _menuItem('save_transcript', LucideIcons.save,
            l10n.sessionInfoSaveTranscriptSoFar),
        _menuItem(
          recording ? 'stop_recording' : 'start_recording',
          recording ? LucideIcons.square : LucideIcons.circle,
          recording
              ? l10n.sessionInfoStopAndSaveTranscript
              : l10n.sessionInfoRecordTranscript,
          color: recording ? ZestColors.statusError : null,
        ),
      ],
      if (canShare) ...[
        const PopupMenuDivider(height: 1),
        _menuItem('share', LucideIcons.users, shared ? l10n.shareMenuManage : l10n.shareMenuItem),
      ],
      if (canEdit) ...[
        const PopupMenuDivider(height: 1),
        _menuItem('edit_connection', LucideIcons.bookmarkPlus,
            l10n.sessionInfoSaveConnection),
      ],
      const PopupMenuDivider(height: 1),
      _menuItem('disconnect', LucideIcons.powerOff, l10n.sessionInfoDisconnect,
          color: ZestColors.statusError),
    ],
  );
  if (picked == null || !context.mounted) return;
  switch (picked) {
    case 'reconnect':
      await reconnectSession(ref, sessionId, s);
    case 'copy_label':
      await _copyWithGate(context, ref, s.connectionLabel, l10n.sessionInfoLabelCopied);
    case 'copy_ip':
      await _copyWithGate(context, ref, s.host ?? '', l10n.sessionInfoIpCopied);
    case 'copy_ip_port':
      final host = s.host ?? '';
      await _copyWithGate(context, ref,
          host.isEmpty ? '' : hostWithPort(host, s.port ?? 22), l10n.sessionInfoIpPortCopied);
    case 'read_screen':
      final terminal = s.session?.terminal;
      if (terminal != null) {
        await showTerminalReader(context, terminal: terminal, name: s.connectionLabel);
      }
    case 'save_transcript':
      final terminal = s.session?.terminal;
      if (terminal != null) {
        await TranscriptActions.saveBufferSoFar(context, ref,
            connectionLabel: s.connectionLabel, terminal: terminal);
      }
    case 'start_recording':
      TranscriptActions.startRecording(context, sessionId, s.connectionLabel);
    case 'stop_recording':
      await TranscriptActions.stopAndSaveRecording(context, ref, sessionId);
    case 'share':
      if (SessionShares.of(sessionId) != null) {
        await showShareParticipants(context, sessionId);
      } else {
        await showShareSession(context, sessionId);
      }
    case 'edit_connection':
      // A quick-connect is ephemeral (id `quick_...`, never saved): open a new
      // host pre-filled with what the session knows instead.
      final cid = s.connectionId;
      final ephemeral = cid == null || cid.startsWith('quick_');
      ConnectionEditScreen.showModal(
        context,
        connectionId: ephemeral ? null : cid,
        initialHost: ephemeral ? s.host : null,
        initialPort: ephemeral ? s.port : null,
        initialLabel: ephemeral && s.connectionLabel.isNotEmpty
            ? s.connectionLabel
            : null,
      );
    case 'disconnect':
      await confirmDisconnectSession(context, ref, sessionId, s);
  }
}

PopupMenuItem<String> _menuItem(String value, IconData icon, String label,
    {Color? color}) {
  final c = color ?? ZestColors.textPrimary;
  return PopupMenuItem<String>(
    value: value,
    height: 36,
    child: Row(
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: c),
          ),
        ),
      ],
    ),
  );
}

/// Every copy here puts a REAL identifier on the clipboard, so each goes
/// through the recording-mode reveal gate (spec 5).
Future<void> _copyWithGate(
  BuildContext context,
  WidgetRef ref,
  String value,
  String done,
) async {
  if (value.isEmpty) return;
  final ok = await confirmRevealWhileRecording(context, ref);
  if (!ok || !context.mounted) return;
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) showTopSnackBar(context, done, isSuccess: true);
}

/// Ask first, then end the session. Used by the status chip's menu and a
/// split pane's own header.
Future<void> confirmDisconnectSession(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
  SessionState s,
) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.sessionInfoDisconnectConfirmTitle(
        Redactable.host(s.connectionLabel).display),
    body: l10n.sessionInfoDisconnectConfirmBody,
    confirmLabel: l10n.sessionInfoDisconnect,
  );
  if (ok == true) {
    unawaited(ref.read(activeSessionsProvider.notifier).endSession(sessionId));
  }
}

/// End [sessionId] and start a fresh session for the same host.
/// `startAutoReconnect` alone is a no-op for a live session: it only schedules
/// retries once a session has already dropped.
Future<void> reconnectSession(
  WidgetRef ref,
  String sessionId,
  SessionState s,
) async {
  if (s.connectionId == null) return;
  // Signed in as it was (its account), the host read from its own space.
  final newSid = await ref.read(activeSessionsProvider.notifier).openAgain(sessionId);
  if (newSid != null) {
    ref.read(workTabsProvider.notifier).onSessionCreated(newSid);
  }
}

/// Shown while a transcript is being recorded. A click stops the recording
/// and saves it (Save As first, so a cancelled save keeps recording).
class _TranscriptChip extends ConsumerWidget {
  const _TranscriptChip({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final red = ZestColors.statusError;
    return _HoverBox(
      tooltip: l10n.sessionInfoStopAndSaveTranscript,
      radius: 12,
      onTap: (_) =>
          TranscriptActions.stopAndSaveRecording(context, ref, sessionId),
      builder: (hover) => Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: red.withValues(alpha: hover ? 0.2 : 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: red.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: red, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              l10n.sessionHeaderRecordingTranscript,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: red),
            ),
          ],
        ),
      ),
    );
  }
}

/// A header button: icon and label, 28px tall, raised while [on].
class HeaderButton extends StatelessWidget {
  const HeaderButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.on = false,
    this.showLabel = true,
    this.tooltip,
    this.trailing,
    this.color,
    this.onBorder,
    this.isToggle = false,
    this.grow,
    this.semanticLabel,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool on;

  /// It turns something on and off (Files, the inspector, tmux, broadcast):
  /// a screen reader says [on] as its state.
  final bool isToggle;

  /// The outline while [on], where it is not the neutral hairline.
  final Color? onBorder;
  final bool showLabel;
  final String? tooltip;
  final Widget? trailing;

  /// Overrides the icon and label colour (tmux uses the accent while on).
  final Color? color;

  /// How far its target reaches past what it draws (an icon alone, to a
  /// mouse's 32 square).
  final EdgeInsets? grow;

  /// What a screen reader calls it, in place of its words and its tooltip
  /// (where the tooltip says more, such as its key).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return _HoverBox(
      tooltip: tooltip ?? (showLabel ? null : label),
      toggled: isToggle ? on : null,
      grow: grow,
      label: semanticLabel,
      onTap: (_) => onTap(),
      builder: (hover) {
        final fg = color ??
            (on || hover ? ZestColors.textPrimary : ZestColors.textSecondary);
        final touch = touchSizedAt(context);
        return Container(
          // 44 to a finger where the controls are touch sized (4.0).
          height: touch ? 44 : 28,
          constraints: touch ? const BoxConstraints(minWidth: 44) : null,
          alignment: touch ? Alignment.center : null,
          padding: EdgeInsets.symmetric(horizontal: showLabel ? 10 : 7),
          decoration: BoxDecoration(
            color: on
                ? ZestColors.chromeElevated
                : hover
                    ? ZestColors.surfaceRaisedAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
                color: on ? (onBorder ?? ZestColors.borderDefault) : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              if (showLabel) ...[
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontSize: 12, color: fg)),
              ],
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing!,
              ],
            ],
          ),
        );
      },
    );
  }
}

/// tmux, one tap from the header. Idle: turns tmux mode on for this session
/// (the tab lists the host's tmux sessions, or attaches straight away when
/// there is only one to make). Attached: shows the tmux session's name and
/// opens the same sessions menu as the workspace strip. Same code path as the
/// Open tmux shortcut and the palette.
class SessionTmuxButton extends ConsumerWidget {
  const SessionTmuxButton({
    super.key,
    required this.sessionId,
    this.showLabel = true,
    this.otherHost,
  });

  final String sessionId;
  final bool showLabel;

  /// The host it acts on, for the tooltip, where a pane of another has the
  /// focus (a local shell's, beside this SSH session).
  final String? otherHost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final host = ref.watch(tmuxHostProvider(sessionId));
    final live = host.live;
    final name = live ? host.controller?.currentSessionName : null;
    final label = name == null
        ? l10n.sessionInfoTmux
        : l10n.sessionInfoTmuxActiveLabel(Redactable.host(name).displayIn(ref));
    final tooltip = otherHost != null
        ? l10n.sessionHeaderToolOn(l10n.sessionInfoTmux, otherHost!)
        : live
            ? l10n.tmuxSessionsMenu
            : host.active
                ? l10n.sessionInfoTmuxPickingTooltip
                : l10n.sessionInfoTmuxOpenTooltip;
    return Builder(
      builder: (btnContext) => HeaderButton(
        icon: LucideIcons.layoutGrid,
        label: label,
        showLabel: showLabel,
        on: host.active,
        tooltip: tooltip,
        color: host.active ? ZestColors.accentPrimary : null,
        trailing: live
            ? Icon(LucideIcons.chevronDown,
                size: 11, color: ZestColors.accentInk)
            : null,
        onTap: () => _onTap(btnContext, ref, host),
      ),
    );
  }

  Future<void> _onTap(
      BuildContext context, WidgetRef ref, TmuxSessionHost host) async {
    if (!host.active) {
      unawaited(host.begin());
      return;
    }
    final c = host.controller;
    if (!host.live || c == null) {
      // The picker (or a failure state) is already on screen in the tab; a
      // tap while choosing just re-lists the host's sessions.
      if (host.stage == TmuxHostStage.picking) unawaited(host.refreshList());
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height + 4,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      color: ZestColors.chromeElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderDefault),
      ),
      items: tmuxSessionsMenuItems(l10n, ref, c),
    );
    if (picked == null || !context.mounted) return;
    // Detach through the host so the tab shows its normal terminal again.
    await handleTmuxSessionsMenu(context, ref, c, picked, onDetach: host.stop);
  }
}

/// Layout: the arrangements for the tab, in a popover under the button.
class _LayoutButton extends StatelessWidget {
  const _LayoutButton({required this.showLabel, required this.onApply});

  final bool showLabel;
  final ValueChanged<LayoutPreset?> onApply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Builder(
      builder: (btnContext) => HeaderButton(
        icon: LucideIcons.layoutDashboard,
        label: l10n.sessionHeaderLayout,
        showLabel: showLabel,
        tooltip: l10n.sessionHeaderLayoutTooltip,
        trailing: Icon(LucideIcons.chevronDown,
            size: 11, color: ZestColors.textTertiary),
        onTap: () => showLayoutPopover(
          btnContext,
          onApply: onApply,
          onUpgrade: () => PricingModal.show(context),
        ),
      ),
    );
  }
}

/// Opens the Layout popover under the widget at [anchorContext], right
/// aligned to it.
void showLayoutPopover(
  BuildContext anchorContext, {
  required ValueChanged<LayoutPreset?> onApply,
  VoidCallback? onUpgrade,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(anchorContext).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) return;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  final right = overlay.size.width - origin.dx - box.size.width;
  showMenu<void>(
    context: anchorContext,
    position: RelativeRect.fromLTRB(
      overlay.size.width - right - LayoutPopover.width,
      origin.dy + box.size.height + 6,
      right,
      0,
    ),
    color: ZestColors.chromeElevated,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: ZestColors.borderDefault),
    ),
    constraints: const BoxConstraints(
        minWidth: LayoutPopover.width, maxWidth: LayoutPopover.width),
    items: [
      // One live item: its own controls stay interactive while the popup is
      // open (the pattern the recording-mode menu uses).
      PopupMenuItem<void>(
        enabled: false,
        padding: EdgeInsets.zero,
        child: LayoutPopover(onApply: onApply, onUpgrade: onUpgrade),
      ),
    ],
  );
}

/// The Layout popover's body: the arrangements for this tab. (Broadcast has a
/// button of its own beside it: lib/features/broadcast/broadcast_controls.dart.)
///
/// What is offered follows the tab. First the automatic grid and the
/// arrangements that hold exactly its terminals; then the ones with room for
/// a few more, whose spare panes are places to connect. One with fewer panes
/// than the tab has terminals is not offered: choosing it would have to move
/// terminals out of sight. The arrangement the tab stands in is marked.
///
/// A free account opens [freeSessionLimit] terminals. Of the arrangements
/// for more it is shown the next size up, locked, and no further; a click
/// on one opens what unlocks it ([onUpgrade]).
class LayoutPopover extends ConsumerWidget {
  const LayoutPopover({super.key, required this.onApply, this.onUpgrade});

  static const double width = 432;

  /// How many cards stand in a row. (Four: with five, the names of several
  /// arrangements were cut off in German, Spanish and Russian.)
  static const int perRow = 4;

  /// An arrangement was chosen; null for the automatic one.
  final ValueChanged<LayoutPreset?> onApply;

  /// A locked arrangement was clicked. Left out, a locked one does nothing.
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final activeTab = ref.watch(activeWorkTabProvider);

    // The terminal panes of the tab: what an arrangement has to hold.
    final tree = activeTab?.paneTree;
    final count = layoutPaneCount(tree);
    final offer = presetsFor(count, room: kLayoutRoomOffered);
    final roomier = [
      for (final p in offer.roomier)
        if (isPro || p.panes <= freeSessionLimit + 1) p,
    ];
    final standsIn = presetOf(tree);
    // The automatic grid is what the tab stands in when it is in its grid
    // with no place left empty: what choosing it would make.
    final automaticNow =
        isTiled(tree) && withoutSftp(tree)!.allLeaves.length == count;

    Widget card(LayoutPreset p) {
      final locked = !isPro && p.panes > freeSessionLimit;
      final upgrade = onUpgrade;
      return _PresetCard(
        key: ValueKey('layout-${p.name}'),
        shape: p.shape,
        label: layoutPresetLabel(l10n, p),
        // (A locked one says what unlocks it once, under the cards, and to
        // the pointer.)
        tooltip: locked ? l10n.deskLayoutMoreWithSqueezed : null,
        locked: locked,
        selected: p == standsIn,
        onTap: locked
            ? (upgrade == null
                ? null
                : () {
                    Navigator.of(context).pop();
                    upgrade();
                  })
            : () {
                Navigator.of(context).pop();
                onApply(p);
              },
      );
    }

    final fitting = <Widget>[
      // The grid a tab nobody arranged stands in: one click puts the tab in
      // it again, however it came to look. (The arrangement that is this
      // grid is not offered a second time under its own name.)
      if (offer.automatic)
        _PresetCard(
          key: const ValueKey('layout-automatic'),
          shape: shapeOfRows(tileRows(count)),
          label: l10n.layoutAutomatic,
          tooltip: l10n.layoutAutomaticHint,
          locked: false,
          selected: automaticNow,
          onTap: () {
            Navigator.of(context).pop();
            onApply(null);
          },
        ),
      for (final p in offer.exact) card(p),
    ];

    // The app's section header, as every section's.
    Widget caption(String text) => ZestSectionHeader(label: text);

    /// [cards] in rows of [perRow], each as wide as the next.
    List<Widget> rows(List<Widget> cards) => [
          for (var from = 0; from < cards.length; from += perRow) ...[
            if (from > 0) const SizedBox(height: 6),
            Row(children: [
              for (var i = from; i < from + perRow; i++) ...[
                if (i > from) const SizedBox(width: 6),
                Expanded(child: i < cards.length ? cards[i] : const SizedBox.shrink()),
              ],
            ]),
          ],
        ];

    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 12, color: ZestColors.textPrimary),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            caption(l10n.sessionHeaderLayout),
            if (fitting.isNotEmpty) ...[
              KeyedSubtree(
                key: const ValueKey('layout-fits'),
                child: Column(mainAxisSize: MainAxisSize.min, children: rows(fitting)),
              ),
            ],
            if (roomier.isNotEmpty) ...[
              const SizedBox(height: 12),
              caption(l10n.layoutRoomForMore),
              KeyedSubtree(
                key: const ValueKey('layout-roomier'),
                child: Column(mainAxisSize: MainAxisSize.min, children: rows(roomier.map(card).toList())),
              ),
            ],
            // What the locked ones need, said once.
            if (!isPro && [...offer.exact, ...roomier].any((p) => p.panes > freeSessionLimit)) ...[
              const SizedBox(height: 10),
              _HoverBox(
                onTap: onUpgrade == null
                    ? null
                    : (_) {
                        Navigator.of(context).pop();
                        onUpgrade!();
                      },
                builder: (hover) => Padding(
                  key: const ValueKey('layout-more-with-squeezed'),
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                  child: Row(
                    children: [
                      Icon(LucideIcons.lock, size: 12, color: ZestColors.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          l10n.deskLayoutMoreWithSqueezed,
                          style: TextStyle(
                            fontSize: 12,
                            color: hover && onUpgrade != null ? ZestColors.textPrimary : ZestColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// How many terminal panes [tree] has for an arrangement to hold: its
/// panes that show a terminal. The SFTP dock and places to connect that
/// stand empty are not counted.
int layoutPaneCount(PaneNode? tree) {
  var count = 0;
  for (final leaf in withoutSftp(tree)?.allLeaves ?? const <PaneLeaf>[]) {
    if (!leaf.isPlaceholder) count++;
  }
  return count;
}

/// The preset's name in the person's language. The ones that are a sum of
/// their rows ("3 + 2") are the same in every language.
String layoutPresetLabel(AppLocalizations l10n, LayoutPreset p) => switch (p) {
      LayoutPreset.single => l10n.layoutPresetSingle,
      LayoutPreset.sideBySide => l10n.layoutPresetSideBySide,
      LayoutPreset.stacked => l10n.layoutPresetStacked,
      LayoutPreset.grid2x2 => l10n.layoutPresetGrid2x2,
      LayoutPreset.oneAndTwo => l10n.layoutPresetOneAndTwo,
      LayoutPreset.twoAndOne => l10n.layoutPresetTwoAndOne,
      LayoutPreset.threeColumns => l10n.layoutPresetThreeColumns,
      LayoutPreset.threeRows => l10n.layoutPresetThreeRows,
      LayoutPreset.grid3x2 => l10n.layoutPresetGrid3x2,
      LayoutPreset.grid2x3 => l10n.layoutPresetGrid2x3,
      LayoutPreset.fourColumns => l10n.layoutPresetFourColumns,
      LayoutPreset.grid4x2 => l10n.layoutPresetGrid4x2,
      LayoutPreset.grid2x4 => l10n.layoutPresetGrid2x4,
      LayoutPreset.oneAndThree => '1 + 3',
      LayoutPreset.threeAndTwo => '3 + 2',
      LayoutPreset.twoAndThree => '2 + 3',
      LayoutPreset.oneAndFour => '1 + 4',
      LayoutPreset.fourAndThree => '4 + 3',
      LayoutPreset.threeAndFour => '3 + 4',
    };

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    super.key,
    required this.shape,
    required this.label,
    required this.locked,
    required this.onTap,
    this.selected = false,
    this.tooltip,
  });

  final PaneShape shape;
  final String label;
  final bool locked;

  /// The tab stands in this arrangement now.
  final bool selected;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _HoverBox(
      tooltip: tooltip,
      onTap: onTap == null ? null : (_) => onTap!(),
      builder: (hover) => Container(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 7),
        decoration: BoxDecoration(
          color: hover && onTap != null
              ? ZestColors.bgSurface
              : ZestColors.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? ZestColors.accentPrimary
                : hover && onTap != null
                    ? ZestColors.borderStrong
                    : ZestColors.borderDefault,
            width: selected ? 1.4 : 1,
          ),
        ),
        // A locked arrangement: its preview grey and faint, a small lock at
        // the card's corner, its name in the muted ink.
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: SizedBox(
                    width: 52,
                    height: 34,
                    child: Opacity(
                      opacity: locked ? 0.4 : 1,
                      child: LayoutDiagram(shape: shape, muted: locked),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: locked
                        ? ZestColors.textMuted
                        : selected
                            ? ZestColors.textPrimary
                            : ZestColors.textSecondary,
                  ),
                ),
              ],
            ),
            if (locked)
              Positioned(
                top: -4,
                right: 0,
                child: Icon(LucideIcons.lock, size: 10, color: ZestColors.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}

/// A split pane's own slim header: a status dot, the host's name and address,
/// and a close control that disconnects that pane's session (after asking).
/// A pane holding more than one session shows them as small tabs instead of
/// the one name. The name area is also the handle for dragging the pane onto
/// another pane to swap them.
class SlimPaneHeader extends ConsumerWidget {
  const SlimPaneHeader({
    super.key,
    required this.leafId,
    required this.sessions,
    required this.activeIndex,
    required this.isFocused,
  });

  final String leafId;
  final List<MapEntry<String, SessionState>> sessions;
  final int activeIndex;
  final bool isFocused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final active = sessions[activeIndex.clamp(0, sessions.length - 1)];

    Widget content;
    if (sessions.length < 2) {
      final hostPort = sessionHostPort(active.value);
      // One sentence to a screen reader: the pane's session, its state, and
      // whether it is the pane in front (the accent's rail says that to the
      // eye only).
      content = Semantics(
        container: true,
        label: [
          Redactable.host(active.value.connectionLabel).display,
          sessionStatusWord(l10n, active.value.status),
          if (isFocused) l10n.a11yPaneInFront,
        ].join(', '),
        excludeSemantics: true,
        child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(status: active.value.status),
          const SizedBox(width: 8),
          // The host's name first: in a narrow pane (a tab of sixteen) the
          // address gives way, the name stays readable.
          Flexible(
            child: NameFirstRow(
              key: ValueKey('pane-name-${active.key}'),
              name: Redactable.host(active.value.connectionLabel),
              nameStyle: TextStyle(
                fontSize: 11.5,
                fontWeight: isFocused ? FontWeight.w600 : FontWeight.w500,
                color: isFocused
                    ? ZestColors.textPrimary
                    : ZestColors.textSecondary,
              ),
              address: hostPort.isEmpty ? null : Redactable.address(hostPort),
              addressStyle: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: ZestColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < sessions.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Flexible(
              child: _PaneTabChip(
                session: sessions[i].value,
                selected: i == activeIndex,
                onTap: () {
                  ref.read(focusedPaneProvider.notifier).state = leafId;
                  ref.read(paneTreeProvider.notifier).setActiveTab(leafId, i);
                },
              ),
            ),
          ],
        ],
      );
    }

    // Drag this pane's header onto another pane's header to swap them.
    final handle = DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != leafId,
      onAcceptWithDetails: (d) =>
          ref.read(paneTreeProvider.notifier).swapPaneSessions(d.data, leafId),
      builder: (context, candidate, _) => Draggable<String>(
        data: leafId,
        // The copy that follows the pointer is see-through and hangs under
        // it, so what it is dragged over still shows (it was solid, and hid
        // the tab it was about to join), and it stands at the pointer
        // wherever along the header it was grabbed (grabbed at the header's
        // right end, it stood far to the left of the pointer).
        dragAnchorStrategy: hangingDragAnchor(reach: 24),
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: kDragGhostOpacity,
            child: Container(
              height: kPaneHeaderHeight,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: ZestColors.chromeElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: ZestColors.accentPrimary.withValues(alpha: 0.6)),
              ),
              alignment: Alignment.centerLeft,
              child: content,
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: _fill(content)),
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: Container(
            color: candidate.isNotEmpty
                ? ZestColors.accentPrimary.withValues(alpha: 0.10)
                : Colors.transparent,
            child: _fill(content),
          ),
        ),
      ),
    );

    // The pane in front, and every pane its tab's broadcast types into, have
    // the accent's 2px rail along the top of the header, and nothing more:
    // no box around the pane (it was a box on some layouts, an orange edge
    // on others, and a 2px orange box around every pane typed into).
    final typedInto = paneReceivesBroadcast(ref, active.key);
    final rail = isFocused
        ? ZestColors.accentPrimary
        : typedInto
            ? ZestColors.accentPrimary.withValues(alpha: 0.55)
            : Colors.transparent;
    return Container(
      key: ValueKey('pane-header-$leafId'),
      height: kPaneHeaderHeight,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(
          top: BorderSide(color: rail, width: 2),
          bottom: BorderSide(color: ZestColors.borderDefault),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: handle),
          // While the tab broadcasts: whether this pane is typed into, and
          // a click that leaves it out or takes it back.
          PaneBroadcastToggle(sessionId: active.key),
          _HoverBox(
            tooltip: l10n.sessionInfoDisconnect,
            // Which pane's session it ends, to a screen reader; a target of
            // 32 across and the header's 30 down to a mouse (it drew 22).
            label: l10n.a11yDisconnectNamed(Redactable.host(active.value.connectionLabel).display),
            grow: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            onTap: (_) => confirmDisconnectSession(
                context, ref, active.key, active.value),
            builder: (hover) => Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hover
                    ? ZestColors.statusError.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(
                LucideIcons.x,
                size: 13,
                color: hover ? ZestColors.statusError : ZestColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _fill(Widget content) => SizedBox(
        height: kPaneHeaderHeight,
        child: Align(alignment: Alignment.centerLeft, child: content),
      );
}

class _PaneTabChip extends StatelessWidget {
  const _PaneTabChip({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final SessionState session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _HoverBox(
      // Its name and its state to a screen reader, selected while it is the
      // pane's tab in front; the header's 30 down to a mouse.
      label: '${Redactable.host(session.connectionLabel).display}, ${sessionStatusWord(l10n, session.status)}',
      selected: selected,
      grow: const EdgeInsets.symmetric(vertical: 4),
      onTap: (_) => onTap(),
      builder: (hover) => Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? ZestColors.chromeElevated
              : hover
                  ? ZestColors.surfaceRaisedAlt
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: selected ? ZestColors.borderDefault : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusDot(status: session.status),
            const SizedBox(width: 6),
            Flexible(
              child: RedactedText(
                Redactable.host(session.connectionLabel),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: selected
                      ? ZestColors.textPrimary
                      : ZestColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final SessionStatus status;

  @override
  Widget build(BuildContext context) => SessionStatusMark(status: status, size: 7);
}


/// Hover + tap wrapper that hands its own [RenderBox] to the tap handler, so
/// a menu can anchor under exactly this widget.
/// The session chrome's buttons: the header's, its status chip, a split
/// pane's. A button to a screen reader, with its words or its tooltip as its
/// name and [toggled] as its state where it is one that turns on and off; a
/// stop of Tab to a keyboard, Enter or Space pressing it, ringed in the
/// accent while it has the focus (4.0 accessibility pass: a GestureDetector
/// alone, it was neither a button nor reachable without a mouse).
class _HoverBox extends StatefulWidget {
  const _HoverBox({
    required this.builder,
    this.onTap,
    this.tooltip,
    this.toggled,
    this.selected,
    this.label,
    this.grow,
    this.radius = 8,
  });

  final Widget Function(bool hover) builder;
  final void Function(RenderBox box)? onTap;
  final String? tooltip;
  final bool? toggled;
  final bool? selected;

  /// What a screen reader calls it, in place of its words and its tooltip.
  final String? label;

  /// How far its target reaches past what it draws ([HitArea]).
  final EdgeInsets? grow;

  /// The focus ring's corners, as the box drawn inside it.
  final double radius;

  @override
  State<_HoverBox> createState() => _HoverBoxState();
}

class _HoverBoxState extends State<_HoverBox> {
  bool _hover = false;
  bool _focused = false;

  void _tap() {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null) widget.onTap!(box);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    // The app's hand-drawn button (ZestPressable): its ring, its keys and
    // its words to a screen reader; drawn as before (no least size of its
    // own: [grow] takes its target past what it draws where it is small).
    Widget child = ZestPressable(
      onTap: enabled ? _tap : null,
      minSize: 0,
      borderRadius: widget.radius,
      toggled: widget.toggled,
      selected: widget.selected,
      semanticLabel: widget.label,
      excludeChildSemantics: widget.label != null,
      onHover: (h) => setState(() => _hover = h),
      onFocusChange: (f) => setState(() => _focused = f),
      child: widget.builder((_hover || _focused) && enabled),
    );
    if (widget.grow != null) child = HitArea(grow: widget.grow!, child: child);
    if (widget.tooltip != null) {
      child = Tooltip(message: widget.tooltip!, excludeFromSemantics: widget.label != null, child: child);
    }
    return child;
  }
}
