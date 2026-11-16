import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/widgets/app_lock_offer.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../a11y/a11y_checks.dart';

/// The app lock is offered once, after the first private key or saved
/// password (found in a security review): on a phone, and on a computer too (4.0,
/// for parity), in the computer's dialog with the computer's
/// words. It stays the person's choice, it is not asked again after Not now,
/// and it is not asked of anyone who has it on already.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester, {bool enabled = true, Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      appLockOfferEnabledProvider.overrideWithValue(enabled),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => maybeOfferAppLock(context, ref),
              child: const Text('saved'),
            ),
          ),
        ),
      ),
    ));
    return c;
  }

  /// [body] on [platform], drawn as a phone's ([touch]) or a computer's.
  void on(String name, TargetPlatform platform, Future<void> Function(WidgetTester tester) body, {bool touch = false}) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      debugTouchLayout = touch;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTouchLayout = null;
      }
    });
  }

  on('a phone: asked once, and Not now is not asked again', TargetPlatform.android, touch: true, (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferTitle), findsOneWidget);
    expect(find.text(en.appLockOfferBody), findsOneWidget);
    await tester.tap(find.text(en.notNow));
    await tester.pumpAndSettle();
    expect(c.read(settingsServiceProvider).appLockOffered, isTrue);

    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferTitle), findsNothing);
  });

  on('a computer: asked once in its dialog, naming Windows Hello; Not now is not asked again', TargetPlatform.windows,
      (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text(en.appLockOfferTitleComputer), findsOneWidget);
    expect(find.text(en.appLockOfferBodyComputer('Windows Hello')), findsOneWidget);
    expect(find.text(en.appLockOfferTitle), findsNothing);
    await tester.tap(find.text(en.notNow));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(c.read(settingsServiceProvider).appLockOffered, isTrue);

    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferTitleComputer), findsNothing);
  });

  on('a computer: Esc is Not now, and it is not asked again', TargetPlatform.macOS, (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferBodyComputer('Touch ID')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferTitleComputer), findsNothing);
    expect(c.read(settingsServiceProvider).appLockOffered, isTrue);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferTitleComputer), findsNothing);
  });

  on('a computer: Turn on goes on to choosing a PIN', TargetPlatform.windows, (tester) async {
    await pump(tester);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.appLockOfferTurnOn));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(en.appLockOfferTitleComputer), findsNothing);
    // PIN setup opened as the computer's dialog.
    expect(find.byType(Dialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  test("each computer's words: Windows Hello, Touch ID, a PIN alone on Linux; a phone's own", () {
    expect(appLockOfferWords(en, TargetPlatform.windows),
        (title: en.appLockOfferTitleComputer, body: en.appLockOfferBodyComputer(en.pinSetupBiometricFactorWindowsHello)));
    expect(appLockOfferWords(en, TargetPlatform.macOS),
        (title: en.appLockOfferTitleComputer, body: en.appLockOfferBodyComputer(en.pinSetupBiometricFactorTouchId)));
    expect(appLockOfferWords(en, TargetPlatform.linux),
        (title: en.appLockOfferTitleComputer, body: en.appLockOfferBodyComputerPin));
    for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(appLockOfferWords(en, p), (title: en.appLockOfferTitle, body: en.appLockOfferBody));
    }
    for (final l in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(l);
      for (final p in TargetPlatform.values) {
        final w = appLockOfferWords(t, p);
        expect(w.title.trim(), isNotEmpty);
        expect(w.body, isNot(contains('{')), reason: '$l $p');
      }
    }
  });

  on('the lock on already: nothing is asked', TargetPlatform.windows, (tester) async {
    await pump(tester, prefs: const {'security_lock_enabled': true});
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferTitleComputer), findsNothing);
  });

  on('turned off (under flutter test): nothing is asked, and nothing is noted', TargetPlatform.windows,
      (tester) async {
    final c = await pump(tester, enabled: false);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(en.appLockOfferTitleComputer), findsNothing);
    expect(c.read(settingsServiceProvider).appLockOffered, isFalse);
  });

  test('the question is asked on computers as well as phones: only flutter test turns it off', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(appLockOfferEnabledProvider), isFalse);
  });

  for (final (name, platform, touch) in [
    ('a computer', TargetPlatform.windows, false),
    ('a phone', TargetPlatform.android, true),
  ]) {
    on('the question on $name: the accessibility guards', platform, touch: touch, (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await pump(tester);
        await tester.tap(find.text('saved'));
        await tester.pumpAndSettle();
        await expectA11y(tester, computer: !touch, where: name);
        // Turn on and Not now are named for a screen reader.
        expect(find.bySemanticsLabel(en.appLockOfferTurnOn), findsOneWidget);
        expect(find.bySemanticsLabel(en.notNow), findsOneWidget);
      } finally {
        handle.dispose();
      }
    });
  }
}
