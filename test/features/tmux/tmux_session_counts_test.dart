import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/local_state_store.dart';

/// The tmux session counts follow the Tree's database across an app lock.
/// Locking closes the database and unlocking opens a new one, so a count
/// written after the unlock must land in the new database, a counter made
/// again must restore what was saved, and nothing may throw while locked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
  });

  tearDown(() => container.dispose());

  Future<int?> stored(AppDatabase db, String connectionId) =>
      LocalStateStore(db).readInt('tmux_sessions:$connectionId');

  /// Keeps the counter alive, the way the Hosts panel and the pill bar do.
  void keepAlive() {
    final sub = container.listen(tmuxSessionCountsProvider, (_, _) {});
    addTearDown(sub.close);
  }

  test('a count written after an unlock lands in the new database', () async {
    final before = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(before.close);
    container.read(databaseSessionProvider.notifier).seed(before);
    keepAlive();
    await container.read(tmuxSessionCountsProvider.notifier).set('h-1', 2);
    expect(await stored(before, 'h-1'), 2);

    // The app locks: its database closes.
    await container.read(databaseSessionProvider.notifier).close();

    // It unlocks with a new database.
    final after = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(after.close);
    container.read(databaseSessionProvider.notifier).seed(after);
    await container.read(tmuxSessionCountsProvider.notifier).set('h-1', 3);
    expect(await stored(after, 'h-1'), 3);
  });

  test('a counter made again restores the saved counts', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await LocalStateStore(db).writeInt('tmux_sessions:h-1', 4);
    container.read(databaseSessionProvider.notifier).seed(db);
    keepAlive();
    await pumpEventQueue();
    expect(container.read(tmuxSessionCountsProvider), {'h-1': 4});
  });

  test('while locked the counts are read and set without throwing', () async {
    // No database yet: the app is locked.
    keepAlive();
    expect(container.read(tmuxSessionCountsProvider), isEmpty);
    await container.read(tmuxSessionCountsProvider.notifier).set('h-1', 1);
    expect(container.read(tmuxSessionCountsProvider), {'h-1': 1},
        reason: 'kept in memory while there is nowhere to write it');
  });
}
