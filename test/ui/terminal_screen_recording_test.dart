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
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// A recording on a phone is the session's, not its screen's (3.0, found
/// while comparing the five versions): the terminal screen
/// stopped it as it closed and threw it away, though the session went on in
/// the background, and a screen opened again said nothing was recording.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const connecting = SessionState(
    status: SessionStatus.connecting,
    connectionId: 'c-s1',
    connectionLabel: 'web-01',
    host: '192.0.2.21',
    port: 22,
  );

  tearDown(() => SessionTranscriptService.stopRecording('s1'));

  testWidgets('a recording goes on as the screen is left, and the screen shows it each time it opens',
      (tester) async {
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
    (container.read(activeSessionsProvider.notifier) as FakeSessions).show({'s1': connecting});
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
    Future<void> step() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    bool shownAsRecording() => tester.widget<TerminalToolbar>(find.byType(TerminalToolbar)).isRecording;

    // Recording, started on an earlier visit to the session.
    SessionTranscriptService.startRecording('s1', 'web-01');
    router.push('/terminal/s1');
    await step();
    expect(shownAsRecording(), isTrue);

    // The screen is left (back to the list): the session goes on, and so does its recording.
    router.pop();
    await step();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalScreen), findsNothing);
    expect(SessionTranscriptService.isRecording('s1'), isTrue);

    router.push('/terminal/s1');
    await step();
    expect(shownAsRecording(), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  });
}
