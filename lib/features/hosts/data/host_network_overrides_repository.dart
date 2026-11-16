import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../database/daos/networks_dao.dart';
import '../../../database/database.dart';
import '../models/host_network_override.dart';

/// Repository for [HostNetworkOverride] rows, scoped per-host. Wraps
/// [NetworksDao]'s host_network_overrides table operations and translates
/// between the Drift row class and the domain model.
class HostNetworkOverridesRepository {
  HostNetworkOverridesRepository(this._dao);

  final NetworksDao _dao;
  static const _uuid = Uuid();

  /// Fetch all overrides for a single host. Empty list when the host has
  /// no overrides at all (the common "default behavior" case).
  Future<List<HostNetworkOverride>> listForHost(String hostId) async {
    final rows = await _dao.getOverridesForHost(hostId);
    return rows.map(_rowToModel).toList();
  }

  /// Fetch the override (if any) that applies for the given (host, network)
  /// pair. Returns null if the host has no specific override for that
  /// network - the resolver should then use the base host config.
  Future<HostNetworkOverride?> getForHostAndNetwork({
    required String hostId,
    required String networkId,
  }) async {
    final row = await _dao.getOverride(hostId: hostId, networkId: networkId);
    if (row == null) return null;
    return _rowToModel(row);
  }

  /// Live per-network override COUNTS across all hosts, excluding no-op
  /// (empty) rows - powers the networks-side "{n} host overrides" badge and
  /// the delete-network warning (Doc-3 A2/A3).
  Stream<Map<String, int>> watchCountsByNetwork() {
    return _dao.watchAllOverrides().map((rows) {
      final counts = <String, int>{};
      for (final row in rows) {
        final model = _rowToModel(row);
        if (model.isEmpty) continue;
        counts[model.networkId] = (counts[model.networkId] ?? 0) + 1;
      }
      return counts;
    });
  }

  /// The non-empty overrides for a single network (across every host) - the
  /// expandable "hosts overriding on this network" list (Doc-3 A3). Carries
  /// each override's `hostId`; the caller resolves host labels.
  Future<List<HostNetworkOverride>> listForNetwork(String networkId) async {
    final rows = await _dao.getOverridesForNetwork(networkId);
    return rows.map(_rowToModel).where((o) => !o.isEmpty).toList();
  }

  /// Insert a new override. Generates a uuid if the model's id is empty.
  Future<HostNetworkOverride> create(HostNetworkOverride override) async {
    final id = override.id.isEmpty ? _uuid.v4() : override.id;
    final stamped = override.copyWith(id: id);
    await _dao.insertOverride(_modelToCompanion(stamped, forInsert: true));
    return stamped;
  }

  /// Insert or update by id.
  Future<HostNetworkOverride> upsert(HostNetworkOverride override) async {
    final id = override.id.isEmpty ? _uuid.v4() : override.id;
    final stamped = override.copyWith(id: id);
    await _dao.upsertOverride(_modelToCompanion(stamped, forInsert: true));
    return stamped;
  }

  Future<void> delete(String overrideId) async {
    await _dao.deleteOverride(overrideId);
  }

  /// Replace the full set of overrides for a host atomically by `(hostId,
  /// networkId)` key. The UI builds the desired state, hands it here, and
  /// we apply it as a single upsert/delete sweep.
  ///
  /// Any existing override whose `(hostId, networkId)` pair is not present
  /// in [desired] is deleted; everything in [desired] is upserted by id.
  ///
  /// Defense-in-depth: drafts whose `hostId` doesn't match the [hostId]
  /// argument are coerced to the correct host before persisting. This
  /// stops a misbehaving caller from accidentally rewriting another
  /// host's override row by passing its id in the draft.
  Future<void> replaceForHost(
    String hostId,
    List<HostNetworkOverride> desired,
  ) async {
    final existing = await listForHost(hostId);
    final existingIds = existing.map((e) => e.id).toSet();
    final desiredKeys = desired.map((d) => d.networkId).toSet();
    for (final old in existing) {
      if (!desiredKeys.contains(old.networkId)) {
        await delete(old.id);
      }
    }
    for (final raw in desired) {
      // Coerce mismatched hostId to the argument host. Any caller who
      // hands us a draft with the wrong hostId is buggy - quietly fix it
      // rather than corrupting another host's row set.
      assert(
        raw.hostId == hostId,
        'replaceForHost: draft for network ${raw.networkId} carries '
        'hostId=${raw.hostId}, expected $hostId',
      );
      final next = raw.hostId == hostId ? raw : raw.copyWith(hostId: hostId);
      // Reuse the existing row's id if one exists for the same network,
      // so the upsert truly updates in place rather than orphaning rows.
      // If `next.id` was already set but doesn't match any existing row
      // for this host, drop it and mint a new id - this prevents an
      // upsert from clobbering a row that belongs to a different host.
      final old = existing.firstWhereOrNull(
        (e) => e.networkId == next.networkId,
      );
      final safeId = next.id.isEmpty || !existingIds.contains(next.id)
          ? (old?.id ?? _uuid.v4())
          : next.id;
      final withId = next.copyWith(id: safeId);
      await upsert(withId);
    }
  }

  /// Wipe all overrides for a host - called when the host itself is
  /// deleted (kept here to keep the API tidy).
  Future<void> deleteAllForHost(String hostId) {
    return _dao.deleteOverridesForHost(hostId);
  }

  // ── Conversion ──────────────────────────────────────────────────

  HostNetworkOverride _rowToModel(HostNetworkOverrideRow row) {
    return HostNetworkOverride(
      id: row.id,
      hostId: row.connectionId,
      networkId: row.networkId,
      address: row.address,
      port: row.port,
      username: row.username,
      identityKeyId: row.identityId,
      jumpHostId: row.jumpHostId,
      jumpHostChain:
          HostNetworkOverride.parseJumpHostChainJson(row.jumpChainJson),
      skipHost: row.skipHost,
    );
  }

  HostNetworkOverridesCompanion _modelToCompanion(
    HostNetworkOverride model, {
    required bool forInsert,
  }) {
    return HostNetworkOverridesCompanion(
      id: Value(model.id),
      connectionId: Value(model.hostId),
      networkId: Value(model.networkId),
      address: Value(model.address),
      port: Value(model.port),
      username: Value(model.username),
      identityId: Value(model.identityKeyId),
      jumpHostId: Value(model.jumpHostId),
      jumpChainJson: Value(model.jumpHostChainJson()),
      skipHost: Value(model.skipHost),
      createdAt: forInsert
          ? Value(DateTime.now())
          : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    );
  }
}

/// Tiny in-file extension to avoid pulling in `package:collection` just
/// for `firstWhereOrNull` - already used elsewhere in the codebase as
/// inline closures, but a shared helper keeps the call sites tidy.
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

/// Const used in tests to build a no-op override quickly.
@visibleForTesting
HostNetworkOverride buildOverrideFixture({
  required String hostId,
  required String networkId,
  String? address,
  int? port,
}) {
  return HostNetworkOverride(
    id: '',
    hostId: hostId,
    networkId: networkId,
    address: address,
    port: port,
  );
}
