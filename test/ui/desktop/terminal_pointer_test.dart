// The mouse in a computer's terminal: selecting copies (when the setting is
// on), a right click pastes, a middle click pastes. Two bugs of
// 2.2.1 are held here from the outside, with the real terminal area and a
// mouse:
//
// Copying after `clear` picked up old text, from
// the wrong rows: after `clear`, what was dragged over was selected, and
// copied, some rows further down (see
// test/terminal/clear_scrollback_rows_test.dart for why).
//
// Copying on one computer and pasting into a remote desktop's terminal
// pasted what was copied before: a right click pasted at the
// press of the button. A remote desktop sends what was copied on the other
// computer when its window is clicked into, with the click, so the clipboard
// changes a moment after the press. The paste is now at the release, which
// is a click, and reads the clipboard then.

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';

import '../../visual/shots_util.dart';
import '../sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

const _clear = '\x1b[H\x1b[2J\x1b[3J';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  /// What the system's clipboard holds, and every time it was written.
  String? clipboard;
  late List<String> copied;

  /// What was sent to the host as typed.
  late List<String> typed;

  setUp(() {
    clipboard = null;
    copied = [];
    typed = [];
  });

  Future<Terminal> pumpTerminal(WidgetTester tester, {Map<String, Object> settings = const {}}) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1200, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          copied.add(clipboard ?? '');
          return null;
        case 'Clipboard.getData':
          return clipboard == null ? null : <String, Object?>{'text': clipboard};
        case 'Clipboard.hasStrings':
          return <String, Object?>{'value': clipboard != null};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    SharedPreferences.setMockInitialValues({'cursor_blink': false, ...settings});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
    final tabs = container.read(workTabsProvider.notifier);
    sessions.show({'s1': connectedSession('s1', 'Web 1')});
    tabs.setActiveTab(tabs.tabContaining('s1')!.id);
    container.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    container.read(paneTreeProvider.notifier).initSinglePane('s1');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: DesktopTerminalArea(
            onConnectTo: (_) {},
            onToggleSftp: (_) {},
            onApplyLayout: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final terminal = sessions.state['s1']!.session!.terminal;
    terminal.onOutput = typed.add;
    expect(find.byType(TerminalView), findsOneWidget);
    return terminal;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  RenderTerminal render(WidgetTester tester) => tester.allRenderObjects.whereType<RenderTerminal>().single;

  TerminalController selectionOf(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).controller!;

  /// A point in the cell at column [x] of screen row [row]: its middle, or
  /// its left edge.
  Offset cell(WidgetTester tester, Terminal terminal, int x, int row, {bool edge = false}) {
    final r = render(tester);
    final topLeft = r.localToGlobal(r.getOffset(CellOffset(x, terminal.buffer.scrollBack + row)));
    return topLeft + Offset(edge ? 1 : r.cellSize.width / 2, r.cellSize.height / 2);
  }

  /// Drags the mouse with the left button held over columns [from] up to
  /// (not including) [to] of screen row [row].
  Future<void> drag(WidgetTester tester, Terminal terminal, int row, int from, int to) async {
    final start = cell(tester, terminal, from, row, edge: true);
    final end = cell(tester, terminal, to - 1, row);
    final gesture = await tester.startGesture(start, kind: ui.PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, end, 0.5)!);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  Future<TestGesture> press(WidgetTester tester, Offset at, int button) async {
    final gesture = await tester.startGesture(at, kind: ui.PointerDeviceKind.mouse, buttons: button);
    await tester.pump();
    return gesture;
  }

  Future<void> release(WidgetTester tester, TestGesture gesture) async {
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('selecting', () {
    testWidgets('dragging over text copies it and the highlight goes', (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('prompt# hello world');
      await tester.pump();
      await drag(tester, terminal, 0, 8, 13);
      expect(copied, ['hello']);
      expect(selectionOf(tester).selection, isNull);
      await finish(tester);
    });

    testWidgets('the blanks around what was dragged over are not copied', (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('prompt#   hello   world');
      await tester.pump();
      await drag(tester, terminal, 0, 8, 17);
      expect(copied, ['hello']);
      await finish(tester);
    });

    testWidgets('after clear, what is dragged over is what is copied', (tester) async {
      final terminal = await pumpTerminal(tester);
      for (var i = 0; i < 60; i++) {
        terminal.write('line $i\r\n');
      }
      await tester.pump();
      expect(terminal.buffer.scrollBack, greaterThan(0));
      terminal.write(_clear);
      terminal.write('prompt# hello world\r\nsecond row here');
      await tester.pump();
      expect(terminal.buffer.scrollBack, 0);

      await drag(tester, terminal, 0, 8, 13);
      expect(copied, ['hello']);
      await drag(tester, terminal, 1, 7, 10);
      expect(copied, ['hello', 'row']);
      expect(selectionOf(tester).selection, isNull);
      await finish(tester);
    });

    testWidgets('dragging over nothing leaves the clipboard alone, and no highlight stays', (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('prompt# hello world');
      await tester.pump();
      clipboard = 'kept';
      await drag(tester, terminal, 4, 10, 30);
      expect(copied, isEmpty);
      expect(clipboard, 'kept');
      expect(selectionOf(tester).selection, isNull, reason: 'a highlight over nothing is not left on screen');
      await finish(tester);
    });

    testWidgets('output that arrives under the mouse while it drags does not lose what is being selected',
        (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('Downloading 10%');
      await tester.pump();
      final start = cell(tester, terminal, 0, 0, edge: true);
      final end = cell(tester, terminal, 14, 0);
      final gesture = await tester.startGesture(start, kind: ui.PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(Offset.lerp(start, end, 0.5)!);
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      // The line is written again while the button is still held.
      terminal.write('\rDownloading 55%');
      await tester.pump();
      expect(selectionOf(tester).selection, isNotNull, reason: 'still what the mouse covers');
      await gesture.up();
      await tester.pump();
      expect(copied, ['Downloading 55%']);
      await finish(tester);
    });

    testWidgets('with copy on select off the selection stays until it is copied or clicked away', (tester) async {
      final terminal = await pumpTerminal(tester, settings: {'copy_on_select': false});
      terminal.write('prompt# hello world');
      await tester.pump();
      await drag(tester, terminal, 0, 8, 13);
      expect(copied, isEmpty);
      final selection = selectionOf(tester);
      expect(terminal.buffer.getText(selection.selection), 'hello');

      // The screen is cleared under it: it is over, with the text.
      terminal.write('\x1b[H\x1b[2J');
      await tester.pump();
      expect(selection.selection, isNull);
      expect(selection.selectionEnded, isFalse, reason: 'forgotten, not only unseen');
      await finish(tester);
    });
  });

  // Found while comparing the five versions: what touch selected was copied and taken away as the
  // finger lifted (a phone's tmux panes did it with this rule), so the Copy that touch selects for never stayed.
  testWidgets('a word selected by touch stays selected and is not copied as the finger lifts; a mouse copies it',
      (tester) async {
    final terminal = await pumpTerminal(tester);
    terminal.write('prompt# hello world');
    await tester.pump();
    final finger = await tester.startGesture(cell(tester, terminal, 10, 0), kind: ui.PointerDeviceKind.touch);
    await tester.pump(const Duration(seconds: 1));
    await finger.up();
    await tester.pump();
    expect(copied, isEmpty);
    expect(terminal.buffer.getText(selectionOf(tester).selection), 'hello', reason: 'still selected');

    await drag(tester, terminal, 0, 14, 19);
    expect(copied, ['world']);
    await finish(tester);
  });

  group('a right click', () {
    testWidgets('pastes what the clipboard holds when the button is let go', (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('prompt# ');
      await tester.pump();
      clipboard = 'the one before';
      final gesture = await press(tester, cell(tester, terminal, 20, 3), kSecondaryButton);
      expect(typed, isEmpty, reason: 'nothing is pasted at the press');
      // What was copied on the other computer arrives with the click.
      clipboard = 'echo copied just now';
      await release(tester, gesture);
      expect(typed, ['echo copied just now']);
      await finish(tester);
    });

    testWidgets('pastes once, and leaves the clipboard as it is', (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('prompt# hello world');
      await tester.pump();
      clipboard = 'ls -la';
      final gesture = await press(tester, cell(tester, terminal, 9, 0), kSecondaryButton);
      await release(tester, gesture);
      expect(typed, ['ls -la']);
      expect(copied, isEmpty);
      await finish(tester);
    });

    testWidgets('with something selected pastes the clipboard, not the selection', (tester) async {
      final terminal = await pumpTerminal(tester);
      terminal.write('prompt# hello world');
      await tester.pump();
      // Selected from the keyboard (select all): it stays, nothing let go of
      // a drag copied it.
      selectionOf(tester).setSelection(terminal.buffer.createAnchor(8, 0), terminal.buffer.createAnchor(13, 0));
      await tester.pump();
      clipboard = 'ls -la';
      final gesture = await press(tester, cell(tester, terminal, 20, 3), kSecondaryButton);
      await release(tester, gesture);
      expect(typed, ['ls -la']);
      expect(copied, isEmpty, reason: 'the selection is not put on the clipboard by the click that pastes');
      await finish(tester);
    });

    testWidgets('pastes nothing when the setting is off', (tester) async {
      final terminal = await pumpTerminal(tester, settings: {'desktop_right_click_paste': false});
      clipboard = 'ls -la';
      final gesture = await press(tester, cell(tester, terminal, 9, 0), kSecondaryButton);
      await release(tester, gesture);
      expect(typed, isEmpty);
      await finish(tester);
    });

    testWidgets('that is dragged away before the button is let go pastes nothing', (tester) async {
      final terminal = await pumpTerminal(tester);
      clipboard = 'ls -la';
      final at = cell(tester, terminal, 9, 0);
      final gesture = await press(tester, at, kSecondaryButton);
      await gesture.moveTo(at + const Offset(120, 60));
      await tester.pump();
      await release(tester, gesture);
      expect(typed, isEmpty);
      await finish(tester);
    });
  });

  group('a middle click', () {
    testWidgets('pastes once', (tester) async {
      final terminal = await pumpTerminal(tester);
      clipboard = 'ls -la';
      final gesture = await press(tester, cell(tester, terminal, 9, 0), kMiddleMouseButton);
      await release(tester, gesture);
      expect(typed, ['ls -la']);
      await finish(tester);
    });

    testWidgets('pastes what the clipboard holds when the button is let go', (tester) async {
      final terminal = await pumpTerminal(tester);
      clipboard = 'the one before';
      final gesture = await press(tester, cell(tester, terminal, 9, 0), kMiddleMouseButton);
      expect(typed, isEmpty, reason: 'nothing is pasted at the press');
      clipboard = 'echo copied just now';
      await release(tester, gesture);
      expect(typed, ['echo copied just now']);
      await finish(tester);
    });

    testWidgets('goes to a program that takes the mouse, and nothing is pasted on top of it', (tester) async {
      final terminal = await pumpTerminal(tester);
      // The program asks for clicks (as tmux and vim do with the mouse on).
      terminal.write('\x1b[?1000h\x1b[?1006h');
      await tester.pump();
      clipboard = 'ls -la';
      final middle = await press(tester, cell(tester, terminal, 9, 0), kMiddleMouseButton);
      await release(tester, middle);
      expect(typed, hasLength(2), reason: 'the press and the release of the click, told to the program');
      expect(typed.every((t) => t.startsWith('\x1b[<1;')), isTrue, reason: 'as the middle button: $typed');
      expect(typed.any((t) => t.contains('ls -la')), isFalse);

      // And a right click is its own as well.
      typed.clear();
      final right = await press(tester, cell(tester, terminal, 9, 0), kSecondaryButton);
      await release(tester, right);
      expect(typed.every((t) => t.startsWith('\x1b[<2;')), isTrue, reason: 'as the right button: $typed');
      expect(typed.any((t) => t.contains('ls -la')), isFalse);
      await finish(tester);
    });

    testWidgets('pastes nothing when its setting is off, whatever a right click does', (tester) async {
      final terminal = await pumpTerminal(tester, settings: {'desktop_middle_click_paste': false});
      clipboard = 'ls -la';
      final gesture = await press(tester, cell(tester, terminal, 9, 0), kMiddleMouseButton);
      await release(tester, gesture);
      expect(typed, isEmpty);
      await finish(tester);
    });

    testWidgets('still pastes with right-click paste off', (tester) async {
      final terminal = await pumpTerminal(tester, settings: {'desktop_right_click_paste': false});
      clipboard = 'ls -la';
      final gesture = await press(tester, cell(tester, terminal, 9, 0), kMiddleMouseButton);
      await release(tester, gesture);
      expect(typed, ['ls -la']);
      await finish(tester);
    });
  });
}
