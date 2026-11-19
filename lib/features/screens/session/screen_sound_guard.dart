// Remote screens (4.0): the remote's sound under the app's lock and recording
// mode, for every session, whether a view of it is left or not.
//
// A view silences its session while it is covered or locked, but a session
// can be playing with no view of the main window left: its screen shown in a
// window of its own while Hosts, Keys or Settings is shown (Settings is where
// recording mode is turned on). This watcher lives with the app's main
// window (ZestSSHApp reads it once, as it reads the recording guard of the
// screens' own windows) and closes every session's ScreenSoundGate while the
// app is locked or recording mode covers that screen. A window of its own
// that no longer shows its screen lets go of the sound it held.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zest_native/screen.dart' show ScreenSession;
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/view/screen_sound_gate.dart';
import 'package:zestssh/features/screens/window/screen_windows_recording.dart' show screenWindowsProvider;
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

/// The screen sessions open now, by their ids (a test gives its own).
final screenSoundSessionsProvider = Provider<Map<String, ScreenSession>>((ref) => {
      for (final e in ref.watch(activeSessionsProvider).entries)
        if (e.value.session?.shell case final ScreenShellService shell)
          if (shell.session case final ScreenSession session) e.key: session,
    });

/// Keeps every screen session's sound silent while the app is locked or
/// recording mode covers its screen, now and at every change, and lets a
/// window of its own that closed stop holding its session's sound. Its value
/// never changes.
final screenSoundGuardProvider = Provider<void>((ref) {
  final windows = ref.watch(screenWindowsProvider);
  var shownBefore = windows.shown.value;

  void check() {
    final locked = ref.read(isAppLockedProvider);
    final recording = ref.read(recordingModeProvider);
    final behaviour = ref.read(screenRecordingBehaviourProvider);
    final shownWhileRecording = ref.read(screenShownWhileRecordingProvider);
    final inWindows = windows.shown.value;
    for (final e in ref.read(screenSoundSessionsProvider).entries) {
      final session = e.value;
      if (session.isClosed) continue;
      final gate = ScreenSoundGate.of(session);
      // A window of its own that closed: what it held goes with it.
      if (!inWindows.contains(e.key)) gate.release(ScreenSoundGate.ownWindow(e.key));
      gate.blocked = locked ||
          screenCoveredWhileRecording(
              recording: recording, behaviour: behaviour, shown: shownWhileRecording.contains(e.key));
    }
    shownBefore = inWindows;
  }

  ref.listen(isAppLockedProvider, (_, _) => check());
  ref.listen(recordingModeProvider, (_, _) => check());
  ref.listen(screenRecordingBehaviourProvider, (_, _) => check());
  ref.listen(screenShownWhileRecordingProvider, (_, _) => check());
  // A session that connects (or connects again: a new session, a new gate)
  // starts under the same rule.
  ref.listen(screenSoundSessionsProvider, (_, _) => check());
  void windowsChanged() {
    if (windows.shown.value != shownBefore) check();
  }

  windows.shown.addListener(windowsChanged);
  ref.onDispose(() => windows.shown.removeListener(windowsChanged));
  check();
});
