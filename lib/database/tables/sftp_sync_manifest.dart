import 'package:drift/drift.dart';

/// Device-local record of what a folder-sync last uploaded where, so an
/// unchanged file costs nothing on the next sync (spec §4, "level 0"): if the
/// local file still matches its recorded size and mtime, the sync skips it
/// without hashing or comparing against the remote.
///
/// This lives in the SQLCipher database, NEVER in the synced blob and NEVER in
/// a `.zest` backup, because it is a map of the user's directory structure and
/// hostnames. It is only a cache: any sync can be run in verify mode, which
/// ignores it and re-scans the remote. Pruned by age and total-row cap.
@DataClassName('SftpSyncManifestRow')
class SftpSyncManifest extends Table {
  /// The saved connection id the remote root belongs to.
  TextColumn get hostId => text().withLength(min: 1, max: 128)();

  /// Remote root, normalised, no trailing slash.
  TextColumn get remoteRoot => text().withLength(min: 1, max: 4096)();

  /// Path relative to the root, NFC-normalised, forward slashes on every OS.
  TextColumn get relPath => text().withLength(min: 1, max: 4096)();

  /// Local file size at last successful upload.
  IntColumn get localSize => integer()();

  /// Local mtime in whole seconds, matching what was stamped on the remote.
  IntColumn get localMtimeS => integer()();

  /// sha256 hex of the content, null unless content hashing was used.
  TextColumn get contentHash => text().nullable()();

  /// Epoch milliseconds when this row was written (after the upload fully
  /// succeeded, never before, so a partial upload never looks done).
  IntColumn get uploadedAt => integer()();

  @override
  Set<Column> get primaryKey => {hostId, remoteRoot, relPath};
}
