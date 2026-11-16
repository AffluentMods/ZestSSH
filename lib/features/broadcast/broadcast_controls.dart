import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/broadcast_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart' show HeaderButton, sessionHostPort;
import 'package:zestssh/ui/widgets/name_first_row.dart';
import 'package:zestssh/ui/widgets/session_status_mark.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/features/hosts/widgets/section_label.dart' show SectionLink;

// Broadcast in the main window (3.0): its own button in the session header,
// beside Layout, with a pop-over that switches it on for the tab in front and
// says which of its terminals get what is typed; and on each pane's own
// header, while the tab broadcasts, a switch that leaves that pane out or
// takes it back. (It used to be a switch at the foot of the Layout pop-over,
// and nothing on a pane said whether it was typed into.)

/// The session header's Broadcast button: lit while the tab in front
/// broadcasts. A click opens [BroadcastPopover] under it.
class BroadcastButton extends ConsumerWidget {
  const BroadcastButton({super.key, this.showLabel = true});

  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tabId = ref.watch(activeWorkTabIdProvider);
    final on = tabId != null && ref.watch(broadcastModeProvider.select((s) => s.broadcasts(tabId)));
    final shortcut = ref.watch(shortcutBindingProvider(ShortcutAction.toggleBroadcast));
    return Builder(
      builder: (btnContext) => HeaderButton(
        key: const ValueKey('broadcast-button'),
        icon: LucideIcons.radio,
        label: on ? l10n.broadcastButtonOn : l10n.terminalBroadcast,
        showLabel: showLabel,
        // Lit as every header button that is on: the title bar's pill is
        // what says it in the accent (it was orange here too).
        on: on,
        tooltip: shortcut == null ? l10n.broadcastButtonTooltip : '${l10n.broadcastButtonTooltip} ($shortcut)',
        trailing: Icon(LucideIcons.chevronDown, size: 11, color: ZestColors.textTertiary),
        onTap: () => showBroadcastPopover(
          btnContext,
          onChooseHosts: () => broadcastToHostsFlow(btnContext, ref),
          onRunOnHosts: () => showRunOnHosts(btnContext),
        ),
      ),
    );
  }
}

/// Opens the Broadcast pop-over under the widget at [anchorContext], right
/// aligned to it. [onChooseHosts] opens "Broadcast to hosts" once the
/// pop-over is closed.
void showBroadcastPopover(BuildContext anchorContext, {VoidCallback? onChooseHosts, VoidCallback? onRunOnHosts}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchorContext).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) return;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  final right = overlay.size.width - origin.dx - box.size.width;
  showMenu<void>(
    context: anchorContext,
    position: RelativeRect.fromLTRB(
      overlay.size.width - right - BroadcastPopover.width,
      origin.dy + box.size.height + 4,
      right,
      0,
    ),
    color: ZestColors.chromeElevated,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: ZestColors.borderDefault),
    ),
    constraints: const BoxConstraints(minWidth: BroadcastPopover.width, maxWidth: BroadcastPopover.width),
    items: [
      // One live item: its controls stay interactive while it is open.
      PopupMenuItem<void>(
        enabled: false,
        padding: EdgeInsets.zero,
        child: BroadcastPopover(onChooseHosts: onChooseHosts, onRunOnHosts: onRunOnHosts),
      ),
    ],
  );
}

/// Broadcast for the tab in front: on or off, and while it is on, which of
/// its terminals get what is typed (each can be left out, and all taken back
/// at once), with what the risky command check does.
class BroadcastPopover extends ConsumerWidget {
  const BroadcastPopover({super.key, this.onChooseHosts, this.onRunOnHosts});

  static const double width = 340;

  /// Opens "Broadcast to hosts" (the pop-over closes first). Left out, the
  /// pop-over does not offer it.
  final VoidCallback? onChooseHosts;

