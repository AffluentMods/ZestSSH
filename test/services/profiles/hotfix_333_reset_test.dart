import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/profiles/profile_boot.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';

import 'profile_world.dart';

/// The keychain plugin's interface over a map: what a phone's database reaches.
class _OverMemory extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  _OverMemory(this.kept);
  final Map<String, String> kept;
  bool refuse = false;
  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => kept.containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async => kept.remove(key);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async => kept.clear();
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    if (refuse) throw PlatformException(code: 'Keystore', message: 'not now');
    return kept[key];
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(kept);
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async =>
      kept[key] = value;
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Devices implements DeviceSessionService {
  @override
  Future<void> signOutHere({Duration within = const Duration(seconds: 6)}) async {}
  @override
  Future<void> forget() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The 3.3.3 hotfix: Reset keeps everything, a sign-out that stopped still locks, and
/// data elsewhere on a Mac is found and brought back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'account-alice';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  ProviderContainer app(AppDatabase? db) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
      secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      deviceSessionServiceProvider.overrideWithValue(_Devices()),
    ]);
    if (db != null) c.read(databaseSessionProvider.notifier).seed(db);
    addTearDown(c.dispose);
    return c;
  }

  group('fix 2: Reset is offered only where nothing says the data is just waiting', () {
    test('never on a computer, never for a keychain\'s or a platform\'s exception, never while a move runs', () {
      final sqlBroken = StateError('SQL logic error: no such table');
      expect(resetOffered(sqlBroken, moving: false, computer: false), isTrue, reason: 'a phone, a broken database');
      expect(resetOffered(sqlBroken, moving: false, computer: true), isFalse, reason: 'a computer has Set aside');
      expect(resetOffered(sqlBroken, moving: true, computer: false), isFalse);
      // A refusal macOS has no status of ours for, and every other platform's.
      expect(resetOffered(PlatformException(code: 'Unexpected security result code', details: -25291), moving: false, computer: false),
          isFalse);
      expect(resetOffered(KeychainAccessDenied(-128), moving: false, computer: false), isFalse);
      expect(resetOffered(const FileSystemException('held'), moving: false, computer: false), isFalse);
      expect(resetOffered(TimeoutException('keychain'), moving: false, computer: false), isFalse);
      expect(
          resetOffered(StateError('Cannot read encryption key from secure storage, but database file exists.'),
              moving: false, computer: false),
          isFalse);
    });
  });

  group('fix 2 and 3: Reset on a phone sets the data aside, and the key stays', () {
    late FlutterSecureStoragePlatform before;
    late _OverMemory keychain;
    setUp(() {
      Profiles.debugReset();
      before = FlutterSecureStoragePlatform.instance;
      keychain = _OverMemory({'zestssh_db_encryption_key': 'the-old-key'});
      FlutterSecureStoragePlatform.instance = keychain;
    });
    tearDown(() => FlutterSecureStoragePlatform.instance = before);

    Future<void> files() async {
      await world.base.create(recursive: true);
      for (final name in ['zestssh.db', 'zestssh.db-wal', 'zestssh_backup_1793000000000.db']) {
        await File(p.join(world.base.path, name)).writeAsString(name);
      }
    }

    test('the files go to a folder of their own, whole, and the key is kept under another name too', () async {
      await files();
      final aside = await AppDatabase.setAsideAndRecreate();
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isFalse, reason: 'the next start is fresh');
      for (final name in ['zestssh.db', 'zestssh.db-wal', 'zestssh_backup_1793000000000.db']) {
        expect(File(p.join(aside.path, name)).readAsStringSync(), name);
      }
      expect(keychain.kept['zestssh_db_encryption_key'], 'the-old-key', reason: 'the key is never deleted');
      final at = int.parse(p.basename(aside.path));
      expect(keychain.kept[AppDatabase.resetAsideKeyName(at)], 'the-old-key');
    });

    test('a key the keychain does not hand over stops it, with nothing moved', () async {
      await files();
      keychain.refuse = true;
      await expectLater(AppDatabase.setAsideAndRecreate(), throwsA(isA<PlatformException>()));
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isTrue);
      expect(Directory(p.join(world.base.path, AppDatabase.resetAsideFolder)).existsSync(), isFalse);
    });

    test('on a computer it is refused: a profile is set aside instead', () async {
      Profiles.turnOn();
      await expectLater(AppDatabase.setAsideAndRecreate(), throwsA(isA<StateError>()));
    });
  });

  group('fix 1: the person\'s own sign-out that stopped before its lock', () {
    test('is finished at the next start on a Mac, whatever Firebase says, and the note goes', () async {
      world.firebaseReported = () async {};
      world.firebase = uid;
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final plan = await manager.planForAccount(uid: uid, label: 'alice@example.com', bearer: 'token');
      final prepared = await manager.prepare(plan);
      await guest.close();
      await manager.commit(prepared);
      final db = prepared.db;
      SecretSeal.openTree = db;
      expect(await manager.settleLockedCopy(db: db, bearer: 'b'), isTrue);
      final id = manager.currentEntry!.id;
      final c = app(db);
      await c.read(profileControllerProvider).signOutBegins();
      // The app ends here, before Firebase's sign-out and the lock.
      await db.close();
      SecretSeal.openTree = null;
      Profiles.debugReset();

      world.firebase = null;
      final next = world.launch();
      await next.start();
      final opened = await next.openCurrent();
      SecretSeal.openTree = opened;
      final c2 = app(opened);
      await c2.read(profileControllerProvider).afterOpened();
      expect(next.list.byId(id)!.state, ProfileState.locked);
      expect(File(p.join(ProfilePaths.root(world.base).path, 'sign_out_v1')).existsSync(), isFalse);
      await c2.read(databaseSessionProvider)!.close();
    });
  });

  group('fix 5: data elsewhere on this computer (guest data, a Mac)', () {
    setUp(() => ProfileController.looksElsewhere = () => true);
    tearDown(() => ProfileController.looksElsewhere = () => Platform.isMacOS);

    /// Guest data with a host, a copy of it before an upgrade, and then emptied, as a
    /// Reset or a new database left it. Returns the open, empty database.
    Future<(ProfileManager, AppDatabase)> emptiedGuestWithCopy() async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      await addHost(db, 'host-of-guest');
      final id = manager.currentEntry!.id;
      final dir = ProfilePaths.ofProfile(world.base, id);
      await db.close();
      final copies = Directory(p.join(dir.path, 'migration_backups'))..createSync(recursive: true);
      File(p.join(dir.path, 'zestssh.db')).copySync(p.join(copies.path, 'pre_v53_to_v54_1793000000000.db'));
      final wal = File(p.join(dir.path, 'zestssh.db-wal'));
      if (wal.existsSync()) wal.copySync(p.join(copies.path, 'pre_v53_to_v54_1793000000000.db-wal'));
      Profiles.debugReset();
      final next = world.launch();
      await next.start();
      final open = await next.openCurrent();
      await open.customStatement('DELETE FROM connections');
      return (next, open);
    }

    test('a copy beside empty guest data is found, and brought back; the copy stays as it was', () async {
      final (manager, db) = await emptiedGuestWithCopy();
      SecretSeal.openTree = db;
      final c = app(db);
      final profiles = c.read(profileControllerProvider);
      final found = await profiles.dataElsewhere();
      expect(found?.kind, DataElsewhereKind.copy);
      expect(found!.profile, manager.currentEntry!.id);
      final copyBefore = found.file!.readAsBytesSync();

      await profiles.bringBackElsewhere(found);
      expect(await hostsOf(db), ['host-of-guest']);
      expect(found.file!.readAsBytesSync(), copyBefore, reason: 'nothing is changed where it lies');
      expect(Directory(p.join(ProfilePaths.root(world.base).path, 'looking')).listSync(), isEmpty);
      expect(await profiles.dataElsewhere(), isNull, reason: 'it holds something now');
      await db.close();
    });

    test('a copy that the key here does not open is not offered', () async {
      final (manager, db) = await emptiedGuestWithCopy();
      final copy = Directory(p.join(ProfilePaths.ofProfile(world.base, manager.currentEntry!.id).path, 'migration_backups'))
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.db'));
      // A copy whose key is another's: what the stand-in database checks.
      final otherDir = Directory(p.join(world.root.path, 'other'));
      final other = await openPlayed(otherDir, 'cc00');
      await addHost(other, 'host-of-someone');
      await other.close();
      for (final f in [copy, File('${copy.path}-wal')]) {
        if (f.existsSync()) f.deleteSync();
      }
      File(p.join(otherDir.path, 'zestssh.db')).copySync(copy.path);
      final otherWal = File(p.join(otherDir.path, 'zestssh.db-wal'));
      if (otherWal.existsSync()) otherWal.copySync('${copy.path}-wal');

      expect(await manager.dataElsewhere(db), isNull);
      await db.close();
    });

    test('an account\'s data, signed out, with guest data on screen: its sign-in is offered, nothing opened', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final plan = await manager.planForAccount(uid: uid, label: 'alice@example.com', bearer: 'token');
      final prepared = await manager.prepare(plan);
      await guest.close();
      await manager.commit(prepared);
      await addHost(prepared.db, 'host-of-alice');
      SecretSeal.openTree = prepared.db;
      expect(await manager.settleLockedCopy(db: prepared.db, bearer: 'b'), isTrue);
      final id = manager.currentEntry!.id;
      expect(await manager.lockCurrent(), SignOutEnd.locked);
      final open = await manager.openGuest();
      await prepared.db.close();
      final found = await manager.dataElsewhere(open);
      expect(found?.kind, DataElsewhereKind.signIn);
      expect(found!.profile, id);
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isFalse, reason: 'still locked');
      expect(manager.list.byId(id)!.state, ProfileState.locked);
      await open.close();
    });

    test('nowhere but a Mac', () async {
      ProfileController.looksElsewhere = () => false;
      final (_, db) = await emptiedGuestWithCopy();
      final c = app(db);
      expect(await c.read(profileControllerProvider).dataElsewhere(), isNull);
      await db.close();
    });
  });
}
