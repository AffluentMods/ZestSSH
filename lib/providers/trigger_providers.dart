import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/daos/terminal_triggers_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';

/// All trigger / highlight rules, newest sort order first (drives the
/// management list).
final triggersProvider = StreamProvider<List<TerminalTrigger>>((ref) {
  return ref.watch(terminalTriggersDaoProvider).watchAll();
});

/// Connections available as a per-host scope in the trigger editor.
final triggerScopeConnectionsProvider =
    StreamProvider<List<Connection>>((ref) {
  return ref.watch(connectionsDaoProvider).watchAll();
});

final triggerCrudProvider = Provider<TriggerCrud>((ref) {
  return TriggerCrud(ref.watch(terminalTriggersDaoProvider));
});

/// Create / update / toggle / delete helper for trigger rules.
class TriggerCrud {
  TriggerCrud(this._dao);

  final TerminalTriggersDao _dao;
  static const _uuid = Uuid();

  Future<String> create({
    required String name,
    required String pattern,
    bool caseSensitive = false,
    bool notify = true,
    bool highlight = false,
    int? highlightColor,
    bool playSound = false,
    String? connectionId,
    bool enabled = true,
  }) async {
    final id = _uuid.v4();
    await _dao.upsert(TerminalTriggersCompanion.insert(
      id: id,
      name: name,
      pattern: pattern,
      caseSensitive: Value(caseSensitive),
      notify: Value(notify),
      highlight: Value(highlight),
      highlightColor: Value(highlightColor),
      playSound: Value(playSound),
      connectionId: Value(connectionId),
      enabled: Value(enabled),
      createdAt: DateTime.now(),
      // updatedAt left absent: the universal newest-wins trigger stamps it.
    ));
    return id;
  }

  /// Update every editable field of an existing rule. `updatedAt` is left absent
  /// so the auto-bump trigger records the edit time for newest-wins sync.
  Future<void> update({
    required String id,
    required String name,
    required String pattern,
    required bool caseSensitive,
    required bool notify,
    required bool highlight,
    required int? highlightColor,
    required bool playSound,
    required String? connectionId,
    required bool enabled,
  }) {
    return _dao.updateRule(id, TerminalTriggersCompanion(
      name: Value(name),
      pattern: Value(pattern),
      caseSensitive: Value(caseSensitive),
      notify: Value(notify),
      highlight: Value(highlight),
      // Explicit Value(null) so clearing a custom colour persists.
      highlightColor: Value(highlightColor),
      playSound: Value(playSound),
      connectionId: Value(connectionId),
      enabled: Value(enabled),
    ));
  }

  Future<void> setEnabled(String id, bool enabled) =>
      _dao.setEnabled(id, enabled);

  Future<void> delete(String id) => _dao.deleteTrigger(id);
}
