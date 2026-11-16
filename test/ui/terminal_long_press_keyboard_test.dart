// A long press on a phone's or a tablet's terminal, and the on-screen
// keyboard (a bug in 3.0.0).
//
// `ls` run, the keyboard closed with Back, a long press on a word to copy it:
// the keyboard came back up over the text, and the word could not be
// selected. A finger's press asked for the keyboard a moment after it went
// down, before anyone knew it would be a long one. Now a short tap brings the
// keyboard up (as it is let go), a long press only selects, a scroll asks for
// nothing, and a mouse's click still takes the keyboard as its button goes
// down, as on a computer.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/terminal/hardware_keyboard_use.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Terminal terminal;

  setUp(() {
    hardwareKeyboardClock = () => DateTime(2026, 10, 25, 9);
  });

  tearDown(() {
    hardwareKeyboardClock = DateTime.now;
  });

  /// The terminal of s1 on [platform], with what `ls` printed on its first
  /// line.
  Future<void> pumpScreen(WidgetTester tester, {TargetPlatform platform = TargetPlatform.android}) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final store = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(store),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
    sessions.show({'s1': connectedSession('s1', 'Web s1')});
    terminal = sessions.state['s1']!.session!.terminal;
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: '/terminal/:id', builder: (_, state) => TerminalScreen(sessionId: state.pathParameters['id']!)),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    router.push('/terminal/s1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    terminal.write('notes.txt  backup.tar  deploy.sh\r\n\$ ');
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  /// The middle of the cell at [column], [row], on the screen.
  Offset cell(WidgetTester tester, int column, int row) {
    final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
    final size = render.cellSize;
    return render.localToGlobal(render.getOffset(CellOffset(column, row)) + Offset(size.width / 2, size.height / 2));
  }

  TerminalController controller(WidgetTester tester) => tester.widget<TerminalView>(find.byType(TerminalView)).controller!;

  /// How often the on-screen keyboard was asked to come up.
  int shown(WidgetTester tester) => tester.testTextInput.log.where((c) => c.method == 'TextInput.show').length;

  /// The on-screen keyboard's room, in the view's pixels (none: closed).
  Future<void> keyboard(WidgetTester tester, double inset) async {
    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> tap(WidgetTester tester, {PointerDeviceKind kind = PointerDeviceKind.touch}) async {
    await tester.tapAt(cell(tester, 5, 6), kind: kind);
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The keyboard brought up by a tap and closed with Back (the terminal
  /// keeps the focus, and its input stays connected).
  Future<void> keyboardClosedWithBack(WidgetTester tester) async {
    await tap(tester);
    expect(shown(tester), greaterThan(0), reason: 'a tap brings the keyboard up');
    await keyboard(tester, 1200);
    await keyboard(tester, 0);
    await tester.pump(const Duration(seconds: 1));
    tester.testTextInput.log.clear();
  }

  testWidgets('a long press on a word selects it and asks for no on-screen keyboard', (tester) async {
    await pumpScreen(tester);
    await keyboardClosedWithBack(tester);
    final focus = tester.widget<TerminalView>(find.byType(TerminalView)).focusNode!;
    expect(focus.hasFocus, isTrue);

    // "backup" of what `ls` printed, held.
    final press = await tester.startGesture(cell(tester, 13, 0), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 150));
    expect(shown(tester), 0, reason: 'the keyboard came up as the finger went down');
    await tester.pump(const Duration(milliseconds: 500));
    final selection = controller(tester).selection;
    expect(selection, isNotNull, reason: 'the long press selected nothing');
    expect(terminal.buffer.getText(selection).trim(), 'backup', reason: 'the word under the finger');
    expect(shown(tester), 0, reason: 'the keyboard came up at the long press');

    // Let go: the sheet with the selection's own actions, and still no
    // keyboard.
    await press.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(shown(tester), 0, reason: 'the keyboard came up as the long press was let go');
    expect(controller(tester).selection, isNotNull);
    await finish(tester);
  });

  testWidgets('a short tap still brings the on-screen keyboard up, as it is let go', (tester) async {
    await pumpScreen(tester);
    await keyboardClosedWithBack(tester);

    final press = await tester.startGesture(cell(tester, 5, 6), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 150));
    expect(shown(tester), 0, reason: 'a finger still down may be a long press');
    await press.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(shown(tester), greaterThan(0), reason: 'a tap left the keyboard closed');
    expect(controller(tester).selection, isNull);
    await finish(tester);
  });

  testWidgets('a tap that clears a selection brings no keyboard up (as before)', (tester) async {
    await pumpScreen(tester);
    await keyboardClosedWithBack(tester);
    final press = await tester.startGesture(cell(tester, 13, 0), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 700));
    await press.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller(tester).selection, isNotNull);
    // The sheet the release opened, closed.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    navigator.pop();
    await tester.pump(const Duration(seconds: 1));
    tester.testTextInput.log.clear();

    await tap(tester);
    expect(controller(tester).selection, isNull, reason: 'the tap cleared the selection');
    expect(shown(tester), 0, reason: 'the tap that cleared the selection brought the keyboard up');
    await tap(tester);
    expect(shown(tester), greaterThan(0), reason: 'the next tap brings it up');
    await finish(tester);
  });

  testWidgets('a tap where the program takes clicks (tmux, vim) is told to it and brings the keyboard up',
      (tester) async {
    await pumpScreen(tester);
    await keyboardClosedWithBack(tester);
    final sent = <String>[];
    terminal.onOutput = sent.add;
    // The program asks for clicks (mode 1000, SGR reports).
    terminal.write('\x1b[?1000h\x1b[?1006h');
    await tester.pump();

    await tap(tester);
    expect(sent.join(), contains('\x1b[<0;'), reason: 'the program was not told of the click');
    expect(shown(tester), greaterThan(0), reason: 'a tap the program took left the keyboard closed');
    await finish(tester);
  });

  testWidgets('a scroll with a finger brings no keyboard up', (tester) async {
    await pumpScreen(tester);
    await keyboardClosedWithBack(tester);
    final press = await tester.startGesture(cell(tester, 5, 10), kind: PointerDeviceKind.touch);
    // Held a moment, then moved slowly (the tap's own wait passes first).
    await tester.pump(const Duration(milliseconds: 150));
    for (var i = 0; i < 10; i++) {
      await press.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await press.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(shown(tester), 0, reason: 'a scroll brought the keyboard up');
    await finish(tester);
  });

  testWidgets("a mouse's click takes the keyboard as its button goes down (a computer's, unchanged)", (tester) async {
    await pumpScreen(tester, platform: TargetPlatform.windows);
    final focus = tester.widget<TerminalView>(find.byType(TerminalView)).focusNode!;
    focus.unfocus();
    await tester.pump();
    expect(focus.hasFocus, isFalse);

    final click = await tester.startGesture(cell(tester, 5, 6), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 150));
    expect(focus.hasFocus, isTrue, reason: 'a mouse press no longer took the focus as it went down');
    await click.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(focus.hasFocus, isTrue);
    await finish(tester);
  });
}
