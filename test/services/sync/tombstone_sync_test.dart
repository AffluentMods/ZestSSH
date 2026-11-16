import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Empty-prefs settings service (no synced settings seeded); (re)built in
/// setUp so each round-trip starts from a clean SharedPreferences.
late SettingsService _settings;

/// Exercises the cloud-sync tombstone / "newest wins" delete-propagation
/// (blob schema_version 10, DB schema v28).
///
/// Two in-memory databases stand in for two devices: one `gatherAll()`s a blob,
/// the other `restoreAll()`s it, and we assert on the merged local state.
/// Without tombstones the merge is a union by id that never deletes, so a host
/// deleted on one device was silently re-added from the other's blob.

SyncDataService _service(AppDatabase db, FlutterSecureStorage storage) =>
    SyncDataService(
      database: db,
      connectionsDao: db.connectionsDao,
      identitiesDao: db.identitiesDao,
      groupsDao: db.connectionGroupsDao,
      knownHostsDao: db.knownHostsDao,
      snippetsDao: db.snippetsDao,
      snippetCategoriesDao: db.snippetCategoriesDao,
      portForwardRulesDao: db.portForwardRulesDao,
      networksDao: db.networksDao,
      connectionTagsDao: db.connectionTagsDao,
      secureStorage: storage,
      settingsService: _settings,
    );

