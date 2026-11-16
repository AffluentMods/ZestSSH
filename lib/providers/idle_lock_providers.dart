import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/idle_lock.dart';
import 'package:zestssh/services/presence/system_presence.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// When the person was last there (3.0): input in the app and in
/// its pop-out windows.
final idleClockProvider = Provider<IdleClock>((ref) => IdleClock());

/// "Lock when idle" on this device, in minutes; 0 when off. Invalidate after
/// changing it.
final idleLockSettingProvider = FutureProvider<int>((ref) async {
  return ref.watch(securityLockServiceProvider).getIdleLockMinutes();
});

/// The shortest "longest auto-lock time" among the Orchards on this device,
/// or null when none sets one: the idle lock they ask for.
final teamIdleLockMinutesProvider = Provider<int?>((ref) {
  if (!kOrchardsEnabled) return null;
  final orchards = ref.watch(orchardSummariesProvider).valueOrNull ?? const <OrchardSummary>[];
  int? least;
  for (final o in orchards) {
    final m = o.rules.maxLockMinutes;
    if (m > 0 && (least == null || m < least)) least = m;
  }
  return least;
});

/// Minutes without input after which the app locks while in front, or null
/// when nothing asks for it (see [idleLockMinutes]).
final idleLockMinutesProvider = Provider<int?>((ref) {
  final device = ref.watch(deviceLockProvider).valueOrNull;
  final team = ref.watch(teamIdleLockMinutesProvider);
  return idleLockMinutes(
    lockOn: device?.on ?? false,
    ownMinutes: ref.watch(idleLockSettingProvider).valueOrNull ?? 0,
    teamMinutes: [?team],
  );
});

/// What the computer says of the person at it: how long since input anywhere
/// on it, and whether it is locked (from a security experience review).
/// Null on a phone, and under
/// `flutter test` (FLUTTER_TEST): what a test finds must not depend on
/// whether the person running it is at the keyboard or has locked the
/// computer. Tests hand in their own.
final systemPresenceProvider = Provider<SystemPresence?>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
  final presence = SystemPresence.forThisDevice();
  ref.onDispose(() => presence?.close());
  return presence;
});

/// "Lock when the computer locks" on this device: on unless turned off.
/// Invalidate after changing it.
final lockWithComputerSettingProvider = FutureProvider<bool>((ref) async {
  return ref.watch(securityLockServiceProvider).getLockWithComputer();
});

/// Whether the app locks when the computer locks or sleeps: on a
/// computer, with the app lock on, unless turned off.
final lockWithComputerProvider = Provider<bool>((ref) {
  if (!isDesktopPlatform) return false;
  if (ref.watch(deviceLockProvider).valueOrNull?.on != true) return false;
  return ref.watch(lockWithComputerSettingProvider).valueOrNull ?? true;
});
