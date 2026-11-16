// A mouse on a phone's or a tablet's terminal (an audit of an external
// keyboard and mouse on Android and an iPad).
//
// A right click pasted through a listener of its own, whatever Settings said
// and whatever the program in the terminal asked for (a right click in tmux
// or mc pasted into it), and the terminal's menu could not be opened with a
// mouse at all: it opened on a finger's long press only. A middle click did
// nothing. Now they are a computer's: the terminal view's own right click
// pastes where Right-click paste is on and nothing is selected, and opens the
// menu where the pointer is otherwise; a program that asked for the mouse is
// sent the click; a middle click pastes where Middle-click paste is on.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const esc = '\x1b';

  late Terminal terminal;
  late List<String> sent;
  late String clipboard;

  setUp(() {
    clipboard = 'uptime';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  Future<void> pumpScreen(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(2048, 1536);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false, ...prefs});
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
    sent = [];
    terminal.onOutput = sent.add;
    terminal.write('alpha beta gamma\r\n');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: TerminalScreen(sessionId: 's1'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
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

  Future<void> click(WidgetTester tester, Offset at, int buttons) async {
    await tester.tapAt(at, buttons: buttons, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  final menuPaste = find.byKey(const ValueKey('terminal-menu-paste'));
  final menuCopySelection = find.byKey(const ValueKey('terminal-menu-copySel'));
  final sheet = find.byType(BottomSheet);

  testWidgets('a right click pastes where Settings says so, and no menu opens', (tester) async {
    await pumpScreen(tester);
    await click(tester, cell(tester, 3, 0), kSecondaryMouseButton);
    expect(sent, ['uptime']);
    expect(menuPaste, findsNothing);
    await finish(tester);
  });

  testWidgets('Right-click paste off: the menu where the pointer is, with the actions of the sheet', (tester) async {
    await pumpScreen(tester, prefs: {'desktop_right_click_paste': false});
    final at = cell(tester, 20, 3);
    await click(tester, at, kSecondaryMouseButton);
    expect(sent, isEmpty, reason: 'it pasted whatever Settings said');
    expect(menuPaste, findsOneWidget);
    expect(sheet, findsNothing, reason: 'a mouse gets a menu at the pointer, a finger the sheet');
    final menu = tester.getTopLeft(find.byType(PopupMenuItem<String>).first);
    expect((menu - at).distance, lessThan(80), reason: 'the menu opens where the pointer is');

    await tester.tap(menuPaste);
    await tester.pumpAndSettle();
    expect(sent, ['uptime'], reason: "the menu's Paste pastes");
    await finish(tester);
  });

  testWidgets('with something selected, a right click opens the menu with Copy first', (tester) async {
    await pumpScreen(tester);
    // A double click selects the word.
    final word = cell(tester, 7, 0);
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(word, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, word, kSecondaryMouseButton);
    expect(sent, isEmpty);
    expect(menuCopySelection, findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('a program that asked for the mouse is sent the right click, and nothing pastes', (tester) async {
    await pumpScreen(tester);
    terminal.write('$esc[?1000h$esc[?1006h');
    await tester.pump();
    await click(tester, cell(tester, 4, 1), kSecondaryMouseButton);
    expect(sent, ['$esc[<2;5;2M', '$esc[<2;5;2m']);
    expect(menuPaste, findsNothing);
    await finish(tester);
  });

  testWidgets('a middle click pastes where Middle-click paste is on, and does nothing where it is off', (tester) async {
    await pumpScreen(tester);
    await click(tester, cell(tester, 2, 0), kMiddleMouseButton);
    expect(sent, ['uptime']);
    expect(menuPaste, findsNothing);
    await finish(tester);

    await pumpScreen(tester, prefs: {'desktop_middle_click_paste': false});
    await click(tester, cell(tester, 2, 0), kMiddleMouseButton);
    expect(sent, isEmpty);
    await finish(tester);
  });
}
