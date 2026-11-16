import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/features/hosts/widgets/host_panel_sections.dart';
import 'package:zestssh/features/hosts/widgets/host_test_views.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_thresholds_dialog.dart' show showMonitorThresholds;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/hostkeys/host_team_pin_view.dart';
import 'package:zestssh/features/orchards/widgets/crate_records_view.dart' show ItemVersionsLink;
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/orchards/widgets/crate_session_logs_view.dart' show HostSessionsLoggedNote;
import 'package:zestssh/features/orchards/widgets/crate_offline_limit_view.dart' show HostCrateClosedNote;
import 'package:zestssh/features/orchards/widgets/crate_watched_view.dart' show HostSessionsWatchedNote;
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/features/hosts/widgets/section_label.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// The host keys this space knows for a direct connection to host:port.
final hostPanelKnownKeysProvider = FutureProvider.autoDispose
    .family<List<KnownHost>, (String, int)>((ref, hp) {
  final db = ref.watch(databaseProvider);
  return db.knownHostsDao.findAllForHostPort(normalizeKnownHost(hp.$1), hp.$2);
});

/// Width of the host panel beside the Hosts grid.
const double kHostPanelWidth = 360;

/// The read-only host panel (3.0): what a host is before anyone opens the
/// editor. Its header (status, when
/// it was last connected, Edit, close), a row of quick actions (its group,
/// Copy SSH command, Open in split, Duplicate), then what the app keeps of
/// it, each section only where it has something to say: its health (with an
/// alert choice per metric) or the way to have it watched, its recent
/// sessions, its port forwards, how it connects, its key, tmux, Wake-on-LAN,
/// its tags and its note; then SFTP and Connect (or Switch to session while
/// one is open).
class HostPanel extends ConsumerWidget {
  const HostPanel({
    super.key,
    required this.card,
    required this.item,
    required this.onClose,
    required this.onConnect,
    required this.onSwitchTo,
    required this.onOpenSftp,
    required this.onOpenTmux,
    required this.onEdit,
    this.onShowGroup,
    this.onOpenInSplit,
    this.onDuplicate,
    this.onOpenMonitor,
    this.onOpenHistory,
    this.onMore,
  });

  final HostCardData card;
  final ConnectionWithDetails item;
  final VoidCallback onClose;
  final VoidCallback onConnect;
  final ValueChanged<String> onSwitchTo;
  final VoidCallback onOpenSftp;
  final VoidCallback onOpenTmux;
  final VoidCallback onEdit;

  /// The group chip: the page shows only that group's hosts.
  final ValueChanged<String>? onShowGroup;

  /// Open in split: the host as a pane beside the tab in front.
  final VoidCallback? onOpenInSplit;

  /// Duplicate (null where this space adds nothing).
  final VoidCallback? onDuplicate;

  /// Server monitor, from the health section's head.
  final VoidCallback? onOpenMonitor;

  /// The command history, from the recent sessions' head.
  final VoidCallback? onOpenHistory;

  /// The host's menu (what a right click on its card holds), opened at the
  /// given place: a more button at the foot, beside Connect, where the
  /// controls are touch sized (4.0, a tablet in landscape).
  final ValueChanged<Offset>? onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final conn = item.connection;
    final sessions = ref.watch(activeSessionsProvider);
    final live = sessions.entries
        .where((e) =>
            e.value.connectionId == conn.id &&
            (e.value.status == SessionStatus.connected ||
                e.value.status == SessionStatus.connecting))
        .firstOrNull;
    final view = ref.watch(monitoredHostViewsProvider)[conn.id];
    final tmux = ref.watch(tmuxSessionCountsProvider)[conn.id] ?? 0;
    final forwards = ref.watch(portForwardRulesForConnectionProvider(conn.id)).valueOrNull ?? const <PortForwardRule>[];
    final label = AppColors.resolveConnectionLabelColorOrNull(
      connColorValue: card.colorValue,
      connColorIndex: card.colorIndex,
      inheritedGroupColor: card.groupColor,
    );
    // The tile behind the icon is in the icon's colour (its own unless the
    // person chose otherwise); behind an uploaded picture, which has no one
    // colour, it is in the host's.
    final hasPicture = card.customIcon?.isNotEmpty ?? false;
    final iconTile = hasPicture
        ? (label ?? ZestColors.textTertiary)
        : OsIcon.seen(HostIconColor.tint(card.iconColor, labelColor: label) ??
            OsCatalog.get(card.iconId ?? card.osId).brandColor);
    final statusWord = live == null
        ? l10n.hostPanelNotConnected
        : live.value.status == SessionStatus.connected
            ? l10n.sessionInfoStatusConnected
            : l10n.sessionInfoStatusConnecting;
    final statusColor = live == null
        ? ZestColors.textDisabled
        : live.value.status == SessionStatus.connected
            ? ZestColors.statusSuccess
            : ZestColors.statusWarning;
    // Not open: when it last was. Where it takes two lines beside Edit, they
    // break between its parts ("last" was left on the first
    // before).
    final status = live == null && conn.lastConnected != null
        ? breakAtDots('$statusWord · ${l10n.hpanelLastSession(timeAgoInSentence(l10n, conn.lastConnected!))}')
        : statusWord;
    final group = item.group;
    // Only hosts reached over SSH can be watched (the monitor reads them so).
    final watchable = conn.protocol.toLowerCase() == 'ssh';
    final hostName = conn.label.isNotEmpty ? conn.label : conn.host;
    final user = item.identity?.username ?? 'root';
    // A remote screen is signed in to by no user: its card's own line, which
    // says where it listens and the host it is reached through.
    final address = ConnectionProtocol.storedIsScreen(conn.protocol)
        ? Redactable.freeText(card.subtitle).displayIn(ref)
        : '${Redactable.username(user).displayIn(ref)}@${Redactable.address(conn.host).displayIn(ref)}:${conn.port}';

