import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/features/hosts/data/folder_icon_catalog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

// How a list of hosts is laid out, the same everywhere:
// with Active first on, the hosts with an open session stand first,
// and the rest under them; inside each the usual groups in their usual order,
// a group's heading only where it has a host there, and among the active ones
// the last used first. With it off, the list as it always was. One switch at
// the top right of each list, remembered per place on this device: on where
// something is run on the host (Run snippet on…, Run on, Broadcast, a
// workflow's run), off everywhere else.

/// The lists and pickers of hosts, each with its own Active first.
enum HostListPlace {
  broadcast(activeFirstByDefault: true),
  runOnHosts(activeFirstByDefault: true),
  runSnippet(activeFirstByDefault: true),
  workflowRun(activeFirstByDefault: true),
  pickHost(activeFirstByDefault: false),
  workflowTarget(activeFirstByDefault: false),
  installKey(activeFirstByDefault: false),
  thresholds(activeFirstByDefault: false),
  hostsPanel(activeFirstByDefault: false),
  hostsPage(activeFirstByDefault: false),
  phoneHosts(activeFirstByDefault: false);

  const HostListPlace({required this.activeFirstByDefault});

  final bool activeFirstByDefault;
}

/// Where each place's Active first is kept in the store: a setting, which
/// "Reset all settings" puts back ([SettingsService.resetPrefixes]).
const String kActiveFirstPrefix = 'active_first_';

/// Whether [HostListPlace] shows its hosts Active first.
final activeFirstProvider = StateProvider.family<bool, HostListPlace>((ref, place) {
  try {
    final kept = ref.read(sharedPreferencesProvider).getBool('$kActiveFirstPrefix${place.name}');
    return kept ?? place.activeFirstByDefault;
  } catch (_) {
    // No store in this scope (a test of something else).
    return place.activeFirstByDefault;
  }
});

/// Turns [place]'s Active first on or off, and remembers it on this device.
void setActiveFirst(WidgetRef ref, HostListPlace place, bool on) {
  ref.read(activeFirstProvider(place).notifier).state = on;
  try {
    // ignore: discarded_futures
    ref.read(sharedPreferencesProvider).setBool('$kActiveFirstPrefix${place.name}', on);
  } catch (_) {
    // No store in this scope: it lasts as long as the page.
  }
}

/// The hosts by id, each with its identity and group: what a host's row says
/// of a host when it is handed only the host.
final hostsByIdProvider = Provider<Map<String, ConnectionWithDetails>>((ref) {
  final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  return {for (final h in hosts) h.connection.id: h};
});

/// The hosts with a session open, or on its way to open.
final openHostIdsProvider = Provider<Set<String>>((ref) {
  return openHostIdsOf(ref.watch(activeSessionsProvider));
});

/// The hosts of [sessions] with a session open, or on its way to open.
Set<String> openHostIdsOf(Map<String, SessionState> sessions) => {
      for (final s in sessions.values)
        if (s.connectionId != null && (s.status == SessionStatus.connected || s.status == SessionStatus.connecting))
          s.connectionId!,
    };

/// How many sessions each host of [sessions] has open, or on their way to
/// open (as [openHostIdsOf] counts them), by host.
Map<String, int> openSessionCountsOf(Map<String, SessionState> sessions) {
  final out = <String, int>{};
  for (final s in sessions.values) {
    final id = s.connectionId;
    if (id == null || (s.status != SessionStatus.connected && s.status != SessionStatus.connecting)) continue;
    out[id] = (out[id] ?? 0) + 1;
  }
  return out;
}

/// When each host's session was last the one in front on this run of the app,
/// by host: "last used", for the hosts with sessions open. (A host's own
/// lastConnected says when it was connected to, and stands in where a session
/// has not been in front.)
final hostUseProvider = NotifierProvider<HostUseNotifier, Map<String, DateTime>>(HostUseNotifier.new);

class HostUseNotifier extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() {
    ref.listen<String?>(v3ActiveSessionTabProvider, (_, sessionId) {
      if (sessionId == null) return;
      final host = ref.read(activeSessionsProvider)[sessionId]?.connectionId;
      if (host != null) state = {...state, host: DateTime.now()};
    });
    return const {};
  }
}

/// A group and its hosts, under its heading: [group] null for the hosts in
/// none.
class HostBlock {
  const HostBlock(this.group, this.hosts);

  final ConnectionGroup? group;
  final List<ConnectionWithDetails> hosts;
}

/// A list of hosts, laid out: [active] and [rest] where it is split (Active
/// first, and a host is active), and only [rest] where it is not.
class HostListLayout {
  const HostListLayout({required this.active, required this.rest});

