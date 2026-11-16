import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/host_checklist.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/broadcast_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart' show confirmUnencryptedConnection;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

// "Broadcast to hosts" (3.0): pick the hosts, and they open together in one
// tab, in its grid, typing to all of them. It used to take opening each
// session, dragging each into one group, and finding the switch in the
// Layout pop-over (in 2.2.1), after which the sessions sat in a layout
// that was hard to read before a command could finally be broadcast:
// a lot of extra work for one
// command.

/// What "Broadcast to hosts" made: the tab, and whether the plan's limit
/// kept some of the hosts from opening.
typedef BroadcastOpened = ({String? tabId, int opened, bool limited});

/// Opens [hosts] for typing into all at once: each one's session (a host
/// that is open already is not opened twice), together in one tab in its
/// grid, in front, broadcasting. A free plan opens as many new ones as it
/// allows, in the order given, and says the rest were kept back
/// ([limited]); hosts that are open already are gathered all the same.
BroadcastOpened openForBroadcast(WidgetRef ref, List<Connection> hosts) {
  final sessions = ref.read(activeSessionsProvider.notifier);
  final tabs = ref.read(workTabsProvider.notifier);
  final ids = <String>[];
  var limited = false;
  for (final host in hosts) {
    final id = sessions.startSession(host);
    if (id == null) {
      limited = true;
      continue;
    }
    tabs.onSessionCreated(id);
    ids.add(id);
  }
  final tab = tabs.gatherInTab(ids);
  if (tab != null) ref.read(broadcastModeProvider.notifier).startTab(tab);
  return (tabId: tab, opened: ids.length, limited: limited);
}

/// Opens "Broadcast to hosts" and, once hosts are picked, opens them for
/// broadcast ([openForBroadcast]). Null when the person backs out. [preselected]
/// are ticked as it opens (the Server monitor's Broadcast to these).
///
/// Where a Telnet host is among them the question every other way of opening
/// one asks is asked first, once for the lot: what is typed to all of them
/// crosses the network to that host as it is, a password among it. Declined,
/// the Telnet hosts are left out and the others open. (They opened with no
/// question: found in a security review.)
Future<BroadcastOpened?> showBroadcastToHosts(BuildContext context, WidgetRef ref, {Set<String> preselected = const {}}) async {
  final picked = await showZestModal<List<Connection>>(
    context: context,
    size: ZestModalSize.large,
    child: BroadcastToHostsDialog(preselected: preselected),
  );
  if (picked == null || picked.isEmpty || !context.mounted) return null;
  var hosts = picked;
  if (hosts.any((c) => c.protocol == 'telnet')) {
    final ok = await confirmUnencryptedConnection(context);
    if (!ok) hosts = [for (final c in hosts) if (c.protocol != 'telnet') c];
  }
  if (hosts.isEmpty) return null;
  return openForBroadcast(ref, hosts);
}

/// "Broadcast to hosts" from start to end: the hosts are picked, opened and
/// shown together, typing to all; a plan that let only some of them open
/// says so.
Future<void> broadcastToHostsFlow(BuildContext context, WidgetRef ref, {Set<String> preselected = const {}}) async {
  final opened = await showBroadcastToHosts(context, ref, preselected: preselected);
  if (opened == null || !context.mounted) return;
  if (opened.limited) {
    showTopSnackBar(
      context,
      AppLocalizations.of(context)!.desktopShellFreeTierLimit(freeSessionLimit),
      isError: true,
    );
  }
}

/// The fewest hosts a broadcast is for.
const kBroadcastFewestHosts = 2;

/// The hosts, by group, with a search: tick the ones to type into (the
/// redesign: the one row of a host, a group's box
/// with how many of it are ticked, chips that tick what the Server monitor
/// found, Active first, and the footer always in sight under the list).
class BroadcastToHostsDialog extends ConsumerStatefulWidget {
  const BroadcastToHostsDialog({super.key, this.preselected = const {}});

  /// Ticked as it opens.
  final Set<String> preselected;

  @override
  ConsumerState<BroadcastToHostsDialog> createState() => _BroadcastToHostsDialogState();
}

class _BroadcastToHostsDialogState extends ConsumerState<BroadcastToHostsDialog> {
  late var _picked = {...widget.preselected};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final sessions = ref.watch(activeSessionsProvider);
    final isPro = ref.watch(isProProvider);

    // (Not a host that cannot be ticked, whatever handed it over.)
    final picked = [
      for (final c in all)
        if (_picked.contains(c.connection.id) && noTerminalReason(c.connection, l10n) == null) c.connection,
    ];
    final openHere = {
      for (final s in sessions.values)
        if (s.status == SessionStatus.connected || s.status == SessionStatus.connecting) s.connectionId,
    };
    // A free plan opens [freeSessionLimit] at once; a host open already
    // takes no new place.
    final newOnes = picked.where((c) => !openHere.contains(c.id)).length;
    final room = freeSessionLimit - ref.read(activeSessionsProvider.notifier).occupiedSessionSlots;
    final overLimit = !isPro && newOnes > room;
    final enough = picked.length >= kBroadcastFewestHosts;
    // A phone's sheet scrolls as one, the keyboard taking the height of a list
    // of its own.
    final sheet = ZestSheetScope.of(context);
    final checklist = HostChecklist(
      picked: _picked,
      onChanged: (picked) => setState(() => _picked = picked),
      keyPrefix: 'broadcast',
      place: HostListPlace.broadcast,
      quickPicks: true,
    );

    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.radio,
      title: l10n.broadcastToHostsTitle,
      subtitle: l10n.broadcastToHostsSubtitle,
      bodyScrolls: sheet,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sheet) checklist else Flexible(child: checklist),
          const SizedBox(height: 8),
          if (overLimit)
            Row(
              key: const ValueKey('broadcast-hosts-limit'),
              children: [
                Icon(LucideIcons.info, size: 14, color: ZestColors.statusWarning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.broadcastToHostsLimit(freeSessionLimit),
                    style: TextStyle(fontSize: 12, color: ZestColors.statusWarning),
                  ),
                ),
              ],
            )
          else if (!enough)
            Text(
              l10n.broadcastToHostsPickTwo,
              style: TextStyle(fontSize: 12, color: ZestColors.textTertiary),
            ),
        ],
      ),
      primaryAction: (
        label: l10n.broadcastToHostsOpen(picked.length),
        icon: LucideIcons.radio,
        onPressed: enough && !overLimit ? () => Navigator.of(context).pop(picked) : null,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
