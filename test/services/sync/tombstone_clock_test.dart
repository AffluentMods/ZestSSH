import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A device's own secure storage, in memory.
class _Vault implements FlutterSecureStorage {
  final kept = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        return Future<String?>.value(kept[key]);
      case #write:
        final value = i.namedArguments[#value] as String?;
        value == null ? kept.remove(key) : kept[key!] = value;
        return Future<void>.value();
      case #delete:
        kept.remove(key);
        return Future<void>.value();
      case #readAll:
        return Future<Map<String, String>>.value(Map.of(kept));
      case #containsKey:
        return Future<bool>.value(kept.containsKey(key));
    }
    return super.noSuchMethod(i);
  }
}

/// A delete made by a clock that was wrong (found in a security review).
/// A delete's time was taken as written. One dated ahead outranked every
/// later change of the item on every device until its date came: a host
/// restored or made again was deleted again at each sync. And a device whose
/// clock was far ahead took every tombstone for older than the two years
/// they are kept, and dropped the whole set at its next gather. Now a delete
/// dated ahead is held to the time this device first hears of it, and no
/// tombstone is pruned while the device's clock is known to be wrong.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final key = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  late AppDatabase db;
  late SyncDataService data;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    db = AppDatabase.forTesting(NativeDatabase.memory());
    data = memoryDataService(db, _Vault(), settings);
  });

  tearDown(() => db.close());

  Future<void> host(String id, String label, DateTime at) => db.into(db.connections).insertOnConflictUpdate(
      ConnectionsCompanion.insert(id: id, label: label, host: '$id.example.com', createdAt: t0, updatedAt: at));

  Future<String?> labelOf(String id) async => (await db.connectionsDao.getById(id))?.label;

  Future<DateTime?> deletedAt(String id) async {
    for (final t in await db.tombstonesDao.getAll()) {
      if (t.entityType == 'connections' && t.entityId == id) return t.deletedAt;
    }
    return null;
  }

  /// What another device holds: no host, and the delete of h1 dated [at].
  Future<Map<String, dynamic>> deletedElsewhere(DateTime at) async {
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    final settings = SettingsService(await SharedPreferences.getInstance());
    await other.tombstonesDao.mark('connections', 'h1', at: at);
    return memoryDataService(other, _Vault(), settings).gatherAll();
  }

  Future<SyncRestoreResult> pull(Map<String, dynamic> blob) =>
      data.restoreAll(blob, merge: SyncMergeBase(key: key, base: null));

  test('a delete dated a year ahead removes the host once, and is held to now: the host made again stands', () async {
    await host('h1', 'web-1', t0);
    final blob = await deletedElsewhere(DateTime.now().add(const Duration(days: 365)));

    final before = DateTime.now();
    expect((await pull(blob)).success, isTrue);
    expect(await labelOf('h1'), isNull, reason: 'deleted elsewhere, and not changed here since');
    final held = (await deletedAt('h1'))!;
    expect(held.isAfter(DateTime.now().add(const Duration(seconds: 1))), isFalse, reason: 'held to now, not a year ahead');
    expect(held.isBefore(before.subtract(const Duration(seconds: 2))), isFalse);

    // The host comes back (a backup, or made again), changed after that.
    await host('h1', 'web-1 again', DateTime.now().add(const Duration(seconds: 5)));
    expect((await pull(blob)).success, isTrue);
    expect(await labelOf('h1'), 'web-1 again', reason: 'the delete does not outrank it until its date');
    expect((await deletedAt('h1'))!.difference(held).inSeconds.abs(), lessThanOrEqualTo(1),
        reason: 'the tombstone here is not moved to the second pull');

    // And what this device sends on carries the time it holds, not the year ahead.
    final sent = (await data.gatherAll())['tombstones'] as List;
    final mine = sent.cast<Map>().singleWhere((t) => t['entityId'] == 'h1');
    expect(DateTime.parse(mine['deletedAt'] as String).isAfter(DateTime.now().add(const Duration(minutes: 1))), isFalse);
  });

  test('a delete dated a few minutes ahead is another device whose clock is about right: taken as written', () async {
    await host('h1', 'web-1', t0);
    final at = DateTime.now().add(const Duration(minutes: 3));
    expect((await pull(await deletedElsewhere(at))).success, isTrue);
    expect(await labelOf('h1'), isNull);
    expect((await deletedAt('h1'))!.difference(at).inSeconds.abs(), lessThanOrEqualTo(1));
  });

  test('a delete dated in the past is taken as written, and a later one of the same host takes its place', () async {
    await host('h1', 'web-1', t0);
    final first = DateTime.now().subtract(const Duration(days: 3));
    expect((await pull(await deletedElsewhere(first))).success, isTrue);
    expect((await deletedAt('h1'))!.difference(first).inSeconds.abs(), lessThanOrEqualTo(1));
    final second = DateTime.now().subtract(const Duration(days: 1));
    expect((await pull(await deletedElsewhere(second))).success, isTrue);
    expect((await deletedAt('h1'))!.difference(second).inSeconds.abs(), lessThanOrEqualTo(1));
  });

  test('a tombstone this device holds dated ahead is put back to now at its next pull', () async {
    await db.tombstonesDao.mark('connections', 'h7', at: DateTime.now().add(const Duration(days: 400)));
    expect((await pull(await deletedElsewhere(DateTime.now().subtract(const Duration(days: 1))))).success, isTrue);
    expect((await deletedAt('h7'))!.isAfter(DateTime.now().add(const Duration(seconds: 1))), isFalse);
  });

  test('a backup that brings back a host deleted here with a date ahead writes it as changed now, not ahead',
      () async {
    await host('h1', 'web-1', t0);
    final backup = SyncDataService.withoutStoreCount(await data.gatherAll());
    await db.connectionsDao.deleteConnection('h1');
    await db.tombstonesDao.mark('connections', 'h1', at: DateTime.now().add(const Duration(days: 400)));

    expect((await data.restoreAll(backup, asBackup: true)).success, isTrue);
    final back = (await db.connectionsDao.getById('h1'))!;
    expect(back.updatedAt.isAfter(DateTime.now().add(const Duration(minutes: 1))), isFalse);
  });

  test('no tombstone is pruned while the clock is known to be wrong; with a clock that is right, the old ones go',
      () async {
    await db.tombstonesDao.mark('connections', 'old', at: DateTime.now().subtract(const Duration(days: 800)));
    await db.tombstonesDao.mark('connections', 'new', at: DateTime.now().subtract(const Duration(days: 8)));

    data.clockInDoubt = true;
    await data.gatherAll();
    expect(await deletedAt('old'), isNotNull);
    expect(await deletedAt('new'), isNotNull);

    data.clockInDoubt = false;
    await data.gatherAll();
    expect(await deletedAt('old'), isNull, reason: 'older than the two years tombstones are kept');
    expect(await deletedAt('new'), isNotNull);
  });
}
