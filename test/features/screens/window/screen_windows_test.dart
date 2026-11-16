// A screen in a window of its own (4.0), the main window's side, with
// the app's windows played: the window is opened with what it needs and
// nothing that names the host, the session's events are passed on, and the
// screen comes back to its tab when asked, when the window is closed, and
// when the session ends.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';

import 'fake_window_backend.dart';

class _Rig {
  _Rig() {
    session = ScreenSession.open(const ScreenConnectOptions.rdp(), native: native);
    engine = native.sessions.single;
    engine.connect(name: 'office-pc', width: 1280, height: 800);
  }

  final native = FakeScreenNative();
  final backend = FakeWindowBackend();
  late final windows = ScreenWindows(backend: backend, watchEvery: const Duration(milliseconds: 40));
  late final ScreenSession session;
  late final FakeScreenSession engine;

  ScreenWindowPayload payload([String sessionId = 's1']) => ScreenWindowPayload(
        sessionId: sessionId,
        handle: session.handle,
        protocol: ScreenProtocol.rdp,
        info: const {'protocol': 'rdp', 'width': 1280, 'height': 800},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opened: a window with the payload and the language, titled without the host, and the tab is told',
      () async {
    final r = _Rig();
    final changes = <Set<String>>[];
    r.windows.shown.addListener(() => changes.add(r.windows.shown.value));
    expect(await r.windows.open(r.session, r.payload()), isTrue);
    final (id, payload) = (r.backend.payloads.keys.single, r.backend.payloads.values.single);
    expect(payload['type'], 'screen');
    expect(payload['sessionId'], 's1');
    expect(payload['handle'], '${r.session.handle}');
    expect(payload.containsKey('locale'), isTrue);
    expect(jsonEncode(payload).contains('office-pc'), isFalse, reason: 'nothing names the host');
    final (frame, title) = r.backend.placed[id]!;
    expect(title, 'ZestSSH');
    expect(frame.size, ScreenWindows.openSize);
    expect(r.windows.isShown('s1'), isTrue);
    expect(changes, [
      {'s1'},
    ]);
    await r.windows.closeAll();
    r.session.close();
  });

  test('opened again: the window it has comes to the front, no second one', () async {
    final r = _Rig();
    await r.windows.open(r.session, r.payload());
    expect(await r.windows.open(r.session, r.payload()), isTrue);
    expect(r.backend.payloads, hasLength(1));
    expect(r.backend.focused, [r.backend.payloads.keys.single]);
    await r.windows.closeAll();
    r.session.close();
  });

  test('what only the owner is told is passed on; new pixels and the clipboard are not', () async {
    final r = _Rig();
    await r.windows.open(r.session, r.payload());
    final id = r.backend.payloads.keys.single;
    r.engine
      ..emit(ScreenEventKind.frame, a: 4)
      ..emit(ScreenEventKind.clipboard, data: Uint8List.fromList(utf8.encode('secret text')))
      ..emit(ScreenEventKind.resize, a: (1600 << 32) | 900)
      ..displays([
        [0, 0, 800, 900],
        [800, 0, 800, 900],
      ])
      ..emit(ScreenEventKind.cursor, a: 1, data: Uint8List(0))
      ..emit(ScreenEventKind.bell);
    await pumpEventQueue();
    final said = [for (final c in r.backend.calls) if (c.$1 == id) c];
    expect(said.every((c) => c.$2 == kScreenWindowEventMethod), isTrue);
    final events = [for (final c in said) decodeScreenWindowEvent(c.$3)];
    expect(events.map((e) => e.runtimeType).toList(), [ScreenResized, ScreenDisplaysChanged, ScreenCursor, ScreenBell]);
    expect(said.any((c) => '${c.$3}'.contains('secret')), isFalse);
    await r.windows.closeAll();
    r.session.close();
  });

  test('brought back: the window closes, the tab is told, nothing more is passed on', () async {
    final r = _Rig();
    await r.windows.open(r.session, r.payload());
    final id = r.backend.payloads.keys.single;
    await r.windows.bringBack('s1');
    expect(r.backend.closed, [id]);
    expect(r.windows.isShown('s1'), isFalse);
    expect(r.windows.shown.value, isEmpty);
    r.backend.calls.clear();
    r.engine.emit(ScreenEventKind.bell);
    await pumpEventQueue();
    expect(r.backend.calls, isEmpty);
    expect(r.session.isClosed, isFalse, reason: 'the session goes on in its tab');
    // Twice is once.
    await r.windows.bringBack('s1');
    expect(r.backend.closed, [id]);
    r.session.close();
  });

  test('the window asks to be brought back: only the window that shows the screen is heard', () async {
    final r = _Rig();
    await r.windows.open(r.session, r.payload());
    final id = r.backend.payloads.keys.single;
    await r.windows.handle(kScreenWindowBackMethod, 's1', id + 5);
    expect(r.windows.isShown('s1'), isTrue, reason: 'another window (an editor) cannot take a screen back');
    await r.windows.handle('screenWindowSomethingElse', 's1', id);
    expect(r.windows.isShown('s1'), isTrue);
    await r.windows.handle(kScreenWindowBackMethod, 'whatever it says', id);
    expect(r.windows.isShown('s1'), isFalse);
    expect(r.backend.closed, [id]);
    r.session.close();
  });

