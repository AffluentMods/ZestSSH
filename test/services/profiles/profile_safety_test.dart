import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/local_data_wipe.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/local_data_wiper.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/deep_link_service.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/services/google_desktop_oauth.dart';
import 'package:zestssh/services/linux_keyring.dart';
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/linux_keychain.dart';
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/profiles/older_version_data.dart';
import 'package:zestssh/services/profiles/profile_boot.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/profiles/windows_keychain.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/error/database_error_screen.dart';
import 'package:zestssh/ui/screens/error/migration_error_screen.dart';
import 'package:zestssh/ui/screens/error/moving_data_screen.dart';
import 'package:zestssh/ui/screens/error/startup_error_screen.dart';
import 'package:zestssh/ui/screens/profile/widgets/older_version_data_dialog.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';

import 'profile_world.dart';

/// The keychain plugin's interface over a [MemoryKeychain]'s map: what the app
/// reaches through [appKeychain] itself, as a Reset does, in a test.
class _OverMemory extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  _OverMemory(this.kept);
  final Map<String, String> kept;
  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => kept.containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async => kept.remove(key);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async => kept.clear();
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => kept[key];
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

/// Review findings about accounts on one computer that have no home of their own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'account-alice';
  const other = 'account-bob';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  Future<void> oldDeviceLockOff() async {
    await makeOldDatabase(world, wal: 'host-in-wal');
    world.device.kept.addAll({
      KeychainNames.databaseKey: kOldKey,
      'session_token': 'made.up.token',
      'session_uid': uid,
      'session_email': 'alice@example.com',
      'identity_key_k1': 'PRIVATE KEY OF K1',
      'identity_password_k1': 'a password',
    });
  }

  Future<AppDatabase> signIn(ProfileManager manager, AppDatabase from, String who, {String bearer = 'token'}) async {
    final plan = await manager.planForAccount(uid: who, label: '$who@example.com', bearer: bearer);
    final prepared = await manager.prepare(plan);
    await from.close();
    await manager.commit(prepared);
    return prepared.db;
  }

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

  group('what overlapped on the keychain\'s one file', () {
    test('a sign-in tells ZestSSH Cloud of its copy only after its session is written, and waits for that', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final c = app(guest);
      final profiles = c.read(profileControllerProvider);
      var sessionThere = true;
      world.cloud.onStore = () {
        final name = KeychainNames.full(manager.currentEntry!.id, uid, 'session_token');
        sessionThere = sessionThere && world.device.kept.containsKey(name);
      };
      await profiles.openForAccount(uid: uid, label: 'a@example.com', bearer: 'token');
      expect(manager.currentEntry!.uid, uid);
      // Time for anything left running beside the session to reach ZestSSH Cloud.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(world.cloud.stores, isEmpty);
      await AccountSecret.sessionToken.write(c.read(secureStorageProvider), 'made.up.token');
      expect(world.cloud.stores, isEmpty);
      await profiles.sessionKept();
      expect(world.cloud.stores, hasLength(1));
      expect(sessionThere, isTrue);
      final open = c.read(databaseSessionProvider)!;
      expect(identical(open, guest), isFalse);
      await open.close();
    });

    test('a session that could not be written tells ZestSSH Cloud nothing, and the profile locks as for a sign-out', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final c = app(guest);
      final profiles = c.read(profileControllerProvider);
      await profiles.openForAccount(uid: uid, label: 'a@example.com', bearer: 'token');
      await profiles.sessionNotKept();
      expect(world.cloud.stores, isEmpty);
      expect(manager.currentEntry!.uid, isNull);
      final open = c.read(databaseSessionProvider)!;
      await open.close();
    });

    test('another process moving: this one waits for it, and goes on from what it left', () async {
      await oldDeviceLockOff();
      final root = await ProfilePaths.root(world.base).create(recursive: true);
      final other = await File(p.join(root.path, 'move.lock')).open(mode: FileMode.append);
      await other.lock(FileLock.exclusive);
      var done = false;
      final manager = world.launch();
      final starting = manager.start().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(done, isFalse);
      expect(File(p.join(root.path, 'move_v1.json')).existsSync(), isFalse, reason: 'nothing of it began');
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isTrue);
      await other.close();
      await starting;
      final db = await manager.openCurrent();
      expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
      await db.close();
    }, skip: Platform.isWindows ? false : 'elsewhere a lock is the whole process\'s');

    test('another process that finished while this one waited: nothing moves a second time', () async {
      await oldDeviceLockOff();
      final root = await ProfilePaths.root(world.base).create(recursive: true);
      final other = await File(p.join(root.path, 'move.lock')).open(mode: FileMode.append);
      await other.lock(FileLock.exclusive);
      final manager = world.launch();
      final starting = manager.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // What it left: the list, which is what says this device has moved.
      final theirs = ProfileEntry(id: newProfileId(), made: 1);
      await ProfileList(entries: [theirs], current: theirs.id).write(world.device);
      await other.close();
      await starting;
      expect(manager.list.current, theirs.id);
      expect(File(p.join(root.path, 'move_v1.json')).existsSync(), isFalse);
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isTrue, reason: 'what is at the old place is not taken');
    }, skip: Platform.isWindows ? false : 'elsewhere a lock is the whole process\'s');

    test('a keychain that cannot be read says so, and locks nothing: that is no sign-out', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
        secureStorageProvider.overrideWithValue(_CannotBeRead()),
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Juiced()),
        deviceSessionServiceProvider.overrideWithValue(_Devices()),
      ]);
      addTearDown(c.dispose);
      c.read(databaseSessionProvider.notifier).seed(db);
      await expectLater(c.read(profileControllerProvider).afterOpened(), throwsA(isA<KeychainFileFailed>()));
      expect(manager.currentEntry!.uid, uid);
      expect(manager.currentEntry!.state, ProfileState.open);
      expect(c.read(databaseSessionProvider), same(db));
      await db.close();
    });
  });

  group('originals, the seal\'s key, restores', () {
    test('no restore while a move is under way: the private key still opens, and the host in the write-ahead file is there', () async {
      await oldDeviceLockOff();
      world.stop = (b) {
        if (b == 'entriesSealed') throw StateError('SQL logic error');
      };
      final manager = world.launch();
      await manager.start();
      final backup = await MigrationBackupService.createPreMigrationBackup(fromVersion: 0, toVersion: 0);
      await expectLater(manager.openCurrent(), throwsStateError);
      // main.dart's general catch: it reads as a failed migration.
      await expectLater(MigrationBackupService.restoreFromBackup(backup), throwsStateError);
      Profiles.debugReset();

      world.stop = null;
      final again = world.launch();
      await again.start();
      final db = await again.openCurrent();
      final keychain = world.keychainOf(Profiles.current!, db);
      expect(await keychain.read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
      expect(await hostsOf(db), contains('host-in-wal'));
      await db.close();
    });

    test('with a move stopped after its secrets were sealed, an open that fails at the next start restores nothing', () async {
      await oldDeviceLockOff();
      world.stop = (b) {
        if (b == 'entriesSealed') throw const PlayedStop('here');
      };
      final first = world.launch();
      await first.start();
      expect(await untilStopped(() async {
        await first.openCurrent();
      }), isTrue);
      Profiles.debugReset();
      world.stop = null;

      // main.dart's copy, and an open that fails in words it takes for a migration.
      world.openDatabase = (dir, hex) async => throw StateError('no such table: x');
      final next = world.launch();
      await next.start();
      final backup = await MigrationBackupService.createPreMigrationBackup(fromVersion: 0, toVersion: 0);
      await expectLater(next.openCurrent(), throwsStateError);
      expect(await next.moveUnderWay(), isTrue);
      await expectLater(MigrationBackupService.restoreFromBackup(backup), throwsStateError);
      Profiles.debugReset();

      world.openDatabase = null;
      final last = world.launch();
      await last.start();
      final db = await last.openCurrent();
      expect(await world.keychainOf(Profiles.current!, db).read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
      expect(await hostsOf(db), contains('host-in-wal'));
      await db.close();
    });

    test('a failure after the migrations passed is no reason to go back: a copy from before has no seal key', () async {
      await oldDeviceLockOff();
      world.stop = (b) {
        if (b == 'done') throw StateError('SQL logic error');
      };
      final manager = world.launch();
      await manager.start();
      final backup = await MigrationBackupService.createPreMigrationBackup(fromVersion: 0, toVersion: 0);
      await expectLater(manager.openCurrent(), throwsStateError);
      expect(await manager.moveUnderWay(), isFalse, reason: 'the move itself was over');
      await expectLater(MigrationBackupService.restoreFromBackup(backup), throwsStateError);
    });

    test('a new seal key is in the main file before anything is sealed with it', () async {
      await oldDeviceLockOff();
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      final dir = ProfilePaths.ofProfile(world.base, manager.currentEntry!.id);
      final copyDir = await Directory(p.join(world.root.path, 'copy')).create();
      final copy = await File(p.join(dir.path, 'zestssh.db')).copy(p.join(copyDir.path, 'zestssh.db'));
      final opened = sql.sqlite3.open(copy.path);
      final rows = opened.select("SELECT key FROM local_state WHERE key = 'secret_seal_key_v1'");
      opened.dispose();
      expect(rows, isNotEmpty, reason: 'the main file alone, as a copy of it has');
      await db.close();
    });

    test('an original whose copy does not open to the same stays, and the others go', () async {
      await oldDeviceLockOff();
      world.stop = (b) {
        if (b == 'teamsMoved') throw const PlayedStop('before the originals');
      };
      final first = world.launch();
      await first.start();
      final stopped = await untilStopped(() async {
        await first.openCurrent();
      });
      expect(stopped, isTrue);
      // The database a stop left open is let go of in the real world by the end of
      // the process; a new one over the same file is what matters here.
      Profiles.debugReset();
      world.stop = null;
      final id = first.list.current!;
      final full = KeychainNames.full(id, uid, 'identity_key_k1');
      // Its copy was lost or damaged somehow.
      world.device.kept.remove(full);
      final other2 = KeychainNames.full(id, uid, 'identity_password_k1');
      final db0 = await openPlayed(ProfilePaths.ofProfile(world.base, id), kOldKey);
      final seal = await SecretSeal.forProfile(db0);
      world.device.kept[other2] = await seal.seal(other2, 'not what it was');
      await db0.close();

      final next = world.launch();
      await next.start();
      final db = await next.openCurrent();
      expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1', reason: 'no copy: it stays');
      expect(world.device.kept['identity_password_k1'], 'a password', reason: 'a copy that differs: it stays');
      expect(world.device.kept.containsKey('session_token'), isFalse, reason: 'one whose copy opens to the same goes');
      await db.close();
    });

    test('a backup takes the write-ahead file along, and a restore puts it back', () async {
      // As on a phone or a computer alike: the service works on the folder.
      await makeOldDatabase(world, wal: 'host-in-wal');
      final path = await MigrationBackupService.createPreMigrationBackup(fromVersion: 1, toVersion: 2);
      expect(File('$path-wal').existsSync(), isTrue);
      // A migration that failed left something else behind.
      final main = File(p.join(world.base.path, 'zestssh.db'));
      await File(p.join(world.base.path, 'zestssh.db-wal')).delete();
      await main.writeAsBytes(const [1, 2, 3]);
      await MigrationBackupService.restoreFromBackup(path);
      expect(hostsInFile(main.path), containsAll(['host-in-main', 'host-in-wal']));
    });
  });

  group('Reset on a signed-in profile', () {
    late FlutterSecureStoragePlatform before;
    setUp(() {
      before = FlutterSecureStoragePlatform.instance;
      FlutterSecureStoragePlatform.instance = _OverMemory(world.device.kept);
    });
    tearDown(() => FlutterSecureStoragePlatform.instance = before);

    test('Reset is not offered on a computer: Set aside keeps the data and its key, and Put it back opens it (3.3.3)', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      expect(await manager.settleLockedCopy(db: db, bearer: 'b'), isTrue);
      await addHost(db, 'host-of-alice');
      final id = manager.currentEntry!.id;
      await db.close();
      SecretSeal.openTree = null;
      Profiles.debugReset();
      // Before 3.3.3 Reset deleted the database, its copies and its key here, and the
      // next start made a new key over the data.
      expect(resetOffered(StateError('file is not a database'), moving: false, computer: true), isFalse);

      final broken = world.launch();
      await broken.start();
      await broken.setAsideCurrent();
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isTrue, reason: 'the key stays');
      expect(await broken.copies.confirmed(id), isNotNull, reason: 'what opens it at ZestSSH Cloud stays');
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      final fresh = await next.openCurrent();
      expect(next.currentEntry!.id, isNot(id));
      await next.askPutBack();
      await fresh.close();
      Profiles.debugReset();

      final back = world.launch();
      await back.start();
      final opened = await back.openCurrent();
      expect(back.currentEntry!.id, id);
      expect(await hostsOf(opened), ['host-of-alice']);
      await opened.close();
    });
  });

  group('a move whose database does not open', () {
    Future<void> brokenMove(ProfileWorld w) async {
      await oldDeviceLockOff();
      // Its key no longer opens it: a lost DPAPI key, or a damaged file.
      world.device.kept[KeychainNames.databaseKey] = 'bb00';
    }

    test('set aside, it starts fresh, deletes nothing, says so, and can then be deleted', () async {
      await brokenMove(world);
      final manager = world.launch();
      await manager.start();
      await expectLater(manager.openCurrent(), throwsA(isA<WrongKey>()));
      expect(await manager.moveUnderWay(), isTrue, reason: 'the marker stays, so Reset is not offered');
      final id = (await ProfileList.read(world.device))!.current!;
      final held = File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'zestssh.db'));
      final copyOfTheSet = File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'pre_move', 'zestssh.db-wal'));
      expect(held.existsSync(), isTrue);
      expect(copyOfTheSet.existsSync(), isTrue);

      await manager.setAsideCurrent();
      expect(await manager.moveUnderWay(), isFalse);
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      final db = await next.openCurrent();
      expect(next.currentEntry!.id, isNot(id));
      expect(next.currentEntry!.uid, isNull);
      expect(await hostsOf(db), isEmpty);
      expect(next.list.byId(id)!.state, ProfileState.setAside);
      expect(await next.setAsideHere(), isTrue);
      // Nothing is deleted: the folder is whole, and what the move had yet to touch
      // is where it was.
      final aside = ProfilePaths.setAside(world.base).listSync().single as Directory;
      expect(File(p.join(aside.path, 'zestssh.db')).existsSync(), isTrue);
      expect(File(p.join(aside.path, 'pre_move', 'zestssh.db-wal')).existsSync(), isTrue);
      expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1');
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isTrue);
      // The account gets a new profile of its own, and never the one set aside.
      expect(next.list.byUid(uid), isNull);

      await next.deleteSetAside();
      expect(await next.setAsideHere(), isFalse);
      expect(next.list.byId(id), isNull);
      expect(world.rawNames(id), isEmpty);
      await db.close();
    });

    testWidgets('the screen: no Reset where none is offered, and Set aside says what it does first', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final l10n = lookupAppLocalizations(const Locale('en'));
      var setAside = 0;
      var fails = false;
      await tester.pumpWidget(DatabaseErrorApp(
        report: 'the report',
        onRetry: () {},
        onReset: null,
        onSetAside: () async {
          setAside++;
          if (fails) throw StateError('held');
        },
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('database-error-reset')), findsNothing);
      expect(find.byType(ErrorDetailsPanel), findsOneWidget, reason: 'Copy details stays');
      await tester.tap(find.byKey(const ValueKey('database-error-set-aside')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.databaseErrorSetAsideBody), findsOneWidget);
      expect(setAside, 0);
      await tester.tap(find.text(l10n.databaseErrorSetAside).last);
      await tester.pumpAndSettle();
      expect(setAside, 1);
      // One that fails says so, with its details, and what it says is what to do.
      fails = true;
      await tester.tap(find.byKey(const ValueKey('database-error-set-aside')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.databaseErrorSetAside).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.databaseErrorSetAsideFailed), findsOneWidget);
    });
  });

  group('every screen a failed move can end on has the way out', () {
    testWidgets('an update that failed and could not be put back', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final l10n = lookupAppLocalizations(const Locale('en'));
      var setAside = 0;
      await tester.pumpWidget(MigrationErrorApp(
        report: 'the report',
        backupRestored: false,
        onContinue: () {},
        onSetAside: () async => setAside++,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('migration-error-set-aside')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.databaseErrorSetAsideBody), findsOneWidget);
      await tester.tap(find.text(l10n.databaseErrorSetAside).last);
      await tester.pumpAndSettle();
      expect(setAside, 1);
    });

    testWidgets('a phone is offered none', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MigrationErrorApp(report: 'the report', backupRestored: false, onContinue: () {}));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('migration-error-set-aside')), findsNothing);
    });

    test('the start\'s own screen offers what it is handed, and only that', () async {
      Future<void> set() async {}
      final move = await startupErrorAppFor(const ProfileMoveFailed('keys', 'read back'), StackTrace.empty, onRetry: () {}, onSetAside: set);
      expect(move.onSetAside, isNotNull);
      final none = await startupErrorAppFor(const ProfileMoveFailed('keys', 'read back'), StackTrace.empty, onRetry: () {});
      expect(none.onSetAside, isNull);
    });

    test('the window\'s own failure offers what it finds, and a try that fails again is said again', () async {
      Widget? shown;
      var started = 0;
      Future<void> set() async {}
      final window = StartupWindow(
        show: (app) => shown = app,
        start: () => started++,
        state: () async => KeyringState.unknown,
        wayOut: (error) async => error is ProfileMoveFailed ? set : null,
      );
      await window.failed(const ProfileMoveFailed('marker', 'several copies'), StackTrace.empty);
      expect((shown! as StartupErrorApp).onSetAside, isNotNull);
      window.retry();
      expect(started, 1);
      await window.failed(StateError('x'), StackTrace.empty);
      expect((shown! as StartupErrorApp).onSetAside, isNull);
    });

    test('main hands every screen of a start its way out, and each try is its own', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('wayOut: (error) => startWayOut('));
      expect('_setAsideAndStart()'.allMatches(main).length, greaterThanOrEqualTo(4), reason: 'the two of a migration, the database, a move');
      final start = main.indexOf('Future<void> Function()? _setAsideAndStart()');
      expect(main.substring(start), contains('_startupWindow.retry()'));
      expect(main, isNot(contains('onRetry: () => main([])')));
      expect(main, isNot(contains('onContinue: () => main([])')));
    });

    testWidgets('and the button is there on that screen', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(StartupErrorApp(report: 'the report', onRetry: () {}, onSetAside: () async {}));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('startup-error-set-aside')), findsOneWidget);
    });
  });

  group('on the screen before the move', () {
    testWidgets('what it says', (tester) async {
      await tester.pumpWidget(const MovingDataApp());
      await tester.pump();
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.movingDataMessage), findsOneWidget);
      expect(l10n.movingDataMessage, 'Moving your data to its new place. Do not close ZestSSH.');
    });

    test('said before the move begins, and only where there is one', () async {
      await oldDeviceLockOff();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var markerAtTheMoment = true;
      var said = 0;
      Future<void> say() async {
        said++;
        markerAtTheMoment = File(p.join(ProfilePaths.root(world.base).path, 'move_v1.json')).existsSync();
      }

      final boot = await bootProfiles(rawPrefs: world.rawPrefs, sayMoving: say, manager: (_) => world.launch());
      expect(said, 1);
      expect(markerAtTheMoment, isFalse, reason: 'before anything of it');
      expect(boot.start, isNotNull);
      final db = await ProfileManager.instance!.openCurrent();
      await db.close();
      Profiles.debugReset();

      final again = await bootProfiles(rawPrefs: world.rawPrefs, sayMoving: say, manager: (_) => world.launch());
      expect(said, 1, reason: 'a start with nothing to move says nothing');
      expect(again.start, isNotNull);
    });
  });

  group('the gate of a phone, as main.dart goes through it', () {
    test('main goes through it before anything reads a setting of a person, and each window has the store', () {
      final main = File('lib/main.dart').readAsStringSync();
      final boot = main.indexOf('bootProfiles(');
      expect(boot, greaterThan(0));
      expect(main.indexOf('installKeychainStore()'), inInclusiveRange(1, boot));
      expect('installKeychainStore()'.allMatches(main), hasLength(2), reason: 'a pop-out has an engine of its own');
      expect(main.indexOf('backupBeforeUpgrade'), greaterThan(boot));
      expect(main.indexOf('TerminalThemes.loadCustomThemes'), greaterThan(boot));
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test('$platform: no helper, no manager, nothing moved, nothing said, and the keychain as it was', () async {
        await oldDeviceLockOff();
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final before = FlutterSecureStoragePlatform.instance;
        installKeychainStore();
        expect(identical(FlutterSecureStoragePlatform.instance, before), isTrue);

        final boot = await bootProfiles(
          rawPrefs: world.rawPrefs,
          sayMoving: () async => fail('nothing moves on a phone'),
          manager: (_) => fail('no manager on a phone'),
        );
        expect(boot.start, isNull);
        expect(identical(boot.prefs, world.rawPrefs), isTrue);
        expect(ProfilePreferences.instance, isNull);
        expect(ProfileManager.instance, isNull);
        expect(Profiles.on, isFalse);
        expect(identical(appKeychain, deviceKeychain), isTrue);
        expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isTrue);
        expect(ProfilePaths.root(world.base).existsSync(), isFalse);
        expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1');
      });
    }

    test('a computer gets its store, once, whichever window asks', () {
      final before = FlutterSecureStoragePlatform.instance;
      addTearDown(() {
        FlutterSecureStoragePlatform.instance = before;
        debugDefaultTargetPlatformOverride = null;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      installKeychainStore();
      final safe = FlutterSecureStoragePlatform.instance;
      expect(safe, isA<SafeWindowsKeychain>());
      installKeychainStore();
      expect(identical(FlutterSecureStoragePlatform.instance, safe), isTrue);
      FlutterSecureStoragePlatform.instance = before;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      installKeychainStore();
      expect(FlutterSecureStoragePlatform.instance, isA<MacKeychain>());
      FlutterSecureStoragePlatform.instance = before;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      installKeychainStore();
      expect(FlutterSecureStoragePlatform.instance, isA<LinuxKeychain>());
    });
  });

  group('Firebase has yet to say', () {
    test('at the first start whose data this is waits for its word', () async {
      await makeOldDatabase(world, wal: 'host-in-wal');
      world.device.kept[KeychainNames.databaseKey] = kOldKey;
      world.firebaseReported = () async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        world.firebase = uid; // Only now does it say who it is.
      };
      final manager = world.launch();
      await manager.start();
      expect(manager.currentEntry!.uid, uid, reason: 'not guest data on a timeout');
    });

    test('no word in time: it says so and nothing moves, and it never decides', () async {
      await makeOldDatabase(world, wal: 'host-in-wal');
      world.device.kept[KeychainNames.databaseKey] = kOldKey;
      world.firebaseReported = () => Completer<void>().future;
      world.firebaseWait = const Duration(milliseconds: 40);
      final manager = world.launch();
      await expectLater(manager.start(), throwsA(isA<ProfileMoveFailed>()));
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isTrue);
      expect(ProfileList.read(world.device), completion(isNull));
      expect(File(p.join(ProfilePaths.root(world.base).path, 'move_v1.json')).existsSync(), isFalse);
    });

    test('at a later start an account with no session is not locked until it has said', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      final said = Completer<void>();
      world.firebase = null;
      final c = app(db);
      Profiles.debugReset();
      Profiles.turnOn();
      final next = ProfileManager(
        base: world.base,
        device: world.device,
        prefs: manager.prefs,
        rawPrefs: world.rawPrefs,
        folders: () => world.folders,
        firebaseUid: () => world.firebase,
        firebaseReported: () => said.future,
        openDatabase: openPlayed,
        api: world.cloud,
        strictKeys: true,
      );
      await next.start();
      ProfileManager.instance = next;
      final done = c.read(profileControllerProvider).afterOpened();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(next.list.byId(next.list.current)!.state, ProfileState.open, reason: 'nothing on a guess');
      world.firebase = uid;
      said.complete();
      await done;
      expect(next.currentEntry!.uid, uid, reason: 'it was signed in all along');
      expect(next.currentEntry!.state, ProfileState.open);
      await db.close();
    });

    test('a Mac\'s sign-in has no session to write: it is not left waiting for one', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      world.firebase = uid;
      final c = app(guest);
      await c.read(profileControllerProvider).afterOpened();
      expect(manager.currentEntry!.uid, uid);
      // Signed out of Firebase later, with no session: this time it is a sign-out.
      world.firebase = null;
      await c.read(profileControllerProvider).afterOpened();
      expect(manager.currentEntry!.uid, isNull, reason: 'it would still be waiting for a session');
      final open = c.read(databaseSessionProvider)!;
      await open.close();
    });
  });

  group('what is in memory goes with the person', () {
    test('at a change of profile: Google\'s access token, a link not yet answered, a browser sign-in still waiting', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      await world.keychainOf(Profiles.current!, db).write(key: 'session_token', value: 'made.up.token');
      final c = app(db);
      await c.read(syncProviderConfigProvider.notifier).ensureLoaded();

      GoogleDesktopOAuth.instance.debugHoldAccessToken('the person\'s');
      expect(GoogleDesktopOAuth.instance.holdsAccessToken, isTrue);
      DeviceSessionHeader.current = 'the person\'s';
      // The first is the link the app opened with, and the next one waits.
      DeepLinkService.debugForgetInitialLink();
      addTearDown(DeepLinkService.debugForgetInitialLink);
      DeepLinkService.injectLink(Uri.parse('zestssh://join#first'));
      DeepLinkService.injectLink(Uri.parse('zestssh://join#second'));
      final browser = DesktopBrowserSignIn.addPasskeyInBrowser(open: (_) async {});
      final browserEnded = expectLater(browser, throwsA(isA<BrowserSignInCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await c.read(profileControllerProvider).lockAfterSignOut();

      expect(GoogleDesktopOAuth.instance.holdsAccessToken, isFalse);
      expect(DeviceSessionHeader.current, isNull);
      await browserEnded.timeout(const Duration(seconds: 5));
      final links = <Uri>[];
      final listening = DeepLinkService.linkStream.listen(links.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await listening.cancel();
      expect(links, isEmpty, reason: 'it was for the person who was here');
      final open = c.read(databaseSessionProvider)!;
      await open.close();
    });

    test('whoever waits for the database while it is closed is told, and never handed the next person\'s', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      await world.keychainOf(Profiles.current!, db).write(key: 'session_token', value: 'made.up.token');
      final c = app(db);
      await manager.locked();
      await c.read(databaseSessionProvider.notifier).close();
      expect(SecretSeal.openTree, isNull);

      final waiting = SecretSeal.whenOpen();
      final told = expectLater(waiting, throwsA(isA<NoProfileOpen>()));
      await c.read(profileControllerProvider).lockAfterSignOut();
      await told.timeout(const Duration(seconds: 5));
    });

    test('a sealed session read once the database opens says none, rather than wait for the next person\'s', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      final keychain = world.keychainOf(Profiles.current!, db);
      await keychain.write(key: 'session_token', value: 'token');
      SecretSeal.openTree = null;
      final closed = world.keychainOf(Profiles.current!, null);
      final reading = AccountSecret.sessionToken.readOnceOpen(closed);
      await Future<void>.delayed(Duration.zero);
      SecretSeal.dropWaiters();
      expect(await reading, isNull);
      await db.close();
    });
  });

  group('the cloud reach', () {
    test('a change of profile leaves the service the app\'s root tied itself to', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance())]);
      addTearDown(c.dispose);
      final reach = c.read(cloudReachProvider);
      refreshPersonState(c);
      expect(identical(c.read(cloudReachProvider), reach), isTrue);
    });
  });

  group('what a wipe of this profile leaves behind', () {
    Future<(ProfileManager, AppDatabase)> alone() async {
      final manager = world.launch();
      await manager.start();
      return (manager, await manager.openCurrent());
    }

    test('alone on the computer with nothing else: nothing to ask', () async {
      final (manager, db) = await alone();
      expect(await manager.otherDataHere(), isFalse);
      await db.close();
    });

    test('a held team', () async {
      final (manager, db) = await alone();
      final held = await ProfilePaths.heldTeams(world.base).create(recursive: true);
      await File(p.join(held.path, '$kTeamA.db')).writeAsString('x');
      expect(await manager.otherDataHere(), isTrue);
      await db.close();
    });

    test('held account keys', () async {
      final (manager, db) = await alone();
      await HeldEntries(world.device).put('account_keys_v1_someone', 'held');
      expect(await manager.otherDataHere(), isTrue);
      await db.close();
    });

    test('the app lock', () async {
      final (manager, db) = await alone();
      world.device.kept['security_pin_hash'] = 'a hash';
      expect(await manager.otherDataHere(), isTrue);
      await db.close();
    });

    test('what an older version left', () async {
      final (manager, db) = await alone();
      await File(p.join(world.base.path, 'zestssh.db')).writeAsString('x');
      expect(await manager.otherDataHere(), isTrue);
      await db.close();
    });

    test('and the wipe does what it says: behaviour, not the source', () async {
      final (manager, guest) = await alone();
      await addHost(guest, 'guest-host');
      await world.keychainOf(Profiles.current!, guest).write(key: 'identity_key_g', value: 'GUEST KEY');
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      await manager.settleLockedCopy(db: db, bearer: 'b');
      final copy = (await manager.copies.confirmed(manager.currentEntry!.id))!.id;
      final aliceId = manager.currentEntry!.id;
      final keychain = ProfileKeychain(world.device);
      await AccountSecret.sessionToken.write(keychain, 'made.up.token');
      world.device.kept['security_pin_hash'] = 'the PIN';
      final c = app(db);
      await c.read(syncProviderConfigProvider.notifier).ensureLoaded();

      c.read(desktopSessionProvider.notifier).state = const UserProfile(uid: uid, email: 'alice@example.com');
      await deleteAllLocalData(c.read, targets: const WipeTargets());
      expect(manager.list.byId(aliceId), isNull);
      expect(world.rawNames(aliceId), isEmpty);
      expect(world.cloud.deletes, contains(copy), reason: 'ZestSSH Cloud\'s secret for it goes, while the session can ask');
      // The guest's, the lock and the list are as they were, and it was the account's
      // that went: a sign-out first would have locked it, and wiped the guest's.
      expect(manager.currentEntry!.id, guestId);
      final open = c.read(databaseSessionProvider)!;
      expect(await hostsOf(open), ['guest-host']);
      expect(await world.keychainOf(Profiles.current!, open).read(key: 'identity_key_g'), 'GUEST KEY');
      expect(world.device.kept['security_pin_hash'], 'the PIN');
      await open.close();
    });

    test('a deleted account: the sign-out leaves its profile open, marked, and never locked', () async {
      final (manager, guest) = await alone();
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      await manager.settleLockedCopy(db: db, bearer: 'b');
      final id = manager.currentEntry!.id;
      await AccountSecret.sessionToken.write(ProfileKeychain(world.device), 'made.up.token');
      final c = app(db);
      await c.read(syncProviderConfigProvider.notifier).ensureLoaded();
      await forgetDeletedAccount(c.read, uid);
      expect(manager.currentEntry!.id, id);
      expect(manager.list.byId(id)!.state, ProfileState.gone);
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isTrue, reason: 'not locked');
      expect(c.read(databaseSessionProvider), same(db));
      await db.close();
    });
  });

  test('the account\'s page goes through the flows above, and has no wipe of its own', () {
    final page = File('lib/ui/screens/profile/profile_screen.dart').readAsStringSync();
    expect(page, contains('await profiles.otherDataHere()'));
    expect(page, contains(RegExp(r'deleteAllLocalData\(\s*ref\.read,\s*everything: everything,')));
    expect(page, contains('forgetDeletedAccount(ref.read, fresh.uid)'));
    expect(page, contains('wipeThisDevice(ref.read)'));
    expect(page, isNot(contains('LocalDataWiper(')));
  });

  group('ciphertext is nobody\'s value', () {
    test('while the database is closed a store that knows of no seal reads none, and one that does reads it sealed', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      final open = world.keychainOf(Profiles.current!, db);
      await open.write(key: 'device_session_v1', value: 'a registration');
      await open.write(key: 'session_token', value: 'a token');
      final closed = world.keychainOf(Profiles.current!, null);
      expect(await closed.read(key: 'device_session_v1'), isNull);
      expect(SecretSeal.isSealed(await closed.read(key: 'session_token')), isTrue);
      expect((await closed.readAll()).keys, isNot(contains('device_session_v1')));
      await db.close();
    });

    test('and no device registers anew for that: nothing is asked while it is closed', () async {
      Profiles.turnOn();
      SecretSeal.openTree = null;
      var registered = 0;
      final service = DeviceSessionService(
        api: _CountingApi(() => registered++),
        store: DeviceSessionStore(world.device),
        firebaseUid: () => uid,
        sessionToken: () async => null,
        saveSessionToken: (_) async {},
        labels: () async => const DeviceLabels(platform: 'macos'),
      );
      await service.ensure();
      expect(registered, 0);
    });
  });

  group('the lower ones', () {
    test('commit: the list names the profile first, and what waits is claimed as it opens if that stopped', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      await HeldEntries(world.device).put('account_keys_v1_$uid', 'keys of alice');
      final prepared = await manager.prepare(await manager.planForAccount(uid: uid, label: 'a@example.com', bearer: 'b'));
      await guest.close();
      // The key, the list's second copy and the list go through, and the next write
      // fails: what waits stays where it is, as it does after a stop.
      world.device.stopAfter = 3;
      await manager.commit(prepared);
      world.device.stopAfter = null;
      final list = (await ProfileList.read(world.device))!;
      expect(list.byUid(uid), isNotNull, reason: 'the list came first');
      expect((await HeldEntries(world.device).names()), contains('account_keys_v1_$uid'), reason: 'it still waits');
      await prepared.db.close();
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      final db = await next.openCurrent();
      expect(await world.keychainOf(Profiles.current!, db).read(key: 'account_keys_v1_$uid'), 'keys of alice');
      expect(await HeldEntries(world.device).names(), isEmpty);
      await db.close();
    });

    test('ids: `..` or an empty one never reaches a path', () async {
      for (final id in ['..', '', 'aaaa', '../..', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA']) {
        expect(isProfileId(id), isFalse, reason: id);
        expect(() => ProfilePaths.ofProfile(world.base, id), throwsArgumentError, reason: id);
      }
      expect(isProfileId(newProfileId()), isTrue);
      // A list that names one is no list, and is never taken for an empty one.
      world.device.kept[ProfileList.name] = jsonEncode({
        'v': 1,
        'current': '..',
        'profiles': [
          {'id': '..', 'state': 'removing', 'made': 1},
        ],
      });
      await expectLater(ProfileList.read(world.device), throwsA(isA<ProfileListUnreadable>()));
    });

    test('a marker naming `..` is a marker that cannot be read', () async {
      await oldDeviceLockOff();
      final marker = File(p.join(ProfilePaths.root(world.base).path, 'move_v1.json'));
      await marker.parent.create(recursive: true);
      await marker.writeAsString(jsonEncode({'v': 1, 'profile': '..', 'stage': 'copied', 'files': []}));
      final manager = world.launch();
      await manager.start();
      expect(isProfileId(manager.list.current), isTrue);
      final db = await manager.openCurrent();
      expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
      await db.close();
    });

    test('forCurrent: with no profile open on a computer there is no such folder, and no one gets everyone\'s', () {
      final parent = Directory(p.join(world.root.path, 'logs'));
      expect(ProfilePaths.forCurrent(parent).path, parent.path, reason: 'on a phone it is what it was');
      Profiles.turnOn();
      expect(() => ProfilePaths.forCurrent(parent), throwsA(isA<NoProfileOpen>()));
      final id = newProfileId();
      Profiles.bind(ActiveProfile(id: id, dir: world.base));
      expect(ProfilePaths.forCurrent(parent).path, p.join(parent.path, id));
    });

    test('a removal whose folder would not go stays on the list, and is tried again', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final db = await signIn(manager, guest, uid);
      final id = manager.currentEntry!.id;
      await manager.markCurrentRemoving();
      final next = await manager.openGuest();
      await db.close();
      final held = await File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'held-by-something')).open(mode: FileMode.write);
      await manager.finishRemovals();
      expect(manager.list.byId(id)?.state, ProfileState.removing);
      await held.close();
      await manager.finishRemovals();
      expect(manager.list.byId(id), isNull);
      expect(ProfilePaths.ofProfile(world.base, id).existsSync(), isFalse);
      await next.close();
    }, skip: Platform.isWindows ? false : 'only Windows refuses to delete a file held open');

    test('changes of profile run one at a time, whatever asks', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final c = app(guest);
      final profiles = c.read(profileControllerProvider);
      final order = <String>[];
      await Future.wait([
        profiles.openForAccount(uid: uid, label: 'a@example.com', bearer: 'b').then((_) => order.add('in')),
        profiles.lockAfterSignOut().then((_) => order.add('out')),
      ]);
      expect(order, ['in', 'out']);
      expect(manager.currentEntry!.uid, isNull, reason: 'the second saw what the first left');
      expect(manager.list.byUid(uid)!.state, ProfileState.hidden);
      final open = c.read(databaseSessionProvider)!;
      await open.close();
    });

    test('a renewal in flight is kept in the profile that asked for it, never in the next person\'s', () async {
      Profiles.turnOn();
      final alice = ActiveProfile(id: newProfileId(), dir: world.base, uid: uid);
      final bob = ActiveProfile(id: newProfileId(), dir: world.base, uid: other);
      Profiles.bind(alice);
      SecretSeal.openTree = null;
      final saved = <String>[];
      final at = DateTime.utc(2026, 10, 30);
      final service = DeviceSessionService(
        api: _CountingApi(() {}, refresh: () {
          // The answer comes after the next person's profile opened.
          Profiles.bind(bob);
          return 'a renewed token';
        }),
        store: DeviceSessionStore(world.device),
        firebaseUid: () => null,
        sessionToken: () async => 'an old token',
        saveSessionToken: (t) async => saved.add(t),
        labels: () async => const DeviceLabels(platform: 'windows'),
        now: () => at,
        issuedAt: (_) => at.subtract(const Duration(days: 30)),
      );
      await service.renewIfOld();
      expect(saved, isEmpty);
      // And with nobody else there it is kept, as ever.
      Profiles.bind(alice);
      final again = DeviceSessionService(
        api: _CountingApi(() {}, refresh: () => 'a renewed token'),
        store: DeviceSessionStore(world.device),
        firebaseUid: () => null,
        sessionToken: () async => 'an old token',
        saveSessionToken: (t) async => saved.add(t),
        labels: () async => const DeviceLabels(platform: 'windows'),
        now: () => at,
        issuedAt: (_) => at.subtract(const Duration(days: 30)),
      );
      await again.renewIfOld();
      expect(saved, ['a renewed token']);
    });

    test('the first profile has its name, and the question never shows an id', () async {
      await oldDeviceLockOff();
      final manager = world.launch();
      await manager.start();
      expect(manager.currentEntry!.label, 'alice@example.com');
      final db = await manager.openCurrent();
      final c = app(db);
      expect(c.read(profileControllerProvider).otherAccounts, isEmpty);
      final bobId = newProfileId();
      manager.list.put(ProfileEntry(id: bobId, uid: other, made: 1));
      expect(c.read(profileControllerProvider).otherAccounts, isEmpty, reason: 'no name: never the id');
      manager.list.put(ProfileEntry(id: bobId, uid: other, label: 'bob@example.com', made: 1));
      expect(c.read(profileControllerProvider).otherAccounts, ['bob@example.com']);
      await db.close();
    });

    group('what is retired at ZestSSH Cloud', () {
      test('is deleted at a sign-in, while it is fresh, and not asked at another start, which would be refused', () async {
        final manager = world.launch();
        await manager.start();
        final guest = await manager.openCurrent();
        final db = await signIn(manager, guest, uid);
        SecretSeal.openTree = db;
        await manager.settleLockedCopy(db: db, bearer: 'b');
        final id = manager.currentEntry!.id;
        final first = (await manager.copies.confirmed(id))!.id;
        // A replace whose flush failed: the network went just then.
        world.cloud.down = false;
        final failing = _RefusingDelete(world.cloud);
        final copies = LockedCopies(world.device);
        final seal = await SecretSeal.forProfile(db);
        final profile = Profiles.current!;
        await copies.settle(profile: profile, hex: 'k' * 64, seal: seal, bearer: 'b', api: failing, replace: true);
        expect(failing.tried, [first]);
        final second = (await copies.confirmed(id))!.id;
        expect(second, isNot(first));
        // Another start, with no sign-in: it is not asked.
        failing.tried.clear();
        await copies.settle(profile: profile, hex: 'k' * 64, seal: seal, bearer: 'b', api: failing);
        expect(failing.tried, isEmpty);
        // The next sign-in: it goes.
        await copies.settle(profile: profile, hex: 'k' * 64, seal: seal, bearer: 'b', api: world.cloud, signedInNow: true);
        expect(world.cloud.deletes, [first]);
        await db.close();
      });

      test('the account holds as many as it may: what this device retired makes room', () async {
        final manager = world.launch();
        await manager.start();
        final guest = await manager.openCurrent();
        final db = await signIn(manager, guest, uid);
        SecretSeal.openTree = db;
        await manager.settleLockedCopy(db: db, bearer: 'b');
        final seal = await SecretSeal.forProfile(db);
        final profile = Profiles.current!;
        final copies = LockedCopies(world.device);
        final full = _FullOnce(world.cloud);
        // Retire one first, as a replace whose flush failed leaves it.
        final failing = _RefusingDelete(world.cloud);
        await copies.settle(profile: profile, hex: 'k' * 64, seal: seal, bearer: 'b', api: failing, replace: true);
        await copies.settle(profile: profile, hex: 'k' * 64, seal: seal, bearer: 'b', api: full, replace: true);
        expect(full.refused, 1);
        expect(await copies.confirmed(profile.id), isNotNull);
        await db.close();
      });

      test('a copy that did not read back: nothing is forgotten, and what it replaces is not deleted', () async {
        final manager = world.launch();
        await manager.start();
        final guest = await manager.openCurrent();
        final db = await signIn(manager, guest, uid);
        SecretSeal.openTree = db;
        await manager.settleLockedCopy(db: db, bearer: 'b');
        final id = manager.currentEntry!.id;
        final first = (await manager.copies.confirmed(id))!.id;
        final seal = await SecretSeal.forProfile(db);
        final losing = _LosesWritesOf(world.device, '${KeychainPrefix.of(id)}${KeychainNames.lockedCopy}');
        await expectLater(
          LockedCopies(losing).settle(profile: Profiles.current!, hex: 'k' * 64, seal: seal, bearer: 'b', api: world.cloud, replace: true),
          throwsA(isA<LockedCopyDoesNotOpen>()),
        );
        expect(world.cloud.deletes, isEmpty, reason: 'the only secret there is stays');
        expect(world.cloud.held.containsKey(first), isTrue);
        expect(world.device.kept.containsKey('${KeychainPrefix.of(id)}${KeychainNames.lockedCopyNext}'), isTrue, reason: 'what it wrote stays, to go on from');
        await db.close();
      });
    });

    group('a marker that cannot be read', () {
      Future<File> marker() async {
        final file = File(p.join(ProfilePaths.root(world.base).path, 'move_v1.json'));
        await file.parent.create(recursive: true);
        return file;
      }

      test('at any stage: the move goes on from its copy, and nothing is lost', () async {
        await oldDeviceLockOff();
        world.stop = (b) {
          if (b == 'filesMoved') throw const PlayedStop('here');
        };
        final first = world.launch();
        await untilStopped(() async {
          await first.start();
        });
        Profiles.debugReset();
        world.stop = null;
        await (await marker()).writeAsString('{"half": ');

        final next = world.launch();
        await next.start();
        final db = await next.openCurrent();
        expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
        expect(await world.keychainOf(Profiles.current!, db).read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
        expect(next.currentEntry!.uid, uid);
        expect(ProfilePaths.root(world.base).listSync().where((e) => e.path.contains('move_v1.json.broken')), hasLength(1));
        await db.close();
      });

      test('with no copy: nothing had moved, and the move starts', () async {
        await oldDeviceLockOff();
        await (await marker()).writeAsString('not json');
        final manager = world.launch();
        await manager.start();
        final db = await manager.openCurrent();
        expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
        await db.close();
      });

      test('with several copies, and none holds a database: nothing had moved, and the move starts', () async {
        await oldDeviceLockOff();
        await (await marker()).writeAsString('not json');
        for (final _ in [1, 2]) {
          await Directory(p.join(ProfilePaths.ofProfile(world.base, newProfileId()).path, 'pre_move')).create(recursive: true);
        }
        final manager = world.launch();
        await manager.start();
        final db = await manager.openCurrent();
        expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
        await db.close();
      });

      test('with several copies, and one holds the database: that is the move under way', () async {
        await oldDeviceLockOff();
        world.stop = (b) {
          if (b == 'filesMoved') throw const PlayedStop('here');
        };
        final first = world.launch();
        await untilStopped(() async {
          await first.start();
        });
        Profiles.debugReset();
        world.stop = null;
        await (await marker()).writeAsString('{"half": ');
        await Directory(p.join(ProfilePaths.ofProfile(world.base, newProfileId()).path, 'pre_move')).create(recursive: true);
        final next = world.launch();
        await next.start();
        final db = await next.openCurrent();
        expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
        expect(await world.keychainOf(Profiles.current!, db).read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
        await db.close();
      });

      test('with several copies that hold a database: it says so, with its reason, and touches nothing', () async {
        await oldDeviceLockOff();
        await (await marker()).writeAsString('not json');
        for (final _ in [1, 2]) {
          final dir = ProfilePaths.ofProfile(world.base, newProfileId());
          await Directory(p.join(dir.path, 'pre_move')).create(recursive: true);
          await File(p.join(dir.path, 'zestssh.db')).writeAsString('a database');
        }
        final manager = world.launch();
        await expectLater(manager.start(), throwsA(isA<ProfileMoveFailed>().having((e) => e.step, 'step', 'marker')));
        expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isTrue);
      });
    });

    test('what an older version left with no hosts is said as keys, never as 0 hosts', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(olderDataWords(l10n, const OlderVersionSummary(hosts: 0, keys: 2, opened: true)), l10n.olderDataBodyKeys(2));
      expect(olderDataWords(l10n, const OlderVersionSummary(hosts: 3, keys: 2, opened: true)), l10n.olderDataBody(3));
      expect(olderDataWords(l10n, const OlderVersionSummary(hosts: 0, keys: 0, opened: false)), l10n.olderDataUnreadable);
    });

    test('what is set aside says how to get it back, or that it can be deleted', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(l10n.teamSetAsideBody, contains('to get it back'));
      expect(l10n.profileSetAsideBody, contains('Put it back'));
      expect(l10n.profileSetAsideBody, contains('delete it'));
      expect(l10n.databaseErrorSetAsideBody, contains('get the old data back'));
    });

    test('a failure of a Mac\'s profile at a start is said, in the words of a sign-in', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      final db = await signIn(manager, guest, uid);
      SecretSeal.openTree = db;
      await manager.settleLockedCopy(db: db, bearer: 'b');
      await manager.lockCurrent();
      final next = await manager.openGuest();
      await db.close();
      SecretSeal.openTree = next;
      world.firebase = uid;
      world.cloud.down = true;
      final c = app(next);
      await c.read(profileControllerProvider).afterOpened();
      expect(manager.currentEntry!.uid, isNull, reason: 'it stays where it is');
      final said = c.read(notificationCenterProvider).history;
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(said.any((n) => n.title == l10n.profileCannotOpenTitle), isTrue);
      await next.close();
    });
  });

  test('the settings a person chose go with their profile', () {
    for (final key in [
      'command_history_enabled',
      'command_history_include_sensitive',
      'monitor_columns_v1',
      'monitor_column_widths_v1',
      'active_first_hosts',
    ]) {
      expect(SettingsService.isProfileKey(key), isTrue, reason: key);
    }
    expect(SettingsService.isProfileKey('workflow_run_panel_fraction'), isFalse, reason: 'a panel\'s size is the window\'s');
  });

}