  final List<HostBlock> active;
  final List<HostBlock> rest;

  bool get split => active.isNotEmpty;

  /// Every host, in the order the list shows them.
  List<ConnectionWithDetails> get inOrder => [
        for (final b in active) ...b.hosts,
        for (final b in rest) ...b.hosts,
      ];
}

/// [hosts] by group: named groups in [groups]' order (one that has not come
/// from the database yet goes by the order its hosts come in), then those in
/// none. With [activeFirst], the [open] ones stand apart first, inside each
/// group the last used first ([lastUsed], else when last connected to).
HostListLayout layOutHosts(
  List<ConnectionWithDetails> hosts, {
  required List<ConnectionGroup> groups,
  required bool activeFirst,
  Set<String> open = const {},
  Map<String, DateTime> lastUsed = const {},
}) {
  List<HostBlock> blocksOf(Iterable<ConnectionWithDetails> those, {bool byUse = false}) {
    final byGroup = <String?, List<ConnectionWithDetails>>{};
    final named = <String, ConnectionGroup>{for (final g in groups) g.id: g};
    final order = <String>[for (final g in groups) g.id];
    for (final h in those) {
      final group = h.group;
      if (group != null && !named.containsKey(group.id)) {
        named[group.id] = group;
        order.add(group.id);
      }
      (byGroup[group?.id] ??= []).add(h);
    }
    if (byUse) {
      DateTime? used(ConnectionWithDetails h) => lastUsed[h.connection.id] ?? h.connection.lastConnected;
      for (final list in byGroup.values) {
        final at = {for (final (i, h) in list.indexed) h: i};
        list.sort((a, b) {
          final ua = used(a);
          final ub = used(b);
          if (ua == null && ub == null) return at[a]!.compareTo(at[b]!);
          if (ua == null) return 1;
          if (ub == null) return -1;
          final c = ub.compareTo(ua);
          return c != 0 ? c : at[a]!.compareTo(at[b]!);
        });
      }
    }
    return [
      for (final id in order)
        if (byGroup[id] != null) HostBlock(named[id], byGroup[id]!),
      if (byGroup[null] != null) HostBlock(null, byGroup[null]!),
    ];
  }

  if (!activeFirst) return HostListLayout(active: const [], rest: blocksOf(hosts));
  return HostListLayout(
    active: blocksOf(hosts.where((h) => open.contains(h.connection.id)), byUse: true),
    rest: blocksOf(hosts.where((h) => !open.contains(h.connection.id))),
  );
}

/// The switch at the top right of a list of hosts, for [place].
class ActiveFirstToggle extends ConsumerWidget {
  const ActiveFirstToggle({super.key, required this.place});

  final HostListPlace place;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final on = ref.watch(activeFirstProvider(place));
    return Tooltip(
      message: l10n.hostsActiveFirstTip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setActiveFirst(ref, place, !on),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.hostsActiveFirst, style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
              const SizedBox(width: 8),
              ZestSwitch(
                key: ValueKey('active-first-${place.name}'),
                value: on,
                onChanged: (v) => setActiveFirst(ref, place, v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A heading of a list split Active first: "ACTIVE 3", "INACTIVE 18".
class HostSectionHeading extends StatelessWidget {
  const HostSectionHeading({super.key, required this.active, required this.count});

  final bool active;
  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final style = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
      color: active ? ZestTokens.statusHealthy : ZestTokens.textTertiary,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Row(
        children: [
          Text((active ? l10n.hostsSectionActive : l10n.hostsSectionInactive).toUpperCase(), style: style),
          const SizedBox(width: 6),
          Text('$count', style: style.copyWith(fontWeight: FontWeight.w500, fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

/// The heading of a group in a list of hosts: the group's folder icon in its
/// colour, its name (masked while a screen is recorded), and what stands
/// after it. [group] null: the hosts in none.
class HostGroupHeading extends ConsumerWidget {
  const HostGroupHeading({super.key, required this.group, this.leading, this.count});

  final ConnectionGroup? group;

  /// What stands before the name (a list that ticks hosts: the group's box).
  final Widget? leading;

  /// How many it has, or how many of them are ticked or open ("2/3").
  final String? count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final g = group;
    final color = g == null
        ? null
        : resolveGroupColor(colorValue: g.colorValue, colorIndex: g.colorIndex, name: g.name);
    final icon = g == null ? null : folderIconFor(g.iconCodePoint);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 4)],
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              g == null ? l10n.hostPanelUngrouped : Redactable.group(g.name).displayIn(ref),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              count!,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                color: ZestTokens.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
