import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException, GoogleAuthProvider;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/account/sign_in_ways.dart';
import 'package:zestssh/ui/screens/profile/email_auth_screen.dart' show emailAuthErrorText;
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart' show SsoLookup;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/auth_service.dart' show AuthService, SsoAccountExists;
import 'package:zestssh/ui/screens/profile/sso_sign_in.dart' show addSignInToAccount, kAppleWay, kGoogleWay, refusedForAddress;

/// One account per email address (3.0), in the app: Account, Security says
/// how the account signs in, and an account made through Google or Apple
/// gets the link to set a password there (one that has a password, to change
/// it); the email screen's words for a wrong password and for an address that
/// has an account; and a sign-in ZestSSH Cloud refuses because the address
/// belongs to another account signs out again and says so.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// The addresses a link was asked for, answered with [linkSent].
  late List<String> linksAsked;
  var linkSent = true;

  /// How many times the website's sign-in page was opened.
  var pagesOpened = 0;

  /// When set, a link is answered only once it completes.
  Completer<bool>? linkGate;

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<ProviderContainer> pumpAccount(WidgetTester tester, Future<SignInWays?> Function() ways) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    linksAsked = [];
    pagesOpened = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 3, 12))),
        signInWaysProvider.overrideWith((ref) => ways()),
        passwordLinkSenderProvider.overrideWithValue((email) async {
          linksAsked.add(email);
          final gate = linkGate;
          return gate == null ? linkSent : gate.future;
        }),
        passwordLinkPageOpenerProvider.overrideWithValue(() async {
          pagesOpened++;
          return true;
        }),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(ProfileScreen)));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  /// Whether [message] shows, on screen or as a desktop notification.
  bool shows(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Navigator).first));
    return container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);
  }

  Finder inRow(Finder f) => find.descendant(of: find.byKey(const ValueKey('sign-in-ways')), matching: f);

  group('How you sign in', () {
    testWidgets('an account made through Google: its way, no password yet, and the link to set one', (tester) async {
      await pumpAccount(tester, () async => SignInWays.fromProviders('you@example.com', ['google.com']));
      expect(inRow(find.text(l10n.accountSignInWays)), findsOneWidget);
      expect(inRow(find.text('Google')), findsOneWidget);
      expect(inRow(find.text(l10n.signInWayPassword)), findsNothing);
      expect(inRow(find.text(l10n.accountSignInWaysNoPassword)), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('sign-in-ways-password')));
      await tester.tap(inRow(find.text(l10n.accountSetPassword)));
      await settle(tester);
      expect(linksAsked, ['you@example.com']);
      expect(shows(tester, l10n.accountPasswordLinkSent('you@example.com')), isTrue);
      await close(tester);
    });

    testWidgets('an account with a password: every way it has, and the link to change it', (tester) async {
      await pumpAccount(
        tester,
        () async => SignInWays.fromProviders('you@example.com', ['password', 'apple.com', 'google.com', 'oidc.northwind']),
      );
      for (final name in ['Google', 'Apple', l10n.signInWayCompany, l10n.signInWayPassword]) {
        expect(inRow(find.text(name)), findsOneWidget, reason: name);
      }
      expect(inRow(find.text(l10n.accountSignInWaysAny)), findsOneWidget);
      expect(inRow(find.text(l10n.accountSetPassword)), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('sign-in-ways-password')));
      await tester.tap(inRow(find.text(l10n.accountChangePassword)));
      await settle(tester);
      expect(linksAsked, ['you@example.com']);
      await close(tester);
    });

    testWidgets('Microsoft is named as such', (tester) async {
      await pumpAccount(tester, () async => SignInWays.fromProviders('you@example.com', ['microsoft.com']));
      expect(inRow(find.text('Microsoft')), findsOneWidget);
      await close(tester);
    });

    testWidgets('a link that could not be sent is said, and can be asked for again', (tester) async {
      linkSent = false;
      addTearDown(() => linkSent = true);
      await pumpAccount(tester, () async => SignInWays.fromProviders('you@example.com', ['apple.com']));
      await tester.ensureVisible(find.byKey(const ValueKey('sign-in-ways-password')));
      await tester.tap(inRow(find.text(l10n.accountSetPassword)));
      await settle(tester);
      // A computer holds no Firebase: it is told what happened, with a code, and sent to
      // the website, which reaches the email service another way.
      expect(find.text(l10n.accountPasswordLinkOtherWayTitle), findsOneWidget);
      expect(find.textContaining(l10n.accountPasswordLinkOtherWayBody), findsOneWidget);
      expect(find.textContaining(ErrorCodes.passwordLinkNotSent.code), findsOneWidget);
      expect(shows(tester, l10n.accountPasswordLinkSent('you@example.com')), isFalse);
      expect(pagesOpened, 0, reason: 'nothing opens until the person says');
      await tester.tap(find.text(l10n.accountPasswordLinkOpenSite).last);
      await settle(tester);
      expect(pagesOpened, 1);
      await tester.tap(inRow(find.text(l10n.accountSetPassword)));
      await settle(tester);
      expect(linksAsked, ['you@example.com', 'you@example.com']);
      await close(tester);
    });

    testWidgets('the page is one the website takes: it stands on its own, with no sign-in waiting in the app', (tester) async {
      expect(AuthService.passwordLinkPage.toString(), 'https://zestssh.com/auth?next=%2Faccount%2Fsecurity');
    });

    testWidgets('while a link is on its way the button waits', (tester) async {
      linkGate = Completer<bool>();
      addTearDown(() => linkGate = null);
      await pumpAccount(tester, () async => SignInWays.fromProviders('you@example.com', ['google.com']));
      OutlinedButton button() => tester.widget<OutlinedButton>(
            find.descendant(of: find.byKey(const ValueKey('sign-in-ways-password')), matching: find.byType(OutlinedButton)),
          );
      await tester.ensureVisible(find.byKey(const ValueKey('sign-in-ways-password')));
      await tester.tap(inRow(find.text(l10n.accountSetPassword)));
      await settle(tester);
      expect(button().onPressed, isNull, reason: 'one link at a time');
      linkGate!.complete(true);
      await settle(tester);
      expect(button().onPressed, isNotNull);
      expect(linksAsked, ['you@example.com']);
      await close(tester);
    });

    testWidgets('an account with no address to send to gets no button to press', (tester) async {
      await pumpAccount(tester, () async => SignInWays.fromProviders('', ['google.com']));
      final button = tester.widget<OutlinedButton>(
        find.descendant(of: find.byKey(const ValueKey('sign-in-ways-password')), matching: find.byType(OutlinedButton)),
      );
      expect(button.onPressed, isNull);
      await close(tester);
    });

    // Signed in through the browser (no Firebase user here, as on a
    // computer): where ZestSSH Cloud cannot say, the row says where the ways
    // are seen and changed, with no error and no Retry.
    // A Firebase sign-in (a phone) keeps its Retry.
    testWidgets('when it cannot be told on a computer, it says where to see them, with no Retry', (tester) async {
      var asked = 0;
      await pumpAccount(tester, () async {
        asked++;
        throw const SignInWaysException(503, 'sign-in-methods-unavailable');
      });
      expect(inRow(find.text(l10n.accountSignInWaysWeb)), findsOneWidget);
      expect(inRow(find.text(l10n.twoStepOpenWeb)), findsOneWidget);
      expect(find.text(l10n.accountSignInWaysFailed), findsNothing);
      expect(inRow(find.text(l10n.retry)), findsNothing);
      expect(asked, 1);
      await close(tester);
    });

    testWidgets('while it is being asked, the row waits', (tester) async {
      final answer = Completer<SignInWays?>();
      await pumpAccount(tester, () => answer.future);
      expect(inRow(find.byType(CircularProgressIndicator)), findsOneWidget);
      answer.complete(SignInWays.fromProviders('you@example.com', ['password']));
      await settle(tester);
      expect(inRow(find.byType(CircularProgressIndicator)), findsNothing);
      expect(inRow(find.text(l10n.signInWayPassword)), findsOneWidget);
      await close(tester);
    });
  });

  group('The email screen says', () {
    String say(String code) => emailAuthErrorText(FirebaseAuthException(code: code), l10n);

    test('a wrong password, and an account that has none yet, the same way', () {
      for (final code in ['invalid-login-credentials', 'invalid-credential', 'wrong-password', 'user-not-found']) {
        expect(say(code), l10n.emailAuthErrorIncorrectOrOtherWay, reason: code);
      }
    });

    test('an address that has an account: sign in to it instead', () {
      expect(say('email-already-in-use'), l10n.emailAuthErrorEmailInUse);
    });

    test('the rest as before', () {
      expect(say('invalid-email'), l10n.emailAuthErrorInvalidEmail);
      expect(say('weak-password'), l10n.emailAuthErrorWeakPassword);
      expect(say('user-disabled'), l10n.emailAuthErrorDisabled);
      expect(say('too-many-requests'), l10n.emailAuthErrorTooManyRequests);
      expect(say('network-request-failed'), l10n.emailAuthErrorNetwork);
      expect(say('operation-not-allowed'), l10n.emailAuthErrorNotEnabled);
      expect(emailAuthErrorText(FirebaseAuthException(code: 'odd', message: 'As Firebase says it'), l10n),
          'As Firebase says it');
      expect(say('odd'), l10n.emailAuthErrorGeneric);
      expect(emailAuthErrorText(StateError('no'), l10n), l10n.emailAuthErrorGeneric);
    });
  });

  group('A sign-in ZestSSH Cloud refuses for its address', () {
    bool? refused;
    var signedOut = 0;

    Future<void> refuse(WidgetTester tester, http.Response answer) async {
      refused = null;
      signedOut = 0;
      final api = SignInWaysApi(
        baseUrl: 'https://api.example.com/v1',
        bearer: () async => 'bearer-1',
        client: MockClient((_) async => answer),
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async {
                  refused = await refusedForAddress(
                    context,
                    ref,
                    api: api,
                    email: 'alice@example.com',
                    signOut: () async => signedOut++,
                  );
                },
                child: const Text('Signed in'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Signed in'));
      await settle(tester);
    }

    testWidgets('signs out again, and says how to get into the account the address has', (tester) async {
      await refuse(tester, http.Response('{"error":"taken","code":"email-has-account"}', 409));
      expect(signedOut, 1);
      expect(find.text(l10n.signInAddressHasAccountTitle), findsOneWidget);
      expect(find.text(l10n.signInAddressHasAccountBody('alice@example.com')), findsOneWidget);
      expect(refused, isNull, reason: 'it is told before it goes on');
      // Got it: what the button is (it said OK; the dialog rules, 3.4).
      await tester.tap(find.text(l10n.desktopGotIt));
      await settle(tester);
      expect(refused, isTrue);
    });

    testWidgets('one it takes stays signed in', (tester) async {
      await refuse(tester, http.Response('{"email":"alice@example.com","methods":["google"]}', 200));
      expect(refused, isFalse);
      expect(signedOut, 0);
      expect(find.text(l10n.signInAddressHasAccountTitle), findsNothing);
    });

    testWidgets('one it could not be asked about stays signed in: the next call finds out', (tester) async {
      await refuse(tester, http.Response('<html>down</html>', 503));
      expect(refused, isFalse);
      expect(signedOut, 0);
    });
  });

  group('A way the address does not have yet', () {
    /// Shows what someone who tried [tried] is offered, and backs out.
    Future<void> offered(WidgetTester tester, SsoLookup tried) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final pending = SsoAccountExists(
        email: 'alice@example.com',
        credential: GoogleAuthProvider.credential(idToken: 'id-token'),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => addSignInToAccount(context, ref, pending, tried),
                child: const Text('Tried'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Tried'));
      await settle(tester);
    }

    testWidgets('someone who tried Google is offered the other ways into the account', (tester) async {
      await offered(tester, kGoogleWay);
      expect(find.text(l10n.ssoSignInExistsTitle), findsOneWidget);
      expect(find.text(l10n.ssoSignInExistsBody('alice@example.com', 'Google')), findsOneWidget);
      expect(find.byKey(const ValueKey('sso-usual-google')), findsNothing, reason: 'Google is the way they tried');
      expect(find.byKey(const ValueKey('sso-usual-email')), findsOneWidget);
      // (Apple's own sign-in only on Apple's devices; this is none.)
      expect(find.byKey(const ValueKey('sso-usual-apple')), findsNothing);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(find.text(l10n.ssoSignInExistsTitle), findsNothing);
    });

    testWidgets('someone who tried Apple is offered Google', (tester) async {
      await offered(tester, kAppleWay);
      expect(find.text(l10n.ssoSignInExistsBody('alice@example.com', 'Apple')), findsOneWidget);
      expect(find.byKey(const ValueKey('sso-usual-google')), findsOneWidget);
      expect(find.byKey(const ValueKey('sso-usual-email')), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
    });
  });
}
