// A screen in a window of its own (4.0), and recording mode: while
// recording mode covers a screen's picture, no window of its own shows it,
// whatever the main window shows. No tab is built in these tests: that is
// the case this watcher is for (the terminals' area is not in the main
// window while Settings is, and Settings is where recording mode is turned
// on).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/features/screens/window/screen_windows_recording.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

import 'fake_window_backend.dart';

class _Rig {
  _Rig._(this.container);

  static Future<_Rig> make({bool recording = false}) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final backend = FakeWindowBackend();
    final windows = ScreenWindows(backend: backend, watchEvery: const Duration(milliseconds: 40));
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => recording),
      screenWindowsProvider.overrideWithValue(windows),
    ]);
    final rig = _Rig._(container)
      ..backend = backend
      ..windows = windows;
    addTearDown(() async {
      await windows.closeAll();
      container.dispose();
      for (final s in rig._sessions) {
        s.close();
      }
    });
    return rig;
  }

  final ProviderContainer container;
  late final FakeWindowBackend backend;
  late final ScreenWindows windows;
  final _native = FakeScreenNative();
  final _sessions = <ScreenSession>[];

  /// A connected session shown in a window of its own.
  Future<void> open(String sessionId) async {
    final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: _native);
    _sessions.add(session);
    _native.sessions.last.connect(width: 1280, height: 800);
    expect(
        await windows.open(session,
            ScreenWindowPayload(sessionId: sessionId, handle: session.handle, protocol: ScreenProtocol.vnc)),
        isTrue);
  }

  void watch() => container.listen(screenWindowsRecordingGuardProvider, (_, _) {});
  set recording(bool on) => container.read(recordingModeProvider.notifier).state = on;
  Future<void> settle() => Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recording mode turned on: every screen in a window of its own comes back, with no tab there to do it', () async {
    final r = await _Rig.make();
    r.watch();
    await r.open('s1');
    await r.open('s2');
    expect(r.windows.shown.value, {'s1', 's2'});
    expect(r.backend.closed, isEmpty);

    r.recording = true;
    await r.settle();
    expect(r.windows.shown.value, isEmpty);
    expect(r.backend.closed, hasLength(2), reason: 'both windows are closed');

    // Off again: nothing is opened by itself.
    r.recording = false;
    await r.settle();
    expect(r.windows.shown.value, isEmpty);
  });

  test('a screen shown for this session stays in its window; taken back, it comes back', () async {
    final r = await _Rig.make();
    r.watch();
    await r.open('s1');
    await r.open('s2');
    r.container.read(screenShownWhileRecordingProvider.notifier).state = {'s2'};
    r.recording = true;
    await r.settle();
    expect(r.windows.shown.value, {'s2'});

    r.container.read(screenShownWhileRecordingProvider.notifier).state = const {};
    await r.settle();
    expect(r.windows.shown.value, isEmpty);
  });

  test('Settings saying not to cover screens: the windows stay; saying to cover them again: they come back', () async {
    final r = await _Rig.make();
    r.watch();
    await r.open('s1');
    final other = ScreenRecordingBehaviour.values.firstWhere((b) => b != ScreenRecordingBehaviour.cover);
    r.container.read(screenRecordingBehaviourProvider.notifier).set(other);
    r.recording = true;
    await r.settle();
    expect(r.windows.shown.value, {'s1'});

    r.container.read(screenRecordingBehaviourProvider.notifier).set(ScreenRecordingBehaviour.cover);
    await r.settle();
    expect(r.windows.shown.value, isEmpty);
  });

  test('recording mode already on: a window that is there when the watcher starts, and one opened later, both come back',
      () async {
    final r = await _Rig.make(recording: true);
    await r.open('s1');
    expect(r.windows.shown.value, {'s1'}, reason: 'nothing watches yet');
    r.watch();
    await r.settle();
    expect(r.windows.shown.value, isEmpty);

    await r.open('s2');
    await r.settle();
    expect(r.windows.shown.value, isEmpty);
    expect(r.backend.closed, hasLength(2));
  });

  test('recording mode off: nothing is touched, and nothing is left listening once the watcher is gone', () async {
    final r = await _Rig.make();
    final sub = r.container.listen(screenWindowsRecordingGuardProvider, (_, _) {});
    await r.open('s1');
    await r.settle();
    expect(r.windows.shown.value, {'s1'});
    sub.close();
    r.container.invalidate(screenWindowsRecordingGuardProvider);
    await r.settle();
    // (The provider is disposed: its listener on the windows is gone, so this changes nothing.)
    await r.open('s2');
    expect(r.windows.shown.value, {'s1', 's2'});
  });
}
