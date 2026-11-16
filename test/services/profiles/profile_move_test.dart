import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/older_version_data.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';

import 'profile_world.dart';

/// The move of a device to profiles, at the first start of the version that has
/// them. It moves real people's data: each thing that could lose it has a test
/// here that fails without its fix, and it stops at every step and goes on.
void main() {
  const pin = '4242';
  const uid = 'account-alice';
  const other = 'account-bob';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  /// A device from before, signed in as [uid] with the app lock off: plain
  /// secrets under their old names, a team of the account, one of another
  /// account, and one of nobody yet.
  Future<void> oldDeviceLockOff({String? signedIn = uid}) async {
    await makeOldDatabase(world, wal: 'host-in-wal');
    world.device.kept.addAll({
      KeychainNames.databaseKey: kOldKey,
      if (signedIn != null) 'session_token': 'made.up.token',
      'session_uid': ?signedIn,
      'identity_key_k1': 'PRIVATE KEY OF K1',
      'identity_password_k1': 'a password',
      'sync_dek': 'the sync key',
      'sync_salt': 'c2FsdA==',
      'device_id': 'device-of-alice',
      'account_keys_v1_$uid': jsonEncode({'state': 'confirmed', 'secret': 'keys of alice'}),
      'account_keys_v1_$other': jsonEncode({'state': 'confirmed', 'secret': 'keys of bob'}),
      'orchard_device_key_v1.$uid': 'device key of alice',
      'orchard_device_key_v1.$other': 'device key of bob',
      'orchard_db_key_$kTeamA': 'a' * 64,
      'orchard_db_key_$kTeamB': 'b' * 64,
      'orchard_db_key_$kTeamC': 'c' * 64,
      'orchard_owners_v1': jsonEncode({kTeamA: uid, kTeamB: other}),
      // The device's own, which stay.
      'security_lock_method': 'none',
      'recovery_proof_accounts_v1': 'a note',
    });
    final teams = await Directory(p.join(world.base.path, 'orchards')).create(recursive: true);
    for (final id in [kTeamA, kTeamB, kTeamC]) {
      await File(p.join(teams.path, '$id.db')).writeAsString('team $id');
      await File(p.join(teams.path, '$id.db-wal')).writeAsString('team wal $id');
    }
    await world.rawPrefs.setString('terminal_theme', 'dracula');
    await world.rawPrefs.setStringList('desktop_pinned_connections', ['host-in-main']);
    await world.rawPrefs.setDouble('terminal_font_size', 16.5);
    await world.rawPrefs.setBool('copy_on_select', false);
    await world.rawPrefs.setInt('default_port', 2222);
    await world.rawPrefs.setString('os_kind_host-in-main', 'debian');
    await world.rawPrefs.setString('app_theme_id', 'orchard');
    // The device's own.
    await world.rawPrefs.setDouble('desktop_sidebar_width', 240);
    await world.rawPrefs.setBool('recording_mode_enabled', true);
    await world.rawPrefs.setBool('security_lock_enabled', false);
    final docs = world.folders.documents;
    await Directory(p.join(docs.path, 'ZestSSH', 'transcripts')).create(recursive: true);
    await File(p.join(docs.path, 'ZestSSH', 'transcripts', 'one.bin')).writeAsString('transcript');
    await Directory(p.join(docs.path, 'ZestSSH', 'session-logs')).create(recursive: true);
    await File(p.join(docs.path, 'ZestSSH', 'session-logs', 'one.log')).writeAsString('log');
    await Directory(p.join(world.folders.support.path, 'ZestSSH', 'backups')).create(recursive: true);
    await File(p.join(world.folders.support.path, 'ZestSSH', 'backups', 'zestssh_auto_1.zest')).writeAsString('backup');
    await Directory(p.join(docs.path, 'ZestSSH', 'backups')).create(recursive: true);
    await File(p.join(docs.path, 'ZestSSH', 'backups', 'zestssh_auto_2.zest')).writeAsString('the destination\'s copy');
    await File(p.join(docs.path, 'ZestSSH', 'backups', 'zestssh_backup_3.zest')).writeAsString('exported by the person');
    await File(p.join(world.base.path, 'zestssh_backup_1.db')).writeAsString('a schema backup');
    await Directory(p.join(world.base.path, 'migration_backups')).create(recursive: true);
    await File(p.join(world.base.path, 'migration_backups', 'pre_v1_to_v2_1.db')).writeAsString('an upgrade copy');
  }

  /// The same with the app lock on: the secrets sealed with today's seal, whose
  /// key is in the database, and the database's key wrapped behind the PIN.
  Future<void> oldDeviceLockOn() async {
    final sealKey = base64.encode(List<int>.generate(32, (i) => i));
    await makeOldDatabase(world, wal: 'host-in-wal', state: {
      'secret_seal_key_v1': sealKey,
      'secret_seal_active_v1': '1',
    });
    final box = AesGcm.with256bits();
    Future<String> sealed(String name, String value) async {
      final b = await box.encrypt(utf8.encode(value), secretKey: SecretKey(base64.decode(sealKey)), aad: utf8.encode(name));
      return '${SecretSeal.prefix}${base64.encode(b.concatenation())}';
    }

    await makeOldVault(world, kOldKey, pin);
    world.device.kept.addAll({
      'session_token': await sealed('session_token', 'made.up.token'),
      'session_uid': uid,
      'identity_key_k1': await sealed('identity_key_k1', 'PRIVATE KEY OF K1'),
      'sync_dek': await sealed('sync_dek', 'the sync key'),
      'orchard_db_key_$kTeamB': await sealed('orchard_db_key_$kTeamB', 'b' * 64),
      'account_keys_v1_$other': await sealed('account_keys_v1_$other', 'keys of bob'),
      'orchard_owners_v1': jsonEncode({kTeamB: other}),
      'security_lock_method': 'pin',
    });
    await Directory(p.join(world.base.path, 'orchards')).create(recursive: true);
    await File(p.join(world.base.path, 'orchards', '$kTeamB.db')).writeAsString('team B');
    await world.rawPrefs.setBool('security_lock_enabled', true);
    await world.rawPrefs.setBool('encrypting_lock_enabled', true);
    await world.rawPrefs.setString('terminal_theme', 'dracula');
  }

  /// A launch that opens the profile, with the PIN where the lock is on.
  Future<(ProfileManager, AppDatabase)> launchAndOpen({bool lockOn = false}) async {
    final manager = world.launch();
    final start = await manager.start();
    expect(start.lockOn, lockOn);
    if (lockOn) {
      final vault = VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current));
      manager.vaultKey = await vault.unlockVaultKey(pin: pin);
    }
    return (manager, await manager.openCurrent());
  }

  void expectLockOffMoved(ProfileManager manager, ProfileEntry entry) {
    expect(entry.uid, uid);
    // The originals are gone, and the device's own are where they were.
    for (final name in ['identity_key_k1', 'identity_password_k1', 'sync_dek', 'session_token', 'session_uid', 'device_id',
        KeychainNames.databaseKey, 'account_keys_v1_$uid', 'orchard_device_key_v1.$uid']) {
      expect(world.device.kept.containsKey(name), isFalse, reason: name);
    }
    expect(world.device.kept['security_lock_method'], 'none');
    expect(world.device.kept['recovery_proof_accounts_v1'], 'a note');
    expect(world.device.kept.containsKey('orchard_owners_v1'), isTrue);
    // No file of the old layout is left, and nothing says who uses the device.
    expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isFalse);
    expect(File(p.join(world.base.path, 'zestssh.db-wal')).existsSync(), isFalse);
    expect(manager.moveUnderWay(), completion(isFalse));
    for (final name in world.device.kept.keys) {
      expect(name.contains(uid), isFalse, reason: 'a name says who uses the device: $name');
    }
  }

  test('the write-ahead file: what is in it alone moves with the set, and the first copy includes it', () async {
    await oldDeviceLockOff();
    // What this is about: the newest change is in the write-ahead file alone.
    final mainAlone = await Directory(p.join(world.root.path, 'main_alone')).create();
    final copied = await File(p.join(world.base.path, 'zestssh.db')).copy(p.join(mainAlone.path, 'zestssh.db'));
    expect(hostsInFile(copied.path), ['host-in-main'], reason: 'renaming the main file alone loses the change');

    final (manager, db) = await launchAndOpen();
    expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
    await db.close();

    final dir = ProfilePaths.ofProfile(world.base, manager.list.current!);
    final copy = Directory(p.join(dir.path, 'pre_move'));
    expect(File(p.join(copy.path, 'zestssh.db-wal')).existsSync(), isTrue, reason: 'the copy includes the changes');
    expect(hostsInFile(p.join(copy.path, 'zestssh.db')), ['host-in-main', 'host-in-wal']);
  });

  test('a sealed secret is bound to its name: it is opened under the old and sealed again under the new', () async {
    await oldDeviceLockOn();
    // What this is about: a copy of the sealed value under the new name reads
    // as missing.
    final stored = world.device.kept['identity_key_k1']!;
    final sealKey = base64.encode(List<int>.generate(32, (i) => i));
    final check = await openPlayed(await Directory(p.join(world.root.path, 'seal_check')).create(), 'x');
    await LocalStateStore(check).write('secret_seal_key_v1', sealKey);
    final seal = await SecretSeal.of(check);
    expect(await seal.open('identity_key_k1', stored), 'PRIVATE KEY OF K1');
    await expectLater(seal.open('p.some.identity_key_k1', stored), throwsA(isA<SecretSealBroken>()));
    await check.close();

    final (manager, db) = await launchAndOpen(lockOn: true);
    final entry = manager.currentEntry!;
    final name = KeychainNames.full(entry.id, uid, 'identity_key_k1');
    expect(world.device.kept[name], isNot(stored), reason: 'sealed again, under the new name');
    expect(SecretSeal.isSealed(world.device.kept[name]), isTrue);
    expect(await (await SecretSeal.of(db)).open(name, world.device.kept[name]!), 'PRIVATE KEY OF K1');
    final keychain = world.keychainOf(Profiles.current!, db);
    expect(await keychain.read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
    expect(await keychain.read(key: 'sync_dek'), 'the sync key');
    expect(await AccountSecret.sessionToken.read(keychain, tree: () => db), 'made.up.token');
    // Only now are the originals gone.
    expect(world.device.kept.containsKey('identity_key_k1'), isFalse);
    expect(world.device.kept.containsKey(KeychainNames.wrappedDatabaseKey), isFalse);
    expect(world.device.kept.containsKey('vault_slots'), isFalse);
    await db.close();
  });

  test('the originals stay until the profile has opened from the new names', () async {
    await oldDeviceLockOff();
    world.stop = (boundary) {
      if (boundary == 'teamsMoved') throw const PlayedStop('before the originals');
    };
    final manager = world.launch();
    await manager.start();
    await untilStopped(() async {
      await manager.openCurrent();
    });
    for (final name in ['identity_key_k1', 'session_token', KeychainNames.databaseKey]) {
      expect(world.device.kept.containsKey(name), isTrue, reason: '$name stays until the profile opened');
    }
  });

  test('with the app lock off a personal secret is sealed by the profile\'s own seal, and opens only with its database',
      () async {
    await oldDeviceLockOff();
    final (manager, db) = await launchAndOpen();
    final entry = manager.currentEntry!;
    for (final name in ['identity_key_k1', 'identity_password_k1', 'sync_dek', 'sync_salt', 'device_id', 'session_token', 'session_uid']) {
      final raw = world.device.kept[KeychainNames.full(entry.id, uid, name)];
      expect(SecretSeal.isSealed(raw), isTrue, reason: '$name is plain with the lock off');
      expect(raw!.contains('PRIVATE'), isFalse);
    }
    final keychain = world.keychainOf(Profiles.current!, db);
    expect(await keychain.read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
    expect(await keychain.read(key: 'device_id'), 'device-of-alice');
    // With the database closed it is what it is: sealed.
    final closed = world.keychainOf(Profiles.current!, null);
    expect(SecretSeal.isSealed(await closed.read(key: 'identity_key_k1')), isTrue);
    // A store that says its id gets its own, and no name holds the id.
    expect(await keychain.read(key: 'account_keys_v1_$uid'), contains('keys of alice'));
    expect(world.device.kept.keys.any((k) => k.contains('account_keys_v1_me')), isTrue);
    await db.close();
  });

  test('settings: a person\'s go into the profile\'s database and leave the store; the device\'s stay', () async {
    await oldDeviceLockOff();
    final (manager, db) = await launchAndOpen();
    expect(manager.prefs.getString('terminal_theme'), 'dracula');
    expect(manager.prefs.getStringList('desktop_pinned_connections'), ['host-in-main']);
    expect(manager.prefs.getDouble('terminal_font_size'), 16.5);
    expect(manager.prefs.getBool('copy_on_select'), isFalse);
    expect(manager.prefs.getInt('default_port'), 2222);
    expect(manager.prefs.getString('os_kind_host-in-main'), 'debian');
    expect(manager.prefs.getDouble('desktop_sidebar_width'), 240);
    expect(manager.prefs.getBool('recording_mode_enabled'), isTrue);
    for (final key in ['terminal_theme', 'desktop_pinned_connections', 'terminal_font_size', 'copy_on_select',
        'default_port', 'os_kind_host-in-main']) {
      expect(world.rawPrefs.containsKey(key), isFalse, reason: '$key is left in the store');
    }
    expect(world.rawPrefs.getDouble('desktop_sidebar_width'), 240);
    // What the lock screen looks like stays on the device as well.
    expect(world.rawPrefs.getString('app_theme_id'), 'orchard');
    expect(manager.prefs.getString('app_theme_id'), 'orchard');
    await db.close();
  });

  test('files: the set, the schema backups, the upgrade copies, a person\'s files', () async {
    await oldDeviceLockOff();
    final (manager, db) = await launchAndOpen();
    final id = manager.list.current!;
    final dir = ProfilePaths.ofProfile(world.base, id);
    expect(File(p.join(dir.path, 'zestssh_backup_1.db')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'migration_backups', 'pre_v1_to_v2_1.db')).existsSync(), isTrue);
    final docs = world.folders.documents;
    expect(File(p.join(docs.path, 'ZestSSH', 'transcripts', id, 'one.bin')).existsSync(), isTrue);
    expect(File(p.join(docs.path, 'ZestSSH', 'session-logs', id, 'one.log')).existsSync(), isTrue);
    expect(File(p.join(world.folders.support.path, 'ZestSSH', 'backups', id, 'zestssh_auto_1.zest')).existsSync(), isTrue);
    expect(File(p.join(docs.path, 'ZestSSH', 'backups', id, 'zestssh_auto_2.zest')).existsSync(), isTrue);
    expect(File(p.join(docs.path, 'ZestSSH', 'backups', 'zestssh_backup_3.zest')).existsSync(), isTrue,
        reason: 'a backup the person exported stays where they put it');
    await db.close();
  });

  test('teams: the account\'s go into its profile, another account\'s wait with their owner, and no owner waits for the server',
      () async {
    await oldDeviceLockOff();
    final (manager, db) = await launchAndOpen();
    final entry = manager.currentEntry!;
    final dir = ProfilePaths.ofProfile(world.base, entry.id);
    final held = ProfilePaths.heldTeams(world.base);
    // The account's own, with its key under the profile's name.
    expect(File(p.join(dir.path, 'orchards', '$kTeamA.db')).readAsStringSync(), 'team $kTeamA');
    expect(File(p.join(dir.path, 'orchards', '$kTeamA.db-wal')).existsSync(), isTrue);
    final keychain = world.keychainOf(Profiles.current!, db);
    expect(await keychain.read(key: 'orchard_db_key_$kTeamA'), 'a' * 64);
    expect((await HeldEntries(world.device).names()).contains('orchard_db_key_$kTeamA'), isFalse);
    // Another account's stays, with its owner, out of an older version's sight.
    expect(File(p.join(held.path, '$kTeamB.db')).existsSync(), isTrue);
    expect(File(p.join(world.base.path, 'orchards', '$kTeamB.db')).existsSync(), isFalse);
    expect(await HeldEntries(world.device).read('orchard_db_key_$kTeamB'), 'b' * 64);
    expect(await HeldEntries(world.device).read('account_keys_v1_$other'), contains('keys of bob'));
    // No owner: it waits. The server's list does not name it: it still waits.
    expect(File(p.join(held.path, '$kTeamC.db')).existsSync(), isTrue);
    await manager.teamsOnServer({'something-else'}, uid: entry.uid!, db: db);
    expect(File(p.join(held.path, '$kTeamC.db')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'orchards', '$kTeamC.db')).existsSync(), isFalse);
    // A list asked as the account here before, come late: it says nothing of this one.
    await manager.teamsOnServer({kTeamC}, uid: 'the-account-before', db: db);
    expect(File(p.join(held.path, '$kTeamC.db')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'orchards', '$kTeamC.db')).existsSync(), isFalse);
    // The server's list names it: only now is it this account's.
    await manager.teamsOnServer({kTeamC}, uid: entry.uid!, db: db);
    expect(File(p.join(held.path, '$kTeamC.db')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'orchards', '$kTeamC.db')).readAsStringSync(), 'team $kTeamC');
    expect(await keychain.read(key: 'orchard_db_key_$kTeamC'), 'c' * 64);
    await db.close();
  });

  test('a team with no owner is never taken in without the server\'s word, but can be used where it lies while it is down',
      () async {
    await oldDeviceLockOff();
    final (manager, db) = await launchAndOpen();
    var asked = 0;
    final added = await manager.useHeldTeamsInPlace((team, key, who) async {
      asked++;
      expect(key, 'c' * 64);
      return team == kTeamC && who == uid;
    });
    expect(asked, 1, reason: 'another account\'s is not even looked at');
    expect(added, 1);
    expect(Profiles.provisionalTeams, {kTeamC});
    expect(File(p.join(ProfilePaths.heldTeams(world.base).path, '$kTeamC.db')).existsSync(), isTrue);
    expect((await AppDatabase.orchardDatabaseFile(kTeamC)).path, contains('held'));
    await db.close();
  });

  test('another account\'s team and secrets go into its profile when it signs in here', () async {
    await oldDeviceLockOff();
    final (manager, db) = await launchAndOpen();
    final seal = await SecretSeal.forProfile(db);
    expect(seal, isNotNull);
    // The other account signs in here.
    final prepared = await manager.prepare(await manager.planForAccount(uid: other, label: 'bob@example.com', bearer: 'b'));
    await db.close();
    await manager.commit(prepared);
    final bob = Profiles.current!;
    expect(bob.uid, other);
    expect(File(p.join(bob.dir.path, 'orchards', '$kTeamB.db')).readAsStringSync(), 'team $kTeamB');
    final keychain = world.keychainOf(bob, prepared.db);
    expect(await keychain.read(key: 'orchard_db_key_$kTeamB'), 'b' * 64);
    expect(await keychain.read(key: 'account_keys_v1_$other'), contains('keys of bob'));
    expect((await HeldEntries(world.device).names()).where((n) => n.contains(other)), isEmpty);
    await prepared.db.close();
  });

  test('the lock on: nothing is touched of the vault\'s blobs and nothing asks a PIN before the database', () async {
    await oldDeviceLockOn();
    final slotsBefore = world.device.kept['vault_slots'];
    final wrappedBefore = world.device.kept[KeychainNames.wrappedDatabaseKey];
    final manager = world.launch();
    final start = await manager.start();
    expect(start.lockOn, isTrue);
    final id = manager.list.current!;
    // By name, unchanged, and both names are kept until the PIN.
    expect(world.device.kept[ProfileVault.slotsName], slotsBefore);
    expect(world.device.kept[ProfileVault.wrappedName(id)], wrappedBefore);
    expect(world.device.kept['vault_slots'], slotsBefore);
    expect(world.device.kept[KeychainNames.wrappedDatabaseKey], wrappedBefore);
    expect(world.device.kept['identity_key_k1'], isNotNull);
    // Files are moved already, and the app sits at its lock.
    expect(File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'zestssh.db')).existsSync(), isTrue);
    await expectLater(manager.openCurrent(), throwsA(isA<VaultLockedException>()));
    final vault = VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current));
    manager.vaultKey = await vault.unlockVaultKey(pin: pin);
    final db = await manager.openCurrent();
    expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
    expect(world.device.kept.containsKey('vault_slots'), isFalse);
    await db.close();
  });

  group('stopped at every step', () {
    Future<void> checkLockOff() async {
      world.stop = null;
      final (manager, db) = await launchAndOpen();
      expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
      expectLockOffMoved(manager, manager.currentEntry!);
      final keychain = world.keychainOf(Profiles.current!, db);
      expect(await keychain.read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
      expect(await keychain.read(key: 'orchard_db_key_$kTeamA'), 'a' * 64);
      expect(manager.prefs.getString('terminal_theme'), 'dracula');
      expect(manager.prefs.getStringList('desktop_pinned_connections'), ['host-in-main']);
      expect(world.rawPrefs.containsKey('terminal_theme'), isFalse);
      await db.close();
    }

    Future<void> checkLockOn() async {
      world.stop = null;
      final (manager, db) = await launchAndOpen(lockOn: true);
      expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
      final keychain = world.keychainOf(Profiles.current!, db);
      expect(await keychain.read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
      expect(await keychain.read(key: 'sync_dek'), 'the sync key');
      expect(world.device.kept.containsKey('vault_slots'), isFalse);
      expect(world.device.kept.containsKey('identity_key_k1'), isFalse);
      expect(await HeldEntries(world.device).read('orchard_db_key_$kTeamB', vaultKey: manager.vaultKey), 'b' * 64);
      await db.close();
    }

    /// Every boundary a whole run of [make] passes.
    Future<List<String>> boundariesOf(Future<void> Function() make, {required bool lockOn}) async {
      final seen = <String>[];
      final dry = await ProfileWorld.create();
      final kept = world;
      world = dry;
      await make();
      dry.stop = seen.add;
      final (_, db) = await launchAndOpen(lockOn: lockOn);
      await db.close();
      await dry.dispose();
      world = kept;
      return seen;
    }

    Future<void> everyStop(Future<void> Function() make, Future<void> Function() check, {required bool lockOn}) async {
      final boundaries = await boundariesOf(make, lockOn: lockOn);
      expect(boundaries.length, greaterThan(10), reason: 'the steps are there to stop at');
      for (final boundary in boundaries) {
        await world.dispose();
        world = await ProfileWorld.create();
        await make();
        world.stop = (at) {
          if (at == boundary) throw const PlayedStop('here');
        };
        final manager = world.launch();
        final stopped = await untilStopped(() async {
          await manager.start();
          if (lockOn) {
            manager.vaultKey = await VaultSlotService(ProfileKeychain(world.device, profile: () => Profiles.current))
                .unlockVaultKey(pin: pin);
          }
          final db = await manager.openCurrent();
          await db.close();
        });
        expect(stopped, isTrue, reason: 'it stopped at $boundary');
        Profiles.debugReset();
        await check();
      }
    }

    test('with the app lock off', () async {
      await everyStop(oldDeviceLockOff, checkLockOff, lockOn: false);
    });

    test('with the app lock on', () async {
      await everyStop(oldDeviceLockOn, checkLockOn, lockOn: true);
    });

    test('and twice in a row at the same place', () async {
      await oldDeviceLockOff();
      for (var i = 0; i < 2; i++) {
        world.stop = (at) {
          if (at == 'entry:identity_key_k1') throw const PlayedStop('here');
        };
        final manager = world.launch();
        await untilStopped(() async {
          await manager.start();
          await manager.openCurrent();
        });
        Profiles.debugReset();
      }
      await checkLockOff();
    });
  });

  group('an older version run after the move', () {
    test('its new, empty zestssh.db is never taken over a profile', () async {
      await oldDeviceLockOff();
      final (manager, db) = await launchAndOpen();
      final id = manager.list.current!;
      await db.close();
      Profiles.debugReset();

      // The older version: no database where it looks, so it makes a new one,
      // with a new key under its old name.
      final older = await openPlayed(world.base, 'bb00');
      await addHost(older, 'made-in-the-older-version');
      await older.close();
      world.device.kept[KeychainNames.databaseKey] = 'bb00';

      final again = world.launch();
      final start = await again.start();
      expect(start.olderVersionData, isTrue);
      expect(again.list.current, id, reason: 'the profile is what opens');
      final reopened = await again.openCurrent();
      expect(await hostsOf(reopened), ['host-in-main', 'host-in-wal']);
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isTrue, reason: 'nor is it touched');

      final data = OlderVersionData(base: world.base, device: world.device, rawPrefs: world.rawPrefs, openDatabase: openPlayed);
      final summary = await data.look();
      expect(summary.hosts, 1);
      expect(summary.opened, isTrue);
      // Deleted on the person's word, and nothing of a profile goes.
      await data.delete();
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isFalse);
      expect(world.device.kept.containsKey(KeychainNames.databaseKey), isFalse);
      expect(world.rawNames(id), isNotEmpty);
      expect(await hostsOf(reopened), ['host-in-main', 'host-in-wal']);
      await reopened.close();
    });

    test('brought into the profile on screen: its hosts and keys come, sealed for the profile, what is there stays, and it goes',
        () async {
      await oldDeviceLockOff();
      final (manager, db) = await launchAndOpen();
      final id = manager.list.current!;
      await db.close();
      Profiles.debugReset();

      final older = await openPlayed(world.base, 'bb00');
      await addHost(older, 'made-in-the-older-version');
      await older.into(older.identities).insert(IdentitiesCompanion.insert(
            id: 'older-key',
            label: 'a key',
            username: 'demo',
            authMethod: 'publicKey',
            createdAt: DateTime.utc(2026, 10, 30),
          ));
      await older.close();
      world.device.kept[KeychainNames.databaseKey] = 'bb00';
      world.device.kept['identity_key_older-key'] = 'PRIVATE KEY OF THE OLDER VERSION';

      final again = world.launch();
      await again.start();
      final open = await again.openCurrent();
      SecretSeal.openTree = open;
      await again.prefs.setString('terminal_theme', 'the person\'s');
      // The older version keeps its settings in the system's store.
      await world.rawPrefs.setString('terminal_theme', 'the older version\'s');
      final storage = world.keychainOf(Profiles.current!, open);
      final data = OlderVersionData(base: world.base, device: world.device, rawPrefs: world.rawPrefs, openDatabase: openPlayed);
      await data.bringInto(SyncDataService(
        database: open,
        connectionsDao: open.connectionsDao,
        identitiesDao: open.identitiesDao,
        groupsDao: open.connectionGroupsDao,
        knownHostsDao: open.knownHostsDao,
        snippetsDao: open.snippetsDao,
        snippetCategoriesDao: open.snippetCategoriesDao,
        portForwardRulesDao: open.portForwardRulesDao,
        networksDao: open.networksDao,
        connectionTagsDao: open.connectionTagsDao,
        secureStorage: storage,
        settingsService: SettingsService(again.prefs),
      ));

      expect(await hostsOf(open), ['host-in-main', 'host-in-wal', 'made-in-the-older-version']);
      expect(await storage.read(key: 'identity_key_older-key'), 'PRIVATE KEY OF THE OLDER VERSION');
      expect(SecretSeal.isSealed(world.device.kept['${KeychainPrefix.of(id)}identity_key_older-key']), isTrue);
      expect(again.prefs.getString('terminal_theme'), 'the person\'s', reason: 'none of its settings come along');
      // It went, with its key and its secrets under the old names.
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isFalse);
      expect(world.device.kept.containsKey(KeychainNames.databaseKey), isFalse);
      expect(world.device.kept.containsKey('identity_key_older-key'), isFalse);
      await open.close();
    });

    test('and one run in the middle of a move: what it made stays, and the set comes from the copy', () async {
      await oldDeviceLockOff();
      world.stop = (at) {
        if (at == 'moved:zestssh.db-wal') throw const PlayedStop('between the files');
      };
      final manager = world.launch();
      await untilStopped(() async {
        await manager.start();
      });
      Profiles.debugReset();
      final id = jsonDecode(await File(p.join(ProfilePaths.root(world.base).path, 'move_v1.json')).readAsString())['profile'] as String;
      // The older version wrote into the main file, which was still there.
      final older = await openPlayed(world.base, kOldKey);
      await addHost(older, 'made-in-the-older-version');
      await older.close();

      world.stop = null;
      final (again, db) = await launchAndOpen();
      expect(again.list.current, id);
      expect(await hostsOf(db), ['host-in-main', 'host-in-wal'], reason: 'the set as the copy was taken');
      await db.close();
      // And what the older version made is still there, for the person to say.
      expect(hostsInFile(p.join(world.base.path, 'zestssh.db')), contains('made-in-the-older-version'));
    });

    test('the lock\'s switches an older version finds are off, so it does not sit at a PIN it cannot check', () async {
      await oldDeviceLockOn();
      final (manager, db) = await launchAndOpen(lockOn: true);
      await db.close();
      expect(world.rawPrefs.getBool('security_lock_enabled'), isFalse);
      expect(world.rawPrefs.getBool('encrypting_lock_enabled'), isFalse);
      // The app's own, under new names, say on.
      expect(manager.prefs.getBool('security_lock_enabled'), isTrue);
      expect(manager.prefs.getBool('encrypting_lock_enabled'), isTrue);
    });
  });

  test('a device signed out: its data is guest data, and takes in no account\'s team keys', () async {
    await oldDeviceLockOff(signedIn: null);
    final (manager, db) = await launchAndOpen();
    final entry = manager.currentEntry!;
    expect(entry.uid, isNull);
    expect(manager.list.guest?.id, entry.id);
    expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
    expect(world.device.kept.keys.where((k) => k.startsWith(entry.id)), isEmpty);
    expect(world.device.kept.keys.where((k) => k.contains('account_keys_v1_') && k.startsWith('p.')), isEmpty);
    expect(await HeldEntries(world.device).read('account_keys_v1_$uid'), contains('keys of alice'));
    await db.close();
  });

  test('a device with nothing on it: guest data, and nothing is moved', () async {
    final (manager, db) = await launchAndOpen();
    expect(manager.currentEntry!.uid, isNull);
    expect(await manager.moveUnderWay(), isFalse);
    await db.close();
  });

  test('a phone: nothing moves, and every path and name is as it was', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      expect(profilesOnThisPlatform, isFalse);
      await oldDeviceLockOff();
      // main.dart turns profiles on for a computer alone, and nothing else does.
      expect(Profiles.on, isFalse);
      expect(appKeychain, same(deviceKeychain));
      expect((await ProfilePaths.databaseDirectory()).path, world.base.path);
      expect(await AppDatabase.databasePath, p.join(world.base.path, 'zestssh.db'));
      expect((await AppDatabase.orchardDatabaseFile(kTeamA)).path, p.join(world.base.path, 'orchards', '$kTeamA.db'));
      final dir = Directory(p.join(world.root.path, 'logs'));
      expect(ProfilePaths.forCurrent(dir).path, dir.path);
      // A sealed secret is as it was: sealed by its store, while the lock is on.
      final db = await openPlayed(await Directory(p.join(world.root.path, 'phone')).create(), 'x');
      await SecretSeal.setActive(db, true);
      final seal = await SecretSeal.of(db);
      expect(seal.active, isTrue);
      expect(SecretSeal.isSealed(await seal.keep('identity_key_k1', 'value')), isTrue);
      await db.close();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    for (final computer in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
      debugDefaultTargetPlatformOverride = computer;
      expect(profilesOnThisPlatform, isTrue, reason: 'a computer has them');
      debugDefaultTargetPlatformOverride = null;
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(profilesOnThisPlatform, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  test('the marker is whole or the last one', () async {
    await oldDeviceLockOff();
    final move = ProfileMove(
      base: world.base,
      device: world.device,
      rawPrefs: world.rawPrefs,
      folders: () => world.folders,
    );
    final marker = await move.beforeOpen();
    expect(marker!.stage, MoveStage.keysNamed);
    expect(File('${move.markerFile.path}.tmp').existsSync(), isFalse);
    expect(await move.readMarker(), isNotNull);
    final list = await ProfileList.read(world.device);
    expect(list!.byId(marker.profile)!.uid, uid);
  });
}
