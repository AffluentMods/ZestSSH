import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import '../host_health_summary.dart';
import '../widgets/host_card.dart';

/// The active host sort mode, shared app-wide so the Hosts page and the desktop
/// host sidebar stay in lockstep: choosing a sort in either place re-sorts both.
/// In-memory (resets to [HostSortMode.recent] on relaunch), mirroring the
/// snippet library's `snippetSortModeProvider`.
final hostSortModeProvider =
    StateProvider<HostSortMode>((_) => HostSortMode.recent);

/// The sort runs the other way: a second click on the Hosts list's active
/// column head. Back to false whenever another sort is chosen (the Sort
/// menu, another column), as [hostSortModeProvider] is held: in memory.
final hostSortReversedProvider = StateProvider<bool>((_) => false);

/// The active group filter on the Hosts page: a group id, the "ungrouped"
/// sentinel ([GroupFilterChips.ungroupedFilterId]), or null for "all groups".
///
/// Held app-wide and in-memory, exactly like [hostSortModeProvider] and the
/// tag filter (`activeTagFiltersProvider`), so opening a host and returning to
/// the list preserves the chosen group instead of snapping back to "All". It
/// used to be a local `State` field on the Hosts page, which reset on every
/// rebuild, so the group had to be re-picked after each visit. Resets to null
/// on relaunch, matching the sort mode and tag filter.
final selectedGroupFilterProvider = StateProvider<String?>((_) => null);

/// How the host grid is ordered. Defaults to [recent] - most users
/// want quick access to whatever they used last.
enum HostSortMode {
  /// Most recently connected first, then never-connected hosts.
  recent,

  /// The worst health first ([HostHealthSummary.compareWorseFirst]): a
  /// critical, a warning, the readings nearest their warning lines, a muted
  /// metric, then hosts Server Monitor does not watch.
  health,

  /// Live status: connected → connecting → disconnected → offline.
  status,

  /// Alphabetical by display label, case-insensitive.
  alphabetical,

  /// Numerical IP address (10.0.0.5 < 10.0.0.20). Hosts that aren't a
  /// pure IPv4 fall back to alphabetical at the end of the list.
  ipAddress,

  /// Group color first, then alphabetical within each group.
  groupColor,

  /// The user's own drag order from Arrange mode (B5), ordered by the
  /// persisted `Connections.sortOrder`. Auto-selected when the user enters
  /// Arrange so the arrangement they make is actually shown afterward.
  /// `sortOrder` is section-local, but a stable sort + the per-group
  /// bucketing in `_buildGroupSections` keeps each section in its own
  /// manual order even when values collide across groups.
  manual;

  /// The sort's name in the person's language (each kept an English one,
  /// which the Hosts page's menu and a computer's host panel showed,
  /// whatever the language).
  String nameIn(AppLocalizations l10n) => switch (this) {
        HostSortMode.recent => l10n.hostSortRecent,
        HostSortMode.health => l10n.hostSortHealth,
        HostSortMode.status => l10n.hostSortStatus,
        HostSortMode.alphabetical => l10n.hostSortAlphabetical,
        HostSortMode.ipAddress => l10n.hostSortIpAddress,
        HostSortMode.groupColor => l10n.hostSortGroupColor,
        HostSortMode.manual => l10n.hostSortManual,
      };
}

/// Sort the hosts list per [mode], with the host's live SSH session
/// status (from `activeSessionsProvider`) and the existing health map
/// also available for ordering.
///
/// Sort is **stable** - equal-key entries preserve their original
/// relative order.
List<({HostCardData data, ConnectionWithDetails connectionWithDetails})>
    sortHostCards({
  required List<({HostCardData data, ConnectionWithDetails connectionWithDetails})> cards,
  required HostSortMode mode,
  required Map<String, SessionState> sessions,
}) {
  final sorted = List.of(cards);
  switch (mode) {
    case HostSortMode.recent:
      sorted.sort((a, b) {
        final aLast = a.connectionWithDetails.connection.lastConnected;
        final bLast = b.connectionWithDetails.connection.lastConnected;
        if (aLast == null && bLast == null) return 0;
        if (aLast == null) return 1;
        if (bLast == null) return -1;
        return bLast.compareTo(aLast); // descending
      });
    case HostSortMode.health:
      sorted.sort((a, b) => a.data.health.compareWorseFirst(b.data.health));
    case HostSortMode.status:
      sorted.sort((a, b) {
        final aRank = _statusRank(a.data, sessions);
        final bRank = _statusRank(b.data, sessions);
        return aRank.compareTo(bRank);
      });
    case HostSortMode.alphabetical:
      sorted.sort((a, b) =>
          _displayLabel(a).toLowerCase().compareTo(
              _displayLabel(b).toLowerCase()));
    case HostSortMode.ipAddress:
      sorted.sort((a, b) {
        final aHost = a.connectionWithDetails.connection.host;
        final bHost = b.connectionWithDetails.connection.host;
        final aIp = _parseIpv4(aHost);
        final bIp = _parseIpv4(bHost);
        // Pure-IP hosts come first, sorted numerically. Non-IP hosts
        // sort alphabetically at the end (so user's "ubuntu.local"
        // doesn't get jumbled in with "10.0.0.5").
        if (aIp != null && bIp != null) {
          return aIp.compareTo(bIp);
        }
        if (aIp != null) return -1;
        if (bIp != null) return 1;
        return aHost.toLowerCase().compareTo(bHost.toLowerCase());
      });
    case HostSortMode.groupColor:
      sorted.sort((a, b) {
        final aGroup = a.connectionWithDetails.group?.name ?? '';
        final bGroup = b.connectionWithDetails.group?.name ?? '';
        // Ungrouped hosts go to the end.
        if (aGroup.isEmpty && bGroup.isNotEmpty) return 1;
        if (bGroup.isEmpty && aGroup.isNotEmpty) return -1;
        final groupCmp =
            aGroup.toLowerCase().compareTo(bGroup.toLowerCase());
        if (groupCmp != 0) return groupCmp;
        return _displayLabel(a)
            .toLowerCase()
            .compareTo(_displayLabel(b).toLowerCase());
      });
    case HostSortMode.manual:
      sorted.sort((a, b) => a.connectionWithDetails.connection.sortOrder
          .compareTo(b.connectionWithDetails.connection.sortOrder));
  }
  return sorted;
}

