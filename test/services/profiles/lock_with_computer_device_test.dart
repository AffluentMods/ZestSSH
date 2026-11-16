import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/security_lock_service.dart';

import 'profile_world.dart';

/// "Lock when the computer locks" is the computer's, as the app lock's other settings
/// are (found in a review): it was kept in each
/// profile, so it was on in one and off in another, and turning the app lock off
/// forgot only the one on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'security_lock_with_computer';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  SecurityLockService serviceIn(ActiveProfile profile) =>
      SecurityLockService(ProfileKeychain(world.device, profile: () => profile, tree: () => null), LocalAuthentication());

  ActiveProfile profile(String id, {String? uid}) =>
      ActiveProfile(id: id, dir: Directory(p.join(world.base.path, 'profiles', id)), uid: uid);

  test('the same in every profile, and forgotten with the app lock', () async {
    final alex = serviceIn(profile('a' * 32, uid: 'alex'));
    final guest = serviceIn(profile('b' * 32));
    expect(KeychainNames.isDevice(name), isTrue);
    await alex.setLockWithComputer(false);
    expect(world.device.kept[name], 'off', reason: "kept as the computer's");
    expect(world.rawNames('a' * 32), isEmpty, reason: 'nothing of it in the profile');
    expect(await guest.getLockWithComputer(), isFalse, reason: 'off in guest data too');
    await guest.clearLock();
    expect(await alex.getLockWithComputer(), isTrue, reason: 'on again with a new app lock, whichever profile turned it off');
  });

  test("an off kept in a profile by a build before this is the computer's at the next start", () async {
    final id = 'c' * 32;
    // Kept sealed, as a profile's entries are: only off was ever kept, so it says off.
    world.device.kept['${KeychainPrefix.of(id)}$name'] = 'zseal1:sealed-off';
    final manager = world.launch();
    await manager.start();
    expect(world.device.kept[name], 'off');
    expect(world.device.kept.containsKey('${KeychainPrefix.of(id)}$name'), isFalse);
  });

  test('with none kept in a profile, nothing is written at a start', () async {
    final manager = world.launch();
    await manager.start();
    expect(world.device.kept.containsKey(name), isFalse);
  });
}
