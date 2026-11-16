import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/connection_groups.dart';

part 'connection_groups_dao.g.dart';

@DriftAccessor(tables: [ConnectionGroups])
class ConnectionGroupsDao extends DatabaseAccessor<AppDatabase>
    with _$ConnectionGroupsDaoMixin {
  ConnectionGroupsDao(super.db);

  Stream<List<ConnectionGroup>> watchAll() {
    return (select(connectionGroups)
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .watch();
  }

  Future<List<ConnectionGroup>> getAll() => select(connectionGroups).get();

  Future<ConnectionGroup?> getById(String id) {
    return (select(connectionGroups)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<void> insertGroup(ConnectionGroupsCompanion entry) {
    return into(connectionGroups).insert(entry);
  }

  Future<void> updateGroup(ConnectionGroupsCompanion entry) {
    return (update(connectionGroups)
          ..where((t) => t.id.equals(entry.id.value)))
        .write(entry);
  }

  Future<void> deleteGroup(String id) => transaction(() async {
        // Delete-propagation tombstone so the group is removed on other
        // devices, not re-added by the sync union-merge; in the delete's
        // transaction, so a delete a team vault refuses leaves none.
        await attachedDatabase.tombstonesDao.mark('connection_groups', id);
        await (delete(connectionGroups)..where((t) => t.id.equals(id))).go();
      });

  Future<void> toggleExpanded(String id, bool isExpanded) {
    return (update(connectionGroups)..where((t) => t.id.equals(id))).write(
      ConnectionGroupsCompanion(isExpanded: Value(isExpanded)),
    );
  }

  /// Persist a full left-to-right group ordering by writing each group's
  /// [ConnectionGroups.sortOrder] to its position in [orderedIds] (0-based).
  ///
  /// Runs as ONE Drift batch so the whole reorder is atomic and emits a single
  /// table-update event - the cloud-sync debouncer collapses a drag session
  /// into one push (same technique as `ConnectionsDao.applyLayout`). Ids not
  /// present in the table are simply no-ops.
  Future<void> setSortOrders(List<String> orderedIds) {
    return batch((b) {
      for (var i = 0; i < orderedIds.length; i++) {
        b.update(
          connectionGroups,
          ConnectionGroupsCompanion(sortOrder: Value(i)),
          where: (t) => t.id.equals(orderedIds[i]),
        );
      }
    });
  }

  /// Set (or clear, with null) the group's user-picked accent color.
  /// [colorIndex] indexes into AppColors.v3GroupColors; null reverts
  /// the group to its legacy name-hash-derived color. A non-null [colorValue]
  /// (ARGB int) overrides the index with an arbitrary custom colour; the two
  /// are alternatives, so this always writes both (custom pick clears the
  /// index, an index pick clears any custom value).
  Future<void> setColor(String id, int? colorIndex, {int? colorValue}) {
    return (update(connectionGroups)..where((t) => t.id.equals(id))).write(
      ConnectionGroupsCompanion(
        colorIndex: Value(colorIndex),
        colorValue: Value(colorValue),
      ),
    );
  }
}
