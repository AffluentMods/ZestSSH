// Remote screens (4.0): the remote's sound under the app's lock and recording
// mode, with no view of the screen left in the main window (its tab not built:
// Hosts, Keys or Settings shown, or its screen in a window of its own): the
// sound must not outlive its views.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/session/screen_sound_guard.dart';
import 'package:zestssh/features/screens/view/screen_sound_gate.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/features/screens/window/screen_windows_recording.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

import '../window/fake_window_backend.dart';

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  set locked(bool on) => state = on;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a session playing in a window of its own is silenced by the lock and by recording mode, and when the window '
      'closes; a session that connects meanwhile starts under the same rule', () async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final windows = ScreenWindows(backend: FakeWindowBackend(), watchEvery: const Duration(milliseconds: 40));
    final native = FakeScreenNative();
    final lock = _Lock();
    final sessions = StateProvider<Map<String, ScreenSession>>((ref) => const {});
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => false),
      isAppLockedProvider.overrideWith((ref) => lock),
      screenWindowsProvider.overrideWithValue(windows),
      screenSoundSessionsProvider.overrideWith((ref) => ref.watch(sessions)),
    ]);
    final opened = <ScreenSession>[];
    addTearDown(() async {
      await windows.closeAll();
      container.dispose();
      for (final s in opened) {
        s.close();
      }
    });
    ScreenSession open() {
      final s = ScreenSession.open(const ScreenConnectOptions.rdp(sound: true, soundOn: false), native: native);
      opened.add(s);
      native.sessions.last.connect(width: 1280, height: 800);
      return s;
    }

    container.listen(screenSoundGuardProvider, (_, _) {});
    final s1 = open();
    container.read(sessions.notifier).state = {'s1': s1};
    expect(await windows.open(s1, ScreenWindowPayload(sessionId: 's1', handle: s1.handle, protocol: ScreenProtocol.rdp)),
        isTrue);
    // Its tab went while the window showed it: the window holds the sound.
    ScreenSoundGate.of(s1).hold(ScreenSoundGate.ownWindow('s1'), on: true);
    final engine = native.sessions.first;
    expect(engine.sounds, [true]);

    lock.locked = true;
    expect(engine.sounds, [true, false], reason: 'locked: silent, with no view to say so');
    lock.locked = false;
    expect(engine.sounds, [true, false, true]);

    container.read(recordingModeProvider.notifier).state = true;
    expect(engine.sounds.last, isFalse, reason: 'recording mode covers screens: silent');
    container.read(recordingModeProvider.notifier).state = false;

    // A session that connects while the app is locked starts blocked.
    lock.locked = true;
    final s2 = open();
    container.read(sessions.notifier).state = {'s1': s1, 's2': s2};
    await Future<void>.delayed(Duration.zero);
    expect(ScreenSoundGate.of(s2).blocked, isTrue);
    lock.locked = false;

    // The window closes (brought back to a tab that is not there): nobody sees it.
    await windows.bringBack('s1');
    await Future<void>.delayed(Duration.zero);
    expect(ScreenSoundGate.of(s1).playing, isFalse);
    expect(engine.sounds.last, isFalse);
  });
}
