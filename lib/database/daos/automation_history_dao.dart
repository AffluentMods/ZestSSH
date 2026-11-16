import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/automation_history.dart';

part 'automation_history_dao.g.dart';

@DriftAccessor(tables: [AutomationHistory])
class AutomationHistoryDao extends DatabaseAccessor<AppDatabase>
    with _$AutomationHistoryDaoMixin {
  AutomationHistoryDao(super.db);

  /// Watch all history entries, newest first.
  Stream<List<AutomationHistoryData>> watchAll() {
    return (select(automationHistory)
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]))
        .watch();
  }

  /// Get all history entries, newest first.
  Future<List<AutomationHistoryData>> getAll() {
    return (select(automationHistory)
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]))
        .get();
  }

  /// Insert a new history entry.
  Future<void> insert(AutomationHistoryCompanion entry) {
    return into(automationHistory).insert(entry);
  }

  /// Delete all history entries.
  Future<int> deleteAll() {
    return delete(automationHistory).go();
  }

  /// Delete entries older than [cutoff].
  Future<int> deleteOlderThan(DateTime cutoff) {
    return (delete(automationHistory)
          ..where((t) => t.timestamp.isSmallerThanValue(cutoff)))
        .go();
  }

  /// Keep only the most recent [maxEntries] entries.
  Future<void> trim(int maxEntries) async {
    final all = await getAll();
    if (all.length <= maxEntries) return;
    final toDelete = all.sublist(maxEntries);
    for (final entry in toDelete) {
      await (delete(automationHistory)
            ..where((t) => t.id.equals(entry.id)))
          .go();
    }
  }
}
