import 'package:drift/drift.dart';

/// Small device-local state that used to live in plaintext preferences and
/// names things about the user's machines: the tab snapshot restored on
/// launch and the saved workspaces (both carry every SFTP pane's remote and
/// local folder and the remote user), and the folder-pin counters (keyed by
/// host and path).
///
/// In the SQLCipher database on purpose, like the feedback queue: a path such
/// as `/srv/backups/vault` or a Windows user folder is exactly what recording
/// mode hides on screen, and preferences are the one place it would sit at
/// rest outside the vault. Device-local: never in the synced blob and never
/// in a `.zest` backup. A plain key-value shape so the callers keep their
/// JSON as it was.
@DataClassName('LocalStateRow')
class LocalState extends Table {
  TextColumn get key => text().withLength(min: 1, max: 512)();

  TextColumn get value => text()();

  /// Epoch milliseconds of the last write.
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {key};
}
