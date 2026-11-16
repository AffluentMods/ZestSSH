import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/idle_lock.dart';
import 'package:zestssh/services/presence/system_presence.dart';
import 'package:zestssh/ui/widgets/idle_lock_watcher.dart';

/// The lock as the test sees it: counts the locks, with why each came (the lock
/// screen says it, 4.0), and unlocks on request.
class _Lock extends AppLockNotifier {
  _Lock(super.ref);

  int locks = 0;
  final reasons = <AppLockReason>[];

  @override
  Future<void> lock([AppLockReason why = AppLockReason.byYou]) async {
    locks++;
    reasons.add(why);
    state = true;
  }
}

/// The computer as the test sees it: when someone last gave input
/// anywhere on it ([inputAt], by the test's clock; null when it cannot say),
/// whether its lock screen is up ([locked]), and whether it fails to answer
/// at all ([fails]). Counts how often it is asked.
class _Computer implements SystemPresence {
  _Computer(this.clock, {this.inputAt});

  final DateTime Function() clock;
  DateTime? inputAt;
  bool? locked = false;
  bool fails = false;
  int idleAsked = 0;
  int lockAsked = 0;

  @override
  Future<Duration?> idleTime() async {
    idleAsked++;
    if (fails) throw StateError('the computer does not answer');
    final at = inputAt;
    return at == null ? null : clock().difference(at);
  }

  @override
  Future<bool?> isLocked() async {
    lockAsked++;
    if (fails) throw StateError('the computer does not answer');
    return locked;
  }

  @override
  Future<void> close() async {}
}

