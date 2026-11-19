import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/mac_secure_enclave_vault_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/secret_seal.dart';

import 'profile_world.dart';

/// The app lock's hardware layer keeps the bytes its hardware key sealed in
/// the keychain, and reads them to open the lock: before any database is
/// open, so they must be a name of the device, read as stored. A Mac's
/// (the Secure Enclave, 4.0) was a name of the profile: sealed with a key
/// inside the database that the lock opens, it read as none while the app was
/// locked, so the lock could never be opened again. Windows' was a device
/// name already.
void main() {
  late ProfileWorld world;
  late AppDatabase db;
  late ActiveProfile alice;

  setUp(() async {
    world = await ProfileWorld.create();
    Profiles.turnOn();
    db = await openPlayed(await Directory(p.join(world.root.path, 'a')).create(), 'x');
    await SecretSeal.forProfile(db);
    alice = ActiveProfile(id: 'aaaa', dir: Directory(p.join(world.base.path, 'profiles', 'aaaa')), uid: 'account-alice');
    Profiles.bind(alice);
  });
  tearDown(() async {
    await db.close();
    await world.dispose();
  });

  test("the Mac hardware layer's sealed key is a name of the device, as Windows' is", () {
    expect(KeychainNames.isDevice(MacSecureEnclaveVaultService.sealedKeyId), isTrue);
    expect(KeychainNames.isDevice('vault_tpm_sealed_key'), isTrue);
  });

  test('written while the app is open, it is read back while the app is locked (no database open, no profile)',
      () async {
    const sealed = 'bytes-the-enclave-sealed';
    // Turned on in Settings: the app is open.
    final open = ProfileKeychain(world.device, profile: () => alice, tree: () => db);
    await open.write(key: MacSecureEnclaveVaultService.sealedKeyId, value: sealed);
    // The lock screen, after a lock or a restart: nothing is open yet.
    final locked = ProfileKeychain(world.device, profile: () => null, tree: () => null);
    expect(await locked.read(key: MacSecureEnclaveVaultService.sealedKeyId), sealed);
    // And with the profile known but its database still closed.
    final closed = ProfileKeychain(world.device, profile: () => alice, tree: () => null);
    expect(await closed.read(key: MacSecureEnclaveVaultService.sealedKeyId), sealed);
  });
}
