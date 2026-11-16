import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';


class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

SessionState _state(String id, String label, SessionStatus status) => SessionState(
      status: status,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: '10.0.0.${id.hashCode % 200}',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(),
        shell: _Shell(),
        startedAt: DateTime(2026, 11, 13, 9),
      ),
    );

/// A computer's session tabs and a split pane's header to a screen reader and
/// a keyboard (4.0 accessibility pass): each tab one control with its name,
/// its state in words and selected while in front, its close button saying
/// which tab it closes, every tab a stop of Tab that Enter brings to the
/// front, and a state said by a shape as well as a colour. Names here are
/// made up.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  // The window's own buttons ask whether it is maximized.
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => false));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('window_manager'), null));

  Future<void> show(WidgetTester tester, Widget child, {Size size = const Size(1600, 400)}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Align(alignment: Alignment.topCenter, child: child)),
      ),
    ));
    await tester.pump();
  }

  Widget bar({required List<String> selected, required List<String> closed, Set<String> pinned = const {}}) => PillBar(
        activeNav: NavSection.hosts,
        activeSessionId: 's1',
        terminalShown: true,
        pinnedTabIds: pinned,
        sessions: [
          MapEntry('s1', _state('s1', 'web-01', SessionStatus.connected)),
          MapEntry('s2', _state('s2', 'db-primary', SessionStatus.connecting)),
          MapEntry('s3', _state('s3', 'cache-02', SessionStatus.error)),
        ],
        onNavChanged: (_) {},
        onSessionSelected: selected.add,
        onSessionClosed: closed.add,
        onNewSession: () {},
        onCommandPalette: () {},
        onHelp: () {},
      );

  SemanticsData data(WidgetTester tester, String label) =>
      tester.getSemantics(find.bySemanticsLabel(label)).getSemanticsData();

  testWidgets('each tab is one control: its name, its state in words, selected while in front', (tester) async {
    final semantics = tester.ensureSemantics();
    final selected = <String>[], closed = <String>[];
    await show(tester, bar(selected: selected, closed: closed, pinned: {'s3'}));
    final web = data(tester, 'web-01, ${en.sessionInfoStatusConnected}');
    expect(web.flagsCollection.isButton, isTrue);
    expect(web.flagsCollection.isSelected, Tristate.isTrue);
    final db = data(tester, 'db-primary, ${en.sessionInfoStatusConnecting}');
    expect(db.flagsCollection.isSelected, isNot(Tristate.isTrue));
    expect(find.bySemanticsLabel('cache-02, ${en.sessionInfoStatusError}, ${en.a11yTabPinned}'), findsOneWidget);
    // Its menu is an action of its own.
    expect(web.customSemanticsActionIds, isNotEmpty);
    // A screen reader's tap brings a tab to the front.
    tester.semantics.tap(find.semantics.byLabel('db-primary, ${en.sessionInfoStatusConnecting}'));
    expect(selected, ['s2']);
    // The close button of the tab in front says which tab it closes.
    expect(find.bySemanticsLabel(en.desktopTerminalAreaCloseNamedTab('web-01')), findsOneWidget);
    tester.semantics.tap(find.semantics.byLabel(en.desktopTerminalAreaCloseNamedTab('web-01')));
    expect(closed, ['s1']);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  testWidgets('a state is said by a shape as well as a colour', (tester) async {
    await show(tester, bar(selected: [], closed: []));
    expect(find.byKey(const ValueKey('status-mark-connected')), findsOneWidget);
    expect(find.byKey(const ValueKey('status-mark-connecting')), findsOneWidget);
    expect(find.byKey(const ValueKey('status-mark-down')), findsOneWidget);
  });

  testWidgets('the keyboard reaches each tab, Enter brings it to the front, the accent rings it', (tester) async {
    final selected = <String>[];
    await show(tester, bar(selected: selected, closed: []));
    // Tab through until db-primary's tab has the focus.
    Finder ringed() => find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        ((w.decoration! as BoxDecoration).border as Border?)?.top.width == 2);
    var steps = 0;
    while (steps++ < 40) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus;
      final inTab = focus?.context != null &&
          find
              .ancestor(of: find.byElementPredicate((e) => e == focus!.context), matching: find.text('db-primary'))
              .evaluate()
              .isEmpty &&
          find
              .descendant(
                  of: find.byElementPredicate((e) => e == focus!.context), matching: find.text('db-primary'))
              .evaluate()
              .isNotEmpty;
      if (inTab) break;
    }
    expect(steps, lessThan(40), reason: 'a tab is a stop of Tab');
    expect(ringed(), findsOneWidget, reason: 'the accent rings the tab with the focus');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, ['s2']);
  });

  testWidgets("a split pane's header: its session in a sentence, its tabs selected, its disconnect named",
      (tester) async {
    final semantics = tester.ensureSemantics();
    await show(
        tester,
        SizedBox(
          width: 600,
          child: SlimPaneHeader(
            leafId: 'leaf-1',
            sessions: [MapEntry('s1', _state('s1', 'web-01', SessionStatus.connected))],
            activeIndex: 0,
            isFocused: true,
          ),
        ),
        size: const Size(800, 200));
    expect(
        find.bySemanticsLabel('web-01, ${en.sessionInfoStatusConnected}, ${en.a11yPaneInFront}'), findsOneWidget);
    final disconnect = find.bySemanticsLabel(en.a11yDisconnectNamed('web-01'));
    expect(disconnect, findsOneWidget);
    expect(tester.getSemantics(disconnect).rect.width, greaterThanOrEqualTo(32));

    await show(
        tester,
        SizedBox(
          width: 600,
          child: SlimPaneHeader(
            leafId: 'leaf-1',
            sessions: [
              MapEntry('s1', _state('s1', 'web-01', SessionStatus.connected)),
              MapEntry('s2', _state('s2', 'db-primary', SessionStatus.disconnected)),
            ],
            activeIndex: 1,
            isFocused: false,
          ),
        ),
        size: const Size(800, 200));
    expect(data(tester, 'db-primary, ${en.sessionInfoStatusDisconnected}').flagsCollection.isSelected, Tristate.isTrue);
    expect(data(tester, 'web-01, ${en.sessionInfoStatusConnected}').flagsCollection.isSelected, isNot(Tristate.isTrue));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
