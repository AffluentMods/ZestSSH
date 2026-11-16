import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Key-value state kept in the encrypted database (`local_state`, schema
/// v36) instead of plaintext preferences: the restored tab snapshot, saved
/// workspaces and the folder-pin counters, all of which name SFTP folders
/// and remote users. Device-local: never synced, never in a backup.
///
/// Every reader that moved here imports its old preference key once and
/// then removes it, so an upgrade keeps the user's state and leaves nothing
/// behind in preferences ([importFromPrefs]).
class LocalStateStore {
  LocalStateStore(this._db);

  final AppDatabase _db;

  Future<String?> read(String key) async {
    final row = await (_db.select(_db.localState)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> write(String key, String value) {
    return _db.into(_db.localState).insertOnConflictUpdate(
          LocalStateCompanion.insert(
            key: key,
            value: value,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  /// The value kept under [key]: the one [make] makes, kept only where there
  /// is none yet (INSERT OR IGNORE), and read back, so a value once kept is
  /// never replaced and two asking at once get the same one.
  Future<String> readOrCreate(String key, String Function() make) async {
    await _db.into(_db.localState).insert(
          LocalStateCompanion.insert(
            key: key,
            value: make(),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return (await read(key))!;
  }

  Future<void> remove(String key) {
    return (_db.delete(_db.localState)..where((t) => t.key.equals(key))).go();
  }

  /// Every key that starts with [prefix]. LIKE treats `_` and `%` in the
  /// prefix as wildcards (there is no ESCAPE clause), so it can over-match;
  /// the exact `startsWith` filter afterwards is what decides.
  Future<List<String>> keysWithPrefix(String prefix) async {
    final rows = await (_db.select(_db.localState)
          ..where((t) => t.key.like('$prefix%')))
        .get();
    return [for (final r in rows) if (r.key.startsWith(prefix)) r.key];
  }

  /// Remove every key that starts with [prefix].
  Future<void> removeWithPrefix(String prefix) async {
    for (final k in await keysWithPrefix(prefix)) {
      await remove(k);
    }
  }

  /// Read an int stored as text, or null.
  Future<int?> readInt(String key) async {
    final v = await read(key);
    return v == null ? null : int.tryParse(v);
  }

  Future<void> writeInt(String key, int value) => write(key, value.toString());

  Future<bool> readBool(String key) async => (await read(key)) == 'true';

  Future<void> writeBool(String key, bool value) =>
      write(key, value ? 'true' : 'false');

  /// One-time import of a value that used to live in preferences under
  /// [prefsKey]: the stored value wins if one exists already, else the
  /// preference is copied in; the preference is removed either way. Returns
  /// the value now in the store, or null when neither side had one.
  Future<String?> importFromPrefs(
    String key,
    String? Function() readPref,
    Future<void> Function() removePref,
  ) async {
    final legacy = readPref();
    if (legacy == null) return read(key);
    final existing = await read(key);
    if (existing == null) await write(key, legacy);
    await removePref();
    return existing ?? legacy;
  }

}

final localStateStoreProvider = Provider<LocalStateStore>(
    (ref) => LocalStateStore(ref.watch(treeDatabaseProvider)));