  test('closed with the button of the window itself, which tells nobody: noticed, and the screen is back in its tab',
      () async {
    final r = _Rig();
    await r.windows.open(r.session, r.payload());
    final id = r.backend.payloads.keys.single;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(r.windows.isShown('s1'), isTrue, reason: 'still open: still there');
    r.backend.open.remove(id);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(r.windows.isShown('s1'), isFalse);
    expect(r.session.isClosed, isFalse);
    // Nothing is watched once no screen has a window.
    final calls = r.backend.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(r.backend.calls, hasLength(calls));
    r.session.close();
  });

  test('the window says it is in front, and that its picture took the keyboard: the tab is told only while the window '
      'is in front by its own word, and only by the window that shows the screen', () async {
    final r = _Rig();
    await r.windows.open(r.session, r.payload());
    final id = r.backend.payloads.keys.single;
    var told = 0;
    r.windows.onWindowFocus('s1', () => told++);
    expect(r.windows.isFront('s1'), isFalse, reason: 'not in front until it says so');
    await r.windows.handle(kScreenWindowFocusMethod, 's1', id);
    expect(told, 0, reason: 'the keyboard taken by a window that is not in front moves nothing');

    await r.windows.handle(kScreenWindowFrontMethod, true, id + 5);
    expect(r.windows.isFront('s1'), isFalse, reason: 'another window cannot speak for this screen');
    for (final notYes in <Object?>[null, 'true', 1, 's1']) {
      await r.windows.handle(kScreenWindowFrontMethod, notYes, id);
      expect(r.windows.isFront('s1'), isFalse, reason: 'only a plain yes counts: $notYes');
    }
    expect(told, 0);

    await r.windows.handle(kScreenWindowFrontMethod, true, id);
    expect(r.windows.isFront('s1'), isTrue);
    expect(told, 1, reason: 'coming to the front is a moment to send the clipboard');
    await r.windows.handle(kScreenWindowFrontMethod, true, id);
    expect(told, 1, reason: 'said again: nothing new');
    await r.windows.handle(kScreenWindowFocusMethod, 's1', id + 5);
    expect(told, 1, reason: 'another window cannot speak for this screen');
    await r.windows.handle(kScreenWindowFocusMethod, 'another session it names', id);
    expect(told, 2, reason: 'the window is who it is, whatever it says');

    await r.windows.handle(kScreenWindowFrontMethod, false, id);
    expect(r.windows.isFront('s1'), isFalse);
    await r.windows.handle(kScreenWindowFocusMethod, 's1', id);
    expect(told, 2);

    r.windows.onWindowFocus('s1', null);
    await r.windows.handle(kScreenWindowFrontMethod, true, id);
    expect(told, 2);
    expect(r.windows.isShown('s1'), isTrue, reason: 'neither brings anything back');
    // Back in its tab: no window, so none in front; a new window starts not in front.
    await r.windows.bringBack('s1');
    expect(r.windows.isFront('s1'), isFalse);
    await r.windows.open(r.session, r.payload());
    expect(r.windows.isFront('s1'), isFalse);
    expect(r.windows.isFront('no such session'), isFalse);
    await r.windows.closeAll();
    r.session.close();
  });

  test('the session ends: the window is told why, and goes', () async {
    final r = _Rig();
    await r.windows.open(r.session, r.payload());
    final id = r.backend.payloads.keys.single;
    r.engine.closeWith('server_closed', 'the server closed the connection');
    await pumpEventQueue();
    final closed = [for (final c in r.backend.calls) decodeScreenWindowEvent(c.$3)].whereType<ScreenClosed>().single;
    expect(closed.reason, ScreenCloseReason.serverClosed);
    expect(r.backend.closed, [id]);
    expect(r.windows.isShown('s1'), isFalse);
  });

  test('no window for a session that has ended, for a reader, or for the number of another session', () async {
    final r = _Rig();
    final reader = ScreenSession.reader(r.session.handle, protocol: ScreenProtocol.rdp, native: r.native);
    expect(await r.windows.open(reader, r.payload()), isFalse, reason: 'only the owner opens a window');
    reader.close();
    expect(
        await r.windows.open(r.session,
            ScreenWindowPayload(sessionId: 's1', handle: r.session.handle + 1, protocol: ScreenProtocol.rdp)),
        isFalse);
    r.session.close();
    expect(await r.windows.open(r.session, r.payload()), isFalse);
    expect(r.backend.payloads, isEmpty);
  });

  test('a window that cannot be opened: the screen stays in its tab', () async {
    final r = _Rig();
    r.backend.failCreate = StateError('no window');
    expect(await r.windows.open(r.session, r.payload()), isFalse);
    expect(r.windows.isShown('s1'), isFalse);
    expect(r.windows.shown.value, isEmpty);
    r.session.close();
  });

  test('every screen back in its tab at once', () async {
    final r = _Rig();
    final other = ScreenSession.open(const ScreenConnectOptions.vnc(), native: r.native);
    r.native.sessions.last.connect();
    await r.windows.open(r.session, r.payload());
    await r.windows.open(
        other, ScreenWindowPayload(sessionId: 's2', handle: other.handle, protocol: ScreenProtocol.vnc),
        at: const Offset(300, 200));
    expect(r.windows.shown.value, {'s1', 's2'});
    await r.windows.closeAll();
    expect(r.windows.shown.value, isEmpty);
    expect(r.backend.closed, hasLength(2));
    r.session.close();
    other.close();
  });
}
