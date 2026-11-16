import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// A connection that failed, on a phone's terminal screen (what went wrong
/// showed too briefly to read; it took a screenshot
/// to read the error). A failed connection is taken out
/// of the list of sessions two seconds after it failed, which on a computer
/// is fine (its dialog holds what went wrong), and the phone's screen went
/// back to the list with it. Now what went wrong stays on the screen until
/// its person leaves or tries again, and leaving puts nothing back in the
/// list. A session that is taken out for another reason (its password prompt
/// cancelled) still takes the screen back to the list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  const refused = 'SocketException: Connection refused (OS Error: Connection refused, errno = 111), '
      'address = 10.50.0.21, port = 22';

  const connecting = SessionState(
    status: SessionStatus.connecting,
    connectionId: 'c-s1',
    connectionLabel: 'web-01',
    host: '10.50.0.21',
    port: 22,
  );
  SessionState failed() => SessionState.error(
        refused,
        connectionId: 'c-s1',
        connectionLabel: 'web-01',
        host: '10.50.0.21',
        port: 22,
        connectionLog: const ['Connecting to 10.50.0.21:22', 'error: $refused'],
      );

  late ProviderContainer container;

  /// The session s1, connecting, on a phone's terminal screen opened from the
  /// list of hosts.
  Future<FakeSessions> onAPhone(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
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
    sessions.show({'s1': connecting});
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('the list of hosts'))),
        GoRoute(
          path: '/terminal/:id',
          builder: (_, state) => TerminalScreen(sessionId: state.pathParameters['id']!),
        ),
      ],
    );
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
    expect(find.byType(TerminalScreen), findsOneWidget);
    return sessions;
  }

  /// A frame, and two more [by] apart: a screen that goes back to the list
  /// does so after a frame, and its going takes frames of its own.
  Future<void> step(WidgetTester tester, [Duration by = const Duration(milliseconds: 100)]) async {
    await tester.pump();
    await tester.pump(by);
    await tester.pump(by);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  final errorView = find.byType(ConnectionErrorView);
  final goBack = find.text(en.connectionErrorGoBack);
  final theList = find.text('the list of hosts');

  testWidgets('a connection that failed stays on the screen after it is taken out of the list of sessions',
      (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({'s1': failed()});
    await step(tester);
    expect(errorView, findsOneWidget);

    // Taken out of the list, as two seconds after a failure.
    sessions.show({});
    await step(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'it stays, for its person to read');
    expect(theList, findsNothing);
    expect(errorView, findsOneWidget);
    expect(tester.widget<ConnectionErrorView>(errorView).errorMessage, refused);
    expect(tester.widget<ConnectionErrorView>(errorView).connectionId, 'c-s1', reason: 'what Try again connects to');
    expect(goBack, findsOneWidget);
    expect(container.read(activeSessionsProvider), isEmpty);
    await finish(tester);
  });

  testWidgets('Go back leaves it, and puts nothing back in the list of sessions', (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({'s1': failed()});
    await step(tester);
    sessions.show({});
    await step(tester);
    await tester.tap(goBack);
    await tester.pump();
    // (Looked at at once: what ending it would put back is gone again two
    // seconds later.)
    expect(container.read(activeSessionsProvider).containsKey('s1'), isFalse,
        reason: 'ending a session that is gone would put it back for a moment');
    await step(tester, const Duration(seconds: 1));
    expect(theList, findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(container.read(activeSessionsProvider), isEmpty);
    await finish(tester);
  });

  testWidgets('Go back while the failed session is still listed ends it, as before', (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({'s1': failed()});
    await step(tester);
    await tester.tap(goBack);
    await tester.pump();
    expect(container.read(activeSessionsProvider)['s1']?.status, SessionStatus.disconnected,
        reason: 'it was ended');
    await step(tester, const Duration(seconds: 1));
    expect(theList, findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(container.read(activeSessionsProvider), isEmpty);
    await finish(tester);
  });

  testWidgets('a session taken out without having failed takes the screen back to the list, as before',
      (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({});
    await step(tester, const Duration(seconds: 1));
    expect(theList, findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
    await finish(tester);
  });

  testWidgets('a failure from before is not kept once the session connects again', (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({'s1': failed()});
    await step(tester);
    sessions.show({'s1': connecting});
    await step(tester);
    expect(errorView, findsNothing);
    sessions.show({});
    await step(tester, const Duration(seconds: 1));
    expect(theList, findsOneWidget, reason: 'nothing that failed is on screen to be kept');
    await finish(tester);
  });

  test('what is kept of a failure, as the session goes', () {
    final first = failed();
    final second = SessionState.error('Connection timed out', connectionId: 'c-s1');
    expect(keptFailure(null, null), isNull);
    expect(keptFailure(first, null), same(first));
    expect(keptFailure(null, first), same(first), reason: 'taken out of the list: kept');
    expect(keptFailure(second, first), same(second), reason: 'the latest failure');
    expect(keptFailure(connecting, first), isNull);
    expect(keptFailure(SessionState.disconnected(connectionId: 'c-s1'), first), isNull);
  });
}
