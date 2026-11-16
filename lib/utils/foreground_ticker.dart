import 'dart:async';

import 'package:flutter/widgets.dart';

/// Calls [onTick] every [every] while the app is in front, and not while it
/// is hidden or in the background (a minimised window, a phone's app behind
/// another): what it keeps up to date is not seen there, and each tick woke
/// the process and asked for a frame nobody would see.
/// Back in front, it ticks once at once, so what it shows is right
/// again before the next tick, and goes on.
///
/// Where no binding has started (a plain unit test), it ticks as a periodic
/// timer would.
class ForegroundTicker with WidgetsBindingObserver {
  ForegroundTicker(this.every, this.onTick) {
    WidgetsBinding? binding;
    try {
      binding = WidgetsBinding.instance;
    } catch (_) {
      binding = null;
    }
    _binding = binding;
    _binding?.addObserver(this);
    _follow(_binding?.lifecycleState, startUp: true);
  }

  final Duration every;
  final VoidCallback onTick;
  WidgetsBinding? _binding;
  Timer? _timer;
  bool _disposed = false;

  /// Whether it ticks now.
  bool get ticking => _timer != null;

  /// The states in which the app is seen: in front, or in front behind a
  /// system sheet (inactive). Null is a binding that has not said yet.
  static bool _inFront(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _follow(state);

  void _follow(AppLifecycleState? state, {bool startUp = false}) {
    if (_disposed) return;
    if (_inFront(state)) {
      if (_timer != null) return;
      if (!startUp) onTick();
      _timer = Timer.periodic(every, (_) => onTick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _binding?.removeObserver(this);
  }
}
