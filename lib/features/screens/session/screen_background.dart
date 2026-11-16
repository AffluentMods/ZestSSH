// Remote screens (4.0) while the app is away from the screen.
//
// Everywhere, the picture is paused: the views that show a screen pause it as
// the app is hidden (ScreenPane, PhoneScreenView) and a screen no view shows
// is paused already, so the server sends nothing until it is seen again, then
// the whole picture.
//
// Android cuts a background app's sockets about 5 s after it leaves the screen
// (Android 15): a connected screen counts as a session for the foreground
// service (ActiveSessionsNotifier._syncForegroundService), which keeps them.
// Computers keep the connection.
//
// iOS keeps no socket of an app it suspends, a few seconds after it leaves the
// screen, and has no background mode that fits a remote screen. So its screens
// are given the time iOS grants (BackgroundGrace, about 30 s: a quick switch to
// another app and back just resumes), closed cleanly [margin] before it runs
// out (the screen and its carrier SSH), shown as paused, and connected again
// in their place when the app is back. They are no "sessions dropped in the
// background": the app closed them itself and connects them again.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/background_grace.dart';

class ScreenBackgroundKeeper {
  ScreenBackgroundKeeper({
    required this.connectedScreens,
    required this.parkedScreens,
    required this.park,
    required this.reconnect,
    required this.grace,
    required this.closesInBackground,
  });

  /// How long before the granted time runs out the screens are closed: room
  /// for the carrier's SSH to say goodbye before iOS suspends the app.
  static const margin = Duration(seconds: 5);

  /// The screen sessions connected now.
  final Iterable<String> Function() connectedScreens;

  /// The screen sessions closed in the background, waiting for the app.
  final Iterable<String> Function() parkedScreens;

  /// Closes a screen session cleanly, kept in its place as paused.
  final Future<void> Function(String sessionId) park;

  /// Connects a paused screen session again, in its place.
  final void Function(String sessionId) reconnect;

  final BackgroundGraceApi grace;

  /// Whether screens are closed in the background (iOS).
  final bool closesInBackground;

  bool _away = false;
  bool _graceHeld = false;
  Timer? _closeTimer;

  /// Whether the app is away from the screen now (as this keeper was told).
  bool get away => _away;

  /// The app left the screen (hidden or paused; told again, nothing more).
  Future<void> hidden() async {
    if (!closesInBackground || _away) return;
    _away = true;
    if (connectedScreens().isEmpty) return;
    _graceHeld = true;
    final given = await grace.begin(onExpired: () => unawaited(_closeAll()));
    // Back in front before the system answered.
    if (!_away) return;
    final wait = (given ?? Duration.zero) - margin;
    if (wait <= Duration.zero) {
      await _closeAll();
      return;
    }
    _closeTimer = Timer(wait, () => unawaited(_closeAll()));
  }

  Future<void> _closeAll() async {
    _closeTimer?.cancel();
    _closeTimer = null;
    if (!_away) return;
    for (final id in connectedScreens().toList()) {
      await park(id);
    }
    await _giveBack();
  }

  Future<void> _giveBack() async {
    if (!_graceHeld) return;
    _graceHeld = false;
    await grace.end();
  }

  /// The app is in front again: the screens closed meanwhile connect again
  /// (how many). A screen still open (a quick switch) is resumed by its view.
  int resumed() {
    if (!_away) return 0;
    _away = false;
    _closeTimer?.cancel();
    _closeTimer = null;
    unawaited(_giveBack());
    final parked = parkedScreens().toList();
    for (final id in parked) {
      reconnect(id);
    }
    return parked.length;
  }

  void dispose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }
}

/// The sessions whose loss in the background iOS's "sessions dropped" notice
/// counts ([sessions] connected as the app leaves the screen): never a remote
/// screen, which the app closes itself and connects again
/// ([ScreenBackgroundKeeper]).
Set<String> connectedBeforeBackground(Map<String, SessionState> sessions, {required bool Function(String) isScreen}) =>
    {
      for (final e in sessions.entries)
        if (e.value.status == SessionStatus.connected && !isScreen(e.key)) e.key,
    };

/// The keeper of this run's screens. Overridden in tests (a fake grace and
/// iOS's rule on any platform).
final screenBackgroundProvider = Provider<ScreenBackgroundKeeper>((ref) {
  final ios = Platform.isIOS;
  final keeper = ScreenBackgroundKeeper(
    connectedScreens: () {
      final sessions = ref.read(activeSessionsProvider);
      return ref
          .read(activeSessionsProvider.notifier)
          .screenSessionIds
          .where((id) => sessions[id]?.status == SessionStatus.connected);
    },
    parkedScreens: () => ref.read(activeSessionsProvider.notifier).parkedScreenIds,
    park: (id) => ref.read(activeSessionsProvider.notifier).parkScreen(id),
    reconnect: (id) => ref.read(activeSessionsProvider.notifier).reconnectNow(id),
    grace: ios ? BackgroundGrace() : const NoBackgroundGrace(),
    closesInBackground: ios,
  );
  ref.onDispose(keeper.dispose);
  return keeper;
});
