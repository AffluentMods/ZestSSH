import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/terminal_triggers.dart';

part 'terminal_triggers_dao.g.dart';

@DriftAccessor(tables: [TerminalTriggers])
class TerminalTriggersDao extends DatabaseAccessor<AppDatabase>
    with _$TerminalTriggersDaoMixin {
  TerminalTriggersDao(super.db);

  /// All rules, oldest first (for backup/sync and the management list).
  Future<List<TerminalTrigger>> getAll() => (select(terminalTriggers)
        ..orderBy([
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.createdAt),
        ]))
      .get();

  /// Watch all rules (drives the live management list + the runtime that
  /// recompiles the active pattern set).
  Stream<List<TerminalTrigger>> watchAll() => (select(terminalTriggers)
        ..orderBy([
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.createdAt),
        ]))
      .watch();

  Future<TerminalTrigger?> getById(String id) =>
      (select(terminalTriggers)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// Insert or update a rule. Leaving `updatedAt` absent lets the universal
  /// newest-wins trigger stamp it.
  Future<void> upsert(TerminalTriggersCompanion entry) =>
      into(terminalTriggers).insertOnConflictUpdate(entry);

  /// Write [entry]'s fields over the saved rule [id]. An edit is an update, not
  /// an insert: the row's createdAt stays, and an insert that left it out was
  /// refused (every edit of a saved alert failed with ZS-1906).
  Future<void> updateRule(String id, TerminalTriggersCompanion entry) =>
      (update(terminalTriggers)..where((t) => t.id.equals(id))).write(entry);

  Future<void> setEnabled(String id, bool enabled) =>
      (update(terminalTriggers)..where((t) => t.id.equals(id)))
          .write(TerminalTriggersCompanion(enabled: Value(enabled)));

  /// Delete a rule by id, leaving a tombstone so the delete propagates to the
  /// user's other devices instead of being re-added by the union merge.
  /// One transaction: a delete a team vault refuses leaves no tombstone.
  Future<void> deleteTrigger(String id) => transaction(() async {
        await attachedDatabase.tombstonesDao.mark('terminal_triggers', id);
        await (delete(terminalTriggers)..where((t) => t.id.equals(id))).go();
      });
}
