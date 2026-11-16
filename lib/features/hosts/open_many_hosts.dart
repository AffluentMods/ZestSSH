import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import 'open_selected_hosts.dart';

// Opening many hosts at once (3.4,
// "Open 42 sessions?"): so many logins at once can trip fail2ban or a
// server's connection limit, so past a few the person is asked how.

/// More hosts than this opened at once, and the person is asked how first.
const int kOpenManyAskOver = 8;

/// How many hosts a batch connects to; the next batch once these have.
const int kOpenBatchSize = 5;

/// How long a batch is waited for, at most, before the next starts: a host
/// waiting for a password to be typed does not hold up the rest for good.
const Duration kOpenBatchPatience = Duration(seconds: 60);

/// How many hosts are opened: in tabs a few at a time, in tabs of split
/// panes, or a tab each all at once.
enum OpenManyAs { batches, panes, all }

String _nameOf(Connection c) => c.label.isNotEmpty ? c.label : c.host;

/// Opens [hosts] in tabs [size] at a time: each batch once the sessions of
/// the one before have connected or failed (or [patience] has gone by), so
/// the servers never see them all log in at once. The tab of the first one
/// opened comes to the front as it opens. [container] outlives the page the
/// person asked on. Returns what was kept back (by the free plan).
Future<SelectedHostsOpened> openHostsInBatches(
  ProviderContainer container,
  List<Connection> hosts, {
  int size = kOpenBatchSize,
  Duration patience = kOpenBatchPatience,
}) async {
  final keptByPlan = <String>[];
  var opened = 0;
  var shown = false;
  for (var start = 0; start < hosts.length; start += size) {
    final end = start + size > hosts.length ? hosts.length : start + size;
    final ids = <String>[];
    for (final host in hosts.sublist(start, end)) {
      final id = container.read(activeSessionsProvider.notifier).startSession(host);
      if (id == null) {
        keptByPlan.add(_nameOf(host));
        continue;
      }
      container.read(workTabsProvider.notifier).onSessionCreated(id);
      ids.add(id);
    }
    opened += ids.length;
    if (!shown && ids.isNotEmpty) {
      shown = true;
      final tabs = container.read(workTabsProvider.notifier);
      final tab = tabs.tabContaining(ids.first);
      if (tab != null) tabs.setActiveTab(tab.id);
      container.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
      container.read(v3ActiveSessionTabProvider.notifier).state = ids.first;
    }
    if (end < hosts.length && ids.isNotEmpty) await settledSessions(container, ids, patience);
  }
  return (opened: opened, keptByPlan: keptByPlan, keptByPanes: const <String>[]);
}

/// Waits until none of the sessions [ids] is still connecting (connected,
/// failed, or gone), or [patience] has gone by.
Future<void> settledSessions(ProviderContainer container, List<String> ids, Duration patience) async {
  bool done(Map<String, SessionState> all) => ids.every((id) => all[id]?.status != SessionStatus.connecting);
  if (done(container.read(activeSessionsProvider))) return;
  final waiting = Completer<void>();
  final sub = container.listen<Map<String, SessionState>>(activeSessionsProvider, (_, next) {
    if (done(next) && !waiting.isCompleted) waiting.complete();
  });
  try {
    await waiting.future.timeout(patience, onTimeout: () {});
  } finally {
    sub.close();
  }
}

/// Opens [hosts] in tabs of split panes, as many as a tab holds in each
/// ([kHostsSplitMaxPanes]), in the order given, the first of those tabs in
/// front. Returns what was kept back (by the free plan).
SelectedHostsOpened openHostsInPaneTabs(WidgetRef ref, List<Connection> hosts) {
  final sessions = ref.read(activeSessionsProvider.notifier);
  final tabs = ref.read(workTabsProvider.notifier);
  final keptByPlan = <String>[];
  String? first;
  var opened = 0;
  for (var start = 0; start < hosts.length; start += kHostsSplitMaxPanes) {
    final end = start + kHostsSplitMaxPanes > hosts.length ? hosts.length : start + kHostsSplitMaxPanes;
    final ids = <String>[];
    for (final host in hosts.sublist(start, end)) {
      final id = sessions.startSession(host);
      if (id == null) {
        keptByPlan.add(_nameOf(host));
        continue;
      }
      tabs.onSessionCreated(id);
      ids.add(id);
    }
    if (ids.isEmpty) continue;
    opened += ids.length;
    if (ids.length > 1) tabs.gatherInTab(ids);
    first ??= tabs.tabContaining(ids.first)?.id;
  }
  if (first != null) {
    tabs.setActiveTab(first);
    ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
    final front = ref.read(workTabsProvider).tabs.where((t) => t.id == first).firstOrNull;
    final sid = front?.paneTree.allLeaves.firstOrNull?.sessionIds.firstOrNull;
    if (sid != null) ref.read(v3ActiveSessionTabProvider.notifier).state = sid;
  }
  return (opened: opened, keptByPlan: keptByPlan, keptByPanes: const <String>[]);
}

