import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/session_spaces.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import '../../helpers/orchard_db_fixture.dart';

/// Sessions keep their space (3.0): a session opened from an
/// Orchard keeps reading and writing that Orchard after you switch to your
/// Tree, and writes nothing anywhere once the Orchard closes. The trigger
/// rules follow the space on screen, and a new database after an unlock.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    final known = dbs[orchardId];
    if (known != null) return known;
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(db, orchardId: orchardId);
    return dbs[orchardId] = db;
  }

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

final _sessionSpacesProvider = Provider<SessionSpaces>((ref) => SessionSpaces(ref));

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

  test('a session opened from an Orchard keeps working in it after a switch', () async {
    final spaces = container.read(_sessionSpacesProvider);
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    final orchardDb = storage.dbs[_orchard]!;
    spaces.opened('team-host');

    await container.read(spaceControllerProvider).switchTo(const TreeSpace());
    spaces.opened('my-host');

    expect(identical(spaces.database('team-host'), orchardDb), isTrue);
    expect(identical(spaces.database('my-host'), tree), isTrue);

    // Back in the Orchard, the Tree's session still works in the Tree.
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    expect(identical(spaces.database('my-host'), tree), isTrue);
  });

  test('once the Orchard closes, its sessions write nowhere else', () async {
    final spaces = container.read(_sessionSpacesProvider);
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    spaces.opened('team-host');
    await container.read(orchardDatabasesProvider.notifier).close(_orchard);
    expect(spaces.database('team-host'), isNull);
    expect(identical(spaces.readDatabase('team-host'), tree), isTrue,
        reason: 'reads fall back to the space on screen');
  });

  test("a host's key is trusted in its session's space, not the one on screen", () async {
    final spaces = container.read(_sessionSpacesProvider);
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    spaces.opened('team-host');
    await container.read(spaceControllerProvider).switchTo(const TreeSpace());

    // A reconnect of the Orchard's session while the Tree is on screen.
    final key = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List.generate(32, (i) => i + 1)));
    await spaces.knownHosts('team-host')!.trustHost('10.0.0.7', 22, key);
    expect(await storage.dbs[_orchard]!.knownHostsDao.getAll(), hasLength(1));
    expect(await tree.knownHostsDao.getAll(), isEmpty, reason: 'nothing of the Orchard lands in the Tree');
    expect((await spaces.knownHosts('team-host')!.verify('10.0.0.7', 22, key)).result, HostKeyVerifyResult.trusted);

    // Closed: nothing to trust with, and nothing written anywhere.
    await container.read(orchardDatabasesProvider.notifier).close(_orchard);
    expect(spaces.knownHosts('team-host'), isNull);
  });

  test('the trigger rules follow the space on screen and survive a lock', () async {
    Future<void> addTrigger(AppDatabase db, String id) => db.customStatement(
        'INSERT INTO terminal_triggers (id, name, pattern, highlight, enabled, created_at) '
        "VALUES (?, ?, 'error', 1, 1, 0)",
        [id, id]);
    await addTrigger(tree, 'tree-rule');
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    await addTrigger(storage.dbs[_orchard]!, 'orchard-rule');
    await container.read(spaceControllerProvider).switchTo(const TreeSpace());

    final runtime = container.read(triggerRuntimeProvider);
    Future<List<String>> rules() async {
      await pumpEventQueue();
      return [for (final r in runtime.highlightRulesFor(null)) r.id];
    }

    expect(await rules(), ['tree-rule']);
    await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
    expect(await rules(), ['orchard-rule']);

    // The app locks (no database), then unlocks with a new one.
    await container.read(databaseSessionProvider.notifier).close();
    await pumpEventQueue();
    final reopened = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(reopened.close);
    await addTrigger(reopened, 'after-unlock');
    container.read(databaseSessionProvider.notifier).seed(reopened);
    expect(await rules(), ['after-unlock']);
  });
}