Future<void> _seedConnection(AppDatabase db, String id, DateTime updatedAt) {
  return db.connectionsDao.insertConnection(
    ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedGroup(AppDatabase db, String id) {
  return db.connectionGroupsDao.insertGroup(
    ConnectionGroupsCompanion(
      id: Value(id),
      name: Value('group-$id'),
      createdAt: Value(DateTime.utc(2026)),
    ),
  );
}

Future<void> _seedSnippet(AppDatabase db, String id, DateTime updatedAt) {
  return db.snippetsDao.insertSnippet(
    SnippetsCompanion(
      id: Value(id),
      label: Value('snip-$id'),
      command: Value('echo $id'),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedRule(AppDatabase db, String id, String connId) {
  return db.portForwardRulesDao.upsertRule(
    PortForwardRulesCompanion(
      id: Value(id),
      connectionId: Value(connId),
      type: const Value('local'),
      bindAddress: const Value('127.0.0.1'),
      bindPort: const Value(8080),
      remoteHost: const Value('localhost'),
      remotePort: const Value(80),
      createdAt: Value(DateTime.utc(2026)),
    ),
  );
}

// -- Config-table seeds (the 5 tables that gained `updatedAt` at schema v29).
// Each sets updatedAt EXPLICITLY so the auto-bump INSERT trigger does NOT fire
// and stamp now(); the newest-wins tests need a controlled modification time.

Future<void> _seedGroupAt(AppDatabase db, String id, DateTime updatedAt) {
  return db.connectionGroupsDao.insertGroup(
    ConnectionGroupsCompanion(
      id: Value(id),
      name: Value('group-$id'),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedIdentityAt(AppDatabase db, String id, DateTime updatedAt) {
  return db.identitiesDao.insertIdentity(
    IdentitiesCompanion(
      id: Value(id),
      label: Value('key-$id'),
      username: const Value('root'),
      authMethod: const Value('password'),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedNetworkAt(AppDatabase db, String id, DateTime updatedAt) {
  return db.networksDao.insertNetwork(
    NetworksCompanion(
      id: Value(id),
      name: Value('net-$id'),
      iconCodePoint: const Value(0xe000),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedRuleAt(
    AppDatabase db, String id, String connId, DateTime updatedAt) {
  return db.portForwardRulesDao.upsertRule(
    PortForwardRulesCompanion(
      id: Value(id),
      connectionId: Value(connId),
      type: const Value('local'),
      bindAddress: const Value('127.0.0.1'),
      bindPort: const Value(8080),
      remoteHost: const Value('localhost'),
      remotePort: const Value(80),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedCategoryAt(AppDatabase db, String name, DateTime updatedAt) {
  return db.snippetCategoriesDao.upsert(
    SnippetCategoriesCompanion(
      name: Value(name),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedTrigger(AppDatabase db, String id, DateTime updatedAt,
    {String pattern = 'error'}) {
  return db.terminalTriggersDao.upsert(
    TerminalTriggersCompanion(
      id: Value(id),
      name: Value('trig-$id'),
      pattern: Value(pattern),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

Future<void> _seedCommandHistory(AppDatabase db, String id, DateTime updatedAt,
    {String command = 'ls'}) {
  return db.commandHistoryDao.upsert(
    CommandHistoryCompanion(
      id: Value(id),
      command: Value(command),
      createdAt: Value(updatedAt),
      updatedAt: Value(updatedAt),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  const storage = FlutterSecureStorage();
  final key = List<int>.filled(32, 7);

  // t1 < t2 < t3, all well BEFORE the real wall clock so a stray now() stamp is
  // detectable (it would be newer than t2/t3).
  final t1 = DateTime.utc(2026, 1, 1);
  final t2 = DateTime.utc(2026, 3, 1);
  final t3 = DateTime.utc(2026, 5, 1);

  late AppDatabase src;
  late AppDatabase dst;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    _settings = SettingsService(await SharedPreferences.getInstance());
    src = AppDatabase.forTesting(NativeDatabase.memory());
    dst = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await src.close();
    await dst.close();
  });

  test('gatherAll emits tombstones; a deleted host does not travel as live',
      () async {
    await _seedConnection(src, 'X', t1);
    await src.tombstonesDao.mark('connections', 'X', at: t2);
    await src.connectionsDao.deleteConnection('X');

    final blob = await _service(src, storage).gatherAll();
    expect(blob['connections'] as List, isEmpty);
    final tombs = blob['tombstones'] as List;
    expect(tombs, hasLength(1));
    expect((tombs.single as Map)['entityType'], 'connections');
    expect((tombs.single as Map)['entityId'], 'X');
  });

  test('delete propagates: a host deleted on one device is removed on the other',
      () async {
    await _seedConnection(src, 'X', t1);
    await _seedConnection(dst, 'X', t1); // both devices had X (synced)

    await src.tombstonesDao.mark('connections', 'X', at: t2);
    await src.connectionsDao.deleteConnection('X');

    final blob = await _service(src, storage).gatherAll();
    await _service(dst, storage).restoreAll(blob);

    expect(await dst.connectionsDao.getById('X'), isNull,
        reason: 'the delete must propagate - X must be gone on dst');
    expect((await dst.tombstonesDao.getAll()).map((t) => t.entityId),
        contains('X'),
        reason: 'dst adopts the tombstone so it re-propagates + never re-adds X');
  });

  test('no resurrection: re-merging the same blob keeps X deleted', () async {
    await _seedConnection(dst, 'X', t1);
    await _seedConnection(src, 'X', t1);
    await src.tombstonesDao.mark('connections', 'X', at: t2);
    await src.connectionsDao.deleteConnection('X');
    final blob = await _service(src, storage).gatherAll();

    await _service(dst, storage).restoreAll(blob);
    await _service(dst, storage).restoreAll(blob); // second sync cycle

    expect(await dst.connectionsDao.getById('X'), isNull);
  });

  test('newest wins - a delete newer than the local record removes it',
      () async {
    await _seedConnection(dst, 'X', t1); // local last-modified t1
    await src.tombstonesDao.mark('connections', 'X', at: t2); // deleted t2 > t1
    final blob = await _service(src, storage).gatherAll();
    await _service(dst, storage).restoreAll(blob);
    expect(await dst.connectionsDao.getById('X'), isNull);
  });

  test('newest wins - a local edit newer than the delete survives', () async {
    await _seedConnection(dst, 'X', t3); // local edited at t3
    await src.tombstonesDao.mark('connections', 'X', at: t2); // deleted t2 < t3
    final blob = await _service(src, storage).gatherAll();
    await _service(dst, storage).restoreAll(blob);
    expect(await dst.connectionsDao.getById('X'), isNotNull,
        reason: 'an edit newer than the delete must win');
  });

  test('newest wins - an edit newer than the delete resurrects on the deleter',
      () async {
    // dst deleted X at t2; src edited X at t3 (after) and still has it live.
    await dst.tombstonesDao.mark('connections', 'X', at: t2);
    await _seedConnection(src, 'X', t3);
    final blob = await _service(src, storage).gatherAll(); // X@t3, no tombstone
    await _service(dst, storage).restoreAll(blob);

    final restored = await dst.connectionsDao.getById('X');
    expect(restored, isNotNull,
        reason: 'the newer edit must beat the older local delete');
    expect(restored!.updatedAt.toUtc(), t3,
        reason: 'restore must PRESERVE the incoming updatedAt, not stamp now()');
  });

  test('preserve updatedAt: a restored host stays deletable by a later delete',
      () async {
    // Round 1: dst learns X (last-modified t1) from a sync. If restore stamped
    // now() instead of preserving t1, the newest-wins comparison below breaks.
    await _seedConnection(src, 'X', t1);
    await _service(dst, storage).restoreAll(await _service(src, storage).gatherAll());
    expect(await dst.connectionsDao.getById('X'), isNotNull);

    // Round 2: X deleted elsewhere at t2 (> t1, but BEFORE the real now()).
    await src.tombstonesDao.mark('connections', 'X', at: t2);
    await src.connectionsDao.deleteConnection('X');
    await _service(dst, storage).restoreAll(await _service(src, storage).gatherAll());

    expect(await dst.connectionsDao.getById('X'), isNull,
        reason: 'a now()-stamp on restore would make X outrank the t2 delete '
            'and wrongly resurrect it');
  });

  test('a non-tombstoned host restores normally (no false suppression)',
      () async {
    await _seedConnection(src, 'Y', t1);
    final blob = await _service(src, storage).gatherAll();
    await _service(dst, storage).restoreAll(blob);
    expect(await dst.connectionsDao.getById('Y'), isNotNull);
  });

  test('round-trip fingerprint stays stable WITH tombstones (no push loop)',
      () async {
    await _seedConnection(src, 'X', t1);
    await src.tombstonesDao.mark('connections', 'Z', at: t2);
    final blobA = await _service(src, storage).gatherAll();
    final fpA = SyncDataService.contentFingerprint(blobA, key);

    await _service(dst, storage).restoreAll(blobA);
    final blobB = await _service(dst, storage).gatherAll();
    final fpB = SyncDataService.contentFingerprint(blobB, key);

    expect(fpB, fpA,
        reason: 'pull -> restore -> gather must yield an identical fingerprint');
  });

  group('TombstonesDao', () {
    test('mark upserts newest deletedAt; getAll; clear; prune', () async {
      await src.tombstonesDao.mark('connections', 'A', at: t1);
      await src.tombstonesDao.mark('connections', 'A', at: t2); // upsert
      var all = await src.tombstonesDao.getAll();
      expect(all, hasLength(1));
      expect(all.single.deletedAt.toUtc(), t2);

      await src.tombstonesDao.mark('snippets', 'B', at: t1);
      await src.tombstonesDao.clear('connections', 'A');
      all = await src.tombstonesDao.getAll();
      expect(all.map((t) => t.entityId), ['B']);

      await src.tombstonesDao.pruneOlderThan(t2); // B@t1 < t2 → pruned
      expect(await src.tombstonesDao.getAll(), isEmpty);
    });
  });

  group('capture sweep - other entities + cascade + GC', () {
    test('group delete propagates (delete-wins, timestamp-less table)',
        () async {
      await _seedGroup(src, 'G');
      await _seedGroup(dst, 'G');
      await src.connectionGroupsDao.deleteGroup('G'); // marks tombstone + del
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.connectionGroupsDao.getById('G'), isNull);
    });

    test('snippet delete propagates', () async {
      await _seedSnippet(src, 'S', t1);
      await _seedSnippet(dst, 'S', t1);
      await src.snippetsDao.deleteSnippet('S');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.snippetsDao.getById('S'), isNull);
    });

    test('snippet edit newer than the delete survives (newest-wins)', () async {
      await _seedSnippet(dst, 'S', t3);
      await src.tombstonesDao.mark('snippets', 'S', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.snippetsDao.getById('S'), isNotNull);
    });

    test('host delete cascades to its port-forward rules', () async {
      await _seedRule(src, 'R', 'X');
      await _seedRule(dst, 'R', 'X');
      await src.portForwardRulesDao.deleteByConnection('X'); // tombstones R
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.portForwardRulesDao.getByConnection('X'), isEmpty,
          reason: 'a host delete must remove its forwards on other devices');
    });

    test('gatherAll prunes tombstones older than the retention window',
        () async {
      // Older than kTombstoneRetention (730 days) so the GC drops it. Uses a
      // margin past the window rather than a fixed date so it can't rot as the
      // wall clock advances.
      await src.tombstonesDao.mark('connections', 'OLD',
          at: DateTime.now().subtract(kTombstoneRetention +
              const Duration(days: 30)));
      await src.tombstonesDao.mark('connections', 'NEW',
          at: DateTime.now().subtract(const Duration(days: 10)));
      final blob = await _service(src, storage).gatherAll();
      final ids = (blob['tombstones'] as List)
          .map((t) => (t as Map)['entityId'])
          .toList();
      expect(ids, contains('NEW'));
      expect(ids, isNot(contains('OLD')), reason: 'retention GC drops it');
    });
  });

  group('terminal_triggers sync (v15)', () {
    test('a created rule round-trips to the other device', () async {
      await _seedTrigger(src, 'T', t1, pattern: r'(?i)\berror\b');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      final restored = await dst.terminalTriggersDao.getById('T');
      expect(restored, isNotNull);
      expect(restored!.pattern, r'(?i)\berror\b');
      expect(restored.updatedAt?.toUtc(), t1,
          reason: 'restore preserves the incoming updatedAt, not now()');
    });

    test('delete propagates', () async {
      await _seedTrigger(src, 'T', t1);
      await _seedTrigger(dst, 'T', t1);
      await src.terminalTriggersDao.deleteTrigger('T');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.terminalTriggersDao.getById('T'), isNull);
    });

    test('edit newer than the delete survives (newest-wins)', () async {
      await _seedTrigger(dst, 'T', t3);
      await src.tombstonesDao.mark('terminal_triggers', 'T', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.terminalTriggersDao.getById('T'), isNotNull);
    });
  });

  group('command_history sync (v16)', () {
    test('a recorded command round-trips to the other device', () async {
      await _seedCommandHistory(src, 'H', t1, command: 'docker ps');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      final all = await dst.commandHistoryDao.getAll();
      expect(all.map((e) => e.command), contains('docker ps'));
    });

    test('delete propagates', () async {
      await _seedCommandHistory(src, 'H', t1);
      await _seedCommandHistory(dst, 'H', t1);
      await src.commandHistoryDao.deleteEntry('H');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.commandHistoryDao.getAll(), isEmpty);
    });
  });

  // The 5 tables that were timestamp-less before schema v29 (groups, identities,
  // networks, port-forward rules, snippet categories). v29 gave each an
  // `updatedAt` so tombstone arbitration is real "newest wins" instead of
  // always delete-wins. For every one we prove three things:
  //   1. it SYNCS and its updatedAt round-trips (gather -> restore preserves it),
  //   2. an EDIT newer than a delete SURVIVES (edit-beats-delete),
  //   3. a DELETE newer than the edit REMOVES it (delete-beats-edit).
  // Where a delete path wasn't already exercised by the capture-sweep group we
  // also drive the real DAO delete to prove it marks a tombstone.
  group('config tables: universal newest-wins (schema v29)', () {
    // -- connection_groups -------------------------------------------------
    test('group syncs and preserves updatedAt', () async {
      await _seedGroupAt(src, 'G', t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      final g = await dst.connectionGroupsDao.getById('G');
      expect(g, isNotNull);
      expect(g!.updatedAt?.toUtc(), t2,
          reason: 'restore must preserve the incoming updatedAt, not stamp now()');
    });
    test('group edit newer than delete survives', () async {
      await _seedGroupAt(dst, 'G', t3);
      await src.tombstonesDao.mark('connection_groups', 'G', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.connectionGroupsDao.getById('G'), isNotNull,
          reason: 'edit@t3 must beat delete@t2');
    });
    test('group delete newer than edit removes', () async {
      await _seedGroupAt(dst, 'G', t1);
      await src.tombstonesDao.mark('connection_groups', 'G', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.connectionGroupsDao.getById('G'), isNull,
          reason: 'delete@t2 must beat edit@t1');
    });

    // -- identities --------------------------------------------------------
    test('identity syncs and preserves updatedAt', () async {
      await _seedIdentityAt(src, 'K', t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      final k = await dst.identitiesDao.getById('K');
      expect(k, isNotNull);
      expect(k!.updatedAt?.toUtc(), t2);
    });
    test('identity delete propagates (DAO marks tombstone)', () async {
      await _seedIdentityAt(src, 'K', t1);
      await _seedIdentityAt(dst, 'K', t1);
      await src.identitiesDao.deleteIdentity('K');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.identitiesDao.getById('K'), isNull);
    });
    test('identity edit newer than delete survives', () async {
      await _seedIdentityAt(dst, 'K', t3);
      await src.tombstonesDao.mark('identities', 'K', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.identitiesDao.getById('K'), isNotNull);
    });
    test('identity delete newer than edit removes', () async {
      await _seedIdentityAt(dst, 'K', t1);
      await src.tombstonesDao.mark('identities', 'K', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.identitiesDao.getById('K'), isNull);
    });

    // -- networks ----------------------------------------------------------
    test('network syncs and preserves updatedAt', () async {
      await _seedNetworkAt(src, 'N', t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      final n = await dst.networksDao.getById('N');
      expect(n, isNotNull);
      expect(n!.updatedAt?.toUtc(), t2);
    });
    test('network delete propagates (DAO marks tombstone)', () async {
      await _seedNetworkAt(src, 'N', t1);
      await _seedNetworkAt(dst, 'N', t1);
      await src.networksDao.deleteNetwork('N');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.networksDao.getById('N'), isNull);
    });
    test('network edit newer than delete survives', () async {
      await _seedNetworkAt(dst, 'N', t3);
      await src.tombstonesDao.mark('networks', 'N', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.networksDao.getById('N'), isNotNull);
    });
    test('network delete newer than edit removes', () async {
      await _seedNetworkAt(dst, 'N', t1);
      await src.tombstonesDao.mark('networks', 'N', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.networksDao.getById('N'), isNull);
    });

    // -- port_forward_rules ------------------------------------------------
    test('port-forward rule syncs and preserves updatedAt', () async {
      await _seedRuleAt(src, 'R', 'C', t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      final rules = await dst.portForwardRulesDao.getByConnection('C');
      expect(rules, hasLength(1));
      expect(rules.single.updatedAt?.toUtc(), t2);
    });
    test('port-forward rule edit newer than delete survives', () async {
      await _seedRuleAt(dst, 'R', 'C', t3);
      await src.tombstonesDao.mark('port_forward_rules', 'R', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.portForwardRulesDao.getByConnection('C'), isNotEmpty);
    });
    test('port-forward rule delete newer than edit removes', () async {
      await _seedRuleAt(dst, 'R', 'C', t1);
      await src.tombstonesDao.mark('port_forward_rules', 'R', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.portForwardRulesDao.getByConnection('C'), isEmpty);
    });

    // -- snippet_categories (PK = name) ------------------------------------
    test('snippet category syncs and preserves updatedAt', () async {
      await _seedCategoryAt(src, 'ops', t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      final c = await dst.snippetCategoriesDao.getByName('ops');
      expect(c, isNotNull);
      expect(c!.updatedAt?.toUtc(), t2);
    });
    test('snippet category delete propagates (DAO marks tombstone)', () async {
      await _seedCategoryAt(src, 'ops', t1);
      await _seedCategoryAt(dst, 'ops', t1);
      await src.snippetCategoriesDao.deleteByName('ops');
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.snippetCategoriesDao.getByName('ops'), isNull);
    });
    test('snippet category edit newer than delete survives', () async {
      await _seedCategoryAt(dst, 'ops', t3);
      await src.tombstonesDao.mark('snippet_categories', 'ops', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.snippetCategoriesDao.getByName('ops'), isNotNull);
    });
    test('snippet category delete newer than edit removes', () async {
      await _seedCategoryAt(dst, 'ops', t1);
      await src.tombstonesDao.mark('snippet_categories', 'ops', at: t2);
      await _service(dst, storage)
          .restoreAll(await _service(src, storage).gatherAll());
      expect(await dst.snippetCategoriesDao.getByName('ops'), isNull);
    });
  });
}
