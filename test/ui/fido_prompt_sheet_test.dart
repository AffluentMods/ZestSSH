import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart' show dbReadyProvider;
import 'package:zestssh/providers/security_providers.dart' show AppLockNotifier, isAppLockedProvider;
import 'package:zestssh/services/fido/fido_platform.dart';
import 'package:zestssh/services/fido/fido_signer.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/fido_make_key_dialog.dart';
import 'package:zestssh/ui/widgets/fido_prompt_sheet.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../a11y/a11y_checks.dart';
import '../visual/shots_util.dart';

/// A conversation with a security key that only remembers what the sheet
/// told it.
class _Signer extends FidoSigner {
  final List<String> pins = [];
  int cancels = 0;

  @override
  void submitPin(String pin) => pins.add(pin);

  @override
  void cancel() {
    cancels++;
    prompt.value = null;
  }
}

/// The app's lock, as a test sets it.
class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock(super.locked);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _both = FidoWays(nfc: true, nfcOn: true, usb: true);
const _nfcOnly = FidoWays(nfc: true, nfcOn: true, usb: false);
const _usbOnly = FidoWays(nfc: false, nfcOn: false, usb: true);

FidoPrompt _prompt(FidoStep step,
        {FidoWays ways = _both, bool again = false, bool pinWrong = false, int? triesLeft, String label = 'web-01'}) =>
    FidoPrompt(
      purpose: FidoPurpose.signIn,
      label: label,
      step: step,
      ways: ways,
      again: again,
      pinWrong: pinWrong,
      pinTriesLeft: triesLeft,
    );

