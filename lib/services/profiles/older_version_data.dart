import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/error_kind.dart';

/// What an older version left at the old place, as it looks now.
class OlderVersionSummary {
  const OlderVersionSummary({required this.hosts, required this.keys, required this.opened, this.locked = false});

  final int hosts;
  final int keys;

  /// Whether it could be read at all: what cannot be left where it is, and this
  /// version cannot say what it holds. Leaving it is a way out, and deleting it is said
  /// as what it is.
  final bool opened;

  /// It is behind an app lock this version has no PIN for, which is why it cannot be
  /// read: said as that.
  final bool locked;

  bool get empty => opened && hosts == 0 && keys == 0;
}

/// An older version run after the move makes a new, empty `zestssh.db` at the
/// old place, and works there. The new version never takes that over a profile
/// and never opens it by itself: it offers what it finds, to bring into the
/// profile on screen or delete. Nothing is done with it until the person says.
class OlderVersionData {
  OlderVersionData({
    required this.base,
    required this.device,
    required this.rawPrefs,
    Future<AppDatabase> Function(Directory dir, String hex)? openDatabase,
  }) : _openDatabase = openDatabase ?? AppDatabase.openAt;

  final Directory base;
  final FlutterSecureStorage device;
  final SharedPreferences rawPrefs;
  final Future<AppDatabase> Function(Directory dir, String hex) _openDatabase;

  File get _main => File(p.join(base.path, ProfileMove.mainFile));

  Future<bool> get isThere => _main.exists();

  Future<AppDatabase?> _open() async {
    final hex = await device.read(key: KeychainNames.databaseKey);
    if (hex == null) return null;
    final db = await _openDatabase(base, hex);
    await db.customSelect('SELECT 1').get();
    return db;
  }

  /// What is there. Never throws.
  Future<OlderVersionSummary> look() async {
    AppDatabase? db;
    try {
      db = await _open();
      if (db == null) {
        final names = await keychainNamesIn(device);
        final locked = names.contains(KeychainNames.wrappedDatabaseKey) || names.contains(KeychainNames.hardwareWrappedDatabaseKey);
        return OlderVersionSummary(hosts: 0, keys: 0, opened: false, locked: locked);
      }
      final hosts = await db.customSelect('SELECT COUNT(*) AS n FROM connections').getSingle();
      final keys = await db.customSelect('SELECT COUNT(*) AS n FROM identities').getSingle();
      return OlderVersionSummary(hosts: hosts.read<int>('n'), keys: keys.read<int>('n'), opened: true);
    } catch (e) {
      AppLogger.warning('Data from an older version could not be read (${errorKind(e)})');
      return const OlderVersionSummary(hosts: 0, keys: 0, opened: false);
    } finally {
      await db?.close();
    }
  }

  /// Brings what is there into [into], the profile on screen, as a restore
  /// does, with its saved passwords and keys sealed for that profile, and then
  /// deletes it. Throws, with nothing deleted, where it cannot be read.
  Future<void> bringInto(SyncDataService into) async {
    final db = await _open();
    if (db == null) throw StateError('It cannot be read');
    try {
      final old = SyncDataService(
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
        secureStorage: device,
        settingsService: SettingsService(rawPrefs),
      );
      // Its hosts and keys, and none of its settings: the person's stay as they
      // are.
      final payload = await old.gatherAll()
        ..remove('settings')
        ..remove('account_keys');
      final result = await into.restoreAll(payload);
      if (!result.success) throw StateError('It could not be brought in');
    } finally {
      await db.close();
    }
    await delete();
  }

  /// Deletes what the older version left: its database with its side files and
  /// the secrets under its names. Nothing of a profile or the lock is touched.
  Future<void> delete() async {
    for (final suffix in ['', ...ProfileMove.sideSuffixes]) {
      final file = File(p.join(base.path, '${ProfileMove.mainFile}$suffix'));
      if (await file.exists()) await file.delete();
    }
    final teams = Directory(p.join(base.path, 'orchards'));
    if (await teams.exists()) await teams.delete(recursive: true);
    // Its secrets, and what it kept in the system's store of what is a person's. Where
    // a move set aside midway may yet come back they are that move's too, and stay until
    // it is deleted or finished.
    if (await oldNamesStillNeeded(base)) return;
    await deleteOldLayoutEntries(device, rawPrefs);
  }
}
