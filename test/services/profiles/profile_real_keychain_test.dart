import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/profiles/windows_keychain.dart';
import 'package:zestssh/services/secret_seal.dart';

import 'profile_world.dart';
import 'windows_keychain_test.dart' show NoLegacy;

const _uid = 'account-alice';

/// The move and a sign-in, the app's own code, on the keychain's real file: with
/// real gaps between its calls, as the kept map of the other tests has none, and a
/// stop inside a write, which that map cannot have. No test on that map could see
/// what this file did to real people's first start.
void main() {
  final notWindows = Platform.isWindows ? false : 'the real DPAPI';

  late ProfileWorld world;
  late SafeKeychainFile file;
  late FlutterSecureStorage device;
  late FlutterSecureStoragePlatform before;

  Future<void> freshComputer() async {
    world = await ProfileWorld.create();
    file = SafeKeychainFile(path: () async => p.join(world.root.path, 'flutter_secure_storage.dat'));
    FlutterSecureStoragePlatform.instance = SafeWindowsKeychain(file, legacy: NoLegacy());
    device = deviceKeychain;
    world.realDevice = device;
  }

  setUp(() async {
    before = FlutterSecureStoragePlatform.instance;
    await freshComputer();
  });

  tearDown(() async {
    await world.dispose();
    FlutterSecureStoragePlatform.instance = before;
  });

  /// A signed-in device from before, with the app lock off.
  Future<void> oldDevice({int keys = 12}) async {
    await makeOldDatabase(world, wal: 'host-in-wal');
    await device.write(key: KeychainNames.databaseKey, value: kOldKey);
    await device.write(key: 'session_token', value: 'made.up.token');
    await device.write(key: 'session_uid', value: _uid);
    await device.write(key: 'session_email', value: 'alice@example.com');
    await device.write(key: 'device_id', value: 'windows_abcdef12');
    for (var i = 0; i < keys; i++) {
      await device.write(key: 'identity_key_k$i', value: 'PRIVATE KEY $i');
    }
    await device.write(key: 'security_lock_method', value: 'none');
  }

  Future<void> expectMoved(ProfileManager manager, AppDatabase db, {int keys = 12}) async {
    expect(await manager.moveUnderWay(), isFalse);
    expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
    final entry = manager.currentEntry!;
    expect(entry.uid, _uid);
    final keychain = ProfileKeychain(device, profile: () => Profiles.current, tree: () => db);
    for (var i = 0; i < keys; i++) {
      expect(await keychain.read(key: 'identity_key_k$i'), 'PRIVATE KEY $i');
      expect(await device.read(key: 'identity_key_k$i'), isNull, reason: 'the original went');
    }
    expect(await keychain.read(key: 'session_token'), 'made.up.token');
    expect(await device.read(key: ProfileVault.plainName(entry.id)), kOldKey);
    expect(await device.read(key: 'security_lock_method'), 'none');
  }

  test('the move, stopped at every place inside every write of the keychain: it goes on, and nothing is lost', () async {
    // A dry run says where there is to stop.
    final places = <String>[];
    await oldDevice();
    file.stop = places.add;
    final dry = world.launch();
    await dry.start();
    final db = await dry.openCurrent();
    await db.close();
    file.stop = null;
    await world.dispose();
    FlutterSecureStoragePlatform.instance = before;
    expect(places.length, greaterThan(10));

    for (var stopAt = 0; stopAt < places.length; stopAt++) {
      await freshComputer();
      await oldDevice();
      var seen = 0;
      file.stop = (_) {
        if (seen++ == stopAt) throw const PlayedStop('inside a write');
      };
      final first = world.launch();
      final stopped = await untilStopped(() async {
        await first.start();
        final opened = await first.openCurrent();
        await opened.close();
      });
      expect(stopped, isTrue, reason: 'place $stopAt of ${places.length}');
      file.stop = null;
      Profiles.debugReset();
      // The app was ended there. Its database closes as the process does; in this
      // test the file is what matters, so one that was left open is let go of.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final next = world.launch();
      await next.start();
      final opened = await next.openCurrent();
      await expectMoved(next, opened);
      await opened.close();
      Profiles.debugReset();
      await world.dispose();
      FlutterSecureStoragePlatform.instance = before;
    }
    await freshComputer();
  }, skip: notWindows, timeout: const Timeout(Duration(minutes: 8)));

  test('the keychain\'s file is copied before anything in it changes, and the copy goes when the data is to be locked', () async {
    await oldDevice();
    final manager = world.launch();
    await manager.start();
    final id = manager.list.current!;
    final copy = File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'pre_move', ProfileMove.keychainCopyName));
    expect(copy.existsSync(), isTrue);
    final holds = SafeKeychainFile(path: () async => copy.path);
    final old = await holds.load(const {});
    expect(old[KeychainNames.databaseKey], kOldKey, reason: 'as it was before its names changed');
    expect(old['identity_key_k1'], 'PRIVATE KEY 1');
    final db = await manager.openCurrent();
    expect(copy.existsSync(), isTrue, reason: 'it stays for a while, as the copy of the database does');
    SecretSeal.openTree = db;
    expect(await manager.settleLockedCopy(db: db, bearer: 'token'), isTrue);
    expect(await manager.lockCurrent(), SignOutEnd.locked);
    expect(copy.existsSync(), isFalse, reason: 'it holds the key that is now out of reach');
    await db.close();
  }, skip: notWindows);

  test('a move of many secrets rewrites the file a few times, not once for each', () async {
    await oldDevice(keys: 200);
    final before = file.replaced;
    final clock = Stopwatch()..start();
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    final written = file.replaced - before;
    expect(written, lessThan(30), reason: 'it was about three for each secret');
    // ignore: avoid_print
    print('200 secrets moved in ${clock.elapsedMilliseconds} ms, the file written $written times');
    await expectMoved(manager, db, keys: 200);
    await db.close();
  }, skip: notWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('a sign-in, its session written beside what else touches the keychain: nothing is lost', () async {
    for (var round = 0; round < ProfileList.maxAccounts; round++) {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final storage = ProfileKeychain(device);
      for (var i = 0; i < 10; i++) {
        await storage.write(key: 'identity_key_$i', value: 'k' * 2000);
      }
      final uid = 'account-$round';
      final prepared = await manager.prepare(await manager.planForAccount(uid: uid, label: 'a@example.com', bearer: 't'));
      SecretSeal.openTree = null;
      await guest.close();
      await manager.commit(prepared);
      SecretSeal.openTree = prepared.db;
      await Future.wait([
        manager.settleLockedCopy(db: prepared.db, bearer: 't'),
        () async {
          await AccountSecret.sessionToken.write(storage, 'made.up.token');
          await storage.write(key: 'session_email', value: 'a@example.com');
          await storage.write(key: 'session_uid', value: uid);
        }(),
        manager.settleLockedCopy(db: prepared.db, bearer: 't'),
      ]);
      final entry = manager.currentEntry!;
      final left = Map<String, String>.of(await device.readAll());
      for (final name in ['session_token', 'session_email', 'session_uid', KeychainNames.lockedCopy]) {
        expect(left.containsKey(KeychainNames.full(entry.id, uid, name)), isTrue, reason: '$name, round $round');
      }
      expect(left.containsKey(ProfileVault.plainName(entry.id)), isTrue, reason: 'its database\'s key, round $round');
      await prepared.db.close();
      SecretSeal.openTree = null;
      Profiles.debugReset();
    }
  }, skip: notWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('the list: a stop inside its write leaves it whole, the one before or the new one', () async {
    final list = ProfileList(entries: [ProfileEntry(id: newProfileId(), made: 1)], current: null);
    await list.write(device);
    final was = jsonEncode((await ProfileList.read(device))!.entries.map((e) => e.toJson()).toList());
    list.put(ProfileEntry(id: newProfileId(), made: 2));
    for (final place in ['half-written', 'temp-written']) {
      file.stop = (at) {
        if (at == place) throw const PlayedStop('inside a write');
      };
      await untilStopped(() => list.write(device));
      file.stop = null;
      final read = await ProfileList.read(device);
      expect(jsonEncode(read!.entries.map((e) => e.toJson()).toList()), was, reason: place);
    }
    await list.write(device);
    expect((await ProfileList.read(device))!.entries, hasLength(2));
  }, skip: notWindows);
}
