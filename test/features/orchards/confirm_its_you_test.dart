import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// One "Confirm it's you" for every change that needs a recent sign-in
/// (found in a security review): the same title everywhere, what
/// the change does, and the window that is true for it, two hours for a team
/// change and ten minutes for an account change (the account page said
/// "Sign in again" and "the last few minutes", the team dialog promised two
/// hours for everything).
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<Future<bool>> open(WidgetTester tester, StepUpSummary? summary,
      {StepUpWindow window = StepUpWindow.team, String? about}) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(builder: (c) {
        context = c;
        return const Scaffold();
      }),
    ));
    final answer = confirmItsYou(context, summary, window: window, about: about);
    await tester.pumpAndSettle();
    return answer;
  }

  Finder window() => find.byKey(const ValueKey('step-up-window'));

  testWidgets('a team change: what it does, and two hours', (tester) async {
    final answer = await open(tester, (what: 'Suspend bob@example.com in Acme', effects: ['They are cut off at once.']));
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(find.text(l10n.stepUpWhy), findsOneWidget);
    expect(find.text('Suspend bob@example.com in Acme'), findsOneWidget);
    expect(tester.widget<Text>(window()).data, l10n.stepUpBody);
    expect(l10n.stepUpBody, contains('two hours'));
    await tester.tap(find.text(l10n.devicesSignInAgainTitle));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });

  testWidgets('an account change: its own words, and ten minutes', (tester) async {
    final answer = await open(tester, null, window: StepUpWindow.account, about: l10n.devicesSignInAgainBody);
    expect(find.text(l10n.stepUpTitle), findsOneWidget, reason: 'the same title as a team change');
    expect(find.text(l10n.devicesSignInAgainBody), findsOneWidget);
    expect(tester.widget<Text>(window()).data, l10n.stepUpWindowAccount);
    expect(l10n.stepUpWindowAccount, contains('ten minutes'));
    expect(find.textContaining('two hours'), findsNothing);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });

  testWidgets('an account change that says what it does: ten minutes there too', (tester) async {
    unawaited(await open(tester, (what: 'Replace your keys', effects: const []), window: StepUpWindow.account));
    expect(find.text(l10n.stepUpWhyAccount), findsOneWidget);
    expect(tester.widget<Text>(window()).data, l10n.stepUpBodyAccount);
  });

  testWidgets('nothing said of the change: a recent sign-in, never "the last few minutes"', (tester) async {
    unawaited(await open(tester, null));
    expect(find.text(l10n.orchardSignInAgainBody), findsOneWidget);
    expect(l10n.orchardSignInAgainBody, isNot(contains('few minutes')));
    expect(tester.widget<Text>(window()).data, l10n.stepUpWindowTeam);
  });

  test('in every language the account window is not the team one', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.stepUpWindowAccount, isNot(words.stepUpWindowTeam), reason: '$locale');
      expect(words.stepUpBodyAccount, isNot(words.stepUpBody), reason: '$locale');
      expect(words.signInAgainPasswordFor('sam@example.com'), contains('sam@example.com'), reason: '$locale');
    }
  });
}