/// Opens [hosts], asking first where there are more than [kOpenManyAskOver]
/// ([askOpenMany]): a few at a time (the first choice), in tabs of split
/// panes ([panes], a computer's), or all at once. No more than that, they
/// open as [few] (the Open menu's choice, a tab each by default). Asks once
/// before any Telnet host, and says what was kept back and why. False where
/// nothing was opened, or the question was cancelled.
Future<bool> openManyHostsFlow(
  BuildContext context,
  WidgetRef ref,
  List<Connection> hosts, {
  bool panes = true,
  OpenSelectedAs few = OpenSelectedAs.tabs,
}) async {
  var list = hosts;
  if (list.length <= kOpenManyAskOver) return openSelectedHostsFlow(context, ref, list, few);
  final how = await askOpenMany(context, list.length, panes: panes);
  if (how == null || !context.mounted) return false;
  if (how == OpenManyAs.all) return openSelectedHostsFlow(context, ref, list, OpenSelectedAs.tabs);
  if (list.any((c) => c.protocol == 'telnet')) {
    final ok = await confirmUnencryptedConnection(context);
    if (!context.mounted) return false;
    if (!ok) list = [for (final c in list) if (c.protocol != 'telnet') c];
  }
  if (list.isEmpty) return false;
  final l10n = AppLocalizations.of(context)!;
  void sayKept(BuildContext at, SelectedHostsOpened result) {
    if (result.keptByPlan.isEmpty || !at.mounted) return;
    final names = result.keptByPlan.map((e) => Redactable.host(e).display).join(', ');
    showTopSnackBar(at, l10n.hostsSelNotOpenedPlan(names, freeSessionLimit), isWarning: true);
  }

  if (how == OpenManyAs.panes) {
    final result = openHostsInPaneTabs(ref, list);
    sayKept(context, result);
    return result.opened > 0;
  }
  // The batches go on after the page that asked has gone; what was kept
  // back is said there while it still is.
  final container = ProviderScope.containerOf(context, listen: false);
  unawaited(openHostsInBatches(container, list).then((result) {
    if (context.mounted) sayKept(context, result);
  }));
  return true;
}

/// "Open 42 sessions?" : in tabs a
/// few at a time (chosen as it opens), in split panes (where [panes]), or
/// all at once. Null where the person cancelled.
Future<OpenManyAs?> askOpenMany(BuildContext context, int count, {bool panes = true}) {
  final l10n = AppLocalizations.of(context)!;
  var choice = OpenManyAs.batches;
  final choices = [
    (OpenManyAs.batches, l10n.bulkOpenBatches(kOpenBatchSize), l10n.bulkOpenBatchesSub(count)),
    if (panes) (OpenManyAs.panes, l10n.bulkOpenPanes(kHostsSplitMaxPanes), l10n.bulkOpenPanesSub),
    (OpenManyAs.all, l10n.bulkOpenAll, l10n.bulkOpenAllSub),
  ];
  return showZestModal<OpenManyAs>(
    context: context,
    size: ZestModalSize.compact,
    child: StatefulBuilder(
      builder: (dialog, setChoice) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.play,
        title: l10n.bulkOpenTitle(count),
        subtitle: l10n.bulkOpenSubtitle,
        primaryKey: const ValueKey('bulk-open-many-go'),
        primaryAction: (
          label: l10n.bulkOpenButton(count),
          icon: LucideIcons.play,
          onPressed: () => Navigator.of(dialog).pop(choice),
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(dialog).pop()),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (how, title, sub) in choices) ...[
              _OpenChoice(
                key: ValueKey('bulk-open-many-${how.name}'),
                title: title,
                sub: sub,
                chosen: choice == how,
                onTap: () => setChoice(() => choice = how),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
            Text(
              l10n.bulkOpenAsked(kOpenManyAskOver),
              key: const ValueKey('bulk-open-many-asked'),
              style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One way of opening, as a card with its radio: the one chosen has the
/// brand's outline.
class _OpenChoice extends StatelessWidget {
  const _OpenChoice({super.key, required this.title, required this.sub, required this.chosen, required this.onTap});

  final String title;
  final String sub;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = ZestTokens.brand;
    return Semantics(
      selected: chosen,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: Material(
        color: chosen ? Color.alphaBlend(brand.withValues(alpha: 0.06), ZestTokens.surfaceRaisedAlt) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: chosen ? brand.withValues(alpha: 0.8) : ZestTokens.borderSubtle),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: chosen ? brand : ZestTokens.borderStrong, width: chosen ? 5 : 1.4),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      const SizedBox(height: 3),
                      Text(sub, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary)),
                    ],
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
