import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/passkey_step_up.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

/// A passkey the test says the fate of.
class _StepUp implements PasskeyStepUp {
  _StepUp({this.has = true, this.offer = false});

  final bool has;
  final bool offer;

  /// What the next tap throws; it goes through where there is none.
  Object? fails;
  var tapped = 0;

  @override
  Future<bool> available() async => has;

  @override
  Future<bool> worthOffering() async => offer;

  @override
  Future<void> confirm() async {
    tapped++;
    final fail = fails;
    if (fail != null) throw fail;
  }
}

/// "Confirm it's you" with a passkey (found in a security review):
/// one tap where the account has one and this device can use it, with the sign-in
/// a press away; a passkey that did not work says why and stays; and what ZestSSH
/// Cloud refuses this way goes on to the sign-in with no dead end.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const summary = (what: 'Suspend bob@example.com in Acme', effects: <String>['They are cut off at once.']);

  /// A team change the server turns away once for want of a recent sign-in.
  Future<({Future<bool> run, List<int> changes, List<int> signIns, ProviderContainer c})> start(
    WidgetTester tester, {
    PasskeyStepUp? stepUp,
    bool signInWorks = true,
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final preferences = await SharedPreferences.getInstance();
    final changes = <int>[];
    final signIns = <int>[];
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      passkeyStepUpProvider.overrideWithValue(stepUp),
      passkeyWayProvider.overrideWith((ref) async => PasskeyWay.here),
      signInRefresherProvider.overrideWithValue((context, ref, {wrongAccount}) async {
        signIns.add(1);
        return signInWorks;
      }),
    ]);
    addTearDown(c.dispose);
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(builder: (ctx, r, _) {
          context = ctx;
          ref = r;
          return const Scaffold();
        }),
      ),
    ));
    final run = withRecentSignIn(context, ref, () async {
      changes.add(1);
      if (changes.length == 1) throw const OrchardServerException(403, 'recent-sign-in-required');
    }, summary: summary);
    await tester.pumpAndSettle();
    return (run: run, changes: changes, signIns: signIns, c: c);
  }

  Finder usePasskey() => find.byKey(const ValueKey('step-up-use-passkey'));
  Finder anotherWay() => find.byKey(const ValueKey('step-up-another-way'));
  Finder problem() => find.byKey(const ValueKey('step-up-passkey-problem'));

  testWidgets('one tap: what the change does, no sign-in, and the change goes through', (tester) async {
    final stepUp = _StepUp();
    final s = await start(tester, stepUp: stepUp);
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(find.text('Suspend bob@example.com in Acme'), findsOneWidget);
    expect(find.text(l10n.twoStepUsePasskey), findsOneWidget);
    expect(find.text(l10n.stepUpSignInAnotherWay), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('step-up-window'))).data, l10n.stepUpPasskeyBody);
    await tester.tap(usePasskey());
    await tester.pumpAndSettle();
    expect(await s.run, isTrue);
    expect(stepUp.tapped, 1);
    expect(s.signIns, isEmpty);
    expect(s.changes.length, 2);
  });

  testWidgets('a passkey that did not work says why, with its code, and stays; another try goes through', (tester) async {
    final stepUp = _StepUp()..fails = const TwoStepRefusal(401, code: 'passkey-failed');
    final s = await start(tester, stepUp: stepUp);
    await tester.tap(usePasskey());
    await tester.pumpAndSettle();
    expect(find.textContaining(l10n.passkeyErrorFailed), findsOneWidget);
    expect(find.textContaining('passkey-failed'), findsOneWidget);
    expect(s.changes.length, 1, reason: 'nothing ran on it');
    stepUp.fails = null;
    await tester.tap(usePasskey());
    await tester.pumpAndSettle();
    expect(await s.run, isTrue);
    expect(s.changes.length, 2);
  });

  testWidgets('closing the system\'s dialog is no error', (tester) async {
    final stepUp = _StepUp()..fails = const PasskeyCancelled();
    await start(tester, stepUp: stepUp);
    await tester.tap(usePasskey());
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(problem()).data, l10n.passkeyCancelledNote);
    expect(find.text(l10n.stepUpTitle), findsOneWidget, reason: 'still asking');
  });

  testWidgets('Sign in another way signs in, and the change goes through', (tester) async {
    final stepUp = _StepUp();
    final s = await start(tester, stepUp: stepUp);
    await tester.tap(anotherWay());
    await tester.pumpAndSettle();
    expect(await s.run, isTrue);
    expect(stepUp.tapped, 0);
    expect(s.signIns.length, 1);
    expect(s.changes.length, 2);
  });

  testWidgets('Cancel: nothing happens', (tester) async {
    final stepUp = _StepUp();
    final s = await start(tester, stepUp: stepUp);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(await s.run, isFalse);
    expect(stepUp.tapped, 0);
    expect(s.signIns, isEmpty);
    expect(s.changes.length, 1);
  });

  for (final code in ['step-up-unavailable', 'no-passkeys', 'passkeys-unavailable']) {
    testWidgets('ZestSSH Cloud says $code: on to the sign-in, no dead end', (tester) async {
      final stepUp = _StepUp()..fails = TwoStepRefusal(409, code: code);
      final s = await start(tester, stepUp: stepUp);
      await tester.tap(usePasskey());
      await tester.pumpAndSettle();
      expect(await s.run, isTrue);
      expect(s.signIns.length, 1);
    });
  }

  testWidgets('no passkey to use: the dialog as it was, and a sign-in', (tester) async {
    final s = await start(tester, stepUp: _StepUp(has: false));
    expect(find.text(l10n.twoStepUsePasskey), findsNothing);
    expect(find.text(l10n.stepUpSignInAnotherWay), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('step-up-window'))).data, l10n.stepUpBody);
    await tester.tap(find.text(l10n.devicesSignInAgainTitle));
    await tester.pumpAndSettle();
    expect(await s.run, isTrue);
    expect(s.signIns.length, 1);
  });

  testWidgets('a sign-in that did not happen: the change does not run', (tester) async {
    final s = await start(tester, stepUp: _StepUp(has: false), signInWorks: false);
    await tester.tap(find.text(l10n.devicesSignInAgainTitle));
    await tester.pumpAndSettle();
    expect(await s.run, isFalse);
    expect(s.changes.length, 1);
  });

  testWidgets('after such a sign-in, an account that could have a passkey is told once', (tester) async {
    final s = await start(tester, stepUp: _StepUp(has: false, offer: true));
    await tester.tap(find.text(l10n.devicesSignInAgainTitle));
    await tester.pumpAndSettle();
    expect(await s.run, isTrue);
    await tester.pumpAndSettle();
    final notices = s.c.read(notificationCenterProvider).history;
    expect(notices.where((n) => n.id == 'passkey-offer').single.title, l10n.stepUpOfferTitle);
    expect(s.c.read(settingsServiceProvider).passkeyOffered, isTrue);
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('told once ever', (tester) async {
    final s = await start(tester, stepUp: _StepUp(has: false, offer: true), prefs: const {'passkey_offered': true});
    await tester.tap(find.text(l10n.devicesSignInAgainTitle));
    await tester.pumpAndSettle();
    expect(await s.run, isTrue);
    await tester.pumpAndSettle();
    expect(s.c.read(notificationCenterProvider).history.where((n) => n.id == 'passkey-offer'), isEmpty);
  });

  testWidgets('only a sign-in will do: the passkey is not even offered', (tester) async {
    final stepUp = _StepUp();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final signIns = <int>[];
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      passkeyStepUpProvider.overrideWithValue(stepUp),
      signInRefresherProvider.overrideWithValue((context, ref, {wrongAccount}) async {
        signIns.add(1);
        return true;
      }),
    ]);
    addTearDown(c.dispose);
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(builder: (ctx, r, _) {
          context = ctx;
          ref = r;
          return const Scaffold();
        }),
      ),
    ));
    final shown = confirmOrSignIn(context, ref, signInOnly: true, askFirst: false, sayWindow: false);
    await tester.pumpAndSettle();
    expect(await shown, ItsYou.confirmed);
    expect(find.text(l10n.twoStepUsePasskey), findsNothing);
    expect(stepUp.tapped, 0);
    expect(signIns.length, 1);
  });

  test('in every language the passkey\'s lines are their own', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.stepUpPasskeyBody, isNot(words.stepUpPasskeyBodyAccount), reason: '$locale');
      expect(words.stepUpSignInAnotherWay, isNot(words.devicesSignInAgainTitle), reason: '$locale');
      expect(words.stepUpReauthBody, isNot(words.stepUpPasskeyBody), reason: '$locale');
    }
  });
}
