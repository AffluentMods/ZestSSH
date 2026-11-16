import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/pane_tree_provider.dart' show focusedPaneProvider;
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Opening the hosts selected on the Hosts page, all at once (its bulk bar's
/// Open): in a tab each, or in one tab side by side.

/// The most panes one tab holds: the same cap as a split made in a session
/// (the desktop shell's own, which says "Maximum 8 panes reached" past it).
const int kHostsSplitMaxPanes = 8;

/// What opening a selection did: how many opened, and the names of those that
/// did not, by why (the free plan's session limit, or the panes a tab holds).
typedef SelectedHostsOpened = ({int opened, List<String> keptByPlan, List<String> keptByPanes});

/// How the hosts open: a tab each, or one tab with them side by side.
enum OpenSelectedAs { tabs, splitPanes }

String _nameOf(Connection c) => c.label.isNotEmpty ? c.label : c.host;

/// Opens [hosts], in the order given. A host that is open already is shown,
/// not opened twice (it takes no new place on the free plan). The free plan
/// opens as many new sessions as it has room for, in order; in split panes
/// only the first [kHostsSplitMaxPanes] get a pane. The tab of the last one
/// opened (or the shared tab) is in front. Returns what was kept back.
SelectedHostsOpened openSelectedHosts(WidgetRef ref, List<Connection> hosts, OpenSelectedAs how) {
  final sessions = ref.read(activeSessionsProvider.notifier);
  final tabs = ref.read(workTabsProvider.notifier);
  final keptByPanes = <String>[];
  var wanted = hosts;
  if (how == OpenSelectedAs.splitPanes && hosts.length > kHostsSplitMaxPanes) {
    wanted = hosts.take(kHostsSplitMaxPanes).toList();
    keptByPanes.addAll(hosts.skip(kHostsSplitMaxPanes).map(_nameOf));
  }
  final ids = <String>[];
  final keptByPlan = <String>[];
  for (final host in wanted) {
    final id = sessions.startSession(host);
    if (id == null) {
      keptByPlan.add(_nameOf(host));
      continue;
    }
    tabs.onSessionCreated(id);
    ids.add(id);
  }
  if (ids.isNotEmpty) {
    var front = ids.last;
    if (how == OpenSelectedAs.splitPanes && ids.length > 1) {
      // One tab (in front), its panes in the grid a tab nobody arranged
      // stands in.
      tabs.gatherInTab(ids);
      front = ids.first;
    } else {
      final tab = tabs.tabContaining(front);
      if (tab != null) tabs.setActiveTab(tab.id);
    }
    // The sessions in front, as a click on one host's Connect does.
    ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
    ref.read(v3ActiveSessionTabProvider.notifier).state = front;
  }
  return (opened: ids.length, keptByPlan: keptByPlan, keptByPanes: keptByPanes);
}

/// [openSelectedHosts] from a click: asks once before any Telnet host (what
/// is typed there crosses the network as it is; declined, those stay
/// closed), then says what was not opened and why. False when nothing was
/// opened at all.
Future<bool> openSelectedHostsFlow(BuildContext context, WidgetRef ref, List<Connection> hosts, OpenSelectedAs how) async {
  var list = hosts;
  if (list.any((c) => c.protocol == 'telnet')) {
    final ok = await confirmUnencryptedConnection(context);
    if (!context.mounted) return false;
    if (!ok) list = [for (final c in list) if (c.protocol != 'telnet') c];
  }
  if (list.isEmpty) return false;
  final result = openSelectedHosts(ref, list, how);
  if (!context.mounted) return result.opened > 0;
  final l10n = AppLocalizations.of(context)!;
  // Host names in a toast are painted: they go through the host rule.
  String names(List<String> n) => n.map((e) => Redactable.host(e).display).join(', ');
  final why = [
    if (result.keptByPanes.isNotEmpty) l10n.hostsSelNotOpenedPanes(names(result.keptByPanes), kHostsSplitMaxPanes),
    if (result.keptByPlan.isNotEmpty) l10n.hostsSelNotOpenedPlan(names(result.keptByPlan), freeSessionLimit),
  ];
  if (why.isNotEmpty) {
    showTopSnackBar(context, why.join(' '), isWarning: true);
  }
  return result.opened > 0;
}

/// Opens [host] as a pane beside the panes of the tab in front (its grid
/// takes it), or in a tab of its own where no tab is open; a host open
/// already is moved there, not opened twice. Says why where the plan's
/// session limit, or the panes a tab holds, keep it from opening.
Future<void> openHostInSplit(BuildContext context, WidgetRef ref, Connection host) async {
  final l10n = AppLocalizations.of(context)!;
  if (host.protocol == 'telnet') {
    final ok = await confirmUnencryptedConnection(context);
    if (!ok || !context.mounted) return;
  }
  final tabs = ref.read(workTabsProvider.notifier);
  final before = ref.read(workTabsProvider).activeTabId;
  final front = before == null ? null : ref.read(workTabsProvider).tabs.where((t) => t.id == before).firstOrNull;
  if (front != null && front.paneTree.allLeaves.length >= kHostsSplitMaxPanes) {
    showTopSnackBar(context, l10n.hostsSelNotOpenedPanes(Redactable.host(_nameOf(host)).display, kHostsSplitMaxPanes),
        isWarning: true);
    return;
  }
  final id = ref.read(activeSessionsProvider.notifier).startSession(host);
  if (id == null) {
    showTopSnackBar(context, l10n.hostsSelNotOpenedPlan(Redactable.host(_nameOf(host)).display, freeSessionLimit),
        isWarning: true);
    return;
  }
  tabs.onSessionCreated(id);
  if (front != null && tabs.tabContaining(id)?.id != front.id) {
    tabs.moveSessionToTab(id, front.id);
    tabs.setActiveTab(front.id);
  }
  ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
  ref.read(v3ActiveSessionTabProvider.notifier).state = id;
}

/// Opens [host] in a pane of its own beside the pane in focus of the tab in
/// front, to its right or below it ([axis]); where no tab is open, in a tab
/// of its own. Its pane has a session of its own (a host open already is
/// opened again: two panes never share one session). Says why where the
/// plan's session limit, or the panes a tab holds, keep it from opening.
Future<void> openHostSplitting(BuildContext context, WidgetRef ref, Connection host, Axis axis) async {
  final l10n = AppLocalizations.of(context)!;
  final state = ref.read(workTabsProvider);
  final front = state.tabs.where((t) => t.id == state.activeTabId).firstOrNull;
  if (front == null) return openHostInSplit(context, ref, host);
  if (host.protocol == 'telnet') {
    final ok = await confirmUnencryptedConnection(context);
    if (!ok || !context.mounted) return;
  }
  final name = Redactable.host(_nameOf(host)).display;
  if (front.paneTree.allLeaves.length >= kHostsSplitMaxPanes) {
    showTopSnackBar(context, l10n.hostsSelNotOpenedPanes(name, kHostsSplitMaxPanes), isWarning: true);
    return;
  }
  final sessions = ref.read(activeSessionsProvider.notifier);
  // Asked before the session is started: one that the plan refuses must not
  // leave the tabs waiting for a pane that never comes.
  if (!ref.read(isProProvider) && sessions.occupiedSessionSlots >= freeSessionLimit) {
    showTopSnackBar(context, l10n.hostsSelNotOpenedPlan(name, freeSessionLimit), isWarning: true);
    return;
  }
  final focused = ref.read(focusedPaneProvider);
  final leaves = withoutSftp(front.paneTree)?.allLeaves ?? front.paneTree.allLeaves;
  final target = leaves.where((l) => l.id == focused).firstOrNull ?? leaves.first;
  final tabs = ref.read(workTabsProvider.notifier);
  tabs.expectSplitSession();
  final id = sessions.startSession(host, allowDuplicate: true);
  if (id == null) return;
  final split = PaneSplit(first: target, second: PaneLeaf.single(sessionId: id), axis: axis);
  tabs.replaceTabTree(front.id, rebalancePaneTree(replacePaneLeaf(front.paneTree, target.id, split), since: front.paneTree));
  tabs.setActiveTab(front.id);
  ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
  ref.read(v3ActiveSessionTabProvider.notifier).state = id;
}

/// Opens [host] again in a tab of its own, a new session even where it is
/// open already (a host's "Open in new tab").
void openHostInNewTab(BuildContext context, WidgetRef ref, Connection host) {
  final id = ref.read(activeSessionsProvider.notifier).startSession(host, allowDuplicate: true);
  if (id == null) {
    showTopSnackBar(
      context,
      AppLocalizations.of(context)!.hostsSelNotOpenedPlan(Redactable.host(_nameOf(host)).display, freeSessionLimit),
      isWarning: true,
    );
    return;
  }
  ref.read(workTabsProvider.notifier).onSessionCreated(id);
  ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
  ref.read(v3ActiveSessionTabProvider.notifier).state = id;
}
