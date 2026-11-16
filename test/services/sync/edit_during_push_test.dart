// Real Argon2id key derivation (the weakest profile deriveKey accepts).
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A store whose next write waits until the test lets it go: a push in flight.
class _SlowStore extends MemoryStoreBackend {
  _SlowStore(super.store);

  Completer<void>? gate;
  Completer<void> reached = Completer<void>();

  @override
  Future<String?> writeObject(Uint8List bytes, {String? ifMatchEtag, bool ifAbsent = false}) async {
    final g = gate;
    if (g != null) {
      gate = null;
      reached.complete();
      await g.future;
    }
    return super.writeObject(bytes, ifMatchEtag: ifMatchEtag, ifAbsent: ifAbsent);
  }
}

/// A timer the test runs by hand.
class _HeldTimer implements Timer {
  _HeldTimer(this.wait, this.then);

  final Duration wait;
  final void Function() then;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

/// A change saved while a push is on its way is not in that push. The cycle
/// cleared the "changes waiting" flag after the push all the same
/// (AutoSyncService._runOneCycle), and the cycle the change asked for returned
/// at once while one ran, so the next cycles found nothing to send and called
/// the device synced: the change stayed on this device until some other change
/// (found in a data review).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SettingsService settings;
  late AppDatabase db;
  late _SlowStore backend;
  late AutoSyncService sync;
  late List<_HeldTimer> timers;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('correct-password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
  });

  Future<void> host(String id, String label) => db.into(db.connections).insertOnConflictUpdate(
      ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: '$id.example.com',
          createdAt: DateTime.utc(2026, 10, 1),
          updatedAt: DateTime.now().toUtc()));

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    backend = _SlowStore(MemoryStore());
    timers = [];
    sync = AutoSyncService(
      syncDataService: memoryDataService(db, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => backend,
      timer: (wait, then) {
        final t = _HeldTimer(wait, then);
        timers.add(t);
        return t;
      },
    );
    await storage.write(key: 'sync_salt', value: base64Encode(salt));
    await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);
    await host('h1', 'web-1');
    await host('h2', 'web-2');
    final v1 = (await backend.push(
      data: await memoryDataService(db, storage, settings).gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    ))
        .version;
    await settings.setSyncServerVersion(v1);
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  Future<Map<String, dynamic>> store() async => SyncService.decrypt((await backend.pull()).encryptedData, dek);

  String? labelIn(Map<String, dynamic> data, String id) =>
      [for (final c in data['connections'] as List) if ((c as Map)['id'] == id) c['label'] as String?].singleOrNull;

  /// Saves h1 and starts a cycle whose push waits: the cycle, and what lets
  /// its push land.
  Future<(Future<void>, Completer<void>)> pushOnItsWay() async {
    await host('h1', 'web-1 renamed');
    await settings.setSyncDirty(true);
    final gate = Completer<void>();
    backend.gate = gate;
    backend.reached = Completer<void>();
    final cycle = sync.triggerSync();
    await backend.reached.future;
    return (cycle, gate);
  }

  test('a change saved while a push is on its way stays marked, and the next cycle sends it', () async {
    final (cycle, gate) = await pushOnItsWay();

    // Meanwhile the person saves another change (notifyLocalChange marks it).
    await host('h2', 'web-2 renamed');
    await settings.setSyncDirty(true);

    gate.complete();
    await cycle;
    expect(labelIn(await store(), 'h1'), 'web-1 renamed');
    expect(labelIn(await store(), 'h2'), 'web-2', reason: 'not in the push that was on its way');
    expect(settings.syncDirty, isTrue, reason: 'the change made during the push is still to send');

    // The next cycle (the timer, a launch) sends it, and then nothing waits.
    await sync.triggerSync();
    expect(labelIn(await store(), 'h2'), 'web-2 renamed');
    expect(settings.syncDirty, isFalse);
  });

  test('a push with nothing saved meanwhile clears the flag', () async {
    await host('h1', 'web-1 renamed');
    await settings.setSyncDirty(true);
    await sync.triggerSync();
    expect(labelIn(await store(), 'h1'), 'web-1 renamed');
    expect(settings.syncDirty, isFalse);
  });

  test('the cycle a change asked for while one ran is run when that one ends', () async {
    final (cycle, gate) = await pushOnItsWay();
    await host('h2', 'web-2 renamed');
    // notifyLocalChange: marked, and its cycle asked for, which returns at once.
    await settings.setSyncDirty(true);
    await sync.triggerSync();
    timers.clear();

    gate.complete();
    await cycle;

    final again = timers.where((t) => !t.cancelled).toList();
    expect(again, hasLength(1), reason: 'the cycle that was asked for goes once this one ends');
    again.single.then();
    // Let the cycle that timer started run to its end.
    for (var i = 0; i < 500 && (sync.isSyncing || settings.syncDirty); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(labelIn(await store(), 'h2'), 'web-2 renamed');
    expect(settings.syncDirty, isFalse);
  });

  test('no cycle is run again when none was asked for meanwhile', () async {
    final (cycle, gate) = await pushOnItsWay();
    timers.clear();
    gate.complete();
    await cycle;
    expect(timers.where((t) => !t.cancelled), isEmpty);
    expect(settings.syncDirty, isFalse);
  });
}
