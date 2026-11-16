// What the computer itself says of the person at it (a security experience
// review). The idle lock counted
// input in ZestSSH's own windows only, so working in another app beside it,
// or reading a long output, locked the app; and a computer that locked or
// slept left ZestSSH open behind its lock screen. A computer's system knows
// how long it has been since the last key press or mouse move anywhere on
// it, and whether its lock screen is up: the idle lock asks it.
//
// Each answer may be null: a system that cannot say leaves the app as it was
// before, on its own input and without the computer's lock. A source never
// throws to its caller.

import 'dart:io' show Platform;

import 'package:zestssh/services/presence/linux_presence.dart';
import 'package:zestssh/services/presence/mac_presence.dart';
import 'package:zestssh/services/presence/windows_presence.dart';

/// The computer's word on the person at it.
abstract class SystemPresence {
  /// How long since the last key press, click or mouse move anywhere on the
  /// computer in this person's session, or null when the system cannot say.
  Future<Duration?> idleTime();

  /// Whether the computer is locked (its lock screen is up), or null when the
  /// system cannot say.
  Future<bool?> isLocked();

  /// Lets go of what it holds (a connection to the session's bus).
  Future<void> close() async {}

  /// This computer's, or null where there is none to ask: a phone, whose
  /// system sends the app away when it locks (the away lock's to judge).
  static SystemPresence? forThisDevice() {
    if (Platform.isWindows) return WindowsPresence();
    if (Platform.isMacOS) return MacPresence();
    if (Platform.isLinux) return LinuxPresence();
    return null;
  }
}
