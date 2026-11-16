// Selecting by touch on the terminal screen of a phone or a tablet.
//
// On Android, released versions too: selecting several words or lines
// brought up the Selection screen, which stopped
// the selection from growing.
//
// A finger held on the terminal for 0.8 s opens the actions sheet; one that
// moves is no long press. The screen measured that move from one touch event
// to the next (more than 10 pixels between two), and on a slow drag each is a
// pixel or two: a drag growing the selection that a long press began (or one
// along a line) never moved, and the sheet opened under the finger, which
// stopped the selection growing. A selection made by the touch now opens the
// sheet as the finger is let go, with the selection's own actions; a finger
// that moves from where it went down is no long press, however slowly.
//
// A gesture that starts up or down to scroll should not open the pop-up
// for copy, paste and find; with the finger staying on the display the
// pop-up jumped up and got in the way of scrolling. It should open only
// on a clear press. A scroll that
// began slowly stayed within Flutter's 18 pixels of a press, the press won,
// selected a word, and the sheet came up; a press is now a finger held still
// (kTerminalPressSlop, 8 pixels), in the terminal's press and in the screen's.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

  late Terminal terminal;

  Future<void> pumpScreen(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
    sessions.show({'s1': connectedSession('s1', 'Web s1')});
    terminal = sessions.state['s1']!.session!.terminal;
    terminal.write('alpha beta gamma delta\r\nepsilon zeta eta theta\r\n');
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

  /// Where on the screen the middle of the cell at [column] of [row] is.
  Offset cell(WidgetTester tester, int column, int row) {
    final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
    final size = render.cellSize;
    return render.localToGlobal(render.getOffset(CellOffset(column, row)) + Offset(size.width / 2, size.height / 2));
  }

  String? selected(WidgetTester tester) {
    final selection = tester.widget<TerminalView>(find.byType(TerminalView)).controller?.selection;
    return selection == null ? null : terminal.buffer.getText(selection).trim();
  }

  final sheet = find.byType(BottomSheet);

  /// The finger [gesture] moved slowly to [to], two pixels at a time, a move
  /// every 16 ms, as a careful drag is.
  Future<void> slowly(WidgetTester tester, TestGesture gesture, Offset from, Offset to) async {
    final steps = ((to - from).distance / 2).ceil();
    for (var i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a long press and a slow drag grow the selection; the sheet opens as the finger is let go',
      (tester) async {
    await pumpScreen(tester);
    final from = cell(tester, 0, 0);
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 600));
    expect(selected(tester), 'alpha', reason: 'a long press selects the word under the finger');

    await slowly(tester, gesture, from, cell(tester, 13, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(sheet, findsNothing, reason: 'the sheet opened under the finger, mid-drag');
    expect(selected(tester), 'alpha beta gamma');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget, reason: 'let go: the sheet, with the selection');
    final copy = lookupAppLocalizations(const Locale('en')).terminalCopySelection;
    expect(find.descendant(of: sheet, matching: find.text(copy)), findsOneWidget);
    expect(selected(tester), 'alpha beta gamma');
    await finish(tester);
  });

  testWidgets('a finger held still on a word: the sheet waits for it to be let go, in case it drags on',
      (tester) async {
    await pumpScreen(tester);
    final gesture = await tester.startGesture(cell(tester, 7, 0), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(selected(tester), 'beta');
    expect(sheet, findsNothing, reason: 'the sheet opened while the finger still held the selection');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    await finish(tester);
  });

  testWidgets('a slow drag down the screen, no long press: no sheet, during it or after', (tester) async {
    await pumpScreen(tester);
    final from = cell(tester, 4, 1);
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.touch);
    // Past the 0.8 s a held finger takes to open the sheet.
    await slowly(tester, gesture, from, from + const Offset(0, 140));
    expect(sheet, findsNothing, reason: 'a drag counted as a long press');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheet, findsNothing, reason: 'nothing was selected');
    expect(selected(tester), isNull);
    await finish(tester);
  });

  testWidgets('a scroll that starts slowly and then holds still: no word selected, no sheet, then or when let go',
      (tester) async {
    await pumpScreen(tester);
    final from = cell(tester, 4, 1);
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.touch);
    // 14 pixels up in the first 0.1 s, under the 18 that made a press of it.
    await slowly(tester, gesture, from, from - const Offset(0, 14));
    // And the finger stays on the screen, past both presses' times.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(selected(tester), isNull, reason: 'the start of a scroll selected a word');
    expect(sheet, findsNothing, reason: 'the sheet came up under a scrolling finger');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(selected(tester), isNull);
    await finish(tester);
  });

  testWidgets('a finger that trembles a little while held is still a clear press', (tester) async {
    await pumpScreen(tester);
    final at = cell(tester, 7, 0);
    final gesture = await tester.startGesture(at, kind: PointerDeviceKind.touch);
    for (final d in const [Offset(2, 1), Offset(-1, 3), Offset(3, -2), Offset(0, 0)]) {
      await gesture.moveTo(at + d);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 1200));
    expect(selected(tester), 'beta');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    await finish(tester);
  });

  testWidgets('a second finger landing while a long press grows its selection does not stop it', (tester) async {
    await pumpScreen(tester);
    final from = cell(tester, 0, 0);
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 600));
    await slowly(tester, gesture, from, cell(tester, 7, 0));
    expect(selected(tester), 'alpha beta');
    // A second finger touches the screen, and goes.
    final other = await tester.startGesture(cell(tester, 2, 3), kind: PointerDeviceKind.touch, pointer: 7);
    await tester.pump(const Duration(milliseconds: 16));
    await other.up();
    await slowly(tester, gesture, cell(tester, 7, 0), cell(tester, 13, 0));
    expect(selected(tester), 'alpha beta gamma', reason: 'the first finger still grows the selection');
    await gesture.up();
    await tester.pumpAndSettle();
    await finish(tester);
  });
}
