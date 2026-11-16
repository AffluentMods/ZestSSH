import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/terminal/widgets/session_info_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

import '../visual/shots_util.dart';

/// The phone's session info (3.0): the app's own dialog, in its
/// language, with the host's name, its address and the user masked in
/// recording mode. It was a plain dialog in English that showed them as they
/// are while recording.
void main() {
  Future<void> open(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    bool recording = false,
    String? label = 'web-01',
    String? host = '10.50.0.5',
    String? username = 'demo',
    DateTime? connectedAt,
    OsKind? os = OsKind.ubuntu,
    Size size = const Size(1000, 800),
    bool phone = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = phone ? TargetPlatform.android : null;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    Redactor.instance.enabled = recording;
    addTearDown(() => Redactor.instance.enabled = false);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
      ],
      child: MaterialApp(
        locale: locale,
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const SizedBox();
        })),
      ),
    ));
    SessionInfoDialog.show(
      context,
      host: host,
      username: username,
      port: 2222,
      connectedAt: connectedAt ?? DateTime.now().subtract(const Duration(hours: 2, minutes: 5)),
      detectedOs: os,
      connectionLabel: label,
    );
    await tester.pumpAndSettle();
  }

  testWidgets("the app's own dialog, in its words: the host, the user, the port, how long, the OS, and Close",
      (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    await open(tester);
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.text('web-01'), findsOneWidget);
    for (final label in [en.sessionDetailsHostname, en.sessionDetailsUsername, en.sessionDetailsPort,
        en.sessionInfoConnectedFor, en.sessionDetailsOs]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('10.50.0.5'), findsOneWidget);
    expect(find.text('demo'), findsOneWidget);
    expect(find.text('2222'), findsOneWidget);
    expect(find.text('2h 5m'), findsOneWidget);
    await tester.tap(find.text(en.close));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsNothing);
  });

  testWidgets('in recording mode the name, the address and the user are masked', (tester) async {
    await open(tester, recording: true);
    for (final shown in ['web-01', '10.50.0.5', 'demo']) {
      expect(find.textContaining(shown), findsNothing, reason: shown);
    }
    expect(find.text(Redactable.host('web-01').display), findsOneWidget);
    expect(find.text(Redactable.address('10.50.0.5').display), findsOneWidget);
    expect(find.text(Redactable.username('demo').display), findsOneWidget);
  });

  testWidgets('what is not known says so, a session with no name is named by its kind, no OS row for none',
      (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    await open(tester, locale: const Locale('de'), label: null, host: null, username: null, os: OsKind.unknown);
    expect(find.text(de.sessionDetailsTitle), findsOneWidget);
    for (final label in [de.sessionDetailsHostname, de.sessionDetailsUsername, de.sessionInfoConnectedFor]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text(de.homeUnknown), findsNWidgets(2));
    expect(find.text(de.sessionDetailsOs), findsNothing);
    expect(find.text(de.close), findsOneWidget);

    // The OS row in a language where it is not "OS".
    final zh = lookupAppLocalizations(const Locale('zh'));
    await open(tester, locale: const Locale('zh'));
    expect(find.text(zh.sessionDetailsOs), findsOneWidget);
  });

  // In the one compact style: a session
  // of 42 seconds said "0m 42s", one of two days "49h 5m".
  test('how long, in the app\'s words', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(SessionInfoDialog.durationText(en, null), en.homeUnknown);
    expect(SessionInfoDialog.durationText(en, const Duration(hours: 3, minutes: 7, seconds: 9)), '3h 7m');
    expect(SessionInfoDialog.durationText(en, const Duration(minutes: 4, seconds: 9)), '4m 9s');
    expect(SessionInfoDialog.durationText(en, const Duration(seconds: 42)), '42s');
    expect(SessionInfoDialog.durationText(en, const Duration(hours: 49, minutes: 5)), '2d 1h');
    final de = lookupAppLocalizations(const Locale('de'));
    expect(SessionInfoDialog.durationText(de, const Duration(hours: 3, minutes: 7)), '3 Std. 7 Min.');
  });

  testWidgets('in every language, on a small phone: nothing clipped', (tester) async {
    await tester.runAsync(loadShotFonts);
    try {
      for (final locale in AppLocalizations.supportedLocales) {
        await open(tester, locale: locale, size: const Size(320, 568), phone: true);
        expect(tester.takeException(), isNull, reason: '$locale');
        await tester.pumpWidget(const SizedBox());
      }
    } finally {
      // Before the test ends (it checks), not in a tear-down.
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
