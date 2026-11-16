import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/services/idle_lock.dart';
import 'package:zestssh/services/security_lock_service.dart';

/// The idle lock (3.0): how long without input before the app
/// locks while in front, from the person's own setting and the Orchards
/// they are in.
void main() {
  group('the minutes', () {
    test('nothing asks for it: no idle lock', () {
      expect(idleLockMinutes(lockOn: true, ownMinutes: 0, teamMinutes: const []), isNull);
      expect(idleLockMinutes(lockOn: true, ownMinutes: 0, teamMinutes: const [0, 0]), isNull);
    });

    test('the person\'s own setting', () {
      expect(idleLockMinutes(lockOn: true, ownMinutes: 10, teamMinutes: const []), 10);
    });

    test('an Orchard asks for it with no setting of their own', () {
      expect(idleLockMinutes(lockOn: true, ownMinutes: 0, teamMinutes: const [15]), 15);
    });

    test('the shortest of all wins', () {
      expect(idleLockMinutes(lockOn: true, ownMinutes: 10, teamMinutes: const [15]), 10);
      expect(idleLockMinutes(lockOn: true, ownMinutes: 30, teamMinutes: const [15, 5, 0]), 5);
      expect(idleLockMinutes(lockOn: true, ownMinutes: 5, teamMinutes: const [15, 60]), 5);
    });

    test('without the app lock there is nothing to lock with', () {
      expect(idleLockMinutes(lockOn: false, ownMinutes: 10, teamMinutes: const [15]), isNull);
    });
  });

  group('the clock', () {
    test('idle only once the time is up, and input starts it afresh', () {
      var now = DateTime.utc(2026, 9, 25, 12);
      final clock = IdleClock(now: () => now);
      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(clock.idleFor(10), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(clock.idleFor(10), isTrue);
      clock.touch();
      expect(clock.idleFor(10), isFalse);
      expect(clock.lastInput, now);
    });

    // From a review of the security experience: input anywhere
    // on the computer counts.
    test('input elsewhere on the computer counts; it can only make someone more recently there', () {
      var now = DateTime.utc(2026, 11, 5, 9);
      final clock = IdleClock(now: () => now);
      now = now.add(const Duration(minutes: 12));
      expect(clock.idleFor(10), isTrue, reason: 'nothing in the app for twelve minutes');
      expect(clock.idleFor(10, elsewhere: const Duration(minutes: 1)), isFalse, reason: 'busy in another app');
      expect(clock.idleFor(10, elsewhere: const Duration(minutes: 10)), isTrue, reason: 'nobody anywhere for ten');
      expect(clock.idleFor(10, elsewhere: null), isTrue, reason: 'the computer cannot say: the app decides');
      expect(clock.idleFor(10, elsewhere: const Duration(minutes: -5)), isTrue, reason: 'nonsense is ignored');
      clock.touch();
      now = now.add(const Duration(minutes: 3));
      expect(clock.idleFor(10, elsewhere: const Duration(hours: 2)), isFalse,
          reason: 'input in the app counts even where the computer says none came');
    });

    test('a look much later than due: the computer slept', () {
      final before = DateTime.utc(2026, 11, 5, 9);
      const due = Duration(seconds: 15);
      expect(sleptBetween(before, before.add(due), due: due), isFalse);
      expect(sleptBetween(before, before.add(const Duration(minutes: 2)), due: due), isFalse,
          reason: 'a busy or throttled app');
      expect(sleptBetween(before, before.add(due + kSleepGap), due: due), isFalse);
      expect(sleptBetween(before, before.add(due + kSleepGap + const Duration(seconds: 1)), due: due), isTrue);
      expect(sleptBetween(before, before.add(const Duration(hours: 8)), due: due), isTrue);
      expect(sleptBetween(before, before.subtract(const Duration(hours: 1)), due: due), isFalse,
          reason: 'a clock set back is no sleep');
    });
  });

  group('Lock when the computer locks', () {
    ProviderContainer containerWith({required bool lockOn, required bool setting}) {
      final c = ProviderContainer(overrides: [
        deviceLockProvider.overrideWith((ref) async => (on: lockOn, minutes: 10)),
        lockWithComputerSettingProvider.overrideWith((ref) async => setting),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    Future<bool> onIn(ProviderContainer c) async {
      c.listen(lockWithComputerProvider, (_, _) {});
      await c.read(deviceLockProvider.future);
      await c.read(lockWithComputerSettingProvider.future);
      return c.read(lockWithComputerProvider);
    }

    test('on with the app lock, unless turned off; never without the app lock', () async {
      expect(await onIn(containerWith(lockOn: true, setting: true)), isTrue);
      expect(await onIn(containerWith(lockOn: true, setting: false)), isFalse);
      expect(await onIn(containerWith(lockOn: false, setting: true)), isFalse);
    });

    test('kept with the app lock\'s settings: on by default, off when turned off, on again with a new lock', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final service = SecurityLockService(const FlutterSecureStorage(), LocalAuthentication());
      expect(await service.getLockWithComputer(), isTrue);
      await service.setLockWithComputer(false);
      expect(await service.getLockWithComputer(), isFalse);
      expect(await const FlutterSecureStorage().read(key: 'security_lock_with_computer'), 'off');
      await service.setLockWithComputer(true);
      expect(await const FlutterSecureStorage().read(key: 'security_lock_with_computer'), isNull);
      await service.setLockWithComputer(false);
      await service.clearLock();
      expect(await service.getLockWithComputer(), isTrue, reason: 'turning the app lock off forgets it');
    });

    test('under flutter test the real computer is not asked', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(systemPresenceProvider), isNull);
    });
  });

  group('from the settings', () {
    ProviderContainer containerWith({required bool lockOn, required int own, int? team}) {
      final c = ProviderContainer(overrides: [
        deviceLockProvider.overrideWith((ref) async => (on: lockOn, minutes: 10)),
        idleLockSettingProvider.overrideWith((ref) async => own),
        teamIdleLockMinutesProvider.overrideWithValue(team),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    Future<int?> minutesOf(ProviderContainer c) async {
      c.listen(idleLockMinutesProvider, (_, _) {});
      await c.read(deviceLockProvider.future);
      await c.read(idleLockSettingProvider.future);
      return c.read(idleLockMinutesProvider);
    }

    test('own setting and a team rule combine', () async {
      expect(await minutesOf(containerWith(lockOn: true, own: 30, team: 10)), 10);
      expect(await minutesOf(containerWith(lockOn: true, own: 5, team: 10)), 5);
      expect(await minutesOf(containerWith(lockOn: true, own: 0, team: null)), isNull);
      expect(await minutesOf(containerWith(lockOn: false, own: 5, team: 10)), isNull);
    });

    test('the Orchards: the shortest longest auto-lock time among them', () async {
      OrchardSummary orchard(String id, int minutes) => OrchardSummary(
            id: id,
            name: id,
            role: 'owner',
            crates: const [],
            defaultCrateId: null,
            rules: RecordRules(requireAppLock: minutes > 0, maxLockMinutes: minutes),
          );
      final c = ProviderContainer(overrides: [
        orchardSummariesProvider.overrideWith((ref) async => [orchard('a', 30), orchard('b', 0), orchard('c', 15)]),
      ]);
      addTearDown(c.dispose);
      c.listen(teamIdleLockMinutesProvider, (_, _) {});
      await c.read(orchardSummariesProvider.future);
      expect(c.read(teamIdleLockMinutesProvider), kOrchardsEnabled ? 15 : isNull);
    });
  });
}
