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

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// The app's sessions as the test sets them: s1 was opened as another of its
/// host's accounts (Connect as); what opening it again was asked to do is
/// kept, and opens nothing.
class _Reopens extends FakeSessions {
  _Reopens(super.ref);

  final again = <String>[];
  final hostAgain = <(String, String?)>[];

  @override
  String? accountOf(String sessionId) => sessionId == 's1' ? 'i-deploy' : null;

  @override
  Future<String?> openAgain(String sessionId) async {
    again.add(sessionId);
    return null;
  }

  @override
  Future<String?> openHostAgain(String connectionId, {String? account}) async {
    hostAgain.add((connectionId, account));
    return null;
  }
}

/// Try again and Reconnect on a phone's terminal screen (3.0, found
/// while comparing the five versions). Both read the host from
/// the space on screen and opened it as its own account: a session opened
/// with Connect as was tried again as another account, and one of a host of
/// another space did not open at all. Now both open it again as it was, in
/// the space it worked in, as a computer's Reconnect does: the session
/// itself where it is still listed, else its host as the account it was
/// opened with (a connection that failed is taken out of the list while the
/// screen still says why).
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
  final dropped = SessionState.disconnected(
    connectionId: 'c-s1',
    connectionLabel: 'web-01',
    host: '10.50.0.21',
    port: 22,
    errorMessage: refused,
    connectionLog: const ['error: $refused'],
    dropped: true,
  );

  late ProviderContainer container;

  /// The session s1, connecting, on a phone's terminal screen.
  Future<_Reopens> onAPhone(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Reopens.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as _Reopens;
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

  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('Try again of a failed connection that is still listed: the session opened again as it was',
      (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({'s1': failed()});
    await step(tester);
    await tester.tap(find.text(en.retry));
    await step(tester);
    expect(sessions.again, ['s1']);
    expect(sessions.hostAgain, isEmpty);
    expect(find.text('the list of hosts'), findsNothing, reason: 'nothing opened: the screen stays');
    await finish(tester);
  });

  testWidgets('Try again once it is taken out of the list: its host, as the account it was opened with',
      (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({'s1': failed()});
    await step(tester);
    // Taken out of the list, as two seconds after a failure.
    sessions.show({});
    await step(tester);
    await tester.tap(find.text(en.retry));
    await step(tester);
    expect(sessions.hostAgain, [('c-s1', 'i-deploy')]);
    expect(sessions.again, isEmpty);
    await finish(tester);
  });

  testWidgets('Reconnect of a session that dropped: opened again as it was', (tester) async {
    final sessions = await onAPhone(tester);
    sessions.show({'s1': dropped});
    await step(tester);
    await tester.tap(find.text(en.terminalReconnect));
    await step(tester);
    expect(sessions.again, ['s1']);
    expect(find.text('the list of hosts'), findsNothing, reason: 'nothing opened: the screen stays');
    await finish(tester);
  });
}
