// A screen in a window of its own (4.0), the window's side, over the
// fake engine and with the app's windows played: it shows the session's
// picture through a view, sends its keys by the session's number, takes what
// the main window passes on, asks to be brought back, and never ends the
// session.
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/features/screens/window/screen_window_app.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/pop_out_window_guard.dart';

import '../view/screen_view_fixture.dart';
import 'fake_window_backend.dart';

const _windowId = 7;

class _Rig {
  _Rig(this.native, this.owner, this.engine, this.backend, this.locked);
  final FakeScreenNative native;
  final ScreenSession owner;
  final FakeScreenSession engine;
  final FakeWindowBackend backend;
  final ValueNotifier<bool> locked;

  /// Each time the window was asked to fill its monitor (true) or be a window again.
  final fullScreens = <bool>[];

  int get view => engine.views.keys.single;

  void frame(Color color, {int seq = 1}) {
    engine.viewFrames[view] = [
      ScreenFrame(seq: seq, width: 800, height: 500, updates: 1, tiles: [tile(0, 0, 8, 8, color)]),
    ];
  }

  List<(int, String, Object?)> get toMain => [for (final c in backend.calls) if (c.$1 == 0) c];

  /// The times it said its picture took the keyboard.
  List<(int, String, Object?)> get focuses => [for (final c in toMain) if (c.$2 == kScreenWindowFocusMethod) c];

  /// What it said of being in front.
  List<(int, String, Object?)> get fronts => [for (final c in toMain) if (c.$2 == kScreenWindowFrontMethod) c];

  /// The times it asked to be brought back.
  List<(int, String, Object?)> get backs => [for (final c in toMain) if (c.$2 == kScreenWindowBackMethod) c];
}

Future<_Rig> _pump(
  WidgetTester tester, {
  bool viewOnly = false,
  bool locked = false,
  String locale = 'en',
  Size size = const Size(900, 640),
}) async {
  final native = FakeScreenNative();
  final owner = ScreenSession.open(const ScreenConnectOptions.rdp(), native: native);
  final engine = native.sessions.single;
  engine.connect(name: 'office-pc', width: 800, height: 500);
  await tester.pump();
  final backend = FakeWindowBackend();
  final lock = ValueNotifier(locked);
  final rig = _Rig(native, owner, engine, backend, lock);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  addTearDown(() async {
    owner.close();
  });
  await tester.pumpWidget(screenWindowApp(
    windowId: _windowId,
    payload: ScreenWindowPayload(
      sessionId: 's1',
      handle: owner.handle,
      protocol: ScreenProtocol.rdp,
      info: const {'protocol': 'rdp', 'width': 800, 'height': 500},
      viewOnly: viewOnly,
    ),
    raw: {'locale': locale},
    backend: backend,
    locked: lock,
    onActivity: () {},
    native: native,
    decodeTile: syncDecode,
    setFullScreen: (on) async => rig.fullScreens.add(on),
  ));
  await tester.pump();
  return rig;
}