/// Sort a plain [ConnectionWithDetails] list by [mode] - the sidebar's
/// per-section sorter. The sidebar already buckets hosts by group, so
/// [HostSortMode.groupColor] falls back to alphabetical within a section.
/// [health] is each host's health ([hostHealthSummariesProvider]), for
/// [HostSortMode.health]. Stable, like [sortHostCards].
List<ConnectionWithDetails> sortConnections({
  required List<ConnectionWithDetails> conns,
  required HostSortMode mode,
  required Map<String, SessionState> sessions,
  Map<String, HostHealthSummary> health = const {},
}) {
  final sorted = List.of(conns);
  switch (mode) {
    case HostSortMode.recent:
      sorted.sort((a, b) {
        final aLast = a.connection.lastConnected;
        final bLast = b.connection.lastConnected;
        if (aLast == null && bLast == null) return 0;
        if (aLast == null) return 1;
        if (bLast == null) return -1;
        return bLast.compareTo(aLast);
      });
    case HostSortMode.health:
      HostHealthSummary of(ConnectionWithDetails c) => health[c.connection.id] ?? HostHealthSummary.none;
      sorted.sort((a, b) => of(a).compareWorseFirst(of(b)));
    case HostSortMode.status:
      sorted.sort((a, b) => _statusRankConn(a.connection.id, sessions)
          .compareTo(_statusRankConn(b.connection.id, sessions)));
    case HostSortMode.alphabetical:
    case HostSortMode.groupColor:
      sorted.sort((a, b) =>
          _connLabel(a).toLowerCase().compareTo(_connLabel(b).toLowerCase()));
    case HostSortMode.ipAddress:
      sorted.sort((a, b) {
        final aIp = _parseIpv4(a.connection.host);
        final bIp = _parseIpv4(b.connection.host);
        if (aIp != null && bIp != null) return aIp.compareTo(bIp);
        if (aIp != null) return -1;
        if (bIp != null) return 1;
        return a.connection.host
            .toLowerCase()
            .compareTo(b.connection.host.toLowerCase());
      });
    case HostSortMode.manual:
      sorted.sort((a, b) =>
          a.connection.sortOrder.compareTo(b.connection.sortOrder));
  }
  return sorted;
}

String _connLabel(ConnectionWithDetails c) =>
    c.connection.label.isNotEmpty ? c.connection.label : c.connection.host;

int _statusRankConn(String connId, Map<String, SessionState> sessions) {
  SessionStatus? primary;
  for (final s in sessions.values) {
    if (s.connectionId == connId) {
      if (s.status == SessionStatus.connected) {
        primary = SessionStatus.connected;
        break;
      }
      if (s.status == SessionStatus.connecting) {
        primary = SessionStatus.connecting;
      } else {
        primary ??= s.status;
      }
    }
  }
  switch (primary) {
    case SessionStatus.connected:
      return 0;
    case SessionStatus.connecting:
      return 1;
    case SessionStatus.disconnected:
      return 2;
    case SessionStatus.error:
      return 2;
    case null:
      return 3;
  }
}

String _displayLabel(
    ({HostCardData data, ConnectionWithDetails connectionWithDetails}) entry) {
  final conn = entry.connectionWithDetails.connection;
  return conn.label.isNotEmpty ? conn.label : conn.host;
}

/// Rank used for status sort - lower means "show first".
int _statusRank(HostCardData data, Map<String, SessionState> sessions) {
  // Active session statuses map onto the same buckets the status pill
  // uses: connected → connecting → disconnected → offline.
  // We re-derive from the sessions map (rather than trusting
  // [HostCardData.status]) so we always match the live truth.
  SessionStatus? primary;
  for (final s in sessions.values) {
    if (s.connectionId == data.id) {
      if (s.status == SessionStatus.connected) {
        primary = SessionStatus.connected;
        break;
      }
      if (s.status == SessionStatus.connecting) {
        primary = SessionStatus.connecting;
      } else {
        primary ??= s.status;
      }
    }
  }
  switch (primary) {
    case SessionStatus.connected:
      return 0;
    case SessionStatus.connecting:
      return 1;
    case SessionStatus.disconnected:
      return 2;
    case SessionStatus.error:
      return 2;
    case null:
      return 3; // offline (no session)
  }
}

/// Parse "192.168.10.21" into a single 32-bit integer for sorting. Returns
/// null for hostnames that aren't a strict IPv4 dotted-quad.
int? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  var result = 0;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    result = (result << 8) | n;
  }
  return result;
}
