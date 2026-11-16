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
import 'package:zestssh/services/ssh_service.dart' show hostKeyFailedAtNewKeys, hostStoppedAnswering;
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// A phone's terminal screen once its session is disconnected and nothing
/// connects it again by itself: it closes by itself a moment later, back to
/// where it was opened from. Not where there is something for its person to
/// read: a session that was ended over its host's key when new keys were
/// taken (3.0, from the SSH core's audit) says what happened in three
/// sentences, and why a connection dropped is said a moment after it did,
/// when the screen has begun to close. It closed under what it said.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  SessionState dropped({String? cause}) => SessionState.disconnected(
        connectionId: 'c-s1',
        connectionLabel: 'web-01',
        host: '10.50.0.21',
        port: 22,
        dropped: true,
        dropCause: cause,
      );

  /// The session s1 on a phone's terminal screen, opened from the list of
  /// hosts.
  Future<FakeSessions> onAPhone(WidgetTester tester) async {
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
    sessions.show({'s1': connectedSession('s1', 'web-01')});
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

  /// The connection of s1 drops, and a moment later it says why ([cause]).
  Future<void> drops(WidgetTester tester, FakeSessions sessions, String cause) async {
    sessions.show({'s1': dropped()});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(en.terminalDisconnected), findsWidgets);
    expect(find.text(en.terminalClosing), findsOneWidget, reason: 'nothing is known yet: it closes by itself');
    sessions.show({'s1': dropped(cause: cause)});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('a session that was ended over its host\'s key when new keys were taken stays on the screen, which '
      'no longer says that it is closing', (tester) async {
    final sessions = await onAPhone(tester);
    await drops(tester, sessions, hostKeyFailedAtNewKeys);
    expect(find.text(en.connHostKeyFailedAtNewKeys), findsOneWidget);
    final saidClosing = find.text(en.terminalClosing).evaluate().isNotEmpty;
    // Longer than a screen that closes by itself waits.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalScreen), findsOneWidget, reason: 'it stays, for its person to read');
    expect(find.text('the list of hosts'), findsNothing);
    expect(find.text(en.connHostKeyFailedAtNewKeys), findsOneWidget);
    expect(saidClosing, isFalse, reason: 'it said that it was closing, under what it had to say');
    expect(find.text(en.terminalClosing), findsNothing);
    expect(find.byKey(const ValueKey('terminal-reconnect')), findsOneWidget, reason: 'connecting again is theirs to do');
    expect(find.byKey(const ValueKey('error-details-toggle')), findsOneWidget, reason: 'with its report');
    await finish(tester);
  });

  testWidgets('a connection that dropped for another reason: the screen closes by itself, as before', (tester) async {
    final sessions = await onAPhone(tester);
    await drops(tester, sessions, hostStoppedAnswering);
    expect(find.text(en.connectionLostNoAnswer('web-01')), findsOneWidget);
    expect(find.text(en.terminalClosing), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalScreen), findsNothing);
    expect(find.text('the list of hosts'), findsOneWidget);
    await finish(tester);
  });
}
