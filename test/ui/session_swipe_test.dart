// Swiping between a phone's sessions (3.1):
// a sideways swipe on the terminal's top bar moves to the previous or
// the next session, in the Sessions tab's order (grouped by host), sliding
// in and saying the session's name for a moment. A swipe across the terminal
// itself moves nothing (it selects text, scrolls less and htop, drives
// tmux); with no session on that side the bar bounces. A computer's and a
// tablet's terminals keep their bar as it was.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/router.dart' show terminalPage;
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/terminal/session_swipe.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/utils/platform_utils.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// The terminal of [open] on a screen of [size] (touch, unless
  /// [computer]), with [sessions] open; [open] pushed over Home.
  Future<GoRouter> pumpTerminal(
    WidgetTester tester, {
    required Map<String, SessionState> sessions,
    required String open,
    Size size = const Size(430, 932),
    bool computer = false,
  }) async {
    debugTouchLayout = !computer;
    addTearDown(() => debugTouchLayout = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const <ConnectionWithDetails>[])),
    ]);
    addTearDown(container.dispose);
    (container.read(activeSessionsProvider.notifier) as FakeSessions).show(sessions);
    final router = GoRouter(routes: [
      GoRoute(path: Routes.home, builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: Routes.terminal, pageBuilder: (_, state) => terminalPage(state)),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    await tester.pump();
    router.push('/terminal/$open');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    return router;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  /// The session on screen.
  String onScreen(WidgetTester tester) => tester.widget<TerminalScreen>(find.byType(TerminalScreen)).sessionId;

  final header = find.byKey(const ValueKey('session-swipe-header'));
  final name = find.byKey(const ValueKey('session-arrival-name'));
  double shift(WidgetTester tester) =>
      tester.widget<Transform>(find.byKey(const ValueKey('session-swipe-shift'))).transform.getTranslation().x;

  // Two on one host, one on another: the Sessions tab lists web-a's two
  // (the same host, grouped), then db-b.
  Map<String, SessionState> three() => {
        'a': connectedSession('a', 'web-a', host: '10.50.0.21'),
        'b': connectedSession('b', 'db-b', host: '10.50.0.22'),
        'c': connectedSession('c', 'web-a', host: '10.50.0.21'),
      };

  test('the order is the Sessions tab\'s: grouped by host, then as opened; dropped ones too, ended ones not', () {
    final sessions = {
      ...three(),
      'd': const SessionState(status: SessionStatus.disconnected, connectionLabel: 'old', host: '10.50.0.22'),
      'e': const SessionState(status: SessionStatus.error, connectionLabel: 'gone', host: '10.50.0.21'),
    };
    expect(sessionsInTabOrder(sessions, const [], unknown: '?'), ['a', 'c', 'b', 'd']);
  });

  test('a host is grouped by its name, its address under it: two names at one address are two hosts', () {
    // (The tab used to group by the address.)
    final sessions = {
      'a': connectedSession('a', 'web-a', host: '10.50.0.21'),
      'b': connectedSession('b', 'web-b', host: '10.50.0.21'),
      'c': connectedSession('c', 'web-a', host: '10.50.0.21'),
    };
    expect(sessionsInTabOrder(sessions, const [], unknown: '?'), ['a', 'c', 'b']);
    expect(sessionsTabHost(sessions['b']!, null, '?'), (name: 'web-b', address: '10.50.0.21'));
    expect(sessionsTabHost(const SessionState(status: SessionStatus.disconnected, host: '10.50.0.9', port: 2222), null, '?'),
        (name: '', address: '10.50.0.9:2222'), reason: 'no name: its address, with a port that is not 22');
    expect(sessionsTabHost(const SessionState(status: SessionStatus.disconnected), null, '?'), (name: '?', address: ''));
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name}, 430 by 932: a swipe on the top bar moves to the next session and back, in the '
        'Sessions tab\'s order, and says the name', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpTerminal(tester, sessions: three(), open: 'c');
        expect(onScreen(tester), 'c');
        expect(header, findsOneWidget);

        // To the left: the next one, db-b (after web-c in the tab's order).
        await tester.drag(header, const Offset(-200, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byType(TerminalScreen), findsNWidgets(2), reason: 'sliding in over the one it leaves');
        await tester.pump(const Duration(milliseconds: 300));
        expect(onScreen(tester), 'b');
        expect(name, findsOneWidget);
        expect(find.descendant(of: name, matching: find.text('db-b')), findsOneWidget);
        expect(find.descendant(of: name, matching: find.text(l10n.sessionSwipePosition(3, 3))), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(name, findsNothing, reason: 'the name for a moment only');

        // To the right, twice: web-c, then web-a.
        await tester.drag(header, const Offset(200, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(onScreen(tester), 'c');
        await tester.drag(header, const Offset(200, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(onScreen(tester), 'a');
        expect(find.descendant(of: name, matching: find.text(l10n.sessionSwipePosition(1, 3))), findsOneWidget);

        // At the first one, a swipe to the right has no session to go to: a
        // bounce, and web-a stays.
        await tester.drag(header, const Offset(200, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(shift(tester), greaterThan(0), reason: 'the bar goes a little way');
        await tester.pump(const Duration(seconds: 1));
        expect(shift(tester), 0, reason: 'and comes back');
        expect(onScreen(tester), 'a');
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on ${platform.name}, 430 by 932: a swipe across the terminal itself moves no session',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpTerminal(tester, sessions: three(), open: 'c');
        final view = find.byType(TerminalView);
        for (final dx in [-250.0, 250.0]) {
          await tester.drag(view, Offset(dx, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(onScreen(tester), 'c', reason: 'a drag of $dx on the terminal');
          expect(find.byType(TerminalScreen), findsOneWidget);
          expect(name, findsNothing);
        }
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on ${platform.name}, 430 by 932: with one session a swipe bounces and moves nothing',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpTerminal(tester, sessions: {'a': connectedSession('a', 'web-a')}, open: 'a');
        for (final dx in [-200.0, 200.0]) {
          await tester.drag(header, Offset(dx, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(shift(tester).sign, dx.sign, reason: 'a small bounce the way of the swipe');
          await tester.pump(const Duration(seconds: 1));
          expect(shift(tester), 0);
          expect(onScreen(tester), 'a');
          expect(find.byType(TerminalScreen), findsOneWidget);
        }
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('a computer\'s terminal and a tablet\'s keep their top bar as it was: no swipe', (tester) async {
    await pumpTerminal(tester, sessions: three(), open: 'c', size: const Size(1440, 900), computer: true);
    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(header, findsNothing);
    await finish(tester);

    await pumpTerminal(tester, sessions: three(), open: 'c', size: const Size(820, 1180));
    expect(find.byType(TerminalScreen), findsOneWidget);
    expect(header, findsNothing);
    await finish(tester);
  });
}