ScreenController _controller(WidgetTester tester) =>
    tester.widget<ScreenView>(find.byKey(const ValueKey('screen-window-view'))).controller;

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('it shows the picture of the session through a view of its own, and never the frames of the tab',
      (tester) async {
    final r = await _pump(tester);
    final c = _controller(tester);
    expect(c.session.isReader, isTrue);
    expect(c.hasPicture, isFalse);
    r.frame(const Color(0xFF204060));
    // One the session keeps for its own reader (the tab): not this window's.
    r.engine.frames.add(ScreenFrame(seq: 9, width: 800, height: 500, updates: 1, tiles: [tile(0, 0, 8, 8, const Color(0xFFFF0000))]));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(c.hasPicture, isTrue);
    expect(c.framesShown, 1);
    expect(r.engine.frames, hasLength(1));
    expect((r.engine.pauses, r.engine.resumes), (0, 0), reason: 'whether the server sends is for the owner to say');
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('keys go to the session by its number', (tester) async {
    final r = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(r.engine.keys.map((k) => (k.$1, k.$3)).toList(), [
      (0x61, true),
      (0x61, false),
    ]);
    await _close(tester);
  });

  testWidgets('the menu key opens the session panel of the window: what a window does by itself, and nothing of '
      'the tab', (tester) async {
    final r = await _pump(tester);
    final c = _controller(tester);
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(r.engine.keys, isEmpty, reason: 'the menu key never reaches the remote');
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    Future<void> pick(String id) async {
      final row = find.byKey(ValueKey('screen-panel-$id'));
      await tester.scrollUntilVisible(row, 150, scrollable: list);
      await tester.pumpAndSettle();
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    for (final never in const ['disconnect', 'ownWindow']) {
      expect(find.byKey(ValueKey('screen-panel-$never')), findsNothing, reason: never);
    }

    // A scaling: the picture here, and the panel stays to show it.
    await pick('fill');
    expect(c.fit, ScreenFit.fill);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);

    // Text size on the remote: asked, and the remote is told by the session's number.
    await pick('textSize');
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('screen-text-size-question-150')));
    await tester.pumpAndSettle();
    expect(c.textScale, 150);
    expect(r.engine.layouts.single.single['scale'], 150);

    // A frame rate limit, for this window.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await pick('frameLimit');
    await tester.tap(find.byKey(const ValueKey('screen-frame-limit-question-30')));
    await tester.pumpAndSettle();
    expect(c.frameLimit, 30);

    // A refresh goes to the session; the panel closes for it.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await pick('refresh');
    expect(r.engine.fullRefreshes, 1);
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);

    // View only from the panel: no key goes any more, and the bar loses its Ctrl+Alt+Del.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-viewOnly')), -150, scrollable: list);
    await pick('viewOnly');
    expect(c.viewOnly, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-window-ctrl-alt-del')), findsNothing);
    expect(r.engine.closed, isFalse);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('Ctrl+Alt+Del from the bar; a screen that is only looked at has no such button and sends no key',
      (tester) async {
    final r = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('screen-window-ctrl-alt-del')));
    await tester.pump();
    expect(r.engine.keys, hasLength(6));
    expect(r.engine.keys.where((k) => k.$3).map((k) => k.$1).toList(), [0xffe3, 0xffe9, 0xffff]);
    await _close(tester);

    final only = await _pump(tester, viewOnly: true);
    expect(find.byKey(const ValueKey('screen-window-ctrl-alt-del')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(only.engine.keys, isEmpty);
    expect(only.engine.pointers, isEmpty);
    await _close(tester);
  });

  testWidgets('full screen: the window fills its monitor, the bar goes, a line names the menu key for a few '
      'seconds; the panel leaves it, and the bar is back', (tester) async {
    final r = await _pump(tester);
    expect(find.byKey(const ValueKey('screen-window-bar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-window-full-screen')));
    await tester.pump();
    await tester.pump();
    expect(r.fullScreens, [true]);
    expect(find.byKey(const ValueKey('screen-window-bar')), findsNothing);
    expect(find.byKey(const ValueKey('screen-window-full-screen-hint')), findsOneWidget);
    expect(find.text('F8'), findsOneWidget, reason: 'the key, drawn as a key');
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('screen-window-full-screen-hint')), findsNothing);

    // The menu key: the panel has the way out at its top.
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.text('Exit full screen'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-panel-fullScreen')));
    await tester.pumpAndSettle();
    expect(r.fullScreens, [true, false]);
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(find.byKey(const ValueKey('screen-window-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-window-full-screen-hint')), findsNothing);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('full screen: the pointer at the top edge brings a bar with Exit full screen, the menu and the way back '
      'to the tab; Exit leaves, and so does Ctrl+Alt+Break', (tester) async {
    final r = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('screen-window-full-screen')));
    await tester.pump();
    await tester.pump();
    expect(r.fullScreens, [true]);
    final bar = find.byKey(const ValueKey('screen-full-screen-bar'));
    expect(bar, findsNothing);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: const Offset(450, 320));
    addTearDown(g.removePointer);
    await tester.pump();
    await g.moveTo(const Offset(450, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(bar, findsOneWidget);
    expect(find.byKey(const ValueKey('screen-full-screen-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-full-screen-disconnect')), findsNothing, reason: "the tab's to end");
    expect(find.byKey(const ValueKey('screen-full-screen-title')), findsNothing, reason: 'this window is never told the name');
    await tester.tap(find.byKey(const ValueKey('screen-full-screen-exit')));
    await tester.pump();
    await tester.pump();
    expect(r.fullScreens, [true, false]);
    expect(find.byKey(const ValueKey('screen-window-bar')), findsOneWidget);

    // Into full screen again, and out by the keys.
    await tester.tap(find.byKey(const ValueKey('screen-window-full-screen')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pause);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pause);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(r.fullScreens, [true, false, true, false]);
    expect(find.byKey(const ValueKey('screen-window-bar')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('full screen: the handle on the edge the panel comes from sits in the room beside the picture, never over '
      'it, and opens the session panel; on the left in a right-to-left language', (tester) async {
    for (final (locale, rtl) in [('en', false), ('ar', true)]) {
      final r = await _pump(tester, locale: locale);
      final handle = find.byKey(const ValueKey('screen-full-screen-handle'));
      expect(handle, findsNothing, reason: 'full screen only');
      await tester.tap(find.byKey(const ValueKey('screen-window-full-screen')));
      await tester.pump();
      await tester.pump();
      expect(r.fullScreens, [true]);
      final c = _controller(tester);
      final view = find.byKey(const ValueKey('screen-window-view'));
      final picture = c.viewport.pictureRect.shift(tester.getTopLeft(view));
      expect(picture.size, const Size(800, 500), reason: '$locale: the remote at its own size in 900 x 640');
      final at = tester.getRect(handle);
      if (rtl) {
        expect(at.left, 0, reason: 'ar: on the left edge');
        expect(at.right, lessThanOrEqualTo(picture.left), reason: 'ar: beside the picture, not over it');
      } else {
        expect(at.right, 900, reason: 'en: on the right edge');
        expect(at.left, greaterThanOrEqualTo(picture.right), reason: 'en: beside the picture, not over it');
      }
      expect(at.size, const Size(16, 56));
      // The keyboard's first stop where the picture does not hold it.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(Focus.of(tester.element(find.descendant(of: handle, matching: find.byType(AnimatedOpacity)))).hasPrimaryFocus,
          isTrue, reason: locale);
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: locale);
      expect(r.engine.keys, isEmpty, reason: 'nothing of it reached the remote');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
      expect(tester.takeException(), isNull);
      await _close(tester);
    }
  });

  testWidgets("the bar's options button opens the screen options, as the menu key does, named with the key",
      (tester) async {
    await _pump(tester);
    expect(find.byTooltip('Screen menu (F8)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-window-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('the picture taking the keyboard is said to the main window, once a time, and not by a screen that '
      'is only looked at', (tester) async {
    final r = await _pump(tester);
    // (The picture has the keyboard as the window opens.)
    await tester.pump();
    expect(r.focuses, [(0, kScreenWindowFocusMethod, 's1')]);
    // Still held: not said again. Given away and taken again: said again.
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    expect(r.focuses, hasLength(1));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    expect(r.focuses, [(0, kScreenWindowFocusMethod, 's1'), (0, kScreenWindowFocusMethod, 's1')]);
    await _close(tester);

    final only = await _pump(tester, viewOnly: true);
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    expect(only.focuses, isEmpty);
    await _close(tester);
  });

  testWidgets('the window says whether it is in front: at its start, before its picture can take the keyboard, and at '
      'every change, once each', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final r = await _pump(tester);
    await tester.pump();
    // Not in front as it opens here, and said first of all.
    expect(r.toMain.first, (0, kScreenWindowFrontMethod, false));
    expect(r.fronts, [(0, kScreenWindowFrontMethod, false)]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(r.fronts.last, (0, kScreenWindowFrontMethod, true));
    expect(r.fronts, hasLength(2));
    // Behind another program, hidden, minimised: each is not in front, said once.
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      expect(r.fronts.last, (0, kScreenWindowFrontMethod, false), reason: '$state');
      expect(r.fronts, hasLength(3), reason: '$state');
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(r.fronts.last, (0, kScreenWindowFrontMethod, true));
    expect(r.fronts, hasLength(4));
    // A screen that is only looked at says it too: what the remote copies may be taken while it is in front.
    await _close(tester);
    final only = await _pump(tester, viewOnly: true);
    await tester.pump();
    expect(only.fronts, [(0, kScreenWindowFrontMethod, true)]);
    await _close(tester);
  });

  testWidgets('Bring it back asks the main window, once, naming the tab', (tester) async {
    final r = await _pump(tester);
    expect(find.text('Bring it back'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-window-back')));
    await tester.tap(find.byKey(const ValueKey('screen-window-back')));
    await tester.pump();
    expect(r.backs, [(0, kScreenWindowBackMethod, 's1')]);
    expect(r.owner.isClosed, isFalse);
    await _close(tester);
  });

  testWidgets('what the main window passes on reaches the picture: the displays; and why the session ended, after '
      'which the window asks to go', (tester) async {
    final r = await _pump(tester);
    final c = _controller(tester);
    expect(c.displays.value.several, isFalse);
    await answerScreenWindowCall(
        _windowId,
        kScreenWindowEventMethod,
        encodeScreenWindowEvent(const ScreenResized(1600, 900)));
    await answerScreenWindowCall(
        _windowId,
        kScreenWindowEventMethod,
        encodeScreenWindowEvent(
            const ScreenDisplaysChanged([ScreenDisplayRect(0, 0, 800, 900), ScreenDisplayRect(800, 0, 800, 900)])));
    await tester.pump();
    expect(c.displays.value.several, isTrue);
    // Something that is no event of a screen: nothing happens.
    await answerScreenWindowCall(_windowId, kScreenWindowEventMethod, 'not json');
    await answerScreenWindowCall(_windowId, 'somethingElse', null);
    expect(r.backs, isEmpty);

    await answerScreenWindowCall(
        _windowId,
        kScreenWindowEventMethod,
        encodeScreenWindowEvent(const ScreenClosed(ScreenCloseReason.serverClosed, 'the server closed the connection')));
    await tester.pump();
    expect(c.session.isClosed, isTrue);
    expect(r.backs, [(0, kScreenWindowBackMethod, 's1')]);
    expect(r.engine.closed, isFalse, reason: 'a window never ends the session');
    await _close(tester);
  });

  testWidgets('the window goes: its view is let go, the session runs on, and it answers no more calls', (tester) async {
    final r = await _pump(tester);
    expect(r.engine.views, hasLength(1));
    await _close(tester);
    expect(r.engine.views, isEmpty);
    expect(r.engine.closed, isFalse);
    expect(r.owner.isClosed, isFalse);
    expect(await answerScreenWindowCall(_windowId, kScreenWindowEventMethod, '{}'), isNull);
  });

  testWidgets('the session is gone before the window is up: it asks to go at once', (tester) async {
    final native = FakeScreenNative();
    final backend = FakeWindowBackend();
    await tester.pumpWidget(screenWindowApp(
      windowId: _windowId,
      payload: const ScreenWindowPayload(sessionId: 's9', handle: 4242, protocol: ScreenProtocol.vnc),
      raw: const {},
      backend: backend,
      locked: ValueNotifier(false),
      onActivity: () {},
      native: native,
      decodeTile: syncDecode,
    ));
    await tester.pump();
    expect([for (final c in backend.calls) if (c.$1 == 0 && c.$2 == kScreenWindowBackMethod) c],
        [(0, kScreenWindowBackMethod, 's9')]);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('the app lock covers the window, as every window of its own', (tester) async {
    final r = await _pump(tester, locked: true);
    expect(tester.widget<PopOutWindowGuard>(find.byType(PopOutWindowGuard)).locked.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(r.engine.keys, isEmpty);
    await _close(tester);
  });

  testWidgets('the app locks with the session panel open: the cover is over the panel too, nothing in it can be '
      'used, the keys held are let go and the window stops reading the picture; unlocked, it goes on', (tester) async {
    final r = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('screen-window-view')));
    await tester.pump();
    // A key held as the lock comes: the remote must not keep it down.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.pump();
    final downs = r.engine.keys.length;
    expect(downs, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    expect(_controller(tester).session.isPaused, isFalse);

    r.locked.value = true;
    await tester.pumpAndSettle();
    final cover = find.byKey(const ValueKey('pop-out-locked'));
    expect(cover, findsOneWidget);
    expect(_controller(tester).session.isPaused, isTrue, reason: 'nothing of the picture is read while the app is locked');
    expect(r.owner.isPaused, isFalse, reason: 'whether the server sends is the main window' 's to say');
    // The panel is still built under the cover, and out of reach: a click where a row of it is lands on
    // the cover, and no key reaches it or the remote.
    final panel = find.byKey(const ValueKey('screen-panel'));
    expect(panel, findsOneWidget);
    final sent = r.engine.keys.length;
    final at = tester.getCenter(panel);
    final hit = tester.hitTestOnBinding(at);
    expect(hit.path.any((e) => e.target == tester.renderObject(cover)), isTrue,
        reason: 'the cover is what a click meets');
    final box = tester.getRect(panel);
    for (var y = box.top + 30; y < box.bottom; y += 44) {
      await tester.tapAt(Offset(box.center.dx, y));
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    final after = r.engine.keys.sublist(sent);
    expect(after.where((k) => k.$3), isEmpty, reason: 'no key goes down on the remote while the app is locked');
    expect(_controller(tester).viewOnly, isFalse, reason: 'no switch of the panel was reached');
    // Every key that was down when the lock came has been let go.
    final down = <int>{};
    for (final k in r.engine.keys) {
      k.$3 ? down.add(k.$1) : down.remove(k.$1);
    }
    expect(down, isEmpty, reason: 'nothing is left held on the remote');

    r.locked.value = false;
    await tester.pumpAndSettle();
    expect(cover, findsNothing);
    expect(_controller(tester).session.isPaused, isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await _close(tester);
  });

  testWidgets('what the main window passes on is heard; the same from another window of the app is not', (tester) async {
    final r = await _pump(tester);
    final closed = encodeScreenWindowEvent(const ScreenClosed(ScreenCloseReason.serverClosed, 'gone'))!;
    await answerScreenWindowCall(_windowId, kScreenWindowEventMethod, closed, from: _windowId + 3);
    await tester.pump();
    expect(r.backs, isEmpty, reason: 'another window cannot end this one' 's view');
    await answerScreenWindowCall(_windowId, kScreenWindowEventMethod, closed);
    await tester.pump();
    expect(r.backs, hasLength(1));
    await _close(tester);
  });

  testWidgets('a window that opens while the app is locked: covered, and it reads nothing of the picture', (tester) async {
    final r = await _pump(tester, locked: true);
    expect(find.byKey(const ValueKey('pop-out-locked')), findsOneWidget);
    expect(_controller(tester).session.isPaused, isTrue);
    r.locked.value = false;
    await tester.pumpAndSettle();
    expect(_controller(tester).session.isPaused, isFalse);
    expect(r.owner.isClosed, isFalse);
    await _close(tester);
  });

  testWidgets('the bar in every language on a narrow window: nothing overflows', (tester) async {
    for (final locale in AppLocalizations.supportedLocales) {
      await _pump(tester, locale: locale.languageCode, size: const Size(420, 400));
      final l10n = lookupAppLocalizations(locale);
      expect(find.text(l10n.screenBringBack), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale');
      await _close(tester);
    }
  });
}
