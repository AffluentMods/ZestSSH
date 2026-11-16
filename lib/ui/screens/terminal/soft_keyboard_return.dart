import 'dart:async';

import 'package:flutter/widgets.dart';

/// The on-screen keyboard of a phone's and a tablet's terminal as the app is
/// left and come back to (in 3.0.0: back in the app, the keyboard
/// was sometimes gone, or an empty space stood where it had been).
///
/// The system takes the keyboard down as the app is left. Back, it often
/// does not bring it up again, though the terminal still has the focus and
/// its input: a tap then did nothing (the input was connected already), and
/// on Android the room the keyboard had could stay, as the insets the system
/// had begun to animate down never settled while the app was away.
///
/// The rule:
/// - The keyboard counts as open while the view's bottom inset is above
///   none, and as closed once the inset stayed at none for [closedAfter]: a
///   keyboard that changes its page or its row of suggestions drops its
///   height for a frame or two, and is no closed keyboard.
/// - As the app is left, what it was is kept (open, with the terminal's
///   focus); what the insets do while it is away says nothing.
/// - Back, a keyboard that was open is asked for again ([show], which gives
///   the terminal the focus again where something took it) a moment later
///   ([showAfter]), once the app lock had its say ([ready]: a locked app
///   shows its lock screen, and the terminal is not on screen), where the
///   terminal's screen is the one in front and taps bring the on-screen
///   keyboard up (no hardware keyboard): the keyboard is up with the row
///   above it, and the insets the system sends with it settle the layout.
///   One that was closed is left closed.
class SoftKeyboardReturn {
  SoftKeyboardReturn({
    required this.inset,
    required this.terminalFocused,
    required this.mayShow,
    required this.show,
    this.ready,
  });

  /// The view's bottom inset (the on-screen keyboard's room), in pixels.
  final double Function() inset;

  /// Whether the terminal has the focus (not the find bar's field, a sheet).
  final bool Function() terminalFocused;

  /// Whether the keyboard may be asked for now: taps bring it up (no
  /// hardware keyboard), and the terminal is the screen in front.
  final bool Function() mayShow;

  /// Gives the terminal the focus and asks for the on-screen keyboard.
  final VoidCallback show;

  /// Done once the app may show the terminal's keyboard after a return (the
  /// app lock's check of it); none: at once.
  final Future<void> Function()? ready;

  /// How long the inset has to stay at none for the keyboard to be closed.
  static const closedAfter = Duration(milliseconds: 400);

  /// How long after the app is back the keyboard is asked for.
  static const showAfter = Duration(milliseconds: 250);

  bool _open = false;
  bool _away = false;
  bool _openAtLeave = false;
  Timer? _closing;
  Timer? _showing;

  /// Whether the on-screen keyboard is open, as it last settled (or its
  /// inset says so now, before a change of the metrics was told).
  bool get open => _open || (!_away && inset() > 0);

  /// The view's metrics changed (its insets among them).
  void metricsChanged() {
    if (_away) return;
    if (inset() > 0) {
      _closing?.cancel();
      _closing = null;
      _open = true;
    } else if (_open && _closing == null) {
      _closing = Timer(closedAfter, () {
        _closing = null;
        if (!_away && inset() <= 0) _open = false;
      });
    }
  }

  /// The app's lifecycle changed.
  void lifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_away) return;
        _away = true;
        _showing?.cancel();
        _showing = null;
        // A fall to none just before (the system taking the keyboard down as
        // the app goes) is no closing by its person.
        _closing?.cancel();
        _closing = null;
        _openAtLeave = _open && terminalFocused();
      case AppLifecycleState.resumed:
        if (!_away) return;
        _away = false;
        final wanted = _openAtLeave;
        _openAtLeave = false;
        _open = wanted || inset() > 0;
        if (wanted) {
          _showing = Timer(showAfter, () async {
            _showing = null;
            await ready?.call();
            if (_away || _disposed) return;
            if (!mayShow()) {
              metricsChanged();
              return;
            }
            show();
            // A keyboard that does not come (no inset for [closedAfter]) is
            // closed after all.
            metricsChanged();
          });
        } else {
          metricsChanged();
        }
      case AppLifecycleState.detached:
        break;
    }
  }

  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _closing?.cancel();
    _showing?.cancel();
  }
}
