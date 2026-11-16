import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/presence/linux_presence.dart';
import 'package:zestssh/services/presence/mac_presence.dart';
import 'package:zestssh/services/presence/system_presence.dart';
import 'package:zestssh/services/presence/windows_presence.dart';

/// What the computer says of the person at it (a security experience
/// review), from the real system
/// where the calls only read: Windows' GetLastInputInfo, GetTickCount64 and
/// WTSQuerySessionInformationW. Nothing here locks the computer or changes
/// anything on it. The other systems' sources, run where their system is
/// not, answer null and never throw: the app then goes on as before.
void main() {
  group('Windows', () {
    final skip = Platform.isWindows ? false : 'Windows only';

    test('this computer is a Windows one', () {
      expect(SystemPresence.forThisDevice(), isA<WindowsPresence>());
    }, skip: skip);

    test('the idle time: how long since input anywhere in this session', () async {
      final presence = WindowsPresence();
      final idle = await presence.idleTime();
      expect(idle, isNotNull, reason: 'GetLastInputInfo answers in a desktop session');
      expect(idle!.isNegative, isFalse);
      // Within the 32-bit tick count's span: the arithmetic wrapped right.
      expect(idle, lessThan(const Duration(days: 50)));
      expect(await presence.idleTime(), isNotNull, reason: 'and again');
    }, skip: skip);

    test('the lock state of this session: an answer, locked or not', () async {
      // Whether the person running the tests has locked the computer is
      // theirs; that Windows answers at all, in the expected shape, is the
      // point. (Checked by hand against the record's
      // other fields: level 1, this process's session id, WTSActive, the
      // station "Console", and the lock screen's LogonUI running.)
      final locked = await WindowsPresence().isLocked();
      expect(locked, isA<bool>());
    }, skip: skip);
  });

  group('a system that is not this one answers nothing, quietly', () {
    test('macOS\'s sources away from a Mac', () async {
      final presence = MacPresence();
      expect(await presence.idleTime(), isNull);
      expect(await presence.isLocked(), isNull);
      // Not tried again, and still no throw.
      expect(await presence.idleTime(), isNull);
      expect(await presence.isLocked(), isNull);
      await presence.close();
    }, skip: Platform.isMacOS ? 'on a Mac it answers' : false);

    test(
      'a Linux desktop\'s sources away from Linux',
      () async {
        final presence = LinuxPresence();
        expect(await presence.idleTime(), isNull);
        expect(await presence.isLocked(), isNull);
        await presence.close();
        // Closed: nothing more is asked.
        expect(await presence.isLocked(), isNull);
      },
      skip: Platform.isLinux ? 'on Linux it may answer' : false,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
