import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/idle_lock.dart';
import 'package:zestssh/utils/logger.dart';

/// Locks the app after a spell without a key press, click, scroll or mouse
/// move, even while it is in front (3.0), when the person's "Lock
/// when idle" or an Orchard's longest auto-lock time asks for it. Input is
/// watched app-wide (every route, dialog and overlay) and never consumed.
/// Time away from the app stays the away lock's to judge: coming back to the
/// app starts the idle clock afresh.
///
/// On a computer the idle lock follows the person, not the window, and the
/// app locks with the computer (a security experience review):
/// input anywhere on the computer
/// counts as someone there, where the computer says so; and with "Lock when
/// the computer locks" (on by default with the app lock) the app locks when
/// the computer's lock screen comes up or it slept. Both are asked at the
/// same looks as the idle clock; a computer that cannot say leaves the app
/// as it was before.
class IdleLockWatcher extends ConsumerStatefulWidget {
  const IdleLockWatcher({super.key, required this.child, this.checkEvery = const Duration(seconds: 15)});

  final Widget child;

  /// How often the clock is looked at: the app locks at most this long after
  /// the idle time is up, or after the computer locked.
  final Duration checkEvery;

  @override
  ConsumerState<IdleLockWatcher> createState() => _IdleLockWatcherState();
}

/// How long the computer may take to answer before it counts as no answer.
const _kAnswerTimeout = Duration(seconds: 5);

class _IdleLockWatcherState extends ConsumerState<IdleLockWatcher> with WidgetsBindingObserver {
  Timer? _timer;
  late final IdleClock _clock = ref.read(idleClockProvider);

  /// When the clock was last looked at: a look much later than due means the
  /// computer slept in between.
  late DateTime _lastLook;

  /// The computer slept since the last check.
  bool _slept = false;

  /// What the computer last said of its own lock while the app was open.
  /// Only a change from unlocked to locked locks the app: a computer that
  /// reads locked all along (one that had it the wrong way round) cannot
  /// lock the app again and again. At a start and at each unlock of the app
  /// it is unlocked, as someone is at it ([_atTheComputer]).
  bool? _computerLocked = false;

  /// A check is waiting for the computer's answer: the next look leaves it.
  bool _checking = false;

  /// The computer failed to answer, and the log said so once.
  bool _failureLogged = false;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
    _lastLook = _clock.now;
    _timer = Timer.periodic(widget.checkEvery, (_) => _look());
    _atTheComputer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent ||
        event is PointerMoveEvent ||
        event is PointerHoverEvent ||
        event is PointerScrollEvent ||
        event is PointerPanZoomUpdateEvent) {
      _clock.touch();
    }
  }

  bool _onKey(KeyEvent event) {
    _clock.touch();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _clock.touch();
  }

  /// A look at the clock: whether the computer slept since the last one is
  /// read now, at the look, and the check follows.
  void _look() {
    final now = _clock.now;
    if (sleptBetween(_lastLook, now, due: widget.checkEvery)) _slept = true;
    _lastLook = now;
    if (_checking) return;
    _checking = true;
    unawaited(_check().whenComplete(() => _checking = false));
  }

  /// Still worth locking: the widget is there and the app is open.
  bool get _open => mounted && !ref.read(isAppLockedProvider);

  Future<void> _check() async {
    if (!mounted) return;
    final slept = _slept;
    _slept = false;
    // While locked there is nothing to lock; unlocking starts afresh.
    if (ref.read(isAppLockedProvider)) return;
    final presence = ref.read(systemPresenceProvider);

    if (ref.read(lockWithComputerProvider)) {
      if (slept) {
        _lock('App locked: the computer slept', AppLockReason.slept);
        return;
      }
      final locked = await _ask(presence?.isLocked);
      if (!_open) return;
      final was = _computerLocked;
      if (locked != null) _computerLocked = locked;
      if (locked == true && was == false) {
        _lock('App locked with the computer', AppLockReason.computerLocked);
        return;
      }
    }

    final minutes = ref.read(idleLockMinutesProvider);
    if (minutes == null || !_clock.idleFor(minutes)) return;
    // Nothing in the app for that long: the computer is asked whether the
    // person was busy elsewhere on it meanwhile.
    final elsewhere = await _ask(presence?.idleTime);
    if (!_open) return;
    if (!_clock.idleFor(minutes, elsewhere: elsewhere)) return;
    _lock('App locked after $minutes minutes without input', AppLockReason(AppLockCause.idle, minutes));
  }

  /// The computer's answer to [question], or null where it has none, fails
  /// or takes too long: the app then goes on without it.
  Future<T?> _ask<T>(Future<T?> Function()? question) async {
    if (question == null) return null;
    try {
      return await question().timeout(_kAnswerTimeout);
    } catch (e) {
      if (!_failureLogged) {
        _failureLogged = true;
        AppLogger.warning('Idle lock: the computer did not answer ($e)');
      }
      return null;
    }
  }

  /// Someone is at the computer: the app has just started, or been unlocked. So the
  /// computer is unlocked, whatever was last read: it read locked after it locked the
  /// app, and nothing at a start, and a lock before the next look was then no change,
  /// so the app stayed open behind the lock screen (found in an
  /// independent review). It is asked at once; one that says locked even now has it
  /// wrong, and is not believed until it reads unlocked.
  void _atTheComputer() {
    _computerLocked = false;
    if (_checking || !ref.read(lockWithComputerProvider)) return;
    _checking = true;
    unawaited(_readAtTheComputer().whenComplete(() => _checking = false));
  }

  Future<void> _readAtTheComputer() async {
    final locked = await _ask(ref.read(systemPresenceProvider)?.isLocked);
    if (mounted && locked == true) _computerLocked = true;
  }

  void _lock(String why, AppLockReason reason) {
    AppLogger.info(why);
    unawaited(ref.read(isAppLockedProvider.notifier).lock(reason));
  }

  @override
  Widget build(BuildContext context) {
    // Kept current while the app runs, so a check reads the settings as
    // they stand.
    ref.watch(idleLockMinutesProvider);
    ref.watch(lockWithComputerProvider);
    ref.listen<bool>(isAppLockedProvider, (was, locked) {
      if (was == true && !locked) {
        _clock.touch();
        _atTheComputer();
      }
    });
    return widget.child;
  }
}
