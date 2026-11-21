// Remote screens (4.1): system keys go to the remote in full screen. The
// keys Windows acts on before any window sees them (the Windows key, Alt+Tab,
// Alt+Esc, Ctrl+Esc, Alt+Space, Alt+F4, Print Screen, the menu key) are taken
// by a small native part (windows/runner/key_grab.cpp) while a full-screen
// remote screen has the keyboard and Settings says so, and come here, to go
// to the remote as the keys they are.
//
// The way back to this computer's keys has two halves that do not depend on
// each other: this file stops asking on every reason the app knows (full
// screen left, the picture losing the keyboard, the tab hidden, view only,
// the screen gone), and the native part takes nothing for a window that is
// not in front, nor once it has not been renewed for two seconds (an app
// whose own code is stuck). Ctrl+Alt+Break leaves full screen as before.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'keysyms.dart';

/// The computer's part that takes system keys.
abstract interface class KeyGrabber {
  /// Takes the system keys from now; false where it could not.
  Future<bool> start();

  /// Takes nothing from now.
  Future<void> stop();

  /// Says the app is still there. Without one for two seconds the native
  /// part takes nothing.
  void renew();

  /// The keys taken: Windows' virtual key, its scan code, whether it is an
  /// extended key, and down or up.
  Stream<(int, int, bool, bool)> get keys;
}

/// [KeyGrabber] over the app's channel `zestssh/key_grab` (windows/runner).
/// Where the runner has no such channel every call does nothing.
class ChannelKeyGrabber implements KeyGrabber {
  ChannelKeyGrabber();

  static const _methods = MethodChannel('zestssh/key_grab');
  static const _events = EventChannel('zestssh/key_grab/events');

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
      // Nothing taken, or gone.
    } on MissingPluginException {
      // No such part on this device.
    }
  }

  @override
  void renew() {
    unawaited(_methods.invokeMethod<void>('renew').catchError((Object _) {}));
  }

  @override
  late final Stream<(int, int, bool, bool)> keys = _events
      .receiveBroadcastStream()
      .handleError((Object _) {})
      .where((e) => e is List && e.length == 4 && e[0] is int && e[1] is int && e[2] is bool && e[3] is bool)
      .map((e) {
    final l = e! as List;
    return (l[0] as int, l[1] as int, l[2] as bool, l[3] as bool);
  });
}

/// The keys the native part takes, by Windows' virtual key: the key this
/// app's keyboard knows it by, and what goes to the remote (X keysym, and the
/// scan code in QEMU's numbering, 0x80 and the code for an extended key).
const Map<int, (PhysicalKeyboardKey, ScreenKey)> kGrabbedKeys = {
  0x5B: (PhysicalKeyboardKey.metaLeft, ScreenKey(0xffeb, 0xdb)), // Windows key, left (Super_L)
  0x5C: (PhysicalKeyboardKey.metaRight, ScreenKey(0xffec, 0xdc)), // Windows key, right (Super_R)
  0x5D: (PhysicalKeyboardKey.contextMenu, ScreenKey(0xff67, 0xdd)), // the menu key
  0x2C: (PhysicalKeyboardKey.printScreen, ScreenKey(0xff61, 0xb7)), // Print Screen
  0x09: (PhysicalKeyboardKey.tab, ScreenKey(0xff09, 0x0f)), // with Alt
  0x20: (PhysicalKeyboardKey.space, ScreenKey(0x20, 0x39)), // with Alt
  0x73: (PhysicalKeyboardKey.f4, ScreenKey(0xffc1, 0x3e)), // with Alt
  0x1B: (PhysicalKeyboardKey.escape, ScreenKey(0xff1b, 0x01)), // with Alt or Ctrl
};

/// Asks for the system keys for one screen while [wanted], and hands each
/// key taken to [onKey].
class ScreenKeyGrab {
  ScreenKeyGrab({required this.grabber, required this.onKey});

  final KeyGrabber grabber;
  final void Function(PhysicalKeyboardKey physical, ScreenKey key, bool down) onKey;

  /// How often the native part is told the app is still there (it lets go
  /// after two seconds without).
  static const renewEvery = Duration(milliseconds: 500);

  /// The screen that has the keys now: one at a time, as there is one
  /// keyboard.
  static ScreenKeyGrab? _owner;

  bool _wanted = false;
  bool _disposed = false;
  Timer? _renew;
  StreamSubscription<(int, int, bool, bool)>? _sub;

  /// Whether the native part takes keys for this screen.
  @visibleForTesting
  bool get grabbing => identical(_owner, this) && _renew != null;

  bool get wanted => _wanted;

  /// Full screen, the picture with the keyboard, Settings on, keys going to
  /// the remote: the system keys are taken for it.
  set wanted(bool value) {
    if (_disposed || value == _wanted) return;
    _wanted = value;
    if (value) {
      unawaited(_start());
    } else {
      _stop();
    }
  }

  Future<void> _start() async {
    _sub ??= grabber.keys.listen(_key);
    _owner = this;
    final ok = await grabber.start();
    // Turned off, or another screen asked, while it started.
    if (!_wanted || !identical(_owner, this)) {
      if (ok && identical(_owner, this)) await grabber.stop();
      return;
    }
    if (!ok) return;
    _renew?.cancel();
    _renew = Timer.periodic(renewEvery, (_) => grabber.renew());
  }

  void _stop() {
    _renew?.cancel();
    _renew = null;
    if (identical(_owner, this)) {
      _owner = null;
      unawaited(grabber.stop());
    }
  }

  void _key((int, int, bool, bool) e) {
    final (vk, _, _, down) = e;
    // Keys meant for another screen, or come after this one let go.
    if (!_wanted || !identical(_owner, this)) return;
    final known = kGrabbedKeys[vk];
    if (known == null) return;
    onKey(known.$1, known.$2, down);
  }

  void dispose() {
    wanted = false;
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
  }
}