    return Container(
      width: kHostPanelWidth,
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(left: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The icon in its own tile, as on the host's card (one tile:
                // a tile inside a tile looked like a frame).
                Container(
                  key: const ValueKey('host-panel-icon-tile'),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconTile.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: HostIcon(
                    iconId: card.iconId,
                    customIcon: card.customIcon,
                    osId: card.osId,
                    size: 40,
                    cornerRadius: 9,
                    iconColor: card.iconColor,
                    labelColor: label,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(
                        Redactable.host(card.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: ZestColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              status,
                              key: const ValueKey('host-panel-status'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: ZestColors.textTertiary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ZestButton(
                  key: const ValueKey('host-panel-edit'),
                  label: l10n.hostPanelEdit,
                  icon: LucideIcons.pencil,
                  onPressed: onEdit,
                ),
                const SizedBox(width: 4),
                _PanelIconButton(
                  key: const ValueKey('host-panel-close'),
                  icon: LucideIcons.x,
                  tooltip: l10n.sessionDetailsClosePanel,
                  onTap: onClose,
                ),
              ],
            ),
          ),
          // ── Quick actions ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (group != null)
                  _QuickChip(
                    key: const ValueKey('host-panel-group'),
                    leading: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: card.groupColor ?? ZestColors.textTertiary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    label: Redactable.group(group.name).displayIn(ref),
                    onTap: onShowGroup == null ? null : () => onShowGroup!(group.id),
                  ),
                if (watchable)
                  _QuickChip(
                    key: const ValueKey('host-panel-copy-ssh'),
                    icon: LucideIcons.copy,
                    label: l10n.hpanelCopySsh,
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: sshCommandFor(item)));
                      if (context.mounted) showTopSnackBar(context, l10n.hpanelCopiedSsh, isSuccess: true);
                    },
                  ),
                if (onOpenInSplit != null)
                  _QuickChip(
                    key: const ValueKey('host-panel-split'),
                    icon: LucideIcons.columns,
                    label: l10n.hpanelOpenInSplit,
                    onTap: onOpenInSplit,
                  ),
                if (onDuplicate != null)
                  _QuickChip(
                    key: const ValueKey('host-panel-duplicate'),
                    icon: LucideIcons.copyPlus,
                    label: l10n.commonDuplicate,
                    onTap: onDuplicate,
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: ZestColors.borderDefault),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                // Health: watched, its figures; not, the way to watch it.
                if (watchable) ...[
                  _Head(
                    label: l10n.hostPanelHealth,
                    action: view == null ? null : l10n.desktopServerMonitor,
                    onAction: onOpenMonitor,
                    menu: view == null ? null : (at) => _healthMenu(context, ref, at, conn.id),
                  ),
                  if (view == null)
                    HostPanelWatch(connectionId: conn.id)
                  else
                    HostPanelHealth(connectionId: conn.id, hostName: hostName, view: view),
                ],
                if (HostPanelRecentSessions.hasAny(ref, conn.id)) ...[
                  _Head(label: l10n.hpanelRecentSessions, action: l10n.narrowSidebarHistory, onAction: onOpenHistory),
                  HostPanelRecentSessions(connectionId: conn.id),
                ],
                if (forwards.isNotEmpty) ...[
                  _Head(
                    label: l10n.hpanelPortForwards,
                    action: '+ ${l10n.hpanelAdd}',
                    onAction: () => addPortForwardFor(context, ref, conn.id),
                  ),
                  HostPanelPortForwards(rules: forwards),
                ],
                _Head(label: l10n.hostPanelConnection),
                // The Blueprint's two-column table: what on the left, its
                // value on the right, in mono where it is typed.
                _KVTable(rows: [
                  (k: l10n.hpanelAddress, v: address, mono: true),
                  if (item.identity != null)
                    (
                      k: l10n.hostPanelKey,
                      v: item.identity!.keyType == null
                          ? item.identity!.label
                          : '${item.identity!.label} (${item.identity!.keyType})',
                      mono: false,
                    ),
                ]),
                // The editor's two tests, on the host as it is saved,
                // for what the editor offers them on.
                if (hostProtocolCanBeTested(conn.protocol))
                  HostPanelTests(key: ValueKey('host-panel-tests-${conn.id}'), item: item),
                // Its versions, where the team records history (3.0).
                ItemVersionsLink(kind: 'host', itemKey: conn.id, name: conn.label),
                // Logged for its team, said before connecting.
                HostSessionsLoggedNote(connectionId: conn.id),
                // Watched: a session starts once someone has joined.
                HostSessionsWatchedNote(connectionId: conn.id),
                // Its Crate is closed on this device by its own offline
                // limit: said before anyone presses Connect.
                HostCrateClosedNote(connectionId: conn.id),
                _Head(label: l10n.sessionDetailsHostKey),
                _HostKeyBox(host: conn.host, port: conn.port, changed: card.hasChangedHostKey),
                // The team's pin for it (3.0).
                HostTeamPinBox(hostId: conn.id, host: conn.host, port: conn.port),
                if (tmux > 0) ...[
                  _Head(label: l10n.hostPanelTmux),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.hostPanelTmuxCount(tmux),
                          style: TextStyle(
                              fontSize: 12.5, color: ZestColors.textSecondary),
                        ),
                      ),
                      _Link(label: l10n.hostPanelOpenTmux, onTap: onOpenTmux),
                    ],
                  ),
                ],
                // Wake-on-LAN, for a host with an address to wake saved.
                if (canWake(conn)) ...[
                  _Head(label: l10n.connectionWakeOnLan),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          l10n.hostPanelWakeHint,
                          style: TextStyle(
                              fontSize: 12.5, height: 1.4, color: ZestColors.textSecondary),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _Link(
                        key: const ValueKey('host-panel-wake'),
                        label: l10n.connectionCardWakeWol,
                        onTap: () => wakeHost(context, ref, conn),
                      ),
                    ],
                  ),
                ],
                if (card.tags.isNotEmpty) ...[
                  _Head(label: l10n.hpanelTags),
                  Wrap(
                    key: const ValueKey('host-panel-tags'),
                    spacing: 5,
                    runSpacing: 5,
                    children: [for (final t in card.tags) HostTagChip(tag: t)],
                  ),
                ],
                if ((conn.note ?? '').trim().isNotEmpty) ...[
                  _Head(label: l10n.hostPanelNote),
                  Text(
                    conn.note!.trim(),
                    key: const ValueKey('host-panel-note'),
                    style: TextStyle(
                        fontSize: 12.5, color: ZestColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          // ── Footer ──
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: ZestColors.borderDefault)),
            ),
            // SFTP and Connect fill the foot together, Connect the larger,
            // each word in its middle (Connect sat where its words ended,
            // after a Spacer).
            child: Row(
              children: [
                // SFTP runs over SSH: a local shell's host has none.
                if (conn.protocol.toLowerCase() != 'localshell') ...[
                  Expanded(
                    child: _FooterButton(
                      key: const ValueKey('host-panel-sftp'),
                      icon: LucideIcons.folderOpen,
                      label: 'SFTP',
                      onTap: onOpenSftp,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  flex: 2,
                  child: _FooterButton(
                    key: const ValueKey('host-panel-primary'),
                    label: live == null
                        ? l10n.hostPanelConnect
                        : l10n.hostPanelSwitchToSession,
                    primary: true,
                    onTap: live == null ? onConnect : () => onSwitchTo(live.key),
                  ),
                ),
                // Touch sized: the rest of the host's menu, in sight.
                if (onMore != null && touchSizedAt(context)) ...[
                  const SizedBox(width: 8),
                  Builder(
                    builder: (button) => _FooterButton(
                      key: const ValueKey('host-panel-more'),
                      icon: LucideIcons.moreVertical,
                      tooltip: l10n.zestCommonMoreActions,
                      onTap: () {
                        final box = button.findRenderObject() as RenderBox?;
                        if (box != null) onMore!(box.localToGlobal(box.size.center(Offset.zero)));
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The health section's ⋯: this host's thresholds, or no longer watching it.
  Future<void> _healthMenu(BuildContext context, WidgetRef ref, Offset at, String id) async {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final pick = await showMenu<String>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(
          key: const ValueKey('host-panel-thresholds'),
          value: 'thresholds',
          height: 36,
          child: Text(l10n.hpanelThresholds, style: TextStyle(fontSize: 13, color: ZestColors.textPrimary)),
        ),
        PopupMenuItem(
          key: const ValueKey('host-panel-unwatch'),
          value: 'unwatch',
          height: 36,
          child: Text(l10n.monitorAgentlessStopHost, style: TextStyle(fontSize: 13, color: ZestColors.textPrimary)),
        ),
      ],
    );
    if (!context.mounted) return;
    if (pick == 'thresholds') await showMonitorThresholds(context, hostId: id);
    if (pick == 'unwatch') await ref.read(connectionsDaoProvider).setMonitored(id, false);
  }
}

/// A quick action under the panel's header: an outlined chip.
class _QuickChip extends StatefulWidget {
  const _QuickChip({super.key, required this.label, this.icon, this.leading, this.onTap});

  final String label;
  final IconData? icon;
  final Widget? leading;
  final VoidCallback? onTap;

  @override
  State<_QuickChip> createState() => _QuickChipState();
}

class _QuickChipState extends State<_QuickChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Reached with Tab, said as a button; pressed anywhere in a mouse's 32
    // (a finger's 48) around its 28 high chip (4.0, the accessibility pass).
    return ZestPressable(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        borderRadius: 7,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hover && widget.onTap != null ? ZestColors.surfaceRaisedAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: ZestColors.borderDefault),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?widget.leading,
              if (widget.icon != null) Icon(widget.icon, size: 13, color: ZestColors.textSecondary),
              const SizedBox(width: 6),
              Text(widget.label, style: TextStyle(fontSize: 12, color: ZestColors.textPrimary)),
            ],
          ),
        ),
    );
  }
}

