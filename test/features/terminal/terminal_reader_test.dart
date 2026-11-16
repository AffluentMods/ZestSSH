import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/terminal/terminal_reader.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// A terminal for a screen reader (4.0 accessibility pass): its painted text
/// said as one named node, its new lines read out as they come, and Read the
/// screen, its lines one to a node. Names here are made up.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('the new lines between two pictures of the screen', () {
    test('lines scrolled in at the bottom are new, in their order', () {
      final before = ['\$ ls', 'a.txt', '\$ ', '', ''];
      final after = ['a.txt', '\$ ls -l', 'total 4', 'b.txt', '\$ '];
      expect(TerminalText.newLines(before, after, cursorRow: 4), ['\$ ls -l', 'total 4', 'b.txt', '\$ ']);
    });

    test('output on a screen that has not scrolled yet is new', () {
      final before = ['\$ uptime', '', '', ''];
      final after = ['\$ uptime', ' 10:01 up 3 days', '\$ ', ''];
      expect(TerminalText.newLines(before, after, cursorRow: 2), [' 10:01 up 3 days', '\$ ']);
    });

    test('only the line under the cursor changing is typing: nothing new', () {
      final before = ['motd', '\$ ', ''];
      final after = ['motd', '\$ sudo apt', ''];
      expect(TerminalText.newLines(before, after, cursorRow: 1), isEmpty);
    });

    test('blank lines are never read, and a cleared screen says its prompt', () {
      final before = ['a', 'b', 'c'];
      final after = ['\$ ', '', ''];
      expect(TerminalText.newLines(before, after, cursorRow: 0), ['\$ ']);
    });
  });

  test("the terminal's lines put a folded line back together", () {
    final terminal = Terminal()..resize(10, 4);
    terminal.write('0123456789abcde\r\nnext\r\n');
    expect(TerminalText.all(terminal), ['0123456789abcde', 'next']);
    expect(TerminalText.all(terminal, last: 1), ['next']);
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget child, {bool readAloud = true}) async {
    SharedPreferences.setMockInitialValues({'terminal_read_aloud': readAloud});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child),
      ),
    ));
    return container;
  }

  Widget readAloud(Terminal terminal, {bool speaks = true, VoidCallback? onActivate}) => TerminalReadAloud(
        terminal: terminal,
        name: 'web-01',
        speaks: speaks,
        onActivate: onActivate,
        child: const SizedBox.expand(),
      );

  List<String> said(WidgetTester tester) => [for (final a in tester.takeAnnouncements()) a.message];

  testWidgets('a terminal is one node with its name, a tap and Read the screen', (tester) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await pump(tester, readAloud(Terminal(), onActivate: () => taps++));
    final node = find.bySemanticsLabel('Terminal: web-01');
    expect(node, findsOneWidget);
    final data = tester.getSemantics(node).getSemanticsData();
    expect(data.hint, en.terminalReaderHint);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.customSemanticsActionIds, isNotEmpty);
    tester.semantics.tap(find.semantics.byLabel('Terminal: web-01'));
    expect(taps, 1);
    semantics.dispose();
  });

  testWidgets('new lines are read out once the output pauses, what is typed is not', (tester) async {
    final semantics = tester.ensureSemantics();
    final terminal = Terminal()..resize(40, 6);
    terminal.write('\$ ');
    await pump(tester, readAloud(terminal));
    tester.takeAnnouncements();

    terminal.write('ls');
    await tester.pump(TerminalReadAloud.settle * 2);
    expect(said(tester), isEmpty, reason: 'typing is said by the keyboard');

    terminal.write('\r\nnotes.md  deploy.sh\r\n');
    await tester.pump(const Duration(milliseconds: 100));
    terminal.write('\$ ');
    await tester.pump(const Duration(milliseconds: 100));
    expect(said(tester), isEmpty, reason: 'nothing before the output pauses');
    await tester.pump(TerminalReadAloud.settle);
    expect(said(tester), ['notes.md  deploy.sh\n\$']);
    semantics.dispose();
  });

  testWidgets('many lines at once: the last of them, and how many more came', (tester) async {
    final semantics = tester.ensureSemantics();
    final terminal = Terminal()..resize(40, 30);
    await pump(tester, readAloud(terminal));
    terminal.write([for (var i = 1; i <= 20; i++) 'line $i'].join('\r\n'));
    await tester.pump(TerminalReadAloud.settle * 2);
    final out = said(tester);
    expect(out, hasLength(1));
    final lines = out.single.split('\n');
    expect(lines, hasLength(TerminalReadAloud.maxLines + 1));
    expect(lines.first, 'line 9');
    expect(lines[TerminalReadAloud.maxLines - 1], 'line 20');
    expect(lines.last, en.terminalReaderMore(8));
    semantics.dispose();
  });

  testWidgets('a full-screen program is said once, not line by line', (tester) async {
    final semantics = tester.ensureSemantics();
    final terminal = Terminal()..resize(40, 6);
    await pump(tester, readAloud(terminal));
    terminal.write('\x1b[?1049h');
    terminal.write('top - 10:01:02 up 3 days\r\nTasks: 101 total');
    await tester.pump(TerminalReadAloud.settle * 2);
    expect(said(tester), [en.terminalReaderFullScreen]);
    terminal.write('\r\nTasks: 102 total');
    await tester.pump(TerminalReadAloud.settle * 2);
    expect(said(tester), isEmpty);
    semantics.dispose();
  });

  testWidgets('nothing is read with Read new output aloud off, or from a pane not in front', (tester) async {
    final semantics = tester.ensureSemantics();
    final terminal = Terminal()..resize(40, 6);
    final container = await pump(tester, readAloud(terminal), readAloud: false);
    expect(container.read(terminalReadAloudProvider), isFalse);
    terminal.write('hello\r\n');
    await tester.pump(TerminalReadAloud.settle * 2);
    expect(said(tester), isEmpty);

    final other = Terminal()..resize(40, 6);
    await pump(tester, readAloud(other, speaks: false));
    other.write('from behind\r\n');
    await tester.pump(TerminalReadAloud.settle * 2);
    expect(said(tester), isEmpty);
    semantics.dispose();
  });

  testWidgets('Read the screen: one node to a line, the newest in focus, the arrows go line by line',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final terminal = Terminal()..resize(40, 6);
    terminal.write('first\r\n\r\nthird\r\n\$ ');
    final container = await pump(tester, Builder(
      builder: (context) => TextButton(
        onPressed: () => showTerminalReader(context, terminal: terminal, name: 'web-01'),
        child: const Text('open'),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(en.terminalReaderTitle('web-01')), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(en.terminalReaderTitle('web-01'))).getSemanticsData().flagsCollection.isHeader,
        isTrue);
    for (final line in ['first', en.terminalReaderBlank, 'third', '\$']) {
      expect(find.bySemanticsLabel(line), findsOneWidget, reason: line);
    }
    bool focused(String label) => tester
        .getSemantics(find.bySemanticsLabel(label))
        .getSemanticsData()
        .flagsCollection
        .isFocused == Tristate.isTrue;
    expect(focused('\$'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focused('third'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump();
    expect(focused('first'), isTrue);

    // Its switch turns Read new output aloud off, on this device.
    await tester.tap(find.byKey(const ValueKey('terminal-reader-speak')));
    await tester.pump();
    expect(container.read(terminalReadAloudProvider), isFalse);

    // Esc leaves it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalReaderView), findsNothing);
    semantics.dispose();
  });
}
