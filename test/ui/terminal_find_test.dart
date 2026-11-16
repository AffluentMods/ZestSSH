// Find in terminal, on every version: the bar brings each match into view.
//
// Found while comparing the five versions: a phone's bar
// marked the matches and counted them, and left the terminal where it was, so
// a match up in the scrollback was "3/7" and nowhere to be seen; a computer's
// bar (a bar of the shell's own) counted the first session's matches,
// wherever the keyboard was, marked none and scrolled nowhere (it called a
// scroll the terminal does not have, and swallowed the error). In tmux mode
// both searched the session's own terminal, hidden behind tmux's panes.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';

import 'sharing_ui_fakes.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

/// [lines] lines of output, "needle" on the lines [at].
void _fill(Terminal terminal, int lines, Set<int> at) {
  for (var i = 0; i < lines; i++) {
    terminal.write(at.contains(i) ? 'needle at $i\r\n' : 'line $i\r\n');
  }
}

/// The scroll of [terminal]'s view.
ScrollPosition _scrollOf(WidgetTester tester, Terminal terminal) => tester
    .state<ScrollableState>(find.descendant(
      of: find.byWidgetPredicate((w) => w is TerminalView && identical(w.terminal, terminal)),
      matching: find.byType(Scrollable),
    ))
    .position;

/// Whether buffer line [line] of [terminal]'s view is on screen, whole.
bool _shows(WidgetTester tester, Terminal terminal, int line) {
  final view = tester.state<TerminalViewState>(
      find.byWidgetPredicate((w) => w is TerminalView && identical(w.terminal, terminal)));
  final height = view.renderTerminal.lineHeight;
  final pos = _scrollOf(tester, terminal);
  return line * height >= pos.pixels - 0.5 && (line + 1) * height <= pos.pixels + pos.viewportDimension + 0.5;
}

/// A tmux host attached to [controller], as a session's tab shows it.
class _Host extends ChangeNotifier implements TmuxSessionHost {
  _Host(this.controller);

  @override
  final TmuxController controller;

  @override
  TmuxHostStage get stage => TmuxHostStage.attached;

  @override
  bool get active => true;

  @override
  bool get live => true;

  @override
  String get sessionId => 's1';

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// tmux with two windows, bash (%0, in front) and logs (%1), as the layout
/// notifications of an attach make them.
TmuxController _tmux() {
  final c = TmuxController(sendBytes: (_) {}, expectMarker: false);
  c.onData(utf8.encode('%session-changed \$0 main\n'));
  c.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
  c.onData(utf8.encode('%layout-change @2 bc63,80x24,0,0,1 bc63,80x24,0,0,1 -\n'));
  c.onData(utf8.encode('%window-renamed @1 bash\n%window-renamed @2 logs\n'));
  return c;
}

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget app(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      );

  testWidgets("a terminal's view brings a line to its middle, as far as its scroll lets it", (tester) async {
    final terminal = Terminal(maxLines: 1000);
    _fill(terminal, 200, const {});
    final key = GlobalKey<TerminalViewState>();
    await tester.pumpWidget(app(Center(
      child: SizedBox(width: 600, height: 300, child: TerminalView(terminal, key: key)),
    )));
    await tester.pump();
    final view = key.currentState!;
    final height = view.renderTerminal.lineHeight;
    final pos = _scrollOf(tester, terminal);
    expect(pos.pixels, pos.maxScrollExtent, reason: 'at the end, as a terminal opens');
    expect(_shows(tester, terminal, 60), isFalse);

    expect(view.scrollToLine(60), isTrue);
    await tester.pump();
    expect(_shows(tester, terminal, 60), isTrue);
    expect((pos.pixels + pos.viewportDimension / 2 - (60 * height + height / 2)).abs(), lessThan(1),
        reason: 'in the middle');

    view.scrollToLine(1);
    await tester.pump();
    expect(pos.pixels, pos.minScrollExtent, reason: 'no further than the top');
    view.scrollToLine(199);
    await tester.pump();
    expect(pos.pixels, pos.maxScrollExtent, reason: 'nor past the end');
  });

