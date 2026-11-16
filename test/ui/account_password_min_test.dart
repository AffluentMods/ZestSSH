import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/profile/email_auth_screen.dart';

/// A new account's password is at least 12 characters (it
/// was 8 before), as on the website and at the sign-in service. A
/// password an account has already is not checked again: signing in takes it.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs!)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: EmailAuthScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder field(int i) => find.byType(TextFormField).at(i);

  testWidgets('a new account needs 12 characters, and says so before', (tester) async {
    expect(kMinAccountPasswordLength, 12);
    expect(l10n.emailAuthPasswordMinHint, 'At least 12 characters');
    await open(tester);
    await tester.tap(find.text(l10n.emailAuthNewHereCreateAccount));
    await tester.pumpAndSettle();
    expect(find.text(l10n.emailAuthPasswordMinHint), findsOneWidget);
    await tester.enterText(field(0), 'sam@example.com');
    await tester.enterText(field(1), 'elevenchars');
    // The button (the screen's title says Create account too).
    await tester.tap(find.ancestor(of: find.text(l10n.emailAuthCreateAccount), matching: find.bySubtype<ButtonStyleButton>()).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.emailAuthPasswordTooShort), findsOneWidget, reason: '11 is too few');
  });

  testWidgets('signing in to an account takes the password it has, whatever its length', (tester) async {
    await open(tester);
    await tester.enterText(field(0), 'sam@example.com');
    await tester.enterText(field(1), 'short8ch');
    await tester.tap(find.ancestor(of: find.text(l10n.emailAuthSignIn), matching: find.bySubtype<ButtonStyleButton>()).first);
    await tester.pump();
    expect(find.text(l10n.emailAuthPasswordTooShort), findsNothing);
  });

  testWidgets('the eye: a click shows the password, typing hides it again, and held down it shows while held',
      (tester) async {
    await open(tester);
    bool hidden() => tester.widget<TextField>(find.descendant(of: field(1), matching: find.byType(TextField))).obscureText;
    final eye = find.byKey(const ValueKey('email-auth-password-eye'));
    await tester.enterText(field(1), 'abc');
    expect(hidden(), isTrue);
    await tester.tap(eye);
    await tester.pump();
    expect(hidden(), isFalse);
    await tester.enterText(field(1), 'abcd');
    await tester.pump();
    expect(hidden(), isTrue, reason: 'typing hides it again');

    final hold = await tester.startGesture(tester.getCenter(eye));
    await tester.pump(const Duration(milliseconds: 700));
    expect(hidden(), isFalse, reason: 'shown while held');
    await hold.up();
    await tester.pump();
    expect(hidden(), isTrue, reason: 'and hidden once let go');
  });
}
