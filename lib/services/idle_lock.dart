// The idle lock (3.0). The app lock has always locked after a spell
// away from the app. An owner who sets an Orchard's "longest auto-lock time"
// also expects a laptop left open on a desk to lock, with the app still in
// front; so where an Orchard asks for it, the app also locks after that long
// without a key press or click. Everyone else keeps the lock as it was, and
// can turn the idle lock on for themselves ("Lock when idle").

/// The choices for "Lock when idle", in minutes; 0 is off.
const kIdleLockChoices = [0, 5, 10, 15, 30, 60];

/// Minutes without input after which the app locks while it is in front, or
/// null when nothing asks for it: the shorter of the person's own setting
/// ([ownMinutes], 0 when off) and every Orchard's longest auto-lock time
/// ([teamMinutes], 0 where an Orchard sets none). Only with the app lock on
/// ([lockOn]): without a PIN or biometrics there is nothing to lock with.
int? idleLockMinutes({
  required bool lockOn,
  required int ownMinutes,
  required Iterable<int> teamMinutes,
}) {
  if (!lockOn) return null;
  int? minutes = ownMinutes > 0 ? ownMinutes : null;
  for (final m in teamMinutes) {
    if (m > 0 && (minutes == null || m < minutes)) minutes = m;
  }
  return minutes;
}

/// When the person last pressed a key, clicked, scrolled or moved the mouse
/// in the app or one of its pop-out windows.
class IdleClock {
  IdleClock({DateTime Function()? now}) : _now = now ?? DateTime.now {
    _last = _now();
  }

  final DateTime Function() _now;
  late DateTime _last;

  /// The time now, by the clock this one reads.
  DateTime get now => _now();

  /// Someone is there.
  void touch() => _last = _now();

  /// When someone was last there.
  DateTime get lastInput => _last;

  /// Whether nobody has been there for [minutes]: not in the app, and, where
  /// the computer says how long it has been without input anywhere on it
  /// ([elsewhere]), not elsewhere on the computer either (a security
  /// experience review: the idle
  /// lock follows the person, not the window). Input elsewhere can only make
  /// the person more recently there; a computer that cannot say leaves the
  /// app's own input to decide.
  bool idleFor(int minutes, {Duration? elsewhere}) {
    final now = _now();
    var last = _last;
    if (elsewhere != null && !elsewhere.isNegative) {
      final there = now.subtract(elsewhere);
      if (there.isAfter(last)) last = there;
    }
    return !now.isBefore(last.add(Duration(minutes: minutes)));
  }
}

/// A look at the clock this much later than due means the computer slept in
/// between (a security experience review): the app's timers do not
/// run while it sleeps, and the wall clock goes on. Two minutes keeps a busy
/// or throttled app (macOS slows the timers of an app nobody sees) from
/// reading as asleep.
const kSleepGap = Duration(minutes: 2);

/// Whether the clock moved from [before] to [now] by more than [due] and
/// [kSleepGap] together: the computer slept.
bool sleptBetween(DateTime before, DateTime now, {required Duration due}) =>
    now.difference(before) > due + kSleepGap;
