import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';
import 'package:zestssh/ui/widgets/title_bar_double_click.dart';

SessionState _state(String label) => SessionState(
  status: SessionStatus.connected,
  connectionId: 'c-$label',
  connectionLabel: label,
  host: '10.50.0.5',
  port: 22,
  username: 'deploy',
);

/// Double-clicking the title bar did nothing (3.3, a Mac user: other Mac
/// apps zoom). It was turned off in 1.7.1, because window_manager's
/// double-tap zoomed on any double-click on the bar, a tab's too. A
/// double-click on the bar's empty space zooms now, or does what a Mac is
/// set to do; one on a tab or a button does nothing to the window, and a
/// tab's click waits for no second one.
void main() {
  late SharedPreferences prefs;
  late int doubleClicks;
  late List<String> selected;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    doubleClicks = 0;
    selected = [];
    debugTitleBarDoubleClicked = () => doubleClicks++;
  });
  tearDown(() => debugTitleBarDoubleClicked = null);

  Future<void> pumpBar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          syncHealthClockProvider.overrideWith(
            (ref) => const Stream<DateTime>.empty(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                PillBar(
                  activeNav: NavSection.hosts,
                  activeSessionId: 't1',
                  sessions: [
                    MapEntry('t1', _state('web-01')),
                    MapEntry('t2', _state('db-01')),
                  ],
                  onNavChanged: (_) {},
                  onSessionSelected: selected.add,
                  onSessionClosed: (_) {},
                  onNewSession: () {},
                  onCommandPalette: () {},
                  onHelp: () {},
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> doubleClickAt(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 10));
    await tester.tapAt(at);
    await tester.pumpAndSettle(kDoubleTapTimeout);
  }

  /// A point on the bar's empty space: in the tab strip, past its last tab.
  Offset emptySpace(WidgetTester tester) {
    final lastTab = tester.getRect(find.text('db-01'));
    final bar = tester.getRect(find.byType(PillBar));
    return Offset(lastTab.right + 160, bar.center.dy);
  }

  testWidgets('a double-click on empty bar space goes to the window', (
    tester,
  ) async {
    await pumpBar(tester);
    await doubleClickAt(tester, emptySpace(tester));
    expect(doubleClicks, 1);
  });

  testWidgets('a double-click on a tab does nothing to the window', (
    tester,
  ) async {
    await pumpBar(tester);
    await doubleClickAt(tester, tester.getCenter(find.text('db-01')));
    expect(doubleClicks, 0);
    expect(selected, isNotEmpty, reason: 'the tab took its clicks');
  });

  testWidgets('a tab\'s click is not held back for a second one', (
    tester,
  ) async {
    await pumpBar(tester);
    await tester.tapAt(tester.getCenter(find.text('db-01')));
    await tester.pump();
    expect(selected, [
      't2',
    ], reason: 'at once, not after the double-click wait');
    await tester.pumpAndSettle(kDoubleTapTimeout);
  });

  testWidgets('one click on empty space is not a double-click', (tester) async {
    await pumpBar(tester);
    await tester.tapAt(emptySpace(tester));
    await tester.pumpAndSettle(kDoubleTapTimeout * 2);
    expect(doubleClicks, 0);
  });

  test('a Mac\'s own setting decides what it does', () {
    expect(titleBarActionOf('Maximize\n', null), TitleBarAction.zoom);
    expect(titleBarActionOf('Fill', null), TitleBarAction.zoom);
    expect(titleBarActionOf('Minimize', null), TitleBarAction.minimize);
    expect(titleBarActionOf('None', null), TitleBarAction.none);
    expect(
      titleBarActionOf(null, null),
      TitleBarAction.zoom,
      reason: 'the system\'s default',
    );
    expect(
      titleBarActionOf(null, '1\n'),
      TitleBarAction.minimize,
      reason: 'the older setting',
    );
    expect(titleBarActionOf(null, '0'), TitleBarAction.zoom);
    expect(
      titleBarActionOf('None', '1'),
      TitleBarAction.none,
      reason: 'the newer setting first',
    );
  });
}
