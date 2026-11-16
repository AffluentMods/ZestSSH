import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/secret_seal.dart';

/// On a computer a waiting recovery's ticket is kept like the other per-account
/// secrets: sealed by the profile open, whatever the app lock, with nothing of it
/// outside that profile. Every screen that reads it is behind the lock, with a
/// profile open: guest data, for a person signed out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('the ticket is sealed in the profile open, waits for the PIN, and no other profile reads it', () async {
    FlutterSecureStorage.setMockInitialValues({});
    Profiles.turnOn();
    addTearDown(Profiles.debugReset);
    final guest = AppDatabase.forTesting(NativeDatabase.memory());
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      SecretSeal.openTree = null;
      await guest.close();
      await other.close();
    });
    await SecretSeal.forProfile(guest);
    await SecretSeal.forProfile(other);
    const device = FlutterSecureStorage();
    var profile = ActiveProfile(id: 'guest-id', dir: Directory.systemTemp);
    final store = LockoutRecoveryStore(ProfileKeychain(device, profile: () => profile));
    SecretSeal.openTree = guest;

    // Asked for from the sign-in screen, with guest data open and the lock off.
    await store.save(WaitingLockout(email: 'sam@example.com', ticket: 'dGlja2V0LXNlY3JldA', completesAt: DateTime.utc(2026, 11, 6)));
    final name = '${profile.prefix}lockout_recovery_v1';
    final kept = (await device.read(key: name))!;
    expect(kept, startsWith(SecretSeal.prefix));
    expect(kept, isNot(contains('dGlja2V0')));
    expect(await device.read(key: 'lockout_recovery_v1'), isNull, reason: 'nothing of it outside the profile');
    expect((await store.read())!.ticket, 'dGlja2V0LXNlY3JldA');

    // The app locks: it is read at the unlock, and never taken for none.
    SecretSeal.openTree = null;
    WaitingLockout? read;
    var done = false;
    unawaited(store.read().then((w) {
      read = w;
      done = true;
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(done, isFalse, reason: 'it waits');
    SecretSeal.openTree = guest;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(read!.ticket, 'dGlja2V0LXNlY3JldA');

    // Someone else's profile open: none here, and that one's stays.
    final waited = profile;
    profile = ActiveProfile(id: 'other-id', dir: Directory.systemTemp, uid: 'alex');
    SecretSeal.openTree = other;
    expect(await store.read(), isNull);
    expect(await device.read(key: name), kept);

    // Back in it, and done: gone.
    profile = waited;
    SecretSeal.openTree = guest;
    expect((await store.read())!.ticket, 'dGlja2V0LXNlY3JldA');
    await store.clear();
    expect(await device.read(key: name), isNull);
    expect(await store.read(), isNull);
  });
}