/// The security key's sheet on a phone (4.0): what it says at each step,
/// what it does with a PIN, that closing it cancels, and that it is a phone's
/// sheet a finger and a screen reader can use, in every language.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  var fonts = false;

  /// A phone, touch sized, with a button that opens [sheet] as the app's
  /// modal does.
  Future<void> pump(WidgetTester tester, Widget sheet,
      {Locale locale = const Locale('en'), double scale = 1.0, Size size = const Size(390, 844)}) async {
    if (!fonts) {
      await tester.runAsync(loadShotFonts);
      fonts = true;
    }
    debugTouchLayout = true;
    addTearDown(() => debugTouchLayout = null);
    final t = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(t.colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: t.toThemeData(compact: false),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showZestModal<void>(context: context, size: ZestModalSize.compact, child: sheet),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    // (Not pumpAndSettle: the sheet's spinner never settles.)
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  group('what it says', () {
    testWidgets('hold the key or plug it in, by what the phone has; again when it left too soon', (tester) async {
      final signer = _Signer()..prompt.value = _prompt(FidoStep.present);
      await pump(tester, FidoPromptSheet(signer: signer));
      expect(find.text(en.fidoSheetTitle), findsOneWidget);
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text(en.fidoPresentBoth), findsOneWidget);
      signer.prompt.value = _prompt(FidoStep.present, ways: _nfcOnly);
      await tester.pump();
      expect(find.text(en.fidoPresentNfc), findsOneWidget);
      signer.prompt.value = _prompt(FidoStep.present, ways: _usbOnly);
      await tester.pump();
      expect(find.text(en.fidoPresentUsb), findsOneWidget);
      signer.prompt.value = _prompt(FidoStep.present, ways: _nfcOnly, again: true);
      await tester.pump();
      expect(find.text('${en.fidoPresentAgain} ${en.fidoPresentNfc}'), findsOneWidget);
      expect(key('fido-pin'), findsNothing);
      expect(key('fido-pin-continue'), findsNothing);
    });

    testWidgets('on an iPhone: near the top of the iPhone', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pump(tester, FidoPromptSheet(signer: _Signer()..prompt.value = _prompt(FidoStep.present, ways: _nfcOnly)));
        expect(find.text(en.fidoPresentNfcIphone), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('touch it, and talking to it', (tester) async {
      final signer = _Signer()..prompt.value = _prompt(FidoStep.touch);
      await pump(tester, FidoPromptSheet(signer: signer));
      expect(find.text(en.fidoTouch), findsOneWidget);
      signer.prompt.value = _prompt(FidoStep.working);
      await tester.pump();
      expect(find.text(en.fidoWorking), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('the PIN', () {
    testWidgets('is typed masked, with nothing for a keyboard to learn, and goes to the key once', (tester) async {
      final signer = _Signer()..prompt.value = _prompt(FidoStep.pin);
      await pump(tester, FidoPromptSheet(signer: signer));
      expect(find.text(en.fidoPinLabel), findsWidgets);
      expect(find.text(en.fidoPinHelp), findsOneWidget);
      final field = tester.widget<EditableText>(find.descendant(of: key('fido-pin'), matching: find.byType(EditableText)));
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
      // Nothing typed: Continue sends nothing.
      await tester.tap(key('fido-pin-continue'));
      await tester.pump();
      expect(signer.pins, isEmpty);
      await tester.enterText(find.descendant(of: key('fido-pin'), matching: find.byType(EditableText)), '1234');
      await tester.tap(key('fido-pin-continue'));
      await tester.pump();
      expect(signer.pins, ['1234']);
      expect(field.controller.text, isEmpty, reason: 'what was typed is not left in the field');
    });

    testWidgets('a wrong PIN says so, with the tries left', (tester) async {
      final signer = _Signer()..prompt.value = _prompt(FidoStep.pin, pinWrong: true, triesLeft: 7);
      await pump(tester, FidoPromptSheet(signer: signer));
      expect(find.text('${en.fidoPinWrong} ${en.fidoPinTriesLeft(7)}'), findsOneWidget);
      signer.prompt.value = _prompt(FidoStep.pin, pinWrong: true);
      await tester.pump();
      expect(find.text(en.fidoPinWrong), findsOneWidget);
    });
  });

  testWidgets('Cancel ends the conversation, and the sheet goes when the conversation ends', (tester) async {
    final signer = _Signer()..prompt.value = _prompt(FidoStep.present);
    await pump(tester, FidoPromptSheet(signer: signer));
    await tester.tap(key('fido-cancel'));
    await tester.pumpAndSettle();
    expect(signer.cancels, 1);
    expect(key('fido-prompt'), findsNothing);
  });

  group('at the app\'s root', () {
    Future<_Signer> host(WidgetTester tester, {bool locked = false}) async {
      final signer = _Signer();
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      final t = BuiltInThemes.getById('default_dark');
      AppColors.applyTheme(t.colorScheme);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => const Scaffold(body: Text('home')))]);
      addTearDown(router.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          isAppLockedProvider.overrideWith((ref) => _Lock(locked)),
          dbReadyProvider.overrideWith((ref) => true),
        ],
        child: MaterialApp.router(
          theme: t.toThemeData(compact: false),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (context, child) => FidoPromptHost(router: router, signer: signer, child: child!),
        ),
      ));
      await tester.pumpAndSettle();
      return signer;
    }

    testWidgets('the sheet comes when a key is asked for, follows the steps, and goes when it is done', (tester) async {
      final signer = await host(tester);
      expect(key('fido-prompt'), findsNothing);
      signer.prompt.value = _prompt(FidoStep.present);
      await tester.pumpAndSettle();
      expect(key('fido-prompt'), findsOneWidget);
      expect(signer.nfcSheetText, en.fidoPresentNfcIphone, reason: "an iPhone's own sheet says the app's words");
      signer.prompt.value = _prompt(FidoStep.working);
      await tester.pump();
      expect(find.text(en.fidoWorking), findsOneWidget);
      signer.prompt.value = null;
      await tester.pumpAndSettle();
      expect(key('fido-prompt'), findsNothing);
      expect(signer.cancels, 0, reason: 'done, not cancelled');
    });

    testWidgets('closing the sheet by the back gesture cancels', (tester) async {
      final signer = await host(tester);
      signer.prompt.value = _prompt(FidoStep.present);
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(signer.cancels, 1);
      expect(key('fido-prompt'), findsNothing);
    });

    testWidgets('while the app is locked nothing is shown and the key is not waited for unseen', (tester) async {
      final signer = await host(tester, locked: true);
      signer.prompt.value = _prompt(FidoStep.present);
      await tester.pumpAndSettle();
      expect(key('fido-prompt'), findsNothing);
      expect(signer.cancels, 1);
    });
  });

  group('a phone\'s sheet', () {
    testWidgets('names, 48 targets and contrast at every step (the 4.0 accessibility pass)', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final failures = <String>[];
        for (final p in [
          _prompt(FidoStep.present),
          _prompt(FidoStep.present, again: true, ways: _nfcOnly),
          _prompt(FidoStep.touch),
          _prompt(FidoStep.working),
          _prompt(FidoStep.pin),
          _prompt(FidoStep.pin, pinWrong: true, triesLeft: 2),
        ]) {
          await pump(tester, FidoPromptSheet(signer: _Signer()..prompt.value = p));
          failures.addAll(await a11yCheck(tester, computer: false, where: 'security key sheet, ${p.step.name}'));
          await tester.pumpWidget(const SizedBox());
        }
        expect(failures, isEmpty);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('fits in every language, 360 wide, at the size drawn and at 1.3 times', (tester) async {
      final problems = <String>[];
      final reported = FlutterError.onError;
      FlutterError.onError = (details) => problems.add(details.exceptionAsString().split('\n').first);
      try {
        for (final locale in AppLocalizations.supportedLocales) {
          for (final scale in const [1.0, 1.3]) {
            for (final p in [
              _prompt(FidoStep.present, again: true, label: 'a-long-host-name.example.org'),
              _prompt(FidoStep.pin, pinWrong: true, triesLeft: 3),
            ]) {
              final before = problems.length;
              await pump(tester, FidoPromptSheet(signer: _Signer()..prompt.value = p),
                  locale: locale, scale: scale, size: const Size(360, 780));
              for (var i = before; i < problems.length; i++) {
                problems[i] = '$locale at $scale, ${p.step.name}: ${problems[i]}';
              }
              await tester.pumpWidget(const SizedBox());
            }
          }
        }
      } finally {
        FlutterError.onError = reported;
      }
      expect(problems, isEmpty);
    });
  });

  group('making a key on a security key', () {
    Future<FidoMakeChoice?> Function() open(WidgetTester tester, List<FidoMakeChoice?> got) => () async {
          final choice = await showFidoMakeKeyDialog(tester.element(find.byType(Scaffold)));
          got.add(choice);
          return choice;
        };

    Future<void> pumpHome(WidgetTester tester, {Locale locale = const Locale('en'), double scale = 1.0}) async {
      if (!fonts) {
        await tester.runAsync(loadShotFonts);
        fonts = true;
      }
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      final t = BuiltInThemes.getById('default_dark');
      AppColors.applyTheme(t.colorScheme);
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: t.toThemeData(compact: false),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: const Scaffold(body: SizedBox.expand()),
      ));
    }

    testWidgets('Ed25519 with no PIN asked unless chosen; the choice comes back with Create, nothing with Cancel',
        (tester) async {
      await pumpHome(tester);
      final got = <FidoMakeChoice?>[];
      open(tester, got)();
      await tester.pumpAndSettle();
      expect(find.text(en.fidoMakeTitle), findsOneWidget);
      expect(find.text(en.fidoMakeIntro), findsOneWidget);
      await tester.tap(key('fido-make-go'));
      await tester.pumpAndSettle();
      expect(got, [(ed25519: true, askPin: false)]);

      open(tester, got)();
      await tester.pumpAndSettle();
      await tester.tap(find.text('ECDSA P-256'));
      await tester.tap(key('fido-make-ask-pin'));
      await tester.pump();
      await tester.tap(key('fido-make-go'));
      await tester.pumpAndSettle();
      expect(got.last, (ed25519: false, askPin: true));

      open(tester, got)();
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(got.last, isNull);
    });

    testWidgets('names, 48 targets and contrast, and it fits in every language at 1.0 and 1.3 times', (tester) async {
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      final reported = FlutterError.onError;
      try {
        await pumpHome(tester);
        open(tester, [])();
        await tester.pumpAndSettle();
        expect(await a11yCheck(tester, computer: false, where: 'new key on a security key'), isEmpty);
        await tester.pumpWidget(const SizedBox());
        FlutterError.onError = (details) => problems.add(details.exceptionAsString().split('\n').first);
        for (final locale in AppLocalizations.supportedLocales) {
          for (final scale in const [1.0, 1.3]) {
            final before = problems.length;
            await pumpHome(tester, locale: locale, scale: scale);
            open(tester, [])();
            await tester.pumpAndSettle();
            for (var i = before; i < problems.length; i++) {
              problems[i] = '$locale at $scale: ${problems[i]}';
            }
            await tester.pumpWidget(const SizedBox());
          }
        }
      } finally {
        FlutterError.onError = reported;
        handle.dispose();
      }
      expect(problems, isEmpty);
    });
  });
}
