// A remote screen's full screen on a computer (4.0): the window goes
// into the system's own full screen and the picture alone is drawn over
// everything the window shows. It only filled the tab's place before, with
// the app's bars, tabs and side bar still around it. The way out: the bar at
// the top edge, the session panel, Ctrl+Alt+Break. The window here is a
// fake that notes what was asked of it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/desktop/screen_pane.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/model/screen_view_size.dart';
import 'package:zestssh/features/screens/view/screen_full_screen.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/window_service.dart';

import '../features/screens/screen_clipboard_test.dart' show FakeClipboardIo;
import '../features/screens/view/screen_view_fixture.dart';

class _Trust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;
  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => true;
  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

const _window = Size(1400, 900);

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late FakeScreenNative native;
  late SharedPreferences prefs;

  /// What was asked of the window, in order: true into full screen, false out of it.
  late List<bool> asked;

  setUp(() async {
    native = FakeScreenNative();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    asked = [];
    ScreenPane.debugDecodeTile = syncDecode;
    ScreenPane.debugClipboard = FakeClipboardIo();
    ScreenPane.debugSetWindowFullScreen = (on) async => asked.add(on);
    WindowService.fullscreen.value = false;
  });
  tearDown(() {
    ScreenPane.debugDecodeTile = null;
    ScreenPane.debugClipboard = null;
    ScreenPane.debugSetWindowFullScreen = null;
    WindowService.fullscreen.value = false;
  });

  Future<(ScreenShellService, FakeScreenSession)> connectScreen(WidgetTester tester,
      {ScreenOptions options = ScreenOptions.defaults, ScreenProtocol protocol = ScreenProtocol.vnc}) async {
    final toServer = StreamController<List<int>>();
    final fromServer = StreamController<Uint8List>();
    addTearDown(() {
      unawaited(toServer.close());
      unawaited(fromServer.close());
    });
    final shell = ScreenShellService(
      target: const DirectTlsTarget('192.0.2.30', 5900),
      trust: _Trust(),
      native: native,
      options: options,
      protocol: protocol,
      inTeam: false,
      connectionId: 'c-desk',
      openDirect: (_, _) async => ScreenChannel(fromServer.stream, toServer.sink),
    );
    final connecting = shell.connect();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      if (native.sessions.isNotEmpty) break;
    }
    final engine = native.sessions.single;
    engine.connect(name: 'demo-desktop', width: 800, height: 500);
    await tester.pump();
    await connecting;
    return (shell, engine);
  }

  /// The pane in a window with what the app draws around a tab: a side bar,
  /// the tabs above, a status bar below.
  Future<void> pumpPane(WidgetTester tester, ScreenShellService shell, {bool recording = false, bool front = true}) async {
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-desk',
      connectionLabel: 'Demo desktop',
      session: TerminalSession(
        id: 's1',
        connectionId: 'c-desk',
        terminal: Terminal(),
        shell: shell,
        startedAt: DateTime(2026, 11, 8),
      ),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: 220, child: Text('the side bar', key: ValueKey('chrome-side'))),
              Expanded(
                child: Column(
                  children: [
                    const SizedBox(height: 40, child: Text('the tabs', key: ValueKey('chrome-tabs'))),
                    Expanded(child: ScreenPane(sessionId: 's1', sessionState: state, front: front, visible: front)),
                    const SizedBox(height: 24, child: Text('the status bar', key: ValueKey('chrome-status'))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  final layer = find.byKey(const ValueKey('screen-full-screen'));
  final view = find.byType(ScreenView);
  final toolbarButton = find.byKey(const ValueKey('screen-toolbar-fullScreen'));
  final bar = find.byKey(const ValueKey('screen-full-screen-bar'));

  Future<void> enter(WidgetTester tester) async {
    await tester.tap(toolbarButton);
    await tester.pump();
    await tester.pump();
  }

  /// A mouse, at [at] to start with.
  Future<TestGesture> mouse(WidgetTester tester, Offset at) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at);
    addTearDown(g.removePointer);
    await tester.pump();
    return g;
  }

  testWidgets('Full screen: the window is asked for the system\'s full screen, and the picture alone is over the whole '
      'window, the same view moved there; Ctrl+Alt+Break leaves it and the window is put back', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpPane(tester, shell);
    expect(layer, findsNothing);
    final inTab = tester.getRect(view);
    expect(inTab.left, greaterThanOrEqualTo(220), reason: 'in its tab, beside the side bar');
    final viewState = tester.state(view);

    await enter(tester);
    expect(asked, [true]);
    expect(layer, findsOneWidget);
    expect(tester.getRect(layer), Offset.zero & _window, reason: 'over everything the window shows');
    expect(tester.getRect(view), Offset.zero & _window, reason: 'the picture has the whole of it');
    expect(find.descendant(of: layer, matching: view), findsOneWidget);
    expect(identical(tester.state(view), viewState), isTrue, reason: 'the same view, not one made anew');
    // What the app draws around a tab is under it: a press there reaches none of it.
    for (final key in ['chrome-side', 'chrome-tabs', 'chrome-status']) {
      expect(find.byKey(ValueKey(key)).hitTestable(), findsNothing, reason: key);
    }
    expect(toolbarButton.hitTestable(), findsNothing, reason: "the tab's own toolbar too");
    // How to get out is said, for a few seconds.
    expect(find.text(en.screenFullScreenHint('F8', en.screenFullScreenExitKeys)), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('screen-full-screen-hint')), findsNothing);

    // Esc is the remote's, as every key but the ways out.
    engine.keys.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(engine.keys.map((k) => k.$1), [0xff1b, 0xff1b]);
    expect(layer, findsOneWidget);

    // Ctrl+Alt+Break: out, and Break itself never reaches the remote.
    engine.keys.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pause);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pause);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(asked, [true, false], reason: 'the window is taken out of the full screen this put it in');
    expect(layer, findsNothing);
    expect(tester.getRect(view), inTab, reason: 'back in its tab, where it was');
    expect(identical(tester.state(view), viewState), isTrue);
    expect(engine.keys.where((k) => k.$1 == 0xff13), isEmpty, reason: 'Pause was not sent');
    expect(toolbarButton.hitTestable(), findsOneWidget);
    // Outside full screen the same keys are the remote's again.
    engine.keys.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pause);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pause);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(asked, [true, false]);
    expect(engine.keys.where((k) => k.$1 == 0xff13), isNotEmpty);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('the bar at the top edge: it comes down as the pointer touches the edge, names the host, and has Exit '
      'full screen, the menu and Disconnect; it goes when the pointer leaves it; Exit leaves', (tester) async {
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    expect(bar, findsNothing, reason: 'the picture alone');

    final pointer = await mouse(tester, const Offset(700, 450));
    await pointer.moveTo(const Offset(700, 40));
    await tester.pump();
    expect(bar, findsNothing, reason: 'near the edge is not on it');
    await pointer.moveTo(const Offset(700, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(bar, findsOneWidget);
    expect(tester.getRect(bar).top, 0);
    expect(find.descendant(of: bar, matching: find.text('Demo desktop')), findsOneWidget);
    for (final key in ['screen-full-screen-exit', 'screen-full-screen-menu', 'screen-full-screen-disconnect']) {
      expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget, reason: key);
    }
    expect(find.descendant(of: bar, matching: find.text(en.screenExitFullScreen)), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text(en.terminalDisconnect)), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-full-screen-back')), findsNothing, reason: "a window of its own's");

    // Onto the bar it stays; off it, it goes after a moment.
    await pointer.moveTo(tester.getCenter(bar));
    await tester.pump(const Duration(seconds: 2));
    expect(bar, findsOneWidget);
    await pointer.moveTo(const Offset(700, 450));
    await tester.pump(const Duration(milliseconds: 300));
    expect(bar, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(bar, findsNothing);

    // Down again, and Exit full screen.
    await pointer.moveTo(const Offset(700, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('screen-full-screen-exit')));
    await tester.pump();
    await tester.pump();
    expect(asked, [true, false]);
    expect(layer, findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('the menu from the bar is the session panel, over the full screen, and its Exit full screen leaves',
      (tester) async {
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    final pointer = await mouse(tester, const Offset(700, 450));
    await pointer.moveTo(const Offset(700, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('screen-full-screen-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-panel-fullScreen')));
    await tester.pumpAndSettle();
    expect(asked, [true, false]);
    expect(layer, findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('the handle on the right edge: in the room beside the picture, never over it, faint until the pointer is '
      'on it, named Session menu, and it opens the session panel; a picture that fills the width keeps it to a slim '
      'edge', (tester) async {
    final semantics = tester.ensureSemantics();
    final handle = find.byKey(const ValueKey('screen-full-screen-handle'));
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    expect(handle, findsNothing, reason: 'full screen only');
    await enter(tester);
    final c = tester.widget<ScreenView>(view).controller;
    Rect picture() => c.viewport.pictureRect.shift(tester.getTopLeft(view));
    // Fit: the 800 x 500 remote at its own size, room on either side of it.
    expect(picture().size, const Size(800, 500));
    final at = tester.getRect(handle);
    expect(at.right, _window.width, reason: 'on the right edge of the monitor');
    expect(at.left, greaterThanOrEqualTo(picture().right), reason: 'in the room beside the picture, not over it');
    expect(at.size, const Size(ScreenFullScreenFrame.handleWidth, ScreenFullScreenFrame.handleHeight));
    expect(at.center.dy, closeTo(_window.height / 2, 1), reason: 'centred on the edge');

    // Faint until the pointer is on it.
    double opacity() =>
        tester.widget<AnimatedOpacity>(find.descendant(of: handle, matching: find.byType(AnimatedOpacity))).opacity;
    expect(opacity(), lessThan(0.5));
    final pointer = await mouse(tester, const Offset(700, 450));
    await pointer.moveTo(at.center);
    await tester.pump();
    expect(opacity(), 1);
    await pointer.moveTo(const Offset(700, 450));
    await tester.pump();
    expect(opacity(), lessThan(0.5));

    // A screen reader is told it, beside the picture's own name.
    expect(find.semantics.byLabel(en.screenSessionMenu), findsOne);
    expect(find.semantics.byLabel(en.screenViewLabel), findsOne);

    // It opens the session panel, over the full screen, which stays.
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')).hitTestable(), findsOneWidget);
    expect(layer, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);

    // The picture as wide as the monitor (Fill): a slim handle on the very edge.
    c.fit = ScreenFit.fill;
    await tester.pump();
    expect(picture().right, greaterThanOrEqualTo(_window.width - 0.5), reason: 'no room left beside it');
    final slim = tester.getRect(handle);
    expect(slim.right, _window.width);
    expect(slim.width, ScreenFullScreenFrame.handleSlim, reason: 'it covers no more than that of the picture');
    expect(find.descendant(of: handle, matching: find.byType(Icon)), findsNothing, reason: 'a line, no arrow');
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
    semantics.dispose();
  });

  testWidgets('a remote with two displays in full screen: no strip; a button for each and All beside the picture on '
      'the left, the one shown filled; Alt and a digit shows that display (with a Ctrl tap so the remote opens no menu); '
      'a picture that leaves no room there has them in the bar at the top edge, never over the picture', (tester) async {
    final (shell, engine) = await connectScreen(tester, protocol: ScreenProtocol.rdp);
    await pumpPane(tester, shell);
    final c = tester.widget<ScreenView>(view).controller;
    engine
      ..emit(ScreenEventKind.resize, a: (1600 << 32) | 500)
      ..displays([
        [0, 0, 800, 500],
        [800, 0, 800, 500],
      ]);
    await tester.pump();
    await tester.pump();
    c.showDisplay(0);
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-display-strip')), findsOneWidget, reason: 'in its tab');
    await enter(tester);
    expect(find.byKey(const ValueKey('screen-display-strip')), findsNothing, reason: 'not in full screen');
    final one = find.byKey(const ValueKey('screen-full-screen-display-0'));
    final two = find.byKey(const ValueKey('screen-full-screen-display-1'));
    final all = find.byKey(const ValueKey('screen-full-screen-display-all'));
    expect(one, findsOneWidget);
    expect(two, findsOneWidget);
    expect(all, findsOneWidget);
    Rect picture() => c.viewport.pictureRect.shift(tester.getTopLeft(view));
    expect(tester.getRect(one).right, lessThanOrEqualTo(picture().left), reason: 'beside the picture, not over it');
    expect(tester.getRect(one).left, greaterThan(0));
    expect(tester.getRect(two).top, greaterThan(tester.getRect(one).top), reason: 'down a column');
    expect(find.byTooltip('${en.screenDisplayName(2)} (Alt+2)'), findsOneWidget);

    await tester.tap(two);
    await tester.pump();
    expect(c.displays.value.shown, 1);
    await tester.tap(all);
    await tester.pump();
    expect(c.displays.value.shown, isNull);

    // Alt and a digit: caught before the remote has it.
    final sent = engine.keys.length;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(c.displays.value.shown, 0);
    expect([for (final k in engine.keys.skip(sent)) k.$1], isNot(contains(0x31)), reason: 'the 1 never reached the remote');

    // Alt went to the remote as it went down: a Ctrl tap before it is let
    // go, so the remote's window does not open its menu bar.
    final after = [for (final k in engine.keys.skip(sent)) (k.$1, k.$3)];
    final altUp = after.lastIndexOf((0xffe9, false));
    expect(altUp, greaterThan(0));
    expect(after.sublist(0, altUp), containsAllInOrder([(0xffe3, true), (0xffe3, false)]));

    // Fill: the picture reaches the edges; nothing is drawn over it, and the
    // buttons are in the bar at the top edge.
    c.fit = ScreenFit.fill;
    await tester.pump();
    expect(one, findsNothing, reason: 'never over the picture');
    final pointer = await mouse(tester, const Offset(700, 450));
    await pointer.moveTo(const Offset(700, 1));
    await tester.pumpAndSettle();
    expect(find.descendant(of: bar, matching: one), findsOneWidget);
    expect(tester.getRect(two).top, tester.getRect(one).top, reason: 'along a row');
    await tester.tap(two);
    await tester.pump();
    expect(c.displays.value.shown, 1);
    await pointer.moveTo(const Offset(700, 450));
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('the keys that show displays follow Settings: changed, the new one works and the old one goes to the remote',
      (tester) async {
    final (shell, engine) = await connectScreen(tester, protocol: ScreenProtocol.rdp);
    await pumpPane(tester, shell);
    final container = ProviderScope.containerOf(tester.element(view));
    await container
        .read(shortcutBindingsProvider.notifier)
        .setBinding(ShortcutAction.screenDisplay2, ShortcutKey(keyId: LogicalKeyboardKey.f9.keyId, ctrl: true));
    final c = tester.widget<ScreenView>(view).controller;
    engine
      ..emit(ScreenEventKind.resize, a: (1600 << 32) | 500)
      ..displays([
        [0, 0, 800, 500],
        [800, 0, 800, 500],
      ]);
    await tester.pump();
    await tester.pump();
    c.showDisplay(0);
    await enter(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(c.displays.value.shown, 0, reason: 'Alt+2 is not the key any more');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.displays.value.shown, 1);
    expect(find.byTooltip('${en.screenDisplayName(2)} (Ctrl+F9)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('the handle is reached with the keyboard where the picture does not hold it, and Enter opens the panel',
      (tester) async {
    final handle = find.byKey(const ValueKey('screen-full-screen-handle'));
    final (shell, engine) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    FocusNode handleFocus() => Focus.of(tester.element(find.descendant(of: handle, matching: find.byType(AnimatedOpacity))));
    // The first stop, before the picture (which keeps Tab for the remote once it has the focus).
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(handleFocus().hasPrimaryFocus, isTrue);
    expect(tester.widget<AnimatedOpacity>(find.descendant(of: handle, matching: find.byType(AnimatedOpacity))).opacity, 1,
        reason: 'lit while it has the focus');
    engine.keys.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')).hitTestable(), findsOneWidget);
    expect(engine.keys, isEmpty, reason: 'nothing of it reached the remote');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('the menu key opens the session panel over the full screen; closing it and leaving full screen at once '
      'puts the picture back in its tab', (tester) async {
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    await tester.tap(find.byType(ScreenView));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')).hitTestable(), findsOneWidget);
    expect(layer, findsOneWidget, reason: 'the panel is over the full screen, which stays');
    // Closed, and full screen left while the panel is still going.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pause);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pause);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(layer, findsNothing);
    expect(asked, [true, false]);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('a screen reader is told the full screen is the remote screen, and is given the buttons of the bar',
      (tester) async {
    final handle = tester.ensureSemantics();
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    // (What is in the semantics tree, which is what a screen reader reads.)
    expect(find.semantics.byLabel(en.screenViewLabel), findsOne);
    final pointer = await mouse(tester, const Offset(700, 450));
    await pointer.moveTo(const Offset(700, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.semantics.byLabel(en.screenExitFullScreen), findsOne);
    expect(find.semantics.byLabel(en.terminalDisconnect), findsOne, reason: "the tab's own toolbar is under the layer");
    expect(find.semantics.byLabel(en.screenFullScreen), findsNothing, reason: 'nor its Full screen button');
    // The app's own bars step out as the shell is told (lib/ui/screens/desktop/desktop_shell.dart).
    final container = ProviderScope.containerOf(tester.element(view));
    expect(container.read(screenFullScreenSessionProvider), 's1');
    await tester.tap(find.byKey(const ValueKey('screen-full-screen-exit')));
    await tester.pump();
    await tester.pump();
    expect(container.read(screenFullScreenSessionProvider), isNull);
    expect(find.semantics.byLabel(en.screenFullScreen), findsOne);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
    handle.dispose();
  });

  testWidgets('a window its person had made full screen already stays so: nothing is asked of it going in or coming out',
      (tester) async {
    WindowService.fullscreen.value = true;
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    expect(layer, findsOneWidget);
    expect(asked, isEmpty);
    await tester.tap(find.byType(ScreenView));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pause);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pause);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(layer, findsNothing);
    expect(asked, isEmpty);
    expect(WindowService.fullscreen.value, isTrue);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('the window leaves full screen another way (the system\'s own key or button): the screen is back in its '
      'tab, and the window is asked nothing more', (tester) async {
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    expect(layer, findsOneWidget);
    WindowService.fullscreen.value = false;
    await tester.pump();
    await tester.pump();
    expect(layer, findsNothing);
    expect(asked, [true]);
    expect(toolbarButton.hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('a tab that is no longer in front leaves full screen', (tester) async {
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    expect(layer, findsOneWidget);
    await pumpPane(tester, shell, front: false);
    await tester.pump();
    expect(layer, findsNothing);
    expect(asked, [true, false]);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('closed while in full screen (its tab closed, the session ended): the window is put back', (tester) async {
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell);
    await enter(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(asked, [true, false]);
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('what covers the picture covers it in full screen: recording mode\'s cover fills the window, and the '
      'layer is inside the app\'s own overlay, under whatever the app draws over its pages (the lock)', (tester) async {
    final (shell, _) = await connectScreen(tester);
    await pumpPane(tester, shell, recording: true);
    final cover = find.byKey(const ValueKey('screen-recording-cover'));
    expect(cover, findsOneWidget);
    await enter(tester);
    expect(layer, findsOneWidget);
    expect(find.descendant(of: layer, matching: cover), findsOneWidget);
    expect(tester.getRect(cover), Offset.zero & _window);
    // The lock is drawn by the app over its Navigator (LockCurtain, lib/app.dart): the full
    // screen is one of that Navigator's own layers, so it is under the lock as every page is.
    expect(find.ancestor(of: layer, matching: find.byType(Navigator)), findsOneWidget);
    expect(find.byType(ScreenFullScreenFrame), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('an RDP screen that resizes the remote: the remote takes the size of the whole monitor on entering, and '
      'the size of the tab again on leaving', (tester) async {
    ScreenViewSize.lastFollowed = null;
    final (shell, engine) = await connectScreen(tester,
        options: const ScreenOptions(scaling: ScreenScaling.remoteResize), protocol: ScreenProtocol.rdp);
    await pumpPane(tester, shell);
    await tester.pump(ScreenController.resizeSettle * 2);
    final inTab = tester.getSize(view);
    expect(engine.resizes.last, (inTab.width.floor() & ~1, inTab.height.floor()));

    await enter(tester);
    await tester.pump(ScreenController.resizeSettle * 2);
    expect(engine.resizes.last, (_window.width.floor() & ~1, _window.height.floor()), reason: 'the whole monitor');

    await tester.tap(find.byType(ScreenView));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pause);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pause);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(ScreenController.resizeSettle * 2);
    expect(engine.resizes.last, (inTab.width.floor() & ~1, inTab.height.floor()), reason: 'back to the tab');
    await tester.pump(const Duration(seconds: 6));
    await finish(tester);
  });

  testWidgets('on a Mac Control+Command+F leaves too, as it leaves any full screen there', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (shell, engine) = await connectScreen(tester);
      await pumpPane(tester, shell);
      await enter(tester);
      expect(find.text(en.screenFullScreenHint('F8', en.screenFullScreenExitKeysMac)), findsOneWidget);
      await tester.tap(find.byType(ScreenView));
      engine.keys.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(layer, findsNothing);
      expect(asked, [true, false]);
      expect(engine.keys.where((k) => k.$1 == 0x66), isEmpty, reason: 'F was not sent');
      await tester.pump(const Duration(seconds: 6));
      await finish(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
