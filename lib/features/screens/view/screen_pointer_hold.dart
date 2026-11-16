// Remote screens (4.0): relative mouse. For a game or a 3D program
// the remote is told how far the mouse moved, not where the pointer is, and
// the pointer of this computer must neither leave the picture nor stop at
// its edge. So the pointer is held: hidden and kept in the window by the
// computer's own system (a small native part behind one channel), which
// reports movement, and the movement goes to the remote as movement.
//
// The way out must always work. It has two halves that do not depend on each
// other: this file lets go on every reason the app knows (the release key,
// the view losing the keyboard, the tab leaving, the session ending, view
// only), and the native part lets go by itself when its window is no longer
// in front or when it has not been renewed for two seconds, which is what
// happens when the app's own code is stuck.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// The computer's part that holds the pointer.
abstract interface class PointerCapture {
  /// Whether this device can hold the pointer at all (Windows, macOS, Linux
  /// under X11 and under a Wayland compositor that locks pointers; not a
  /// phone, whose Mouse pointer mode sends movement without holding one).
  Future<bool> available();

  /// Starts holding: the pointer hidden and kept in the window, its movement
  /// on [moves]. False where it could not.
  Future<bool> start();

  /// Lets go. Nothing where it is not held.
  Future<void> stop();

  /// Says the app is still there. Without one for two seconds the native
  /// part lets go by itself and says so on [lost].
  void renew();

  /// Movement while held, in the mouse's own counts: (dx, dy).
  Stream<(int, int)> get moves;

  /// The native part let go by itself.
  Stream<void> get lost;
}

/// [PointerCapture] over the app's channel `zestssh/pointer_capture`
/// (windows/runner, macos/Runner, linux/runner). On a device whose runner has
/// no such channel every call answers "not available".
class ChannelPointerCapture implements PointerCapture {
  ChannelPointerCapture();

  static const _methods = MethodChannel('zestssh/pointer_capture');
  static const _events = EventChannel('zestssh/pointer_capture/events');

  late final Stream<Object?> _all = _events.receiveBroadcastStream().handleError((Object _) {});

  @override
  Future<bool> available() async {
    try {
      return await _methods.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> start() async {
    try {
      return await _methods.invokeMethod<bool>('start') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } on PlatformException {
      // Not held, or gone: there is nothing to let go of.
    } on MissingPluginException {
      // No such part on this device.
    }
  }

  @override
  void renew() {
    unawaited(_methods.invokeMethod<void>('renew').catchError((Object _) {}));
  }

  @override
  Stream<(int, int)> get moves => _all.where((e) => e is List && e.length == 2 && e[0] is int && e[1] is int).map((e) {
        final list = e! as List;
        return (list[0] as int, list[1] as int);
      });

  @override
  Stream<void> get lost => _all.where((e) => e == 'lost').map((_) {});
}

/// Holds the pointer for one screen and sends its movement.
class ScreenPointerHold extends ChangeNotifier {
  ScreenPointerHold({required this.capture, required this.send});

  final PointerCapture capture;

  /// Movement to the remote: (dx, dy) with these buttons down.
  final void Function(int dx, int dy, int buttons) send;

  /// How often the native part is told the app is still there. It lets go
  /// by itself after four of these without one.
  static const renewEvery = Duration(milliseconds: 500);

  /// The most movement one frame sends a way: what the engine takes in one
  /// call's eight events.
  static const most = 8 * 32767;

  bool _held = false;
  bool _starting = false;

  // Counts every letting go. A grab that is still waiting for the computer's
  // answer when one happens is not to hold after all: the release key, the
  // tab leaving or the session ending in that moment would otherwise be
  // lost, and the pointer held with nobody knowing.
  int _letGoes = 0;
  bool _disposed = false;
  int _buttons = 0;
  int _dx = 0;
  int _dy = 0;
  bool _flushing = false;
  Timer? _renew;
  StreamSubscription<(int, int)>? _moves;
  StreamSubscription<void>? _lost;

  /// The pointer is held: movement goes to the remote as movement.
  bool get held => _held;

  /// Starts holding. True when it is held after this (also where it was
  /// already); false where this device cannot, or it was let go meanwhile.
  Future<bool> grab() async {
    if (_disposed) return false;
    if (_held) return true;
    if (_starting) return false;
    _starting = true;
    final asked = _letGoes;
    // Listened to from before the computer answers: a hold it lets go of in
    // the same moment (its window was not in front after all) is not missed.
    var lostAlready = false;
    final lost = capture.lost.listen((_) {
      if (_held) {
        _letGo(tellNative: false);
      } else {
        lostAlready = true;
      }
    });
    var started = false;
    try {
      started = await capture.start();
    } finally {
      _starting = false;
      if (!started) unawaited(lost.cancel());
    }
    if (_disposed || asked != _letGoes || lostAlready) {
      // Let go of while it was being taken: the computer is told so.
      unawaited(lost.cancel());
      unawaited(capture.stop());
      return false;
    }
    if (!started) return false;
    _held = true;
    _dx = 0;
    _dy = 0;
    _moves = capture.moves.listen(_moved);
    _lost = lost;
    capture.renew();
    _renew = Timer.periodic(renewEvery, (_) => capture.renew());
    notifyListeners();
    return true;
  }

  /// Lets go: the pointer is this computer's again. Nothing where it is not
  /// held. Any button the remote still has down is let go of too.
  void release() => _letGo(tellNative: true);

  void _letGo({required bool tellNative}) {
    _letGoes++;
    if (!_held) return;
    _held = false;
    _renew?.cancel();
    _renew = null;
    unawaited(_moves?.cancel());
    unawaited(_lost?.cancel());
    _moves = null;
    _lost = null;
    _dx = 0;
    _dy = 0;
    if (_buttons != 0) {
      _buttons = 0;
      send(0, 0, 0);
    }
    if (tellNative) unawaited(capture.stop());
    if (!_disposed) notifyListeners();
  }

  /// The buttons down now (as a pointer's): sent at once, with whatever
  /// movement waits, so a click lands where the movement before it ended.
  void buttons(int now) {
    if (!_held || now == _buttons) return;
    _buttons = now;
    final (dx, dy) = (_dx, _dy);
    _dx = 0;
    _dy = 0;
    send(dx, dy, now);
  }

  void _moved((int, int) by) {
    if (!_held) return;
    _dx = (_dx + by.$1).clamp(-most, most);
    _dy = (_dy + by.$2).clamp(-most, most);
    if (_flushing) return;
    _flushing = true;
    // One a frame, summed: a mouse reports up to a thousand times a second.
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _flushing = false;
      if (!_held || (_dx == 0 && _dy == 0)) return;
      final (dx, dy) = (_dx, _dy);
      _dx = 0;
      _dy = 0;
      send(dx, dy, _buttons);
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _letGo(tellNative: true);
    _disposed = true;
    super.dispose();
  }
}
