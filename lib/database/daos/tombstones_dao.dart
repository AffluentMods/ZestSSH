import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/tombstones.dart';

part 'tombstones_dao.g.dart';

/// DAO for delete-propagation tombstones (see [Tombstones] for the why).
///
/// Every mutation is idempotent (upsert / conditional delete) so a caller never
/// has to know the current state.
@DriftAccessor(tables: [Tombstones])
class TombstonesDao extends DatabaseAccessor<AppDatabase>
    with _$TombstonesDaoMixin {
  TombstonesDao(super.db);

  /// Record that a synced record was deleted. Upserts, so re-deleting the same
  /// id just refreshes [Tombstones.deletedAt]. Ideally called in the SAME
  /// transaction as the row delete so a crash can't lose the marker.
  Future<void> mark(String entityType, String entityId, {DateTime? at}) {
    return into(tombstones).insertOnConflictUpdate(
      TombstonesCompanion(
        entityType: Value(entityType),
        entityId: Value(entityId),
        deletedAt: Value(at ?? DateTime.now()),
      ),
    );
  }

  /// All tombstones - emitted into the sync blob by [SyncDataService.gatherAll]
  /// and consulted by [SyncDataService.restoreAll].
  Future<List<Tombstone>> getAll() => select(tombstones).get();

  /// Drop the tombstone for (entityType, entityId), if any. Called when a
  /// record with that id is legitimately (re)created so it is no longer
  /// suppressed as deleted.
  Future<void> clear(String entityType, String entityId) {
    return (delete(tombstones)..where(
          (t) => t.entityType.equals(entityType) & t.entityId.equals(entityId),
        ))
        .go();
  }

  /// Retention GC: drop tombstones older than [cutoff] to bound sync-blob size.
  /// A device offline longer than the retention window re-resurrects the items
  /// whose tombstones were pruned (documented tradeoff).
  Future<int> pruneOlderThan(DateTime cutoff) {
    return (delete(
      tombstones,
    )..where((t) => t.deletedAt.isSmallerThanValue(cutoff))).go();
  }
}
