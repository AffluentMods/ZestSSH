import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/command_history.dart';

part 'command_history_dao.g.dart';

@DriftAccessor(tables: [CommandHistory])
class CommandHistoryDao extends DatabaseAccessor<AppDatabase>
    with _$CommandHistoryDaoMixin {
  CommandHistoryDao(super.db);

  static const _uuid = Uuid();

  /// Local cap on stored entries. History is append-only and syncs in the
  /// config blob, so it is bounded to the most-recent [maxEntries] to keep the
  /// blob small; older entries are pruned on insert.
  static const int maxEntries = 2000;

  /// Record a command run. Prunes back to [maxEntries] afterwards. Returns the
  /// new row id.
  Future<String> record({
    required String command,
    String? connectionId,
    String? hostLabel,
    String? cwd,
    DateTime? at,
  }) async {
    final id = _uuid.v4();
    await into(commandHistory).insert(CommandHistoryCompanion.insert(
      id: id,
      command: command,
      connectionId: Value(connectionId),
      hostLabel: Value(hostLabel),
      cwd: Value(cwd),
      createdAt: at ?? DateTime.now(),
      // updatedAt absent -> the universal insert trigger stamps it.
    ));
    await pruneToCap();
    return id;
  }

  /// Attach the shell-integration result (exit code + duration) to an entry once
  /// the command finishes. No-op if the row is already gone (pruned/deleted).
  /// LOCAL-ONLY columns, so this never changes the synced blob shape; the
  /// updatedAt bump just re-pushes the (identical) command text, newest-wins.
  Future<void> updateResult(
    String id, {
    int? exitCode,
    int? durationMs,
  }) async {
    await (update(commandHistory)..where((t) => t.id.equals(id))).write(
      CommandHistoryCompanion(
        exitCode: Value(exitCode),
        durationMs: Value(durationMs),
      ),
    );
  }

  /// Insert-or-update by id, WITHOUT pruning. Used by sync restore, which
  /// upserts many rows and prunes once at the end via [pruneToCap].
  Future<void> upsert(CommandHistoryCompanion entry) =>
      into(commandHistory).insertOnConflictUpdate(entry);

  Future<void> pruneToCap() async {
    // Delete everything except the most-recent [maxEntries] rows. Cheap enough
    // for an occasional command; created_at is indexed by the ordering.
    await customStatement(
      'DELETE FROM command_history WHERE id NOT IN '
      '(SELECT id FROM command_history ORDER BY created_at DESC LIMIT ?)',
      [maxEntries],
    );
  }

  /// Most-recent entries first (drives the history screen).
  Stream<List<CommandHistoryEntry>> watchRecent({int limit = 500}) {
    return (select(commandHistory)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .watch();
  }

  /// The newest command that starts with exactly [prefix] and is longer than
  /// it (history suggestions, 3.0): one run on [preferConnectionId] first,
  /// then any other. Null when there is none.
  Future<String?> latestStartingWith(String prefix, {String? preferConnectionId}) async {
    if (prefix.isEmpty) return null;
    final row = await customSelect(
      'SELECT command FROM command_history '
      'WHERE substr(command, 1, ?) = ? AND length(command) > ? '
      'ORDER BY (connection_id IS NOT NULL AND connection_id = ?) DESC, created_at DESC LIMIT 1',
      variables: [
        Variable.withInt(prefix.length),
        Variable.withString(prefix),
        Variable.withInt(prefix.length),
        Variable.withString(preferConnectionId ?? ''),
      ],
      readsFrom: {commandHistory},
    ).getSingleOrNull();
    return row?.read<String>('command');
  }

  /// Case-insensitive substring search over the command text, newest first.
  Future<List<CommandHistoryEntry>> search(String query, {int limit = 500}) {
    final q = query.trim();
    final sel = select(commandHistory)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit);
    if (q.isNotEmpty) {
      sel.where((t) => t.command.lower().contains(q.toLowerCase()));
    }
    return sel.get();
  }

  /// All rows, for the sync dump.
  Future<List<CommandHistoryEntry>> getAll() => select(commandHistory).get();

  Future<int> count() async {
    final c = countAll();
    final row = await (selectOnly(commandHistory)..addColumns([c]))
        .getSingle();
    return row.read(c) ?? 0;
  }

  /// Delete one entry, tombstoned so the removal propagates to other devices
  /// (important for scrubbing a sensitive entry everywhere).
  Future<void> deleteEntry(String id) async {
    await attachedDatabase.tombstonesDao.mark('command_history', id);
    await (delete(commandHistory)..where((t) => t.id.equals(id))).go();
  }

  /// Clear all local history, tombstoning each entry so the clear propagates.
  /// Bounded by [maxEntries].
  Future<void> clearAll() async {
    final ids =
        (await (selectOnly(commandHistory)..addColumns([commandHistory.id]))
                .get())
            .map((r) => r.read(commandHistory.id)!)
            .toList();
    for (final id in ids) {
      await attachedDatabase.tombstonesDao.mark('command_history', id);
    }
    await delete(commandHistory).go();
  }
}