  testWidgets('the bar shows each match: the last as it is found, Enter the next and Shift+Enter the one before, '
      "the field keeping the keyboard; Enter before the search ran searches then; an input method's Enter is its "
      'own; Escape closes it', (tester) async {
    final terminal = Terminal(maxLines: 1000);
    _fill(terminal, 120, const {20, 45, 70});
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final field = FocusNode();
    addTearDown(field.dispose);
    final shown = <int>[];
    var closed = 0;
    await tester.pumpWidget(app(Column(children: [
      TerminalSearchBar(
        terminal: terminal,
        controller: controller,
        theme: TerminalThemes.defaultTheme,
        focusNode: field,
        onShowLine: shown.add,
        onClose: () => closed++,
      ),
    ])));
    await tester.pump();
    expect(field.hasFocus, isTrue, reason: 'the field it was given takes the keyboard');

    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pump(const Duration(milliseconds: 250));
    expect(shown, [70], reason: 'the last match, the most recent output');
    expect(find.text('3/3'), findsOneWidget);
    expect(controller.highlights, hasLength(3), reason: 'all marked');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(shown, [70, 20], reason: 'Enter: the next, round to the first');
    expect(find.text('1/3'), findsOneWidget);
    expect(field.hasFocus, isTrue, reason: 'the field keeps the keyboard');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(shown, [70, 20, 70], reason: 'Shift+Enter: the one before, round to the last');

    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(shown, [70, 20, 70, 20], reason: "the keypad's Enter too");

    // Typed, and Enter at once: searched then, at its last match.
    await tester.enterText(find.byType(TextField), 'needle at 2');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(shown.last, 20);
    expect(find.text('1/1'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(shown, hasLength(5), reason: 'and not once more when the wait is over');

    // A word an input method is composing: its Enter ends the word.
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'needle',
      selection: TextSelection.collapsed(offset: 6),
      composing: TextRange(start: 0, end: 6),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(shown, hasLength(5), reason: "the input method's Enter");
    await tester.pump(const Duration(milliseconds: 250));
    expect(shown.last, 70, reason: 'searched when typing stops, as ever');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1, reason: 'Escape closes the bar');
  });

  testWidgets('another terminal to search: the marks leave the first, and the same words are looked for in it; so '
      'too where only the terminal is another (a tmux pane captured anew)', (tester) async {
    final first = Terminal(maxLines: 1000), second = Terminal(maxLines: 1000), third = Terminal(maxLines: 1000);
    _fill(first, 40, const {5});
    _fill(second, 40, const {12, 30});
    _fill(third, 40, const {8});
    final ctrlFirst = TerminalController(), ctrlSecond = TerminalController();
    addTearDown(ctrlFirst.dispose);
    addTearDown(ctrlSecond.dispose);
    final which = ValueNotifier(0);
    addTearDown(which.dispose);
    final shown = <int>[];
    await tester.pumpWidget(app(ValueListenableBuilder<int>(
      valueListenable: which,
      builder: (_, i, _) => TerminalSearchBar(
        terminal: [first, second, third][i],
        controller: i == 0 ? ctrlFirst : ctrlSecond,
        theme: TerminalThemes.defaultTheme,
        onShowLine: shown.add,
        onClose: () {},
      ),
    )));
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.pump(const Duration(milliseconds: 250));
    expect(shown, [5]);
    expect(ctrlFirst.highlights, hasLength(1));

    which.value = 1;
    await tester.pump();
    expect(ctrlFirst.highlights, isEmpty, reason: 'the marks leave the first');
    expect(ctrlSecond.highlights, hasLength(2));
    expect(shown, [5, 30]);
    expect(find.text('2/2'), findsOneWidget);

    which.value = 2;
    await tester.pump();
    expect(shown, [5, 30, 8], reason: 'the same controller, another terminal');
    expect(find.text('1/1'), findsOneWidget);
    expect(ctrlSecond.highlights, hasLength(1));
  });

  group('in tmux mode', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues(const {'tmux_intro_seen': true});
      prefs = await SharedPreferences.getInstance();
    });