/// The idle lock at work (3.0): the app locks once nobody has
/// pressed a key, clicked or moved the mouse for the minutes asked for, with
/// the app in front; any input, coming back to the app, or unlocking starts
/// the clock afresh; and nothing locks when nothing asks for it.
void main() {
  late DateTime now;
  late _Lock lock;

  /// [computer] stands for what the computer says (none: a phone, or a
  /// computer that cannot say); [withComputer] for "Lock when the computer
  /// locks".
  Future<void> pump(WidgetTester tester, {int? minutes, SystemPresence? computer, bool withComputer = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    now = DateTime.utc(2026, 9, 25, 9);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        idleClockProvider.overrideWithValue(IdleClock(now: () => now)),
        idleLockMinutesProvider.overrideWithValue(minutes),
        systemPresenceProvider.overrideWithValue(computer),
        lockWithComputerProvider.overrideWithValue(withComputer),
        isAppLockedProvider.overrideWith((ref) => lock = _Lock(ref)),
      ],
      child: const MaterialApp(
        home: IdleLockWatcher(
          checkEvery: Duration(seconds: 1),
          child: Scaffold(body: Center(child: TextField())),
        ),
      ),
    ));
    await tester.pump();
    expect(lock.state, isFalse, reason: 'unlocked to begin with');
  }

  /// Time passes with nobody there.
  Future<void> wait(WidgetTester tester, Duration d) async {
    now = now.add(d);
    await tester.pump(d);
  }

  testWidgets('nobody there for the minutes asked: it locks', (tester) async {
    await pump(tester, minutes: 10);
    await wait(tester, const Duration(minutes: 9, seconds: 58));
    expect(lock.locks, 0);
    await wait(tester, const Duration(seconds: 3));
    expect(lock.locks, 1);
    expect(lock.state, isTrue);
    expect(lock.reasons, [const AppLockReason(AppLockCause.idle, 10)], reason: 'the lock screen says: after 10 minutes idle');
  });

  testWidgets('a key press starts the clock afresh', (tester) async {
    await pump(tester, minutes: 10);
    await wait(tester, const Duration(minutes: 9));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await wait(tester, const Duration(minutes: 9));
    expect(lock.locks, 0);
    await wait(tester, const Duration(minutes: 1, seconds: 2));
    expect(lock.locks, 1);
  });

  testWidgets('moving the mouse or clicking starts it afresh too', (tester) async {
    await pump(tester, minutes: 10);
    await wait(tester, const Duration(minutes: 9));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(const Offset(40, 40));
    await wait(tester, const Duration(minutes: 9));
    expect(lock.locks, 0, reason: 'a hover counts');
    await tester.tapAt(const Offset(60, 60));
    await wait(tester, const Duration(minutes: 9));
    expect(lock.locks, 0, reason: 'a click counts');
    await wait(tester, const Duration(minutes: 1, seconds: 2));
    expect(lock.locks, 1);
    await mouse.removePointer();
  });

  testWidgets('coming back to the app starts it afresh: time away is the away lock\'s', (tester) async {
    await pump(tester, minutes: 10);
    await wait(tester, const Duration(minutes: 9));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await wait(tester, const Duration(minutes: 9));
    expect(lock.locks, 0);
  });

  testWidgets('while locked nothing more happens, and unlocking starts afresh', (tester) async {
    await pump(tester, minutes: 10);
    await wait(tester, const Duration(minutes: 10, seconds: 2));
    expect(lock.locks, 1);
    await wait(tester, const Duration(minutes: 30));
    expect(lock.locks, 1, reason: 'no second lock while locked');
    lock.unlock();
    await tester.pump();
    await wait(tester, const Duration(minutes: 9));
    expect(lock.locks, 1);
    await wait(tester, const Duration(minutes: 1, seconds: 2));
    expect(lock.locks, 2);
  });

  testWidgets('nothing asks for it: it never locks', (tester) async {
    await pump(tester);
    await wait(tester, const Duration(hours: 3));
    expect(lock.locks, 0);
    expect(lock.state, isFalse);
  });

  // The idle lock follows the person, not the window, and the app locks with
  // the computer (as a security review
  // asked).
  group('the computer', () {
    /// Time passes with the computer awake: the clock and the looks at it go
    /// on together, half a minute at a time.
    Future<void> awake(WidgetTester tester, Duration d) async {
      var left = d;
      while (left > Duration.zero) {
        final step = left < const Duration(seconds: 30) ? left : const Duration(seconds: 30);
        now = now.add(step);
        await tester.pump(step);
        left -= step;
      }
    }

    /// The computer sleeps for [d]: the clock goes on, the app's timers do
    /// not; the first look after it comes when it wakes.
    Future<void> sleep(WidgetTester tester, Duration d) async {
      now = now.add(d);
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('input elsewhere on the computer keeps the app open; nobody anywhere locks it', (tester) async {
      final computer = _Computer(() => now);
      await pump(tester, minutes: 10, computer: computer);
      computer.inputAt = now;
      await awake(tester, const Duration(minutes: 9));
      // Working in another app: no input in ZestSSH for ten minutes and more.
      computer.inputAt = now;
      await awake(tester, const Duration(minutes: 5));
      expect(lock.locks, 0, reason: 'input elsewhere counts as someone there');
      computer.inputAt = now;
      await awake(tester, const Duration(minutes: 9, seconds: 50));
      expect(lock.locks, 0);
      // Nobody anywhere for the ten minutes.
      await awake(tester, const Duration(seconds: 15));
      expect(lock.locks, 1);
      expect(lock.state, isTrue);
    });

    testWidgets('the computer is asked only once the app\'s own input is ten minutes old', (tester) async {
      final computer = _Computer(() => now, inputAt: now);
      await pump(tester, minutes: 10, computer: computer);
      await awake(tester, const Duration(minutes: 9, seconds: 58));
      expect(computer.idleAsked, 0, reason: 'nothing to ask while the app saw input');
      expect(computer.lockAsked, 0, reason: 'nor of its lock, with the switch off');
      await awake(tester, const Duration(seconds: 3));
      expect(computer.idleAsked, greaterThan(0));
      expect(lock.locks, 1, reason: 'nobody anywhere since the start');
    });

    testWidgets('a computer that cannot say: the app\'s own input decides, as before', (tester) async {
      final silent = _Computer(() => now);
      await pump(tester, minutes: 10, computer: silent);
      await awake(tester, const Duration(minutes: 9, seconds: 58));
      expect(lock.locks, 0);
      await awake(tester, const Duration(seconds: 3));
      expect(silent.idleAsked, greaterThan(0));
      expect(lock.locks, 1, reason: 'no answer: locked as before');
    });

    testWidgets('a computer that fails to answer: the app\'s own input decides, as before', (tester) async {
      final failing = _Computer(() => now)..fails = true;
      await pump(tester, minutes: 10, computer: failing);
      await awake(tester, const Duration(minutes: 9, seconds: 58));
      expect(lock.locks, 0);
      await awake(tester, const Duration(seconds: 3));
      expect(failing.idleAsked, greaterThan(0));
      expect(lock.locks, 1, reason: 'a failure never keeps the app from locking');
    });

    testWidgets('the computer locks: the app locks with it while the switch is on', (tester) async {
      final computer = _Computer(() => now);
      await pump(tester, computer: computer, withComputer: true);
      await awake(tester, const Duration(minutes: 3));
      expect(computer.lockAsked, greaterThan(0));
      expect(lock.locks, 0, reason: 'unlocked computer, open app');
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 1);
      expect(lock.state, isTrue);
      expect(lock.reasons, [AppLockReason.computerLocked], reason: 'the lock screen says: when the computer locked');
    });

    testWidgets('with the switch off the computer\'s lock leaves the app as it is', (tester) async {
      final computer = _Computer(() => now);
      await pump(tester, computer: computer);
      await awake(tester, const Duration(minutes: 1));
      computer.locked = true;
      await awake(tester, const Duration(minutes: 5));
      expect(lock.locks, 0);
      expect(computer.lockAsked, 0, reason: 'not even asked');
    });

    testWidgets('the computer slept: the app locks while the switch is on', (tester) async {
      await pump(tester, computer: _Computer(() => now), withComputer: true);
      await awake(tester, const Duration(minutes: 1));
      await sleep(tester, const Duration(hours: 1));
      expect(lock.locks, 1);
      expect(lock.reasons, [AppLockReason.slept], reason: 'the lock screen says: when the computer went to sleep');
    });

    testWidgets('the computer slept with the switch off: the app stays open', (tester) async {
      await pump(tester, computer: _Computer(() => now));
      await awake(tester, const Duration(minutes: 1));
      await sleep(tester, const Duration(hours: 1));
      await awake(tester, const Duration(minutes: 1));
      expect(lock.locks, 0);
    });

    testWidgets('the same with no computer to ask: a sleep is seen by the clock alone', (tester) async {
      await pump(tester, withComputer: true);
      await awake(tester, const Duration(minutes: 1));
      await sleep(tester, const Duration(minutes: 30));
      expect(lock.locks, 1);
    });

    testWidgets('a look a little late is no sleep', (tester) async {
      await pump(tester, computer: _Computer(() => now), withComputer: true);
      await awake(tester, const Duration(minutes: 1));
      await sleep(tester, const Duration(seconds: 90));
      await awake(tester, const Duration(minutes: 1));
      expect(lock.locks, 0);
    });

    testWidgets('a lock that cannot be read never locks the app, and the idle lock goes on', (tester) async {
      final computer = _Computer(() => now)..fails = true;
      await pump(tester, minutes: 10, computer: computer, withComputer: true);
      await awake(tester, const Duration(minutes: 9, seconds: 58));
      expect(computer.lockAsked, greaterThan(0));
      expect(lock.locks, 0, reason: 'no answer is no lock');
      await awake(tester, const Duration(seconds: 3));
      expect(lock.locks, 1, reason: 'the idle lock as before');
    });

    testWidgets('a computer that does not know whether it is locked leaves the app open', (tester) async {
      final unknown = _Computer(() => now)..locked = null;
      await pump(tester, computer: unknown, withComputer: true);
      await awake(tester, const Duration(minutes: 5));
      expect(unknown.lockAsked, greaterThan(0));
      expect(lock.locks, 0);
    });

    testWidgets('a computer that reads locked all along locks the app only when it changes to locked',
        (tester) async {
      final computer = _Computer(() => now)..locked = true;
      await pump(tester, computer: computer, withComputer: true);
      await awake(tester, const Duration(minutes: 5));
      expect(lock.locks, 0, reason: 'never seen unlocked: no change to go by');
      computer.locked = false;
      await awake(tester, const Duration(seconds: 2));
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 1);
      // Unlocked by its person while the computer still reads locked: not
      // locked again at every look.
      lock.unlock();
      await tester.pump();
      await awake(tester, const Duration(minutes: 5));
      expect(lock.locks, 1);
    });

    // Found in a security review: what was last read stayed
    // "locked" after the computer locked the app, and was nothing at a start, so a
    // computer locked again before the next look never locked the app.
    testWidgets('locked again before the first look after an unlock: the app locks with it', (tester) async {
      final computer = _Computer(() => now);
      await pump(tester, computer: computer, withComputer: true);
      await awake(tester, const Duration(minutes: 1));
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 1);
      // Back after a while: the computer, then the app; the computer locked again at once.
      await awake(tester, const Duration(minutes: 30));
      computer.locked = false;
      lock.unlock();
      await tester.pump();
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 2, reason: 'not open behind the lock screen');
      expect(lock.state, isTrue);
    });

    testWidgets('locked before the first look after a start: the app locks with it', (tester) async {
      final computer = _Computer(() => now);
      await pump(tester, computer: computer, withComputer: true);
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 1);
    });

    testWidgets('a computer that reads locked as the app is unlocked at it is not believed until it reads unlocked', (tester) async {
      final computer = _Computer(() => now);
      await pump(tester, computer: computer, withComputer: true);
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 1);
      // Unlocked by its person while the computer still reads locked.
      lock.unlock();
      await tester.pump();
      await awake(tester, const Duration(minutes: 5));
      expect(lock.locks, 1);
      computer.locked = false;
      await awake(tester, const Duration(seconds: 2));
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 2, reason: 'believed again once it read unlocked');
    });

    testWidgets('a sleep while the app is locked does not lock it again once it is unlocked', (tester) async {
      final computer = _Computer(() => now);
      await pump(tester, computer: computer, withComputer: true);
      await awake(tester, const Duration(minutes: 1));
      computer.locked = true;
      await awake(tester, const Duration(seconds: 2));
      expect(lock.locks, 1);
      await sleep(tester, const Duration(hours: 8));
      computer.locked = false;
      await awake(tester, const Duration(seconds: 2));
      lock.unlock();
      await tester.pump();
      await awake(tester, const Duration(minutes: 5));
      expect(lock.locks, 1);
      expect(lock.state, isFalse);
    });
  });
}
