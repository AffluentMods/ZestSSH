import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/local_state_store.dart';
import '../../helpers/orchard_db_fixture.dart';

/// Switching spaces (3.0): every screen follows the active space,
/// but personal sync, backups and the device-local state always stay on the
/// Tree, so an Orchard's data can never reach your own sync or a `.zest`
/// file. Locking the app closes the Orchards and goes back to the Tree.

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};
  final deleted = <String>[];
  var opens = 0;

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    opens++;
    final known = dbs[orchardId];
    if (known != null) return known;
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(db, orchardId: orchardId);
    return dbs[orchardId] = db;
  }

  @override
  Future<void> delete(String orchardId) async {
    deleted.add(orchardId);
    dbs.remove(orchardId);
  }

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

ConnectionsCompanion _host(String id) {
  final now = DateTime(2026, 9, 23);
  return ConnectionsCompanion.insert(
    id: id,
    label: id,
    host: '10.0.0.1',
    port: const Value(22),
    createdAt: now,
    updatedAt: now,
  );
}

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;
  late AppDatabase tree;
  late _MemoryStorage storage;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  });

  tearDown(() async {
    container.dispose();
    for (final db in storage.dbs.values) {
      await db.close();
    }
    await tree.close();
  });

  test('the app follows the active space; personal sync stays on the Tree', () async {
    await tree.connectionsDao.insertConnection(_host('personal'));
    expect(container.read(activeSpaceProvider), const TreeSpace());
    expect(identical(container.read(databaseProvider), tree), isTrue);

    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    final orchardDb = container.read(databaseProvider);
    expect(identical(orchardDb, tree), isFalse);
    expect(orchardDb.isOrchard, isTrue);
    await container.read(connectionsDaoProvider).insertConnection(_host('team'));

    // Screens read the Orchard.
    final shown = await container.read(connectionsDaoProvider).getAll();
    expect(shown.map((c) => c.id), ['team']);

    // Personal sync and backups read the Tree, whichever space is active.
    final blob = await container.read(syncDataServiceProvider).gatherAll();
    final synced = (blob['connections'] as List).map((c) => (c as Map)['id']);
    expect(synced, ['personal']);
  });

  test('device-local state is written to the Tree while an Orchard is active', () async {
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    await container.read(localStateStoreProvider).write('workspace.saved', '{}');
    final inTree = await tree.customSelect('SELECT COUNT(*) AS n FROM local_state').getSingle();
    final inOrchard = await storage.dbs[_orchard]!
        .customSelect('SELECT COUNT(*) AS n FROM local_state')
        .getSingle();
    expect(inTree.read<int>('n'), 1);
    expect(inOrchard.read<int>('n'), 0);
  });

  test('locking the app closes the Orchards and goes back to the Tree', () async {
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    expect(container.read(orchardDatabasesProvider).keys, [_orchard]);
    await container.read(databaseSessionProvider.notifier).close();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(activeSpaceProvider), const TreeSpace());
    expect(container.read(orchardDatabasesProvider), isEmpty);
  });

  test('when the Orchard on screen closes, the app goes back to the Tree', () async {
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    await container.read(orchardDatabasesProvider.notifier).forgetAll();
    expect(container.read(activeSpaceProvider), const TreeSpace());
    expect(identical(container.read(databaseProvider), tree), isTrue);
  });

  test('forgetting an Orchard deletes its database and its key', () async {
    const secure = FlutterSecureStorage();
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    expect(await secure.read(key: OrchardDatabaseKeys.storageKey(_orchard)), isNotNull);
    await container.read(orchardDatabasesProvider.notifier).forgetAll();
    expect(storage.deleted, [_orchard]);
    expect(await secure.read(key: OrchardDatabaseKeys.storageKey(_orchard)), isNull);
  });

  test('two screens opening one Orchard at once share one database', () async {
    final notifier = container.read(orchardDatabasesProvider.notifier);
    final both = await Future.wait([notifier.open(_orchard), notifier.open(_orchard)])
        .timeout(const Duration(seconds: 5));
    expect(identical(both[0], both[1]), isTrue);
    expect(storage.opens, 1, reason: 'the second open waits for the first');
    expect(identical(await notifier.open(_orchard), both[0]), isTrue);
    expect(storage.opens, 1, reason: 'an open database is reused');
  });

  test('a database whose key is gone is made again rather than read', () async {
    await storage.open(_orchard, 'old');
    expect(await storage.exists(_orchard), isTrue);
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    expect(storage.deleted, [_orchard], reason: 'no key could ever open it');
  });
}
