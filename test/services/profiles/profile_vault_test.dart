import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/vault_slot_service.dart';

import 'profile_world.dart';

/// The app lock with several profiles: the PIN opens a random vault key, which
/// wraps each profile's key on its own, and turning it on or off with several
/// profiles can stop anywhere without stranding one.
void main() {
  const pin = '4242';
  final ka = 'a1' * 32, kb = 'b2' * 32, kc = 'c3' * 32, kd = 'd4' * 32;
  final keys = {'aaaa': ka, 'bbbb': kb, 'cccc': kc};

  late ProfileWorld world;
  late MemoryKeychain device;
  late ProfileVault vault;
  late VaultSlotService slots;

  setUp(() async {
    world = await ProfileWorld.create();
    device = world.device;
    vault = ProfileVault(device);
    Profiles.turnOn();
    slots = VaultSlotService(ProfileKeychain(device, profile: () => null));
    for (final e in keys.entries) {
      device.kept[ProfileVault.plainName(e.key)] = e.value;
    }
  });
  tearDown(() => world.dispose());

  Future<void> expectAllOpen({SecretKey? vaultKey}) async {
    for (final e in keys.entries) {
      final plain = device.kept[ProfileVault.plainName(e.key)];
      if (plain != null) {
        expect(plain, e.value);
      } else {
        expect(await vault.unwrap(e.key, vaultKey!), e.value, reason: e.key);
      }
    }
  }

  test('the PIN opens a vault key that wraps each profile on its own: one signing out strands no other', () async {
    final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
    // The vault key opens each, and is none of their keys.
    final opened = await slots.unlockVaultKey(pin: pin);
    expect(await opened.extractBytes(), await vaultKey.extractBytes());
    final bytes = await opened.extractBytes();
    final asHex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    for (final hex in keys.values) {
      expect(asHex, isNot(hex));
      expect(bytes, isNot(utf8.encode(hex)));
    }
    expect(device.kept[ProfileVault.wrappedName('aaaa')], isNot(device.kept[ProfileVault.wrappedName('bbbb')]));
    // The first profile signs out: its copies go. The others open as before.
    await vault.dropCopies('aaaa');
    expect(await vault.unwrap('bbbb', opened), kb);
    expect(await vault.unwrap('cccc', opened), kc);
    expect(await vault.startUpCheck(['bbbb', 'cccc']), isTrue);
  });

  test('turning it on: every wrapped copy first, then the slots, and only then the plain keys go', () async {
    await vault.turnOn(keys: keys, slots: slots, pin: pin);
    int first(String entry) => device.log.indexOf(entry);
    final wraps = [for (final id in keys.keys) first('write:${ProfileVault.wrappedName(id)}')];
    final slotsAt = first('write:${ProfileVault.slotsName}');
    final deletes = [for (final id in keys.keys) first('delete:${ProfileVault.plainName(id)}')];
    expect(wraps.every((w) => w >= 0 && w < slotsAt), isTrue, reason: device.log.join('\n'));
    expect(deletes.every((d) => d > slotsAt), isTrue, reason: device.log.join('\n'));
  });

  test('turning it off: every plain key first, then the vault', () async {
    final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
    device.log.clear();
    await vault.turnOff(profiles: keys.keys, vaultKey: vaultKey);
    int first(String entry) => device.log.indexOf(entry);
    final plains = [for (final id in keys.keys) first('write:${ProfileVault.plainName(id)}')];
    final wraps = [for (final id in keys.keys) first('delete:${ProfileVault.wrappedName(id)}')];
    final slotsAt = first('delete:${ProfileVault.slotsName}');
    final lastPlain = plains.reduce((a, b) => a > b ? a : b);
    expect(plains.every((w) => w >= 0), isTrue);
    expect(wraps.every((d) => d > lastPlain), isTrue, reason: device.log.join('\n'));
    expect(slotsAt, greaterThan(lastPlain), reason: device.log.join('\n'));
    await expectAllOpen();
    expect(await vault.hasSlots(), isFalse);
  });

  test('turning it on, stopped at every write: every profile still opens, and the start says how the lock stands', () async {
    for (var stopAfter = 0; stopAfter < 12; stopAfter++) {
      device.kept.removeWhere((k, _) => k.contains('vault') || k.contains('wrapped') || k.startsWith('p.'));
      for (final e in keys.entries) {
        device.kept[ProfileVault.plainName(e.key)] = e.value;
      }
      device.stopAfter = stopAfter;
      SecretKey? vaultKey;
      final stopped = await untilStopped(() async {
        vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
      });
      device.stopAfter = null;
      final lockOn = await vault.startUpCheck(keys.keys);
      if (lockOn) {
        vaultKey = await slots.unlockVaultKey(pin: pin);
        await vault.settleAfterUnlock(keys.keys, vaultKey!);
        for (final id in keys.keys) {
          expect(device.kept.containsKey(ProfileVault.plainName(id)), isFalse, reason: 'settled, step $stopAfter');
        }
      } else {
        expect(stopped, isTrue);
        for (final id in keys.keys) {
          expect(device.kept.containsKey(ProfileVault.wrappedName(id)), isFalse, reason: 'dropped, step $stopAfter');
        }
        expect(device.kept.containsKey(ProfileVault.slotsName), isFalse);
      }
      await expectAllOpen(vaultKey: vaultKey);
    }
  });

  test('turning it off, stopped at every write: the vault is there while any profile needs it', () async {
    for (var stopAfter = 0; stopAfter < 12; stopAfter++) {
      device.kept.removeWhere((k, _) => k.contains('vault') || k.startsWith('p.'));
      for (final e in keys.entries) {
        device.kept[ProfileVault.plainName(e.key)] = e.value;
      }
      final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
      device.stopAfter = stopAfter;
      await untilStopped(() => vault.turnOff(profiles: keys.keys, vaultKey: vaultKey));
      device.stopAfter = null;
      final lockOn = await vault.startUpCheck(keys.keys);
      if (lockOn) {
        expect(await slots.unlockVaultKey(pin: pin), isNotNull, reason: 'step $stopAfter');
      }
      await expectAllOpen(vaultKey: lockOn ? vaultKey : null);
    }
  });

  test('at start the vault is never dropped while any profile\'s only copy is wrapped by it', () async {
    final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
    // One profile has its plain key beside the copy, as a turning on or off that
    // stopped leaves it; the others have only the copy.
    device.kept[ProfileVault.plainName('aaaa')] = ka;
    expect(await vault.startUpCheck(keys.keys), isTrue);
    expect(await vault.hasSlots(), isTrue);
    expect(await vault.unwrap('bbbb', vaultKey), kb);
    // Every profile has its plain key: nothing needs the vault.
    device.kept[ProfileVault.plainName('bbbb')] = kb;
    device.kept[ProfileVault.plainName('cccc')] = kc;
    expect(await vault.startUpCheck(keys.keys), isFalse);
    expect(await vault.hasSlots(), isFalse);
    // With no profile holding a key at all, the PIN stays the PIN.
    device.kept[ProfileVault.slotsName] = '{}';
    expect(await vault.startUpCheck(const <String>[]), isTrue);
  });

  test('new names: an older version run after the move mistakes nothing for its own', () async {
    final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
    expect(device.kept.containsKey('vault_slots'), isFalse);
    expect(device.kept.containsKey('vault_wrapped_db_key'), isFalse);
    // What an older version does as it starts: it finds no vault of its own,
    // makes a key of its own, and at its next start, finding the old names with
    // a plain key beside them, drops them. Nothing of the new names is touched.
    final older = VaultSlotService(device);
    expect(await older.reconcileAndIsLocked(), isFalse);
    device.kept['zestssh_db_encryption_key'] = 'a key of its own';
    expect(await older.reconcileAndIsLocked(), isFalse);
    expect(await vault.hasSlots(), isTrue);
    expect(await vault.startUpCheck(keys.keys), isTrue);
    for (final e in keys.entries) {
      expect(await vault.unwrap(e.key, vaultKey), e.value);
    }
  });

  test('the hardware layer wraps each profile, and each then needs it', () async {
    final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
    final hardware = List<int>.generate(32, (i) => i + 1);
    await vault.enableHardware(keys.keys, hardware);
    for (final e in keys.entries) {
      expect(device.kept.containsKey(ProfileVault.wrappedName(e.key)), isFalse);
      expect(device.kept.containsKey(ProfileVault.hardwareName(e.key)), isTrue);
      await expectLater(vault.unwrap(e.key, vaultKey), throwsA(isA<VaultLockedException>()));
      expect(await vault.unwrap(e.key, vaultKey, hardwareKey: hardware), e.value);
    }
    expect(await vault.startUpCheck(keys.keys), isTrue);
    // A profile made while it is on gets it too.
    await vault.wrap('dddd', kd, vaultKey, hardwareKey: hardware);
    expect(device.kept.containsKey(ProfileVault.wrappedName('dddd')), isFalse);
    expect(await vault.unwrap('dddd', vaultKey, hardwareKey: hardware), kd);
    await vault.disableHardware(keys.keys, hardware);
    for (final e in keys.entries) {
      expect(await vault.unwrap(e.key, vaultKey), e.value);
    }
    expect(await vault.hardwareOn(), isFalse);
  });

  test('what waits for its account follows the lock: wrapped by the vault while it is on, plain when it is off', () async {
    final held = HeldEntries(device);
    await held.put('orchard_db_key_x', 'a team key');
    final raw = device.kept.values.firstWhere((v) => v.contains('a team key'));
    expect(raw, contains('a team key'));
    final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
    expect(device.kept.values.any((v) => v.contains('a team key')), isFalse);
    await expectLater(held.read('orchard_db_key_x'), throwsA(isA<VaultLockedException>()));
    expect(await held.read('orchard_db_key_x', vaultKey: vaultKey), 'a team key');
    await vault.turnOff(profiles: keys.keys, vaultKey: vaultKey);
    expect(await held.read('orchard_db_key_x'), 'a team key');
    // Its name says nothing of whose it is.
    expect(device.kept.keys.any((k) => k.contains('orchard_db_key_x')), isFalse);
  });

  group('what waits for its account has no other copy: it opens whatever turning the lock on or off stopped at', () {
    const waiting = {'orchard_db_key_x': 'a team key', 'account_keys_v1_someone': 'keys of someone'};

    void freshDevice() {
      device.kept.clear();
      for (final e in keys.entries) {
        device.kept[ProfileVault.plainName(e.key)] = e.value;
      }
    }

    Future<void> expectStillOpens(int step) async {
      final lockOn = await vault.startUpCheck(keys.keys);
      final vaultKey = lockOn ? await slots.unlockVaultKey(pin: pin) : null;
      final held = HeldEntries(device);
      for (final e in waiting.entries) {
        expect(await held.read(e.key, vaultKey: vaultKey), e.value, reason: 'step $step');
      }
      await expectAllOpen(vaultKey: vaultKey);
      if (vaultKey == null) return;
      // The next unlock puts right what was left, and it goes on opening.
      await vault.settleAfterUnlock(keys.keys, vaultKey);
      expect(device.kept.values.any((v) => waiting.values.any(v.contains)), isFalse, reason: 'wrapped, step $step');
      for (final e in waiting.entries) {
        expect(await held.read(e.key, vaultKey: vaultKey), e.value, reason: 'step $step');
      }
    }

    test('turning it on', () async {
      for (var stopAfter = 0; stopAfter < 14; stopAfter++) {
        freshDevice();
        final held = HeldEntries(device);
        for (final e in waiting.entries) {
          await held.put(e.key, e.value);
        }
        device.stopAfter = stopAfter;
        await untilStopped(() => vault.turnOn(keys: keys, slots: slots, pin: pin));
        device.stopAfter = null;
        await expectStillOpens(stopAfter);
      }
    });

    test('turning it off', () async {
      for (var stopAfter = 0; stopAfter < 18; stopAfter++) {
        freshDevice();
        final held = HeldEntries(device);
        for (final e in waiting.entries) {
          await held.put(e.key, e.value);
        }
        final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
        device.stopAfter = stopAfter;
        await untilStopped(() => vault.turnOff(profiles: keys.keys, vaultKey: vaultKey));
        device.stopAfter = null;
        await expectStillOpens(stopAfter);
      }
    });

    test('at start the vault stays while one is wrapped by it, even with every profile\'s plain key here', () async {
      await HeldEntries(device).put('orchard_db_key_x', 'a team key');
      final vaultKey = await vault.turnOn(keys: keys, slots: slots, pin: pin);
      keys.forEach((id, hex) => device.kept[ProfileVault.plainName(id)] = hex);
      expect(await vault.startUpCheck(keys.keys), isTrue);
      expect(await HeldEntries(device).read('orchard_db_key_x', vaultKey: vaultKey), 'a team key');
    });
  });

  test('the manager: a profile made or opened with the lock on is wrapped, and the guest\'s opens after the PIN', () async {
    device.kept.clear();
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    final guest = manager.currentEntry!;
    expect(device.kept[ProfileVault.plainName(guest.id)], isNotNull);
    await db.close();

    // The lock turned on: the guest's key is wrapped.
    final hex = device.kept[ProfileVault.plainName(guest.id)]!;
    manager.vaultKey = await vault.turnOn(keys: {guest.id: hex}, slots: slots, pin: pin);
    expect(device.kept.containsKey(ProfileVault.plainName(guest.id)), isFalse);

    // The next start: nothing opens without the PIN.
    Profiles.debugReset();
    final next = world.launch();
    expect((await next.start()).lockOn, isTrue);
    await expectLater(next.openCurrent(), throwsA(isA<VaultLockedException>()));
    next.vaultKey = await VaultSlotService(ProfileKeychain(device, profile: () => Profiles.current)).unlockVaultKey(pin: pin);
    final reopened = await next.openCurrent();
    await reopened.close();

    // A new account's profile: its key wrapped by the vault key, with no plain
    // key ever kept.
    device.log.clear();
    final prepared = await next.prepare(await next.planForAccount(uid: 'account-a', label: null, bearer: 'token'));
    await next.commit(prepared);
    final id = next.currentEntry!.id;
    expect(id, isNot(guest.id));
    expect(device.log.any((l) => l == 'write:${ProfileVault.plainName(id)}'), isFalse);
    expect(await vault.unwrap(id, next.vaultKey!), isNotEmpty);
    await prepared.db.close();

    // It is not one profile's key that is the lock's: this one locks, and the
    // guest's still opens with the PIN.
    await next.lockCurrent();
    expect(next.list.byId(id)!.state, ProfileState.hidden, reason: 'no secret at the cloud yet');
    final guestAgain = await next.openGuest();
    await guestAgain.close();
  });

  test('a locked copy\'s key opens only with its own secret, and is bound to its profile and id', () async {
    final copies = LockedCopies(device);
    final db = await openPlayed(await Directory(p.join(world.root.path, 'x')).create(), 'x');
    final seal = await SecretSeal.forProfile(db);
    final profile = ActiveProfile(id: 'pppp', dir: Directory(world.root.path), uid: 'u');
    final cloud = world.cloud;
    expect(await copies.confirmed('pppp'), isNull);
    expect(await copies.settle(profile: profile, hex: 'the key', seal: seal, bearer: 't', api: cloud), isTrue);
    final copy = (await copies.confirmed('pppp'))!;
    final secret = cloud.held[copy.id]!;
    expect(await copies.open('pppp', copy, secret), 'the key');
    await expectLater(copies.open('qqqq', copy, secret), throwsA(isA<LockedCopyDoesNotOpen>()));
    await expectLater(copies.open('pppp', LockedCopy(id: 'other', blob: copy.blob), secret), throwsA(isA<LockedCopyDoesNotOpen>()));
    await expectLater(copies.open('pppp', copy, List<int>.filled(32, 7)), throwsA(isA<LockedCopyDoesNotOpen>()));
    // Nothing of it is in the clear on this device.
    expect(device.kept.values.any((v) => v.contains('the key')), isFalse);
    await db.close();
  });

  test('a list that cannot be read stops the app: it is never taken for a device with no profiles', () async {
    device.kept[ProfileList.name] = 'not what was written';
    device.kept.remove(ProfileList.copyName);
    await expectLater(ProfileList.read(device), throwsA(isA<ProfileListUnreadable>()));
    final manager = world.launch();
    await expectLater(manager.start(), throwsA(isA<ProfileListUnreadable>()));
  });

  test('a profile that cannot open never makes a key over its database', () async {
    device.kept.clear();
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    final entry = manager.currentEntry!;
    await db.close();
    device.kept.remove(ProfileVault.plainName(entry.id));
    await expectLater(manager.openCurrent(), throwsA(isA<StateError>()));
    expect(device.kept.containsKey(ProfileVault.plainName(entry.id)), isFalse);
  });

  test('sealed by the keychain itself: a store hands it each value as it is', () async {
    final db = await openPlayed(await Directory(p.join(world.root.path, 'y')).create(), 'x');
    final seal = await SecretSeal.forProfile(db);
    expect(seal.active, isFalse, reason: 'the stores do not seal it twice');
    expect(await seal.keep('identity_key_x', 'value'), 'value');
    expect(await keepSealed(db, 'identity_key_x', 'value'), 'value');
    expect(await sealSecretsAtRest(db, device), 0);
    expect(await unsealSecretsAtRest(db, device), 0);
    expect(await settleSecretsAtRest(db, device, lockOn: true), 0);
    await db.close();
  });

  test('turning the lock off leaves every personal secret sealed', () async {
    device.kept.clear();
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    final entry = manager.currentEntry!;
    final keychain = world.keychainOf(Profiles.current!, db);
    await keychain.write(key: 'identity_key_x', value: 'a private key');
    final name = KeychainNames.full(entry.id, null, 'identity_key_x');
    expect(SecretSeal.isSealed(device.kept[name]), isTrue);
    final hex = device.kept[ProfileVault.plainName(entry.id)]!;
    manager.vaultKey = await vault.turnOn(keys: {entry.id: hex}, slots: slots, pin: pin);
    await vault.turnOff(profiles: [entry.id], vaultKey: manager.vaultKey!);
    expect(SecretSeal.isSealed(device.kept[name]), isTrue);
    expect(await keychain.read(key: 'identity_key_x'), 'a private key');
    await db.close();
  });

  test('a file of the app is where the profile says', () async {
    device.kept.clear();
    final manager = world.launch();
    await manager.start();
    final id = manager.list.current!;
    expect((await ProfilePaths.databaseDirectory()).path, ProfilePaths.ofProfile(world.base, id).path);
    expect(await AppDatabase.databasePath, p.join(ProfilePaths.ofProfile(world.base, id).path, 'zestssh.db'));
    expect((await AppDatabase.orchardDatabaseFile(kTeamA)).path,
        p.join(ProfilePaths.ofProfile(world.base, id).path, 'orchards', '$kTeamA.db'));
    Profiles.bind(null);
    await expectLater(ProfilePaths.databaseDirectory(), throwsStateError);
  });

  test('no file or folder name says who uses the device', () async {
    device.kept.clear();
    final manager = world.launch();
    await manager.start();
    final prepared = await manager.prepare(await manager.planForAccount(uid: 'account-alice', label: 'sam@example.com', bearer: 't'));
    await manager.commit(prepared);
    await prepared.db.close();
    final names = [for (final e in world.base.listSync(recursive: true)) e.path];
    expect(names.any((n) => n.contains('alice') || n.contains('sam')), isFalse);
    expect(device.kept.keys.any((k) => k.contains('alice') || k.contains('sam')), isFalse);
  });

  test('a profile id is random and tells nothing', () {
    final ids = {for (var i = 0; i < 50; i++) newProfileId()};
    expect(ids.length, 50);
    expect(ids.every((id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id)), isTrue);
    expect(ProfileManager, isNotNull);
  });
}
