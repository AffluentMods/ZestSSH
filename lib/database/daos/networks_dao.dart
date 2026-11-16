import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/networks.dart';

part 'networks_dao.g.dart';

/// DAO for [Networks] and [HostNetworkOverrides].
///
/// Higher-level model conversion (Drift row ↔ `Network` domain object,
/// `triggersJson` ↔ `List<NetworkTrigger>`) lives in
/// `lib/features/networks/data/network_repository.dart`. This file is
/// purely the SQL layer.
@DriftAccessor(tables: [Networks, HostNetworkOverrides])
class NetworksDao extends DatabaseAccessor<AppDatabase>
    with _$NetworksDaoMixin {
  NetworksDao(super.db);

  // ── Networks ────────────────────────────────────────────────────

  /// Watch all networks ordered by [Networks.sortOrder]. The Default
  /// network ends up last because it's stored with a very large sortOrder.
  Stream<List<NetworkRow>> watchAll() {
    return (select(networks)
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.createdAt),
          ]))
        .watch();
  }

  Future<List<NetworkRow>> getAll() {
    return (select(networks)
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.createdAt),
          ]))
        .get();
  }

  Future<NetworkRow?> getById(String id) {
    return (select(networks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<void> insertNetwork(NetworksCompanion entry) {
    return into(networks).insert(entry);
  }

  /// Insert if missing, otherwise update - used by `ensureDefaultExists`
  /// at app start so we tolerate re-runs cleanly.
  Future<void> upsertNetwork(NetworksCompanion entry) {
    return into(networks).insertOnConflictUpdate(entry);
  }

  Future<void> updateNetwork(NetworksCompanion entry) {
    return (update(networks)..where((t) => t.id.equals(entry.id.value)))
        .write(entry);
  }

  Future<void> deleteNetwork(String id) => transaction(() async {
        // Delete-propagation tombstone so the network is removed on other
        // devices; the merge cascades its host/port-forward overrides on the
        // other side. In the delete's transaction, so a delete a team vault
        // refuses leaves none.
        await attachedDatabase.tombstonesDao.mark('networks', id);
        await (delete(networks)..where((t) => t.id.equals(id))).go();
      });

  /// Update the sortOrder of one network. Repository layer calls this in
  /// a transaction with reordered ids.
  Future<void> updateSortOrder(String id, int sortOrder) {
    return (update(networks)..where((t) => t.id.equals(id)))
        .write(NetworksCompanion(sortOrder: Value(sortOrder)));
  }

  // ── HostNetworkOverrides ─────────────────────────────────────────

  Future<List<HostNetworkOverrideRow>> getOverridesForHost(String hostId) {
    return (select(hostNetworkOverrides)
          ..where((t) => t.connectionId.equals(hostId)))
        .get();
  }

  /// All override rows across every host - used by the backup/sync dump
  /// (`SyncDataService.gatherAll`). Mirrors [getAll] for the parent table.
  Future<List<HostNetworkOverrideRow>> getAllOverrides() {
    return select(hostNetworkOverrides).get();
  }

  /// First override row for a `(host, network)` pair, tolerant of accidental
  /// duplicates (earliest by `createdAt`). Used by sync restore to upsert on
  /// the logical `(connectionId, networkId)` key rather than blindly by the
  /// surrogate `id`, so two devices that independently created an override
  /// for the same pair converge onto one row instead of duplicating it or
  /// tripping [getOverride]'s single-row assumption.
  Future<HostNetworkOverrideRow?> getOverrideByPair({
    required String hostId,
    required String networkId,
  }) {
    return (select(hostNetworkOverrides)
          ..where((t) =>
              t.connectionId.equals(hostId) & t.networkId.equals(networkId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<HostNetworkOverrideRow?> getOverride({
    required String hostId,
    required String networkId,
  }) {
    return (select(hostNetworkOverrides)
          ..where((t) =>
              t.connectionId.equals(hostId) & t.networkId.equals(networkId)))
        .getSingleOrNull();
  }

  /// Live stream of every override row across all hosts - powers the
  /// networks-side aggregation (per-network override counts, Doc-3 A2/A3).
  Stream<List<HostNetworkOverrideRow>> watchAllOverrides() {
    return select(hostNetworkOverrides).watch();
  }

  /// All override rows for a single network (across every host) - the
  /// expandable "hosts overriding on this network" list (Doc-3 A3).
  Future<List<HostNetworkOverrideRow>> getOverridesForNetwork(
      String networkId) {
    return (select(hostNetworkOverrides)
          ..where((t) => t.networkId.equals(networkId)))
        .get();
  }

  Future<void> insertOverride(HostNetworkOverridesCompanion entry) {
    return into(hostNetworkOverrides).insert(entry);
  }

  Future<void> upsertOverride(HostNetworkOverridesCompanion entry) {
    return into(hostNetworkOverrides).insertOnConflictUpdate(entry);
  }

  Future<void> deleteOverride(String id) {
    return (delete(hostNetworkOverrides)..where((t) => t.id.equals(id)))
        .go();
  }

  /// Used when a host is deleted - wipes all overrides referencing it.
  Future<void> deleteOverridesForHost(String hostId) {
    return (delete(hostNetworkOverrides)
          ..where((t) => t.connectionId.equals(hostId)))
        .go();
  }

  /// Used when a network is deleted - wipes all overrides referencing it
  /// across every host. Hosts with overrides for a deleted network simply
  /// fall back to their base config.
  Future<void> deleteOverridesForNetwork(String networkId) {
    return (delete(hostNetworkOverrides)
          ..where((t) => t.networkId.equals(networkId)))
        .go();
  }
}