  /// Opens "Run on hosts" (the pop-over closes first): one command on many
  /// hosts without a terminal, with each one's result (3.0).
  final VoidCallback? onRunOnHosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tab = ref.watch(activeWorkTabProvider);
    final state = ref.watch(broadcastModeProvider);
    final sessions = ref.watch(activeSessionsProvider);
    final guardOn = ref.watch(dangerousCommandProtectionProvider);
    final terminals = tab == null ? const <String>[] : terminalsOf(tab, away: ref.watch(broadcastAwayProvider));
    final on = tab != null && state.broadcasts(tab.id);
    final can = terminals.length >= kBroadcastFewest;
    final leftOut = tab == null ? const <String>{} : state.leftOut(tab.id);
    final notifier = ref.read(broadcastModeProvider.notifier);

    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 12, color: ZestColors.textPrimary),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The app's section header, as every section's.
            ZestSectionHeader(label: l10n.terminalBroadcast),
            // The switch, its name and what it does are one control to a
            // screen reader (4.0 accessibility pass: the switch had no name).
            Opacity(
              opacity: can || on ? 1 : 0.55,
              child: MergeSemantics(
                child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.broadcastSwitchTitle,
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        // The pop-over's words keep their last two together
                        // ("below.", "all" and "asking." were alone on a
                        // line).
                        Text(
                          noOrphan(!can && !on
                              ? l10n.bcastPopNeedsSplit
                              : on
                                  ? l10n.broadcastSwitchOnHint
                                  : l10n.broadcastSwitchHint),
                          style: TextStyle(fontSize: 11.5, height: 1.35, color: ZestColors.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ZestSwitch(key: const ValueKey('broadcast-switch'), value: on, onChanged: tab != null && (can || on)
                        ? (v) => v ? notifier.startTab(tab.id) : notifier.stopTab(tab.id)
                        : null),
                ],
              ),
              ),
            ),
            if (on) ...[
              const SizedBox(height: 14),
              ZestSectionHeader(
                label: l10n.broadcastReceiversCaption,
                trailing: leftOut.isEmpty
                    ? null
                    : SectionLink(
                        key: const ValueKey('broadcast-include-all'),
                        label: l10n.broadcastIncludeAll,
                        onTap: () => notifier.receiveAll(tab.id),
                      ),
              ),
              // (A long tab scrolls here, the pop-over stays its size.)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final id in terminals)
                        if (sessions[id] case final session?)
                          _ReceiverRow(
                            key: ValueKey('broadcast-receiver-$id'),
                            session: session,
                            receives: !leftOut.contains(id),
                            onChanged: (receives) => notifier.setReceiving(tab.id, id, receives),
                          ),
                    ],
                  ),
                ),
              ),
            ],
            if (onChooseHosts != null || onRunOnHosts != null) const SizedBox(height: 8),
            // Hosts that are not open yet, opened together for it.
            if (onChooseHosts case final choose?)
              _PopoverAction(
                key: const ValueKey('broadcast-choose-hosts'),
                icon: LucideIcons.plus,
                label: l10n.bcastPopOpenSeveral,
                onTap: () {
                  Navigator.of(context).pop();
                  choose();
                },
              ),
            // One command on many hosts, each with its result, and no
            // terminal to watch (3.0).
            if (onRunOnHosts case final runOn?)
              _PopoverAction(
                key: const ValueKey('broadcast-run-on-hosts'),
                icon: LucideIcons.listChecks,
                label: l10n.bcastPopRunOnSeveral,
                onTap: () {
                  Navigator.of(context).pop();
                  runOn();
                },
              ),
            const SizedBox(height: 12),
            Divider(height: 1, color: ZestColors.borderDefault),
            const SizedBox(height: 12),
            // The risky command check, switched here where it matters most:
            // before a line reaches every terminal of the tab. It is the
            // app's one "Dangerous command protection" setting (snippets and
            // pastes ask by it too), on unless the person turned it off. One
            // control to a screen reader with its words.
            MergeSemantics(
              child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    guardOn ? LucideIcons.shieldCheck : LucideIcons.shieldAlert,
                    size: 16,
                    color: guardOn ? ZestColors.textSecondary : ZestColors.statusWarning,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.bcastPopRiskyTitle,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        noOrphan(guardOn ? l10n.bcastPopRiskyOn : l10n.bcastPopRiskyOff),
                        key: const ValueKey('broadcast-risky-line'),
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          color: guardOn ? ZestColors.textTertiary : ZestColors.statusWarning,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: l10n.bcastPopRiskyTooltip(l10n.settingsInlineDangerousCommandProtection),
                  child: ZestSwitch(
                    key: const ValueKey('broadcast-risky-switch'),
                    value: guardOn,
                    // Saved, as Settings saves it.
                    onChanged: (v) => ref.read(settingsUpdaterProvider).setDangerousCommandProtection(v),
                  ),
                ),
              ],
            ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the pop-over's ways on (a row as wide as the pop-over, its icon
