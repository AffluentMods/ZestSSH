import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/sftp_sync_manifest.dart';

part 'sftp_sync_manifest_dao.g.dart';

/// DAO for the folder-sync manifest (see [SftpSyncManifest] for the why). All
/// mutations are idempotent upserts/deletes.
@DriftAccessor(tables: [SftpSyncManifest])
class SftpSyncManifestDao extends DatabaseAccessor<AppDatabase>
    with _$SftpSyncManifestDaoMixin {
  SftpSyncManifestDao(super.db);

  /// Hard cap on stored rows, oldest pruned first beyond it (spec §4).
  static const int _rowCap = 200000;

  /// Every record for one (host, remoteRoot), keyed by relative path, for a
  /// single-query level-0 lookup at plan time.
  Future<Map<String, SftpSyncManifestRow>> forRoot(
      String hostId, String remoteRoot) async {
    final rows = await (select(sftpSyncManifest)
          ..where((t) =>
              t.hostId.equals(hostId) & t.remoteRoot.equals(remoteRoot)))
        .get();
    return {for (final r in rows) r.relPath: r};
  }

  /// Record a file AFTER its upload fully succeeded. Upserts on the natural key.
  Future<void> record({
    required String hostId,
    required String remoteRoot,
    required String relPath,
    required int size,
    required int mtimeSeconds,
    String? contentHash,
  }) {
    return into(sftpSyncManifest).insertOnConflictUpdate(
      SftpSyncManifestCompanion(
        hostId: Value(hostId),
        remoteRoot: Value(remoteRoot),
        relPath: Value(relPath),
        localSize: Value(size),
        localMtimeS: Value(mtimeSeconds),
        contentHash: Value(contentHash),
        uploadedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// Forget a whole root (e.g. the user changed the remote target).
  Future<void> clearRoot(String hostId, String remoteRoot) =>
      (delete(sftpSyncManifest)
            ..where((t) =>
                t.hostId.equals(hostId) & t.remoteRoot.equals(remoteRoot)))
          .go();

  /// Refresh [uploadedAt] for rows a level-0 hit just confirmed are still
  /// current, so a stable tree that never needs re-uploading does not age out
  /// of the manifest at 90 days and then re-scan every file. One UPDATE per
  /// chunk of 500 keys (well under SQLite's bound-variable limit).
  Future<void> touch({
    required String hostId,
    required String remoteRoot,
    required List<String> relPaths,
  }) async {
    if (relPaths.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < relPaths.length; i += 500) {
      final end = i + 500 > relPaths.length ? relPaths.length : i + 500;
      final chunk = relPaths.sublist(i, end);
      await (update(sftpSyncManifest)
            ..where((t) =>
                t.hostId.equals(hostId) &
                t.remoteRoot.equals(remoteRoot) &
                t.relPath.isIn(chunk)))
          .write(SftpSyncManifestCompanion(uploadedAt: Value(now)));
    }
  }

  /// Prune: drop rows untouched for 90+ days, then cap total rows, deleting the
  /// oldest overflow. Cheap no-op when under the cap.
  Future<void> prune() async {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 90))
        .millisecondsSinceEpoch;
    await (delete(sftpSyncManifest)
          ..where((t) => t.uploadedAt.isSmallerThanValue(cutoff)))
        .go();

    final countExp = sftpSyncManifest.hostId.count();
    final total = await (selectOnly(sftpSyncManifest)..addColumns([countExp]))
        .map((r) => r.read(countExp) ?? 0)
        .getSingle();
    if (total <= _rowCap) return;

    // Delete the oldest overflow in ONE statement. The table is a rowid table
    // (a composite PRIMARY KEY does not opt out of rowid), so the subquery can
    // address rows directly. The previous per-row loop cost one autocommit
    // and one fsync per row under SQLCipher, i.e. a whole run's uploads.
    final overflow = total - _rowCap;
    await customStatement(
      'DELETE FROM sftp_sync_manifest WHERE rowid IN '
      '(SELECT rowid FROM sftp_sync_manifest ORDER BY uploaded_at ASC LIMIT ?)',
      [overflow],
    );
  }
}
