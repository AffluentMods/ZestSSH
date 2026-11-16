import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';

/// The 1.8 reactive database session: `databaseProvider` throws while locked,
/// resolves once a database is seeded/opened, and throws again after close -
/// which is what lets the router treat a locked (DB-closed) app as "show only
/// the unlock screen".
void main() {
  test('locked -> seed -> close transitions dbReady + databaseProvider',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Locked: no DB, provider throws, dbReady false.
    expect(container.read(dbReadyProvider), isFalse);
    expect(() => container.read(databaseProvider), throwsStateError);

    // Seed (the lock-OFF bootstrap path).
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    container.read(databaseSessionProvider.notifier).seed(db);

    expect(container.read(dbReadyProvider), isTrue);
    expect(container.read(databaseProvider), same(db));

    // Close (auto-lock): back to locked.
    await container.read(databaseSessionProvider.notifier).close();

    expect(container.read(dbReadyProvider), isFalse);
    expect(() => container.read(databaseProvider), throwsStateError);
  });

  test('DAO providers rebuild across a lock/unlock cycle', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final db1 = AppDatabase.forTesting(NativeDatabase.memory());
    container.read(databaseSessionProvider.notifier).seed(db1);
    expect(container.read(connectionsDaoProvider), same(db1.connectionsDao));

    await container.read(databaseSessionProvider.notifier).close();
    expect(() => container.read(connectionsDaoProvider), throwsStateError);

    // Re-open with a fresh DB (a re-unlock): DAO provider resolves the new one.
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    container.read(databaseSessionProvider.notifier).seed(db2);
    expect(container.read(connectionsDaoProvider), same(db2.connectionsDao));

    await db1.close();
    await db2.close();
  });
}