/// and its words to the left, as a menu's items): the words may take two
/// lines, and stay left aligned.
class _PopoverAction extends StatefulWidget {
  const _PopoverAction({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_PopoverAction> createState() => _PopoverActionState();
}

class _PopoverActionState extends State<_PopoverAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = _hover ? ZestColors.textPrimary : ZestColors.textSecondary;
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: _hover ? ZestColors.surfaceRaisedAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(widget.icon, size: 16, color: fg),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(noOrphan(widget.label), style: TextStyle(fontSize: 12.5, height: 1.35, color: fg)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One terminal of the tab in the pop-over: its status, its host's name
/// first and the address after it where there is room, and whether it gets
/// what is typed. A click anywhere on it changes that.
class _ReceiverRow extends StatelessWidget {
  const _ReceiverRow({super.key, required this.session, required this.receives, required this.onChanged});

  final SessionState session;
  final bool receives;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final hostPort = sessionHostPort(session);
    // One control to a screen reader: the terminal, its state and its box
    // (the box had no name; the dot's colour said the state to the eye only).
    return MergeSemantics(
      child: InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onChanged(!receives),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        // The box first, as in every list of choices of the app.
        child: Row(
          children: [
            Checkbox(
              value: receives,
              onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 6),
            Semantics(
              label: sessionStatusWord(AppLocalizations.of(context)!, session.status),
              child: SessionStatusMark(status: session.status, size: 7),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: NameFirstRow(
                name: Redactable.host(session.connectionLabel),
                nameStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: receives ? ZestColors.textPrimary : ZestColors.textTertiary,
                ),
                address: hostPort.isEmpty ? null : Redactable.address(hostPort),
                addressStyle: TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono', color: ZestColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// On a pane's own header while its tab broadcasts: whether this terminal
/// gets what is typed (lit) or is left out (dim), and a click that changes
/// it. Nothing while the tab does not broadcast, nor for a terminal that is
/// no part of it (behind another in its pane, or in a window of its own).
/// Whether the pane of [sessionId] is typed into by its tab's broadcast now
/// (its header carries the accent's rail then).
bool paneReceivesBroadcast(WidgetRef ref, String sessionId) {
  final tab = ref.watch(activeWorkTabProvider);
  final state = ref.watch(broadcastModeProvider);
  if (tab == null || !state.broadcasts(tab.id)) return false;
  final terminals = terminalsOf(tab, away: ref.watch(broadcastAwayProvider));
  return terminals.contains(sessionId) && !state.leftOut(tab.id).contains(sessionId);
}

class PaneBroadcastToggle extends ConsumerStatefulWidget {
  const PaneBroadcastToggle({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PaneBroadcastToggle> createState() => _PaneBroadcastToggleState();
}

class _PaneBroadcastToggleState extends ConsumerState<PaneBroadcastToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tab = ref.watch(activeWorkTabProvider);
    final state = ref.watch(broadcastModeProvider);
    if (tab == null || !state.broadcasts(tab.id)) return const SizedBox.shrink();
    final terminals = terminalsOf(tab, away: ref.watch(broadcastAwayProvider));
    if (!terminals.contains(widget.sessionId)) return const SizedBox.shrink();
    final receives = !state.leftOut(tab.id).contains(widget.sessionId);
    // A quiet icon: that the pane is typed into is said by the accent's rail
    // along its header (an orange chip on every pane was too much orange).
    final color = receives ? ZestColors.textSecondary : ZestColors.textDisabled;
    return Tooltip(
      message: receives ? l10n.broadcastPaneReceives : l10n.broadcastPaneLeftOut,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: ValueKey('pane-broadcast-${widget.sessionId}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => ref.read(broadcastModeProvider.notifier).setReceiving(tab.id, widget.sessionId, !receives),
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? ZestColors.surfaceRaisedAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(LucideIcons.radio, size: 13, color: color),
          ),
        ),
      ),
    );
  }
}
