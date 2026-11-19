import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/screens/window/screen_window_app.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/view_windows.dart';
import 'package:zestssh/ui/windows/editor_window.dart' show editorWindowHandlers;

/// On Windows a remote screen's window of its own is a view of the main
/// window's engine (no second engine racing the first in the graphics
/// driver): the runner opens the window and its view, the main app draws the
/// screen's window app into it, the calls between the tab and the window go
/// straight across, and a window closes only once nothing is drawn in it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/view_windows');
  late List<MethodCall> calls;
  late Map<String, Object?> openAnswer;

  setUp(() {
    calls = [];
    openAnswer = {'id': 1000, 'viewId': 7};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'open' ? openAnswer : null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    screenWindowHandlers.clear();
    editorWindowHandlers.clear();
  });

  String payload() => jsonEncode({
        ...const ScreenWindowPayload(sessionId: 's1', handle: 42, protocol: ScreenProtocol.rdp).toJson(),
        'locale': 'en',
      });

  testWidgets('a window: opened by the runner, its view found, the screen\'s window app drawn into it, placed and '
      'made full screen by its id', (tester) async {
    final windows = ViewWindows(channel: channel, viewOf: (id) => id == 7 ? tester.view : null);
    final backend = ViewWindowsBackend(windows);
    final id = await backend.createWindow(payload());
    expect(id, 1000);
    expect(calls.first.method, 'open');
    expect(windows.windows.value.keys, [1000]);
    expect(windows.windows.value[1000]!.view, tester.view);
    expect(await backend.windowIds(), [1000]);

    await backend.place(id, const Rect.fromLTWH(10, 20, 1100, 720), 'ZestSSH');
    expect(calls.last.method, 'place');
    expect(calls.last.arguments, {'id': 1000, 'x': 10, 'y': 20, 'width': 1100, 'height': 720, 'title': 'ZestSSH'});

    await windows.fullScreen(id, true);
    expect(calls.last.method, 'fullScreen');
    expect(calls.last.arguments, {'id': 1000, 'on': true});
  });

  testWidgets('the tab\'s calls reach the window\'s own handler, here', (tester) async {
    final windows = ViewWindows(channel: channel, viewOf: (id) => tester.view);
    final backend = ViewWindowsBackend(windows);
    final id = await backend.createWindow(payload());
    final heard = <(String, Object?)>[];
    screenWindowHandlers[id] = (method, arguments) async {
      heard.add((method, arguments));
      return 'ok';
    };
    expect(await backend.invoke(id, kScreenWindowEventMethod, 'x'), 'ok');
    expect(heard, [(kScreenWindowEventMethod, 'x')]);
    expect(await backend.invoke(id + 1, kScreenWindowEventMethod, 'x'), isNull, reason: 'no such window');
  });

  testWidgets('closed (by the app, or by its person with the window\'s own button): out of the tree first, then '
      'the runner closes the view and the window', (tester) async {
    final windows = ViewWindows(channel: channel, viewOf: (id) => tester.view);
    final backend = ViewWindowsBackend(windows);
    final id = await backend.createWindow(payload());
    final closing = backend.close(id);
    expect(windows.windows.value, isEmpty, reason: 'out of what is drawn at once');
    expect(calls.where((c) => c.method == 'close'), isEmpty, reason: 'not before the frame is drawn');
    await tester.pump();
    await closing;
    expect(calls.last.method, 'close');
    expect(calls.last.arguments, {'id': id});
    expect(await backend.windowIds(), isEmpty);

    // The window's own close button: the runner asks, and the same happens.
    openAnswer = {'id': 1001, 'viewId': 7};
    final second = await backend.createWindow(payload());
    // (Not waited for: closing waits for the frame the pumps draw.)
    final asked = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('closeRequested', {'id': 1001})),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
    await asked;
    expect(windows.windows.value.containsKey(second), isFalse);
    expect(calls.last.method, 'close');
    expect(calls.last.arguments, {'id': 1001});
  });

  testWidgets('closed twice at once (its X while the session ends): one close, after the frame without it', (tester) async {
    final windows = ViewWindows(channel: channel, viewOf: (id) => tester.view);
    final backend = ViewWindowsBackend(windows);
    final id = await backend.createWindow(payload());
    final first = backend.close(id);
    final second = backend.close(id);
    expect(calls.where((c) => c.method == 'close'), isEmpty, reason: 'the second waits for the first');
    await tester.pump();
    await first;
    await second;
    expect(calls.where((c) => c.method == 'close').length, 1);
  });

  testWidgets("an editor's window of its own is a view too: the main window's calls reach its handler, and its own "
      "calls reach the main window's handler with its id", (tester) async {
    final windows = ViewWindows(channel: channel, viewOf: (id) => tester.view);
    final asked = <(String, Object?, int)>[];
    windows.mainCall = (method, arguments, from) async {
      asked.add((method, arguments, from));
      return 'from main';
    };
    final backend = ViewWindowsBackend(windows);
    final id = await backend.createWindow(jsonEncode({'type': 'editor', 'editKey': 'k1', 'locale': 'en'}));
    expect(windows.windows.value.keys, [id]);
    final heard = <String>[];
    editorWindowHandlers[id] = (method, arguments) async {
      heard.add(method);
      return 'editor';
    };
    screenWindowHandlers[id] = (method, arguments) async => 'screen';
    expect(await backend.invoke(id, 'editorAddTab', '{}'), 'editor', reason: 'to the editor, not a screen');
    expect(heard, ['editorAddTab']);

    // A screen window opened beside it still answers as a screen.
    openAnswer = {'id': 1001, 'viewId': 7};
    final screen = await backend.createWindow(payload());
    screenWindowHandlers[screen] = (method, arguments) async => 'screen';
    expect(await backend.invoke(screen, kScreenWindowEventMethod, 'x'), 'screen');

    // The window's own calls (its link to the main window) go to the main window's handler.
    final view = windows.windows.value[id]!.child;
    expect(view, isNotNull);
    expect(asked, isEmpty);
    final closing = backend.close(id);
    await tester.pump();
    await closing;
    expect(await backend.windowIds(), [screen]);
  });

  testWidgets("an editor's window reads providers of its own, not the main window's (its tabs are its own)",
      (tester) async {
    final counter = StateProvider<int>((ref) => 0);
    final main = ProviderContainer(overrides: [counter.overrideWith((ref) => 7)]);
    addTearDown(main.dispose);
    int? read;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: main,
      child: ProvidersOfItsOwn(
        child: Consumer(builder: (context, ref, _) {
          read = ref.watch(counter);
          return const SizedBox();
        }),
      ),
    ));
    expect(read, 0, reason: "a fresh provider, not the main window's 7");
  });

  testWidgets('a view that never comes: the window is closed again and opening fails', (tester) async {
    final windows = ViewWindows(channel: channel, viewOf: (id) => null);
    await tester.runAsync(() async {
      await expectLater(ViewWindowsBackend(windows).createWindow(payload()), throwsStateError);
    });
    expect(calls.last.method, 'close');
    expect(windows.windows.value, isEmpty);
  });
}
