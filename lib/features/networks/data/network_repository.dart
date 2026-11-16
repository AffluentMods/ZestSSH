import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../../core/theme/group_color.dart';
import '../../../database/daos/networks_dao.dart';
import '../../../database/database.dart';
import '../../../utils/logger.dart';
import '../models/network.dart';
import '../models/network_trigger.dart';
import 'network_icon_catalog.dart';

/// Sentinel sortOrder for the Default network. Pinned to the bottom by
/// being numerically larger than any user network can sensibly reach.
const int _defaultNetworkSortOrder = 1 << 30;

/// Domain-level repository for [Network]. Wraps [NetworksDao] and handles
/// the Drift row ↔ domain model translation, plus invariants like:
///
/// - the system Default network always exists
/// - the Default network is never deleted
/// - reorder operations always leave Default last
class NetworkRepository {
  NetworkRepository(this._dao);

  final NetworksDao _dao;

  // ── Reads ───────────────────────────────────────────────────────

  /// Returns the ordered list of networks. Default is always last.
  Future<List<Network>> list() async {
    final rows = await _dao.getAll();
    return rows.map(_rowToNetwork).toList();
  }

  /// Watch the ordered list. Used by the Networks page and the manual
  /// override picker so they live-update when the list changes.
  Stream<List<Network>> watch() {
    return _dao.watchAll().map(
          (rows) => rows.map(_rowToNetwork).toList(),
        );
  }

  Future<Network?> get(String id) async {
    final row = await _dao.getById(id);
    if (row == null) return null;
    return _rowToNetwork(row);
  }

  // ── Writes ──────────────────────────────────────────────────────

  /// Insert a brand-new network. Caller must provide a unique [Network.id]
  /// (typically a uuid). The Default network is created via
  /// [ensureDefaultExists] only - don't call this with `isFallback: true`.
  Future<void> create(Network network) async {
    if (network.isFallback && network.id != kDefaultNetworkId) {
      throw ArgumentError(
        'Only the system Default network may have isFallback = true',
      );
    }
    final companion = _networkToCompanion(network, forInsert: true);
    await _dao.insertNetwork(companion);
  }

  Future<void> update(Network network) async {
    final companion = _networkToCompanion(network, forInsert: false);
    await _dao.updateNetwork(companion);
  }

  /// Delete a non-Default network. Cleans up any host overrides that
  /// reference it, and the port forwards' states on it (On, Off: they were
  /// left behind, as Move to... never left them). Throws if [id] is the
  /// Default network. One transaction: a team vault refusing the network
  /// leaves its hosts' overrides and its forwards' states.
  Future<void> delete(String id) async {
    if (id == kDefaultNetworkId) {
      throw StateError('The Default network cannot be deleted');
    }
    await _dao.transaction(() async {
      await _dao.deleteOverridesForNetwork(id);
      await _dao.attachedDatabase.portForwardRulesDao.deleteNetworkOverridesForNetwork(id);
      await _dao.deleteNetwork(id);
    });
  }

  /// Apply a new ordering to all non-Default networks. The list must
  /// contain exactly the same set of ids as currently stored, minus the
  /// Default network's id. Default is always pinned to the bottom and is
  /// not reordered through this API.
  ///
  /// Throws [StateError] if [idsInOrder] contains the Default id (the
  /// caller must drop it before passing in).
  Future<void> reorder(List<String> idsInOrder) async {
    if (idsInOrder.contains(kDefaultNetworkId)) {
      throw StateError(
        'reorder must not include the Default network id - '
        'Default is always pinned last and not reorderable.',
      );
    }
    for (var i = 0; i < idsInOrder.length; i++) {
      await _dao.updateSortOrder(idsInOrder[i], i);
    }
  }

  /// Create the system Default network if absent. Idempotent - safe to
  /// call on every app start.
  Future<void> ensureDefaultExists({String defaultName = 'Default'}) async {
    final existing = await _dao.getById(kDefaultNetworkId);
    if (existing != null) {
      AppLogger.info(
        '[networks] Default network already exists, skipping creation',
      );
      return;
    }
    final network = Network.systemDefault(name: defaultName);
    final companion = _networkToCompanion(network, forInsert: true);
    await _dao.insertNetwork(companion);
    AppLogger.info('[networks] Created system Default network');
  }

  // ── Conversion ──────────────────────────────────────────────────

  Network _rowToNetwork(NetworkRow row) {
    // Look up the icon from the const catalog instead of building an
    // IconData at runtime - release builds tree-shake out any non-
    // const IconData and would otherwise fail with "non-constant
    // invocations of IconData".  The codePoint is what we store, so
    // the catalog is the source of truth for which icons round-trip.
    return Network(
      id: row.id,
      name: row.name,
      color: _colorFromIndex(row.colorIndex),
      colorValue: row.colorValue,
      icon: iconForCodePoint(row.iconCodePoint),
      triggers: Network.parseTriggersJson(row.triggersJson),
      isFallback: row.isFallback,
      bringUpVpn: row.bringUpVpn,
    );
  }

  NetworksCompanion _networkToCompanion(
    Network network, {
    required bool forInsert,
  }) {
    final sortOrder = network.isFallback
        ? _defaultNetworkSortOrder
        : null; // null = let updateSortOrder set it later via reorder()
    return NetworksCompanion(
      id: Value(network.id),
      name: Value(network.name),
      colorIndex: Value(network.color.index),
      // Custom colour overrides the palette index; a fallback network never
      // carries one (it is always gray).
      colorValue: Value(network.isFallback ? null : network.colorValue),
      iconCodePoint: Value(network.icon.codePoint),
      iconFontFamily: Value(network.icon.fontFamily),
      iconFontPackage: Value(network.icon.fontPackage),
      triggersJson: Value(network.triggersJson()),
      isFallback: Value(network.isFallback),
      bringUpVpn: Value(network.bringUpVpn),
      sortOrder: sortOrder == null
          ? const Value.absent()
          : Value(sortOrder),
      createdAt: forInsert
          ? Value(DateTime.now())
          : const Value.absent(),
    );
  }

  GroupColor _colorFromIndex(int index) {
    if (index < 0 || index >= GroupColor.values.length) {
      // Defensive: legacy/corrupt data falls back to the Default color.
      return GroupColor.gray;
    }
    return GroupColor.values[index];
  }
}

/// Convenience extension for tests and editors that want to pre-build a
/// trivial network without going through the editor's validation logic.
@visibleForTesting
extension NetworkRepoTestHelpers on NetworkRepository {
  /// Insert a placeholder network with a single subnet trigger. Returns
  /// the inserted [Network]. Test-only - the editor in section 6 has its
  /// own validation/save path.
  Future<Network> debugCreatePlaceholder({
    required String id,
    required String name,
    required String cidr,
    GroupColor color = GroupColor.blue,
  }) async {
    final network = Network(
      id: id,
      name: name,
      color: color,
      icon: defaultNetworkIcon,
      triggers: [SubnetTrigger(cidr)],
      isFallback: false,
    );
    await create(network);
    return network;
  }
}
