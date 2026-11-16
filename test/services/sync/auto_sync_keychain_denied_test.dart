import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// The plugin on a Mac, where the person says no to macOS's question about one
/// of the app's items ([denied]).
class _Plugin extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  final kept = <String, String>{};
  final reads = <String>[];
  bool Function(String name)? denied;

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    reads.add(key);
    if (denied?.call(key) ?? false) {
      throw PlatformException(
          code: 'Unexpected security result code', message: 'Code: -128, Message: The user canceled.', details: -128);
    }
    return kept[key];
  }

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async =>
      kept[key] = value;

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async => kept.remove(key);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => kept.containsKey(key);

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(kept);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async => kept.clear();
}

/// A reported bug right after 3.3.0: on a Mac, macOS asked
/// over and over whether ZestSSH may use what it saved in its keychain. A no to the
/// sync key was a failure like any other: background sync tried again at its next
/// turn (and each Orchard round at its own), and each try brought the question up
/// again. Now a no is kept for the run: what runs by itself waits, asks nothing,
/// and goes on once the person chooses Try again (3.3.2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FlutterSecureStoragePlatform before;
  late _Plugin plugin;
  late AppDatabase db;
  late AutoSyncService sync;

  setUp(() async {
    before = FlutterSecureStoragePlatform.instance;
    plugin = _Plugin();
    FlutterSecureStoragePlatform.instance = MacKeychain(plugin);
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    await settings.setSyncMode('auto');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    const storage = FlutterSecureStorage();
    plugin.kept['sync_dek'] = 'a made-up key';
    sync = AutoSyncService(
      syncDataService: memoryDataService(db, storage, settings),
      settingsService: settings,
      secureStorage: storage,
      resolveBackend: () => MemoryStoreBackend(MemoryStore()),
    );
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
    FlutterSecureStoragePlatform.instance = before;
  });

  int asked() => plugin.reads.where((name) => name == 'sync_dek').length;

  test('background sync that macOS says no to waits: nothing asked again, nothing counted, until Try again', () async {
    plugin.denied = (name) => name == 'sync_dek';
    await sync.triggerSync();
    expect(asked(), 1);
    expect(keychainWaitsForPerson, isTrue);

    for (var i = 0; i < 5; i++) {
      await sync.triggerSync();
    }
    expect(asked(), 1, reason: 'no try by itself brought the question up again');
    expect(sync.activity.value.paused, isFalse, reason: 'not failures that pause sync: it waits for the person');

    // The person chooses Try again, and Always Allow.
    plugin.denied = null;
    keychainDenials!.tryAgain();
    expect(keychainWaitsForPerson, isFalse);
    await sync.triggerSync();
    expect(asked(), 2);
  });

  test('the rounds of teams by their timers wait too, until Try again', () {
    final rounds = File('lib/features/orchards/orchard_providers.dart').readAsStringSync();
    expect('if (!keychainWaitsForPerson) unawaited('.allMatches(rounds), hasLength(4),
        reason: 'syncAll, checkOfflineLimits, exportRounds and checkInvites, each by its timer');
  });

  test('Sync now that macOS says no to says so, with its code', () async {
    plugin.denied = (name) => name == 'sync_dek';
    await expectLater(
        sync.syncNowManual(), throwsA(isA<SyncException>().having((e) => e.message, 'message', endsWith('(ZS-1913)'))));
  });
}