/// A keychain whose file is held for longer than anyone waits.
class _CannotBeRead implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation i) => Future<String?>.error(const KeychainFileFailed('read', 32));
}

class _CountingApi implements DeviceSessionsApi {
  _CountingApi(this.onRegister, {this.refresh});
  final void Function() onRegister;
  final String Function()? refresh;

  @override
  Future<({String id, String? token})> register(DeviceLabels labels) async {
    onRegister();
    return (id: 'id', token: 'id.token');
  }

  @override
  Future<String?> current() async => null;

  @override
  Future<String> refreshSessionToken(String token) async => refresh!();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// ZestSSH Cloud with a delete that does not get through.
class _RefusingDelete extends LockedCopiesApi {
  _RefusingDelete(this._cloud) : super(baseUrl: 'http://played.invalid');
  final LockedCopiesApi _cloud;
  final tried = <String>[];
  @override
  Future<void> store({required String bearer, required String id, required List<int> secret}) =>
      _cloud.store(bearer: bearer, id: id, secret: secret);
  @override
  Future<bool> delete({required String bearer, required String id, bool onScreen = true}) async {
    tried.add(id);
    throw const LockedCopyRefused(403, 'recent-sign-in-required');
  }
}

/// An account at its limit, until something is deleted.
class _FullOnce extends LockedCopiesApi {
  _FullOnce(this._cloud) : super(baseUrl: 'http://played.invalid');
  final LockedCopiesApi _cloud;
  int refused = 0;
  bool _room = false;
  @override
  Future<void> store({required String bearer, required String id, required List<int> secret}) async {
    if (!_room) {
      refused++;
      throw const LockedCopyRefused(409, 'locked-copies-full');
    }
    await _cloud.store(bearer: bearer, id: id, secret: secret);
  }

  @override
  Future<bool> delete({required String bearer, required String id, bool onScreen = true}) async {
    _room = true;
    return _cloud.delete(bearer: bearer, id: id, onScreen: onScreen);
  }
}

/// A keychain that loses what is written under one name.
class _LosesWritesOf implements FlutterSecureStorage {
  _LosesWritesOf(this._device, this._name);
  final FlutterSecureStorage _device;
  final String _name;

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        return _device.read(key: key!);
      case #write:
        if (key == _name) return Future<void>.value();
        return _device.write(key: key!, value: i.namedArguments[#value] as String?);
      case #delete:
        return _device.delete(key: key!);
      case #readAll:
        return _device.readAll();
    }
    return super.noSuchMethod(i);
  }
}
