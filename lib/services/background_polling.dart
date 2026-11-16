import 'package:flutter/widgets.dart' show AppLifecycleState;

/// Whether Server Monitor's polling and the reachability checks stop at the
/// app's lifecycle [state]. On a phone or tablet they stop when the app goes
/// to the background (inactive or paused) and start again when it comes
/// back. On a computer ([computer]) they never stop for the window: a window
/// that loses focus (another window clicked) reports inactive, and one sent
/// to the tray is hidden, while the app is running and watching servers
/// behind it. They stopped there every time the person clicked another
/// window (found in a code audit).
bool backgroundPollingStops(AppLifecycleState state, {required bool computer}) {
  if (computer) return false;
  return state == AppLifecycleState.paused || state == AppLifecycleState.inactive;
}