    testWidgets('Find searches the pane in front, and the next one in front in its turn; asked for again its field '
        'takes the keyboard back; closed, the keyboard goes back to the pane', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _tmux();
      addTearDown(c.dispose);
      final bash = c.windows.first.activePane!.terminal;
      final logs = c.windows.last.activePane!.terminal;
      _fill(bash, 80, const {6});
      _fill(logs, 80, const {9, 50});
      final open = ValueNotifier((false, 0));
      addTearDown(open.dispose);
      var closed = 0;
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: app(ValueListenableBuilder<(bool, int)>(
          valueListenable: open,
          builder: (_, asked, _) => TmuxSessionView(
            host: _Host(c),
            onLeave: () {},
            findOpen: asked.$1,
            findAsk: asked.$2,
            onFindClose: () {
              closed++;
              open.value = (false, 0);
            },
          ),
        )),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TerminalSearchBar), findsNothing);
      expect(_shows(tester, bash, 6), isFalse);

      open.value = (true, 0);
      await tester.pump();
      final bar = find.byType(TerminalSearchBar);
      expect(tester.widget<TerminalSearchBar>(bar).terminal, same(bash), reason: 'the pane in front');
      final field = find.descendant(of: bar, matching: find.byType(TextField));
      await tester.enterText(field, 'needle');
      await tester.pump(const Duration(milliseconds: 250));
      expect(_shows(tester, bash, 6), isTrue, reason: 'its match brought into view');

      // Another window, so another pane, in front.
      await tester.tap(find.text('logs'));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<TerminalSearchBar>(bar).terminal, same(logs));
      expect(find.text('2/2'), findsOneWidget, reason: 'the same words, looked for in it');
      expect(_shows(tester, logs, 50), isTrue);

      final pane = tester.widget<TerminalView>(find.byWidgetPredicate((w) => w is TerminalView && identical(w.terminal, logs)));
      pane.focusNode!.requestFocus();
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      open.value = (true, 1);
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue, reason: 'asked for again');
      expect(find.byType(TerminalSearchBar), findsOneWidget, reason: 'and still open');

      // Closed with the keyboard in neither the bar nor a pane (a click on its
      // close button takes no keyboard).
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(pane.focusNode!.hasFocus, isFalse);
      await tester.tap(find.byTooltip(_l10n.terminalSearchClose));
      await tester.pump();
      await tester.pump();
      expect(closed, 1);
      expect(find.byType(TerminalSearchBar), findsNothing);
      expect(pane.focusNode!.hasFocus, isTrue, reason: 'the keyboard back to the pane in front');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group("a phone's terminal screen", () {
    Future<FakeSessions> pumpScreen(WidgetTester tester, {TmuxSessionHost? tmux}) async {
      tester.view.physicalSize = const Size(1800, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {'cursor_blink': false, 'tmux_intro_seen': true});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(FakeSessions.new),
        connectionHealthProvider.overrideWith((ref) => _Health()),
        if (tmux != null) tmuxHostProvider.overrideWith((ref, sessionId) => tmux),
      ]);
      addTearDown(container.dispose);
      final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
      sessions.show({'s1': connectedSession('s1', 'Web s1')});
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
      return sessions;
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets('its bar brings a match in the scrollback into view', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final sessions = await pumpScreen(tester);
      final terminal = sessions.state['s1']!.session!.terminal;
      _fill(terminal, 150, const {12});
      await tester.pump();
      expect(_shows(tester, terminal, 12), isFalse);

      await tester.tap(find.byTooltip(_l10n.termTbFind));
      await tester.pump();
      await tester.enterText(find.descendant(of: find.byType(TerminalSearchBar), matching: find.byType(TextField)), 'needle');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1/1'), findsOneWidget);
      expect(_shows(tester, terminal, 12), isTrue, reason: 'it was counted, and left where it was');
      await finish(tester);
    });

    testWidgets('in tmux mode its bar searches the tmux pane in front, and closes', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final c = _tmux();
      addTearDown(c.dispose);
      final pane = c.windows.first.activePane!.terminal;
      _fill(pane, 60, const {4});
      await pumpScreen(tester, tmux: _Host(c));
      expect(find.byType(TmuxSessionView), findsOneWidget);

      await tester.tap(find.byTooltip(_l10n.termTbFind));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TerminalSearchBar), findsOneWidget, reason: "tmux's alone: not the session's own as well");
      expect(tester.widget<TerminalSearchBar>(find.byType(TerminalSearchBar)).terminal, same(pane),
          reason: "the pane's, not the session's hidden behind it");
      await tester.enterText(find.descendant(of: find.byType(TerminalSearchBar), matching: find.byType(TextField)), 'needle');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1/1'), findsOneWidget);
      expect(_shows(tester, pane, 4), isTrue);

      await tester.tap(find.byTooltip(_l10n.terminalSearchClose));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TerminalSearchBar), findsNothing);
      await tester.tap(find.byTooltip(_l10n.termTbFind));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TerminalSearchBar), findsOneWidget, reason: 'and opens again');
      await finish(tester);
    });
  });
}
