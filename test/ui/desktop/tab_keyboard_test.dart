import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';

import '../sharing_ui_fakes.dart';

// A tab picked on a computer gives its terminal the keyboard. It took a
// click to pick the tab and a second, into the terminal, before anything
// could be typed (an extra click every time):
// the terminal that had the keyboard went behind the one picked,
// where it cannot keep it, and nothing gave the one in front the keyboard.

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late Map<String, List<String>> typed;

  /// Two sessions, each in a tab of its own, s1's in front.
  Future<FakeSessions> pumpArea(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
    // (The tabs, read first, give each session that comes a tab of its own.)
    final tabs = container.read(workTabsProvider.notifier);
    sessions.show({'s1': connectedSession('s1', 'Web 1'), 's2': connectedSession('s2', 'Web 2')});
    tabs.setActiveTab(tabs.tabContaining('s1')!.id);
    container.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    typed = {'s1': [], 's2': []};
    for (final id in ['s1', 's2']) {
      sessions.state[id]!.session!.terminal.onOutput = typed[id]!.add;
    }
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Column(
            children: [
              // Something else that takes the keyboard, as the shell's
              // search does.
              const TextField(key: ValueKey('elsewhere')),
              Expanded(
                child: DesktopTerminalArea(onConnectTo: (_) {}, onToggleSftp: (_) {}, onApplyLayout: (_) {}),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return sessions;
  }

  /// The tab of [sessionId] picked, as the shell's pill and its keys pick
  /// one (DesktopShell._selectTab).
  Future<void> pick(WidgetTester tester, String sessionId) async {
    final tabs = container.read(workTabsProvider.notifier);
    tabs.setActiveTab(tabs.tabContaining(sessionId)!.id);
    final index = ['s1', 's2'].indexOf(sessionId);
    container.read(desktopSelectedTabProvider.notifier).state = index;
    container.read(terminalKeyboardAskProvider.notifier).state++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  FocusNode? focusOf(WidgetTester tester, String sessionId, FakeSessions sessions) {
    final terminal = sessions.state[sessionId]!.session!.terminal;
    final view = tester.widgetList<TerminalView>(find.byType(TerminalView, skipOffstage: false))
        .where((v) => identical(v.terminal, terminal))
        .firstOrNull;
    return view?.focusNode;
  }

  Future<void> type(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
  }

  testWidgets('the terminal of a tab picked takes the keyboard: what is typed goes to it at once', (tester) async {
    final sessions = await pumpArea(tester);
    expect(focusOf(tester, 's1', sessions)!.hasFocus, isTrue, reason: 'the tab in front as it opens');

    await pick(tester, 's2');
    expect(focusOf(tester, 's2', sessions)!.hasFocus, isTrue);
    await type(tester);
    expect(typed['s2'], ['a']);
    expect(typed['s1'], isEmpty);

    await pick(tester, 's1');
    expect(focusOf(tester, 's1', sessions)!.hasFocus, isTrue);
    await type(tester);
    expect(typed['s1'], ['a']);
    expect(typed['s2'], ['a']);
  });

  testWidgets('the tab in front picked again, with the keyboard elsewhere, takes it back', (tester) async {
    final sessions = await pumpArea(tester);
    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pump();
    expect(focusOf(tester, 's1', sessions)!.hasFocus, isFalse);

    await pick(tester, 's1');
    expect(focusOf(tester, 's1', sessions)!.hasFocus, isTrue);
    await type(tester);
    expect(typed['s1'], ['a']);
  });

  testWidgets('a tab picked under a dialog leaves the keyboard in the dialog', (tester) async {
    final sessions = await pumpArea(tester);
    showDialog<void>(
      context: tester.element(find.byType(DesktopTerminalArea)),
      builder: (_) => const Dialog(child: TextField(key: ValueKey('in-dialog'), autofocus: true)),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(
        find.descendant(of: find.byKey(const ValueKey('in-dialog')), matching: find.byType(EditableText)));
    expect(field.focusNode.hasFocus, isTrue);

    await pick(tester, 's2');
    expect(field.focusNode.hasFocus, isTrue);
    expect(focusOf(tester, 's2', sessions)!.hasFocus, isFalse);
  });

  testWidgets('a split tab picked: its first terminal takes the keyboard', (tester) async {
    final sessions = await pumpArea(tester);
    // s1's tab split, s2 beside it, then s2's tab... gone into it: one tab.
    await pick(tester, 's2');
    final panes = container.read(paneTreeProvider.notifier);
    panes.initSinglePane('s1');
    final leaf = container.read(paneTreeProvider)!.allLeaves.first.id;
    panes.splitPaneDirectional(leaf, Axis.horizontal, 's2', false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(paneTreeProvider), isA<PaneSplit>());

    await tester.tap(find.byKey(const ValueKey('elsewhere')));
    await tester.pump();
    container.read(focusedPaneProvider.notifier).state = null;
    container.read(terminalKeyboardAskProvider.notifier).state++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(focusOf(tester, 's1', sessions)!.hasFocus, isTrue);
    await type(tester);
    expect(typed['s1'], ['a']);
  });
}
