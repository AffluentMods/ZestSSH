// A phone's remote screen in the background (4.0, commit 13): paused as the
// app leaves the screen (the server sends nothing), the whole picture again
// when it is back; the zoom, pan, scaling, view only and mode kept for the
// same screen connected again (iOS closes it in the background); the page a
// screen closed in the background shows meanwhile.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

import '../features/screens/view/screen_view_fixture.dart';

Future<(ScreenSession, FakeScreenSession)> _connect(WidgetTester tester) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
  final engine = native.sessions.single;
  engine.connect(width: 800, height: 500);
  await tester.pump();
  addTearDown(session.close);
  return (session, engine);
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpPhone(WidgetTester tester, {ScreenSession? session, Widget? stateBody}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: PhoneScreenView(
          sessionId: 's1',
          connectionId: 'c1',
          label: 'build box',
          session: session,
          stateBody: stateBody,
          onBack: () {},
          onDisconnect: () {},
          decodeTile: syncDecode,
        ),
      ),
    ));
    await tester.pump();
  }

  ScreenController controllerOf(WidgetTester tester) => tester.widget<ScreenView>(find.byType(ScreenView)).controller;

  Future<void> away(WidgetTester tester) async {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
  }

  Future<void> back(WidgetTester tester) async {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
  }

  testWidgets('the app leaves the screen: paused (the server sends nothing); back: resumed, the whole picture first',
      (tester) async {
    final (session, engine) = await _connect(tester);
    await pumpPhone(tester, session: session);
    final c = controllerOf(tester);
    expect(c.isPaused, isFalse);
    expect(engine.pauses, 0);

    await away(tester);
    expect(c.isPaused, isTrue);
    expect(session.isPaused, isTrue);
    expect(engine.pauses, 1, reason: 'once, though hidden and paused both came');

    await back(tester);
    expect(c.isPaused, isFalse);
    expect(engine.resumes, 1, reason: 'resume asks the server for the whole screen');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a page left paused (Back to the list) is not resumed by the app coming back', (tester) async {
    final (session, engine) = await _connect(tester);
    await pumpPhone(tester, session: session);
    controllerOf(tester).pause();
    await away(tester);
    await back(tester);
    expect(controllerOf(tester).isPaused, isTrue);
    expect(engine.resumes, 0);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('connected again (iOS closed it in the background): the same zoom, pan, scaling, view only and mode',
      (tester) async {
    final (first, _) = await _connect(tester);
    await pumpPhone(tester, session: first);
    final c = controllerOf(tester);
    c.fit = ScreenFit.fill;
    c.viewport.zoomTo(2.5, const Offset(600, 300), const Offset(195, 400));
    c.viewOnly = true;
    c.touchMode = ScreenTouchMode.mousePointer;
    final zoom = c.viewport.zoom;
    final origin = c.viewport.origin;
    expect(zoom, greaterThan(1));

    // Closed: the page shows its state meanwhile.
    await pumpPhone(tester, stateBody: const ScreenParkedView());
    expect(find.text('Paused while ZestSSH is in the background. It reconnects when you come back.'), findsOneWidget);
    await pumpPhone(tester, stateBody: const ScreenParkedView(reconnecting: true));
    expect(find.text('Connecting the remote screen again'), findsOneWidget);

    final (again, engine) = await _connect(tester);
    await pumpPhone(tester, session: again);
    final c2 = controllerOf(tester);
    expect(identical(c, c2), isFalse);
    expect(c2.fit, ScreenFit.fill);
    expect(c2.viewport.zoom, closeTo(zoom, 1e-9));
    expect(c2.viewport.origin, origin);
    expect(c2.viewOnly, isTrue);
    expect(c2.touchMode, ScreenTouchMode.mousePointer);
    expect(engine.fullRefreshes, 1, reason: 'the whole picture of the new session');
    await tester.pump(const Duration(seconds: 5));
  });
}
