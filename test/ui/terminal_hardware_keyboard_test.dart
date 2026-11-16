// A keyboard plugged in or paired with a phone or a tablet, on its terminal
// screen (an audit of an external keyboard on
// Android and an iPad).
//
// The row of keys over the keyboard stayed with a keyboard on the desk, and a
// tap on the terminal brought the on-screen keyboard up over half the screen.
// The app had no keys there at all: they lived in a computer's shell. Now the
// row hides once a hardware keyboard is typed on (Settings: Automatic, the
// default, or Always) and comes back as HardwareKeyboardUse says; a tap gives
// the terminal the keyboard's input and asks for no on-screen keyboard until
// its person asks for one (the row's Show keyboard key, or a key of the row);
// and a computer's keys work there, Ctrl on Android, Cmd on an iPad.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart' show quickConnectFocusWanted;
import 'package:zestssh/ui/screens/terminal/hardware_keyboard_use.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// The app lock, its check of a return from the background held until a
/// test lets it go ([check]).
class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  Completer<void>? check;

  void set(bool locked) => state = locked;

  @override
  Future<void> get resumeChecked => check?.future ?? Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  late DateTime now;
  late ProviderContainer container;
  late List<String> sent;

  setUp(() {
    now = DateTime(2026, 10, 22, 9);
    hardwareKeyboardClock = () => now;
    debugPhoneKeysRow = true;
    quickConnectFocusWanted.value = false;
  });

  tearDown(() {
    hardwareKeyboardClock = DateTime.now;
    debugPhoneKeysRow = null;
  });

  /// The terminal of s1 (and s2 beside it) on [platform], opened from Home.
  Future<GoRouter> pumpScreen(WidgetTester tester,
      {TargetPlatform platform = TargetPlatform.android,
      Map<String, Object> prefs = const {},
      List<Override> overrides = const []}) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = const Size(2048, 1536);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    // Hide (a phone's default) unless a test says otherwise: the screen is
    // a tablet's, whose default keeps the keys a keyboard lacks.
    SharedPreferences.setMockInitialValues({
      'cursor_blink': false,
      if (!prefs.containsKey('keys_row_auto_hide')) 'keys_row_hardware': 'hide',
      ...prefs,
    });
    final store = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(store),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      ...overrides,
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
    sessions.show({'s1': connectedSession('s1', 'Web s1'), 's2': connectedSession('s2', 'Web s2')});
    sent = [];
    sessions.state['s1']!.session!.terminal.onOutput = sent.add;
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
    return router;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  Offset cell(WidgetTester tester, int column, int row) {
    final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
    final size = render.cellSize;
    return render.localToGlobal(render.getOffset(CellOffset(column, row)) + Offset(size.width / 2, size.height / 2));
  }

  final row = find.byType(TerminalSoftKeyboard);
  final showKeyboard = find.byKey(const ValueKey('keys-row-show-keyboard'));

  /// How often the on-screen keyboard was asked to come up.
  int shown(WidgetTester tester) => tester.testTextInput.log.where((c) => c.method == 'TextInput.show').length;

  Future<void> tap(WidgetTester tester) async {
    await tester.tapAt(cell(tester, 5, 2), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key,
      {bool ctrl = false, bool shift = false, bool meta = false}) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('the row of keys and the on-screen keyboard', () {
    testWidgets('a hardware key hides the row, and a tap then asks for no on-screen keyboard', (tester) async {
      await pumpScreen(tester);
      expect(row, findsOneWidget);
      await tap(tester);
      expect(shown(tester), greaterThan(0), reason: 'with no hardware keyboard a tap brings the keyboard up');
      expect(showKeyboard, findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsNothing, reason: 'the row stayed with a keyboard on the desk');

      tester.testTextInput.log.clear();
      await tap(tester);
      expect(shown(tester), 0, reason: 'a tap brought the on-screen keyboard up over the terminal');
      expect(row, findsNothing, reason: 'a tap soon after a hardware key leaves the row hidden');
      await finish(tester);
    });

    testWidgets('a tap after 20 seconds without a hardware key brings the row back, with its Show keyboard key',
        (tester) async {
      await pumpScreen(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsNothing);

      now = now.add(const Duration(seconds: 21));
      tester.testTextInput.log.clear();
      await tap(tester);
      expect(row, findsOneWidget);
      expect(shown(tester), 0, reason: 'the row is back, the keyboard still asked for by its key');
      expect(showKeyboard, findsOneWidget);

      await tester.tap(showKeyboard);
      await tester.pump(const Duration(milliseconds: 300));
      expect(shown(tester), greaterThan(0), reason: 'the key brings the on-screen keyboard up');
      expect(showKeyboard, findsNothing, reason: 'taps bring it up again from now on');
      tester.testTextInput.log.clear();
      await tap(tester);
      expect(shown(tester), greaterThan(0));

      // A hardware key starts it all over.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsNothing);
      await finish(tester);
    });

    testWidgets('text from the on-screen keyboard brings the row back; a hardware key\'s own text does not',
        (tester) async {
      await pumpScreen(tester);
      await tap(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsNothing);

      // The text a hardware key types comes a moment after its key event.
      tester.testTextInput.updateEditingValue(const TextEditingValue(text: '  l', selection: TextSelection.collapsed(offset: 3)));
      await tester.pump();
      expect(row, findsNothing);

      now = now.add(const Duration(seconds: 2));
      tester.testTextInput.updateEditingValue(const TextEditingValue(text: '  x', selection: TextSelection.collapsed(offset: 3)));
      await tester.pump();
      expect(row, findsOneWidget, reason: 'the on-screen keyboard is typed on');
      await finish(tester);
    });

    testWidgets('a tablet keeps only the keys a keyboard lacks while one is typed on (its default, 3.2.1)',
        (tester) async {
      await pumpScreen(tester, prefs: {'keys_row_hardware': 'none chosen'});
      expect(find.byKey(const ValueKey('softkey-fn')), findsOneWidget, reason: 'the whole row before a hardware key');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsOneWidget, reason: 'the row stays, with fewer keys');
      for (final id in hardwareMissingKeyIds) {
        expect(find.byKey(ValueKey('softkey-$id')), findsOneWidget, reason: '$id is a key the keyboard lacks');
      }
      for (final id in ['esc', 'tab', 'ctrl', 'up', 'fn']) {
        expect(find.byKey(ValueKey('softkey-$id')), findsNothing, reason: 'the keyboard has $id');
      }
      await tester.tap(find.byKey(const ValueKey('softkey-f5')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(sent.join(), contains('\x1B[15~'), reason: 'F5 types');
      await finish(tester);
    });

    testWidgets('a key of the row used: taps bring the on-screen keyboard up again', (tester) async {
      await pumpScreen(tester, prefs: {'keys_row_auto_hide': false});
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsOneWidget, reason: 'Always: the row stays');
      expect(showKeyboard, findsOneWidget);
      await tester.tap(find.text('ESC').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(showKeyboard, findsNothing);
      tester.testTextInput.log.clear();
      await tap(tester);
      expect(shown(tester), greaterThan(0));
      await finish(tester);
    });

    test('a key only a hardware keyboard sends, and the keys an on-screen keyboard sends too', () {
      KeyDownEvent down(LogicalKeyboardKey key) =>
          KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: key, timeStamp: Duration.zero);
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.numpad5,
        LogicalKeyboardKey.period,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.f5,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        expect(isHardwareKeyboardKey(down(key)), isTrue, reason: '$key');
      }
      for (final key in [
        LogicalKeyboardKey.backspace,
        // Android's keyboards send the digits as keys (sendKeyChar).
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit9,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowUp,
      ]) {
        expect(isHardwareKeyboardKey(down(key)), isFalse, reason: '$key');
      }
      expect(
          isHardwareKeyboardKey(
              const KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: LogicalKeyboardKey.keyA, timeStamp: Duration.zero)),
          isFalse);
    });
  });

  group('the on-screen keyboard (a bug in 3.0.0)', () {
    /// The on-screen keyboard's room, in the view's pixels (none: closed).
    Future<void> keyboard(WidgetTester tester, double inset) async {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
    }

    Future<void> lifecycle(WidgetTester tester, List<AppLifecycleState> states) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    Future<void> leave(WidgetTester tester) async {
      // The system takes the keyboard down as the app goes.
      await keyboard(tester, 0);
      await lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
      await tester.pump(const Duration(seconds: 5));
    }

    Future<void> comeBack(WidgetTester tester) async {
      await lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('a number, and a page of numbers that drops the height for a frame, keep the row', (tester) async {
      await pumpScreen(tester);
      await tap(tester);
      await keyboard(tester, 600);
      expect(row, findsOneWidget);

      // Off to the page of numbers and symbols: the height drops for a frame
      // or two and comes back taller.
      await keyboard(tester, 0);
      await keyboard(tester, 0);
      await keyboard(tester, 640);
      expect(row, findsOneWidget, reason: 'the row went with a change of page');

      // Gboard and Samsung's keyboard send a digit as a key press.
      for (final digit in [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit0]) {
        await tester.sendKeyEvent(digit);
        await tester.pump();
        expect(row, findsOneWidget, reason: 'a number key hid the row ($digit)');
      }
      tester.testTextInput.log.clear();
      await tap(tester);
      expect(shown(tester), greaterThan(0), reason: 'a tap after a number brought no keyboard up');
      expect(showKeyboard, findsNothing);

      // A hardware keyboard still says so with its Escape (Android takes
      // its on-screen keyboard down as one is typed on: then its letters).
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(row, findsNothing);
      await finish(tester);
    });

    testWidgets("Android: a character's key with the on-screen keyboard up keeps the row; without it, hides it",
        (tester) async {
      await pumpScreen(tester);
      await tap(tester);
      await keyboard(tester, 600);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyEvent(LogicalKeyboardKey.period);
      await tester.pump();
      expect(row, findsOneWidget, reason: "an on-screen keyboard's key is no hardware keyboard");

      // The on-screen keyboard closed (no frame at none decides it): a
      // letter is a hardware keyboard's.
      await keyboard(tester, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsOneWidget, reason: 'a single frame at none closed the keyboard');
      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsNothing);
      await finish(tester);
    });

    testWidgets("an iPad's bar of shortcuts (an inset) with a hardware keyboard: a letter hides the row",
        (tester) async {
      await pumpScreen(tester, platform: TargetPlatform.iOS);
      await tap(tester);
      await keyboard(tester, 110);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(row, findsNothing);
      await finish(tester);
    });

    testWidgets('back in the app, a keyboard that was up comes up again', (tester) async {
      await pumpScreen(tester);
      await tap(tester);
      await keyboard(tester, 600);
      // A change of page just before (a frame at none) is no closing.
      await keyboard(tester, 0);
      await keyboard(tester, 640);
      tester.testTextInput.log.clear();

      await leave(tester);
      expect(shown(tester), 0);
      await comeBack(tester);
      expect(shown(tester), greaterThan(0), reason: 'the keyboard stayed down (or its room stayed empty)');
      expect(row, findsOneWidget);
      await finish(tester);
    });

    testWidgets('back in the app, a keyboard its person closed stays closed', (tester) async {
      await pumpScreen(tester);
      await tap(tester);
      await keyboard(tester, 600);
      await keyboard(tester, 0);
      await tester.pump(const Duration(seconds: 1));
      tester.testTextInput.log.clear();

      await leave(tester);
      await comeBack(tester);
      expect(shown(tester), 0, reason: 'a keyboard closed before the app was left came up');
      expect(row, findsOneWidget);
      await finish(tester);
    });

    testWidgets('back in the app, the terminal has the focus again where something took it', (tester) async {
      await pumpScreen(tester);
      await tap(tester);
      await keyboard(tester, 600);
      final focus = tester.widget<TerminalView>(find.byType(TerminalView)).focusNode!;
      expect(focus.hasFocus, isTrue);
      tester.testTextInput.log.clear();

      await leave(tester);
      focus.unfocus();
      await tester.pump();
      await comeBack(tester);
      expect(focus.hasFocus, isTrue, reason: 'the focus was not given back to the terminal');
      expect(shown(tester), greaterThan(0));
      await finish(tester);
    });

    testWidgets('back in the app, the keyboard waits for the app lock: none while locked, up once unlocked',
        (tester) async {
      final lock = _Lock();
      await pumpScreen(tester, overrides: [isAppLockedProvider.overrideWith((ref) => lock)]);
      await tap(tester);
      await keyboard(tester, 600);
      tester.testTextInput.log.clear();

      // The lock engages as the app is back: no keyboard (the app shows its
      // lock screen in place of the terminal).
      lock.check = Completer<void>();
      await leave(tester);
      await comeBack(tester);
      expect(shown(tester), 0, reason: 'the keyboard came before the app lock had its say');
      lock.set(true);
      lock.check!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      expect(shown(tester), 0, reason: 'the keyboard came up over a locked app');

      // Unlocked by the check: the keyboard is up again.
      lock.set(false);
      lock.check = Completer<void>();
      await keyboard(tester, 600);
      await leave(tester);
      await comeBack(tester);
      expect(shown(tester), 0);
      lock.check!.complete();
      await tester.pump(const Duration(milliseconds: 100));
      expect(shown(tester), greaterThan(0), reason: 'the keyboard stayed down after the check');
      await finish(tester);
    });

    testWidgets('back in the app with a hardware keyboard: no on-screen keyboard', (tester) async {
      await pumpScreen(tester);
      await tap(tester);
      await keyboard(tester, 600);
      // A key only a hardware keyboard has (its letters say nothing while the
      // on-screen keyboard is up on Android).
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(row, findsNothing);
      tester.testTextInput.log.clear();

      await leave(tester);
      await comeBack(tester);
      expect(shown(tester), 0, reason: 'a hardware keyboard is typed on');
      await finish(tester);
    });
  });

  group("the app's keys", () {
    testWidgets('Android: Ctrl+Shift+F finds, Ctrl+= and Ctrl+0 zoom, Ctrl+Shift+W asks before it closes', (tester) async {
      await pumpScreen(tester);
      expect(find.byType(TerminalSearchBar), findsNothing);
      await chord(tester, LogicalKeyboardKey.keyF, ctrl: true, shift: true);
      expect(find.byType(TerminalSearchBar), findsOneWidget);
      // The bar's field has the keyboard: back to the terminal.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalSearchBar), findsNothing);

      final size = container.read(terminalFontSizeProvider);
      await chord(tester, LogicalKeyboardKey.equal, ctrl: true);
      expect(container.read(terminalFontSizeProvider), size + 1);
      await chord(tester, LogicalKeyboardKey.minus, ctrl: true);
      await chord(tester, LogicalKeyboardKey.minus, ctrl: true);
      expect(container.read(terminalFontSizeProvider), size - 1);
      await chord(tester, LogicalKeyboardKey.digit0, ctrl: true);
      expect(container.read(terminalFontSizeProvider), 14);
      expect(sent, isEmpty, reason: 'none of them reached the shell');

      await chord(tester, LogicalKeyboardKey.keyW, ctrl: true, shift: true);
      expect(find.text(en.terminalDisconnectConfirm), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(find.byType(TerminalScreen), findsOneWidget);
      await finish(tester);
    });

    testWidgets("Android: Ctrl+T is the shell's in the terminal; Ctrl+Tab goes to the next session", (tester) async {
      await pumpScreen(tester);
      await chord(tester, LogicalKeyboardKey.keyT, ctrl: true);
      expect(sent, ['\x14'], reason: 'Ctrl+T transposes two characters in a shell');
      expect(quickConnectFocusWanted.value, isFalse);

      await chord(tester, LogicalKeyboardKey.tab, ctrl: true);
      await tester.pumpAndSettle();
      expect(tester.widget<TerminalScreen>(find.byType(TerminalScreen)).sessionId, 's2');
      await finish(tester);
    });

    testWidgets('an iPad: Cmd in place of Ctrl, and Cmd+T opens quick connect at Home', (tester) async {
      final router = await pumpScreen(tester, platform: TargetPlatform.iOS);
      await chord(tester, LogicalKeyboardKey.keyF, meta: true, shift: true);
      expect(find.byType(TerminalSearchBar), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final size = container.read(terminalFontSizeProvider);
      await chord(tester, LogicalKeyboardKey.equal, meta: true);
      expect(container.read(terminalFontSizeProvider), size + 1);
      // Ctrl+Shift+F is no app key there.
      await chord(tester, LogicalKeyboardKey.keyF, ctrl: true, shift: true);
      expect(find.byType(TerminalSearchBar), findsNothing);

      await chord(tester, LogicalKeyboardKey.keyT, meta: true);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalScreen), findsNothing);
      expect(router.routerDelegate.currentConfiguration.uri.path, Routes.home);
      expect(quickConnectFocusWanted.value, isTrue, reason: "Home's quick connect field is asked for");
      await finish(tester);
    });
  });
}
