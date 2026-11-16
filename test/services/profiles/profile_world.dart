import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/vault_slot_service.dart';

/// A test's keychain: in memory, and it can say what was done in which order,
/// and stop on a name to play an app that was ended there.
class MemoryKeychain implements FlutterSecureStorage {
  MemoryKeychain([Map<String, String>? initial]) : kept = {...?initial};

  final Map<String, String> kept;

  /// Every write and delete, as `write:<name>` and `delete:<name>`.
  final log = <String>[];

  /// Throws at this many writes and deletes from now: the app ended there.
  int? stopAfter;

  void _count() {
    final left = stopAfter;
    if (left == null) return;
    if (left <= 0) throw const PlayedStop('keychain');
    stopAfter = left - 1;
  }

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        return Future<String?>.value(kept[key]);
      case #write:
        _count();
        final value = i.namedArguments[#value] as String?;
        log.add('write:$key');
        value == null ? kept.remove(key) : kept[key!] = value;
        return Future<void>.value();
      case #delete:
        _count();
        log.add('delete:$key');
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

/// The app ended here.
class PlayedStop implements Exception {
  const PlayedStop(this.at);
  final String at;
  @override
  String toString() => 'PlayedStop($at)';
}

/// ZestSSH Cloud, played: its locked copies in memory.
class PlayedCloud extends LockedCopiesApi {
  PlayedCloud() : super(baseUrl: 'http://played.invalid');

  final held = <String, Uint8List>{};
  final stores = <String>[];
  final handBacks = <String>[];
  final deletes = <String>[];

  /// For each delete, whether it was as the account on screen.
  final deletesOnScreen = <bool>[];

  /// Nothing answers.
  bool down = false;

  /// The secret is taken, and the answer lost, this many times.
  int answersLost = 0;

  /// The sign-in is too old for a hand-back.
  bool oldSignIn = false;

  void Function()? onHandBack;
  void Function()? onStore;

  void _reach() {
    if (down) throw const SocketException('played: no route');
  }

  @override
  Future<void> store({required String bearer, required String id, required List<int> secret}) async {
    _reach();
    onStore?.call();
    held.putIfAbsent(id, () => Uint8List.fromList(secret));
    stores.add(id);
    if (answersLost > 0) {
      answersLost--;
      throw const SocketException('played: the answer was lost');
    }
  }

  @override
  Future<Uint8List> handBack({required String bearer, required String id}) async {
    _reach();
    onHandBack?.call();
    if (oldSignIn) throw const LockedCopyRefused(403, 'recent-sign-in-required');
    final secret = held[id];
    if (secret == null) throw const LockedCopyRefused(404, 'locked-copy-not-found');
    handBacks.add(id);
    return Uint8List.fromList(secret);
  }

  /// The account was deleted (from another device): its copies went with it.
  bool accountGone = false;

  @override
  Future<List<LockedCopyInfo>> list({required String bearer}) async {
    _reach();
    if (accountGone) throw const LockedCopyRefused(401, 'account-not-found');
    return [for (final id in held.keys) LockedCopyInfo(id: id, platform: 'windows', madeOn: '2026-11-05')];
  }

  @override
  Future<bool> delete({required String bearer, required String id, bool onScreen = true}) async {
    _reach();
    deletes.add(id);
    deletesOnScreen.add(onScreen);
    return held.remove(id) != null;
  }
}

/// A database that takes one key: what SQLCipher does, played in a row of its
/// own, as a debug build's database has no key. A wrong one does not open.
class WrongKey implements Exception {
  const WrongKey();
}

const kKeyRow = 'test_database_key';

AppDatabase _onFile(File file) => AppDatabase.forTesting(NativeDatabase(file, setup: (db) {
      db.execute('PRAGMA journal_mode = WAL');
    }));

/// Opens the personal database in [dir], played as encrypted with [hex].
Future<AppDatabase> openPlayed(Directory dir, String hex) async {
  await dir.create(recursive: true);
  final db = _onFile(File(p.join(dir.path, 'zestssh.db')));
  await db.customSelect('SELECT 1').get();
  final store = LocalStateStore(db);
  final kept = await store.read(kKeyRow);
  if (kept == null) {
    await store.write(kKeyRow, hex);
  } else if (kept != hex) {
    await db.close();
    throw const WrongKey();
  }
  return db;
}

/// A computer in a test: its folders, its keychain, its preferences. Nothing
/// here reaches the real app data.
class ProfileWorld {
  ProfileWorld._(this.root, this.device, this.rawPrefs);

  static Future<ProfileWorld> create({Map<String, Object> prefs = const {}, Map<String, String>? keychain}) async {
    final root = await Directory.systemTemp.createTemp('zest_profiles_');
    SharedPreferences.setMockInitialValues(prefs);
    final raw = await SharedPreferences.getInstance();
    final world = ProfileWorld._(root, MemoryKeychain(keychain), raw);
    ProfilePaths.debugBase = world.base;
    await world.base.create(recursive: true);
    return world;
  }

  final Directory root;
  final MemoryKeychain device;
  final SharedPreferences rawPrefs;
  final cloud = PlayedCloud();
  void Function(String boundary)? stop;
  String? firebase;

  /// Firebase's first report, where a test plays that it takes its time.
  Future<void> Function()? firebaseReported;
  Duration firebaseWait = const Duration(seconds: 60);

  /// How a database opens, where a test plays that it does not.
  Future<AppDatabase> Function(Directory dir, String hex)? openDatabase;

  /// The store a test runs the app's own code on instead of [device]: the real
  /// file, with real gaps between its calls.
  FlutterSecureStorage? realDevice;

  Directory get base => Directory(p.join(root.path, 'appdata'));
  PersonFolders get folders =>
      PersonFolders(documents: Directory(p.join(root.path, 'docs')), support: Directory(p.join(root.path, 'support')));

  /// The app's start, as main.dart makes it: a new manager over what is on the
  /// disk and in the keychain.
  ProfileManager launch({LockedCopiesApi? api}) {
    final helper = ProfilePreferences(rawPrefs);
    ProfilePreferences.instance = helper;
    final manager = ProfileManager(
      base: base,
      device: realDevice ?? device,
      prefs: helper,
      rawPrefs: rawPrefs,
      folders: () => folders,
      firebaseUid: () => firebase,
      firebaseReported: firebaseReported,
      firebaseWait: firebaseWait,
      openDatabase: openDatabase ?? openPlayed,
      api: api ?? cloud,
      strictKeys: true,
      stop: (boundary) => stop?.call(boundary),
    );
    ProfileManager.instance = manager;
    return manager;
  }

  /// The keychain as a store sees it with [profile] open and [db] its database.
  FlutterSecureStorage keychainOf(ActiveProfile profile, AppDatabase? db) =>
      ProfileKeychain(device, profile: () => profile, tree: () => db);

  /// The profile's raw names in the keychain.
  List<String> rawNames(String id) =>
      device.kept.keys.where((k) => k.startsWith(KeychainPrefix.of(id))).toList()..sort();

  Future<void> dispose() async {
    Profiles.debugReset();
    ProfilePaths.debugBase = null;
    ProfileManager.instance = null;
    ProfilePreferences.instance = null;
    SecretSeal.openTree = null;
    if (await root.exists()) {
      for (var i = 0; i < 5; i++) {
        try {
          await root.delete(recursive: true);
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  }
}

/// Inserts a host row.
Future<void> addHost(AppDatabase db, String id) {
  final at = DateTime.utc(2026, 10, 30, 9);
  return db.into(db.connections).insert(
      ConnectionsCompanion.insert(id: id, label: id, host: '$id.example.com', createdAt: at, updatedAt: at));
}

Future<List<String>> hostsOf(AppDatabase db) async =>
    [for (final row in await db.select(db.connections).get()) row.id]..sort();

const kOldKey = 'aa00000000000000000000000000000000000000000000000000000000000000';

/// A device as the version before profiles left it, in [world]: `zestssh.db`
/// with [wal]'s host in its write-ahead file alone, as the window closes
/// without merging it. Returns the host in the main file and the one in the
/// write-ahead file. The database holds [sealKey] as the seal's key, if given.
Future<void> makeOldDatabase(ProfileWorld world, {String hex = kOldKey, required String wal, Map<String, String> state = const {}}) async {
  final scratch = await Directory(p.join(world.root.path, 'scratch')).create(recursive: true);
  final path = p.join(scratch.path, 'zestssh.db');
  final schema = _onFile(File(path));
  await schema.customSelect('SELECT 1').get();
  await addHost(schema, 'host-in-main');
  final store = LocalStateStore(schema);
  await store.write(kKeyRow, hex);
  for (final e in state.entries) {
    await store.write(e.key, e.value);
  }
  await schema.close();
  // A connection that is never closed, as an app that was ended: its last
  // change is in the write-ahead file alone, and the three files are copied as
  // they then lie.
  final open = sql.sqlite3.open(path);
  open.execute('PRAGMA journal_mode = WAL');
  open.execute('PRAGMA wal_autocheckpoint = 0');
  open.execute(
    'INSERT INTO connections (id, label, host, created_at, updated_at) VALUES (?, ?, ?, 1793000000, 1793000000)',
    [wal, wal, '$wal.example.com'],
  );
  for (final name in ['zestssh.db', 'zestssh.db-wal', 'zestssh.db-shm']) {
    await File(p.join(scratch.path, name)).copy(p.join(world.base.path, name));
  }
  open.dispose();
  await scratch.delete(recursive: true);
}

/// The hosts in the database file at [path], read as it lies, with no key.
List<String> hostsInFile(String path) {
  final db = sql.sqlite3.open(path);
  try {
    return [for (final row in db.select('SELECT id FROM connections ORDER BY id')) row['id'] as String];
  } finally {
    db.dispose();
  }
}

/// Runs [body]; a [PlayedStop] from it, the app ended there, is swallowed.
Future<bool> untilStopped(Future<void> Function() body) async {
  try {
    await body();
    return false;
  } on PlayedStop {
    return true;
  }
}

/// A vault of the lock as the version before profiles made it, for [dbKey].
Future<void> makeOldVault(ProfileWorld world, String dbKey, String pin) =>
    VaultSlotService(world.device).enableLock(dbKeyHex: dbKey, pin: pin);

@visibleForTesting
const kTeamA = '11111111-1111-4111-8111-111111111111';
@visibleForTesting
const kTeamB = '22222222-2222-4222-8222-222222222222';
@visibleForTesting
const kTeamC = '33333333-3333-4333-8333-333333333333';
