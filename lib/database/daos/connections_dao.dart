import 'package:drift/drift.dart';
import 'package:zestssh/core/models/shared_pins.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/connection_groups.dart';
import 'package:zestssh/database/tables/connections.dart';
import 'package:zestssh/database/tables/identities.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;

part 'connections_dao.g.dart';

/// Joined connection row for the home screen list.
class ConnectionWithDetails {
  final Connection connection;
  final Identity? identity;
  final ConnectionGroup? group;

  ConnectionWithDetails({
    required this.connection,
    this.identity,
    this.group,
  });
}

@DriftAccessor(tables: [Connections, Identities, ConnectionGroups])
class ConnectionsDao extends DatabaseAccessor<AppDatabase>
    with _$ConnectionsDaoMixin {
  ConnectionsDao(super.db);

  /// Watch all connections ordered by group then sort order.
  Stream<List<Connection>> watchAll() {
    return (select(connections)
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) =>
                OrderingTerm(expression: t.label, mode: OrderingMode.asc),
          ]))
        .watch();
  }

  /// Watch all connections with joined identity and group data.
  Stream<List<ConnectionWithDetails>> watchAllWithDetails() {
    final query = select(connections).join([
      leftOuterJoin(
          identities, identities.id.equalsExp(connections.identityId)),
      leftOuterJoin(connectionGroups,
          connectionGroups.id.equalsExp(connections.groupId)),
    ])
      ..orderBy([
        OrderingTerm(expression: connections.sortOrder),
        OrderingTerm(
            expression: connections.label, mode: OrderingMode.asc),
      ]);

    return query.watch().map((rows) {
      return rows.map((row) {
        return ConnectionWithDetails(
          connection: row.readTable(connections),
          identity: row.readTableOrNull(identities),
          group: row.readTableOrNull(connectionGroups),
        );
      }).toList();
    });
  }

  /// Watch connections filtered by label or host.
  Stream<List<Connection>> watchFiltered(String query) {
    final pattern = '%$query%';
    return (select(connections)
          ..where((t) =>
              t.label.like(pattern) | t.host.like(pattern))
          ..orderBy([(t) => OrderingTerm(expression: t.label)]))
        .watch();
  }

  /// Count the total number of saved connections.
  Future<int> countAll() async {
    final count = connections.id.count();
    final query = selectOnly(connections)..addColumns([count]);
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<Connection>> getAll() => select(connections).get();

  Future<Connection?> getById(String id) {
    return (select(connections)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Find an existing connection matching host and port.
  ///
  /// Used by Quick Connect to reuse existing connections instead of
  /// creating duplicates.
  Future<Connection?> findByHostPort(String host, int port) {
    return (select(connections)
          ..where(
              (t) => t.host.equals(host) & t.port.equals(port))
          ..orderBy([(t) => OrderingTerm.desc(t.lastConnected)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> insertConnection(ConnectionsCompanion entry) {
    return into(connections).insert(entry);
  }

  Future<void> updateConnection(ConnectionsCompanion entry) {
    return (update(connections)..where((t) => t.id.equals(entry.id.value)))
        .write(entry);
  }

  Future<void> deleteConnection(String id) {
    return (delete(connections)..where((t) => t.id.equals(id))).go();
  }

  Future<void> touchLastConnected(String id) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(lastConnected: Value(DateTime.now())),
    );
  }

  Future<void> updateSortOrder(String id, int newOrder) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(sortOrder: Value(newOrder)),
    );
  }

  // ── Part B: home-screen card layout ──────────────────────────────

  /// Set a host's card size code (0=Medium row, 1=Large full card, 2=legacy
  /// Large, 3=Small square). 3.0 shows every host as one card and no longer
  /// sets it; the code is kept (and synced) for apps from before 3.0.
  Future<void> updateSizeTier(String id, int tier) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(sizeTier: Value(tier)),
    );
  }

  /// Pin / unpin a host (sorts it to the front of its section).
  Future<void> setPinned(String id, bool pinned) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(pinned: Value(pinned)),
    );
  }

  /// Set (or clear, with null) a host's free-text note.
  Future<void> updateNote(String id, String? note) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(note: Value(note)),
    );
  }

  /// Set (or clear, with null) a host's SFTP directory pins - a JSON array of
  /// {label,path} (schema v30). A synced column, mirroring
  /// [setPinned] / [updateNote]: fingerprint-based sync carries the change, so
  /// no updatedAt bump (a minor pin edit shouldn't resurrect a deleted host).
  Future<void> setPins(String id, String? pins) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(pins: Value(pins)),
    );
  }

  /// Set (or clear, with null) a team host's shared SFTP bookmarks (4.0,
  /// schema v56), as [sanitizeSharedPinsJson] leaves them. A column of the
  /// host's team record: in an Orchard's database the write guard refuses it
  /// where the host's vault does not let this account edit, and the change
  /// is queued for the team like any edit of the host.
  Future<void> setSharedPins(String id, String? sharedPins) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(sharedPins: Value(sanitizeSharedPinsJson(sharedPins))),
    );
  }

  // ── SFTP host default (remember-last-folder spec, section 2) ──────

  /// Remember the last remote folder a pane settled in on this host, in
  /// realpath form, with the user it was seen under. Synced with the record
  /// like [setPins]. A no-op when nothing changed, so a plain revisit never
  /// touches the row (or its `updatedAt`).
  Future<void> setLastRemotePath(
    String id, {
    required String path,
    String? user,
    DateTime? at,
  }) async {
    final q = selectOnly(connections)
      ..addColumns([connections.lastRemotePath, connections.lastRemoteUser])
      ..where(connections.id.equals(id));
    final row = await q.getSingleOrNull();
    if (row == null) return;
    if (row.read(connections.lastRemotePath) == path &&
        row.read(connections.lastRemoteUser) == user) {
      return;
    }
    await (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(
        lastRemotePath: Value(path),
        lastRemoteUser: Value(user),
        lastRemotePathAt: Value(at ?? DateTime.now()),
      ),
    );
  }

  /// "Forget last folder" (spec section 4): clear the host default. Synced,
  /// so it clears on every device.
  Future<void> clearLastRemotePath(String id) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      const ConnectionsCompanion(
        lastRemotePath: Value(null),
        lastRemoteUser: Value(null),
        lastRemotePathAt: Value(null),
      ),
    );
  }

  // ── Server Monitor (v20): agentless SSH polling opt-in ────────────

  /// Opt a host in / out of agentless SSH monitoring (v20). Synced, so it
  /// propagates to the user's other devices like [setPinned].
  Future<void> setMonitored(String id, bool monitored) {
    return (update(connections)..where((t) => t.id.equals(id))).write(
      ConnectionsCompanion(monitored: Value(monitored)),
    );
  }

  /// Watch the set of hosts the user opted in to agentless monitoring, in a
  /// stable order (sortOrder then label) so the free-tier cap ("first N")
  /// is deterministic. Drives the AgentlessMonitorPoller's target set.
  Stream<List<Connection>> watchMonitored() {
    return (select(connections)
          ..where((t) => t.monitored.equals(true))
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.label, mode: OrderingMode.asc),
          ]))
        .watch();
  }

  /// One-shot read of the monitored hosts (same order as [watchMonitored]).
  Future<List<Connection>> getMonitored() {
    return (select(connections)
          ..where((t) => t.monitored.equals(true))
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.label, mode: OrderingMode.asc),
          ]))
        .get();
  }

  /// Count how many hosts are currently opted in to monitoring - the value
  /// the free-tier "can add another monitored host" gate reads.
  Future<int> countMonitored() async {
    final count = connections.id.count();
    final query = selectOnly(connections)
      ..addColumns([count])
      ..where(connections.monitored.equals(true));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// Commit a whole arrange-mode session in ONE transaction so the
  /// db.tableUpdates listener (and therefore the cloud-sync push) fires
  /// exactly once, not once per card. Each row carries the fields the
  /// arrange grid can change.
  Future<void> applyLayout(
    List<({String id, int sortOrder, bool pinned, int sizeTier})> rows,
  ) {
    // A single Drift batch is already atomic and emits one table-update
    // event, so the auto-sync debouncer collapses a whole arrange session
    // into one push.
    return batch((b) {
      for (final r in rows) {
        b.update(
          connections,
          ConnectionsCompanion(
            sortOrder: Value(r.sortOrder),
            pinned: Value(r.pinned),
            sizeTier: Value(r.sizeTier),
          ),
          where: (t) => t.id.equals(r.id),
        );
      }
    });
  }

  /// Clear group references from all connections that use the given group.
  Future<void> clearGroupReferences(String groupId) {
    return (update(connections)..where((t) => t.groupId.equals(groupId)))
        .write(const ConnectionsCompanion(groupId: Value(null)));
  }

  /// Clear connectVia references from all connections that use the given connection as a jump host.
  ///
  /// A remote screen keeps its carrier's id (4.0): its address is as that SSH
  /// host saw it, and with no carrier it would be dialled straight from the
  /// device, on whatever network it is on. Left pointing at nothing, it is
  /// refused at connect (ZS-1808) until its person picks a carrier again (found in a
  /// 4.0 security review).
  Future<void> clearConnectViaReferences(String connectionId) {
    // VNC and RDP alike (two kind classes, one rule).
    final screens = [
      for (final p in ConnectionProtocol.values)
        if (p.isScreen) p.name,
    ];
    return (update(connections)
          ..where((t) => t.connectViaId.equals(connectionId) & (t.protocol.isNull() | t.protocol.isNotIn(screens))))
        .write(const ConnectionsCompanion(connectViaId: Value(null)));
  }

  /// Clear snippet references from all connections that use the given snippet.
  Future<void> clearSnippetReferences(String snippetId) {
    return (update(connections)..where((t) => t.snippetId.equals(snippetId)))
        .write(const ConnectionsCompanion(snippetId: Value(null)));
  }

  /// Count how many connections reference a specific identity.
  Future<int> countByIdentity(String identityId) async {
    final count = connections.id.count();
    final query = selectOnly(connections)
      ..addColumns([count])
      ..where(connections.identityId.equals(identityId));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// Watch the most recent lastConnected date for each identity.
  /// Returns a map of identityId → last used DateTime.
  Stream<Map<String, DateTime>> watchIdentityLastUsed() {
    final maxLastConnected = connections.lastConnected.max();
    final query = selectOnly(connections)
      ..addColumns([connections.identityId, maxLastConnected])
      ..where(connections.identityId.isNotNull() &
          connections.lastConnected.isNotNull())
      ..groupBy([connections.identityId]);

    return query.watch().map((rows) {
      final map = <String, DateTime>{};
      for (final row in rows) {
        final id = row.read(connections.identityId);
        final dt = row.read(maxLastConnected);
        if (id != null && dt != null) map[id] = dt;
      }
      return map;
    });
  }

  /// Watch counts of connections for all identities.
  /// Returns a map of identityId → connection count.
  Stream<Map<String, int>> watchIdentityUsageCounts() {
    final count = connections.id.count();
    final query = selectOnly(connections)
      ..addColumns([connections.identityId, count])
      ..where(connections.identityId.isNotNull())
      ..groupBy([connections.identityId]);

    return query.watch().map((rows) {
      final map = <String, int>{};
      for (final row in rows) {
        final id = row.read(connections.identityId);
        final cnt = row.read(count) ?? 0;
        if (id != null) map[id] = cnt;
      }
      return map;
    });
  }

  /// Delete all connections.
  Future<void> deleteAll() => delete(connections).go();
}
