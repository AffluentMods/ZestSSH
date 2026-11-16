// Remote screens (4.0): recording mode and a screen in a window of
// its own. While recording mode covers a screen's picture, no window of its
// own may show it: the screen comes back to its tab, which is covered.
//
// The tab does that itself while it is there. It is not always there: the
// terminals' area leaves the main window whenever Hosts, Keys or Settings is
// shown, and Settings is where recording mode is turned on. So this watcher
// lives with the app's main window (ZestSSHApp reads it once) and does the
// same whatever the main window shows.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// Brings every screen that recording mode covers back from its window, now
/// and at every change: recording mode turned on, Settings saying to cover
/// screens, "Show for this session" taken back, and a window opened while
/// its screen is covered. Its value never changes.
final screenWindowsRecordingGuardProvider = Provider<void>((ref) {
  final windows = ref.watch(screenWindowsProvider);
  void check() {
    final recording = ref.read(recordingModeProvider);
    if (!recording) return;
    final behaviour = ref.read(screenRecordingBehaviourProvider);
    final shown = ref.read(screenShownWhileRecordingProvider);
    for (final sessionId in windows.shown.value) {
      if (screenCoveredWhileRecording(recording: recording, behaviour: behaviour, shown: shown.contains(sessionId))) {
        unawaited(windows.bringBack(sessionId));
      }
    }
  }

  ref.listen(recordingModeProvider, (_, _) => check());
  ref.listen(screenRecordingBehaviourProvider, (_, _) => check());
  ref.listen(screenShownWhileRecordingProvider, (_, _) => check());
  windows.shown.addListener(check);
  ref.onDispose(() => windows.shown.removeListener(check));
  check();
});

/// The app's windows of screens ([ScreenWindows.instance]); a test puts its
/// own here.
final screenWindowsProvider = Provider<ScreenWindows>((ref) => ScreenWindows.instance);