/// A section of the panel, headed as the Blueprint heads them: the brand
/// tick, the name in capitals, a rule, and an action at its end, and a ⋯
/// where the section has a menu.
class _Head extends StatelessWidget {
  const _Head({required this.label, this.action, this.onAction, this.menu});

  final String label;
  final String? action;
  final VoidCallback? onAction;

  /// A ⋯ after the action, opening a menu where it was clicked.
  final void Function(Offset at)? menu;

  @override
  Widget build(BuildContext context) {
    final trailing = action == null ? null : SectionLink(label: action!, onTap: onAction);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ZestSectionHeader(
        label: label,
        trailing: menu == null
            ? trailing
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (trailing != null) Flexible(child: trailing),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: AppLocalizations.of(context)!.hostsListHostMenu,
                    waitDuration: const Duration(milliseconds: 500),
                    excludeFromSemantics: true,
                    // A mouse's 32 square (it was its 15 px icon), reached
                    // with Tab, said with the section it is for.
                    child: Builder(
                      builder: (button) => ZestPressable(
                        key: ValueKey('host-panel-head-menu-$label'),
                        onTap: () => menu!(globalCentreOf(button)),
                        onSecondaryTapUp: (e) => menu!(e.globalPosition),
                        semanticLabel: '${AppLocalizations.of(context)!.hostsListHostMenu}, $label',
                        excludeChildSemantics: true,
                        borderRadius: 6,
                        child: Icon(LucideIcons.moreHorizontal, size: 15, color: ZestColors.textTertiary),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Connection's rows as a bordered two-column table: the name on the raised
/// cell at the left, the value on the sunken one at the right.
class _KVTable extends StatelessWidget {
  const _KVTable({required this.rows});

  final List<({String k, String v, bool mono})> rows;

  @override
  Widget build(BuildContext context) {
    // The Inspector's read-only rows, the one way the app shows a name and
    // its value: the name at the left in the muted ink, the value at the
    // right, a hairline between rows (it was a table of raised and sunken
    // cells, a third look).
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++)
          Container(
            constraints: const BoxConstraints(minHeight: 34),
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              border: i == rows.length - 1 ? null : Border(bottom: BorderSide(color: ZestColors.borderSubtle)),
            ),
            child: Row(
              children: [
                Text(rows[i].k, style: TextStyle(fontSize: 12.5, color: ZestColors.textTertiary)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    rows[i].v,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: rows[i].mono ? 11.5 : 12.5,
                      fontFamily: rows[i].mono ? 'JetBrainsMono' : null,
                      color: ZestColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _HostKeyBox extends ConsumerWidget {
  const _HostKeyBox({
    required this.host,
    required this.port,
    required this.changed,
  });

  final String host;
  final int port;
  final bool changed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final keys = ref.watch(hostPanelKnownKeysProvider((host, port))).valueOrNull;
    final IconData icon;
    final Color tone;
    final String title;
    final String body;
    if (changed) {
      icon = LucideIcons.shieldAlert;
      tone = ZestColors.statusError;
      title = l10n.hostPanelKeyChanged;
      body = l10n.hostPanelKeyChangedBody;
    } else if (keys == null || keys.isEmpty) {
      icon = LucideIcons.shield;
      tone = ZestColors.textTertiary;
      title = l10n.hostPanelKeyUnknown;
      body = l10n.hostPanelKeyUnknownBody;
    } else {
      final first = keys
          .map((k) => k.firstSeen)
          .reduce((a, b) => a.isBefore(b) ? a : b)
          .toLocal();
      icon = LucideIcons.shieldCheck;
      tone = ZestColors.statusSuccess;
      title = l10n.hostPanelKeyKnown(
          MaterialLocalizations.of(context).formatMediumDate(first));
      body = l10n.hostPanelKeyKnownBody;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: ZestColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(body,
              style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary)),
          if (!changed && keys != null)
            for (final k in keys) ...[
              const SizedBox(height: 6),
              Text(
                '${k.keyType}  ${k.fingerprint}',
                style: TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'JetBrainsMono',
                  color: ZestColors.textTertiary,
                ),
              ),
            ],
        ],
      ),
    );
  }
}

class _Link extends StatefulWidget {
  const _Link({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Reached with Tab, said as a button, a mouse's 32 high (it was its
    // line of 17).
    return ZestPressable(
      onTap: widget.onTap,
      onHover: (h) => setState(() => _hover = h),
      borderRadius: 4,
      child: Text(
        widget.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: _hover ? ZestColors.accentHover : ZestColors.accentInk,
        ),
      ),
    );
  }
}

class _FooterButton extends StatefulWidget {
  const _FooterButton({
    super.key,
    this.label,
    required this.onTap,
    this.icon,
    this.primary = false,
    this.tooltip,
  });

  /// Its words; none for an icon's button, named by [tooltip].
  final String? label;
  final String? tooltip;
  final IconData? icon;
  final bool primary;
  final VoidCallback onTap;

  @override
  State<_FooterButton> createState() => _FooterButtonState();
}

class _FooterButtonState extends State<_FooterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.primary;
    final fill = primary
        ? (_hover ? ZestColors.accentHover : ZestColors.accentPrimary)
        : (_hover ? ZestColors.surfaceRaisedAlt : ZestColors.chromeElevated);
    final fg = primary ? ZestColors.onBrand : ZestColors.textPrimary;
    final label = widget.label;
    final touch = touchSizedAt(context);
    final tip = widget.tooltip;
    final button = ZestPressable(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        semanticLabel: label == null ? tip : null,
        excludeChildSemantics: label == null,
        minSize: 0,
        child: Container(
          // A finger's 48 where the controls are touch sized (4.0); taller
          // where the system's text is larger.
          constraints: BoxConstraints(minHeight: touch ? 48 : 38, minWidth: label == null ? (touch ? 48 : 38) : 0),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 14),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8),
            border: primary ? null : Border.all(color: ZestColors.borderDefault),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 15, color: fg),
                if (label != null) const SizedBox(width: 7),
              ],
              if (label != null)
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ),
            ],
          ),
        ),
    );
    return tip == null ? button : Tooltip(message: tip, excludeFromSemantics: label == null, child: button);
  }
}

class _PanelIconButton extends StatefulWidget {
  const _PanelIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_PanelIconButton> createState() => _PanelIconButtonState();
}

class _PanelIconButtonState extends State<_PanelIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      excludeFromSemantics: true,
      // Pressed anywhere in a mouse's 32 (a finger's 48) around its 28,
      // reached with Tab, named for a screen reader.
      child: ZestPressable(
          onTap: widget.onTap,
          onHover: (h) => setState(() => _hover = h),
          semanticLabel: widget.tooltip,
          excludeChildSemantics: true,
          borderRadius: 6,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? ZestColors.surfaceRaisedAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon,
                size: 15,
                color: _hover ? ZestColors.textPrimary : ZestColors.textTertiary),
          ),
      ),
    );
  }
}
