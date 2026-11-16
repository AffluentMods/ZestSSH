import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/passkey_step_up.dart';
import 'package:zestssh/services/account/two_step_api.dart';

import 'shots_util.dart';

class _StepUp implements PasskeyStepUp {
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> worthOffering() async => false;
  @override
  Future<void> confirm() async => throw const TwoStepRefusal(401, code: 'passkey-failed');
}

/// "Confirm it's you" with a passkey, a computer's and a phone's width, English
/// and the longest words. Pictures land in build/shots/confirm-passkey-*.png.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> shot(WidgetTester tester, String name, Locale locale, Size size, {bool failed = false}) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        passkeyStepUpProvider.overrideWithValue(_StepUp()),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          theme: ThemeData.dark().copyWith(textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'GeistSans')),
          home: Consumer(builder: (ctx, r, _) {
            context = ctx;
            ref = r;
            return const Scaffold();
          }),
        ),
      ),
    ));
    final l10n = lookupAppLocalizations(locale);
    final asked = confirmOrSignIn(context, ref,
        summary: (what: l10n.stepUpDeleteTeam('Northwind'), effects: const <String>[]));
    await tester.pumpAndSettle();
    if (failed) {
      await tester.tap(find.byKey(const ValueKey('step-up-use-passkey')));
      await tester.pumpAndSettle();
    }
    realShadows();
    await tester.pump();
    await saveShot(tester, key, name);
    plainShadows();
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    await asked;
  }

  testWidgets('a computer', (tester) async {
    await shot(tester, 'confirm-passkey-desktop-en', const Locale('en'), const Size(1000, 640));
  }, skip: !shotsEnabled);

  testWidgets('a computer, a passkey that did not work, the longest words', (tester) async {
    await shot(tester, 'confirm-passkey-desktop-de', const Locale('de'), const Size(1000, 640), failed: true);
  }, skip: !shotsEnabled);

  testWidgets('a phone', (tester) async {
    await shot(tester, 'confirm-passkey-phone-en', const Locale('en'), const Size(390, 844));
  }, skip: !shotsEnabled);
}
