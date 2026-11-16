import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';

/// The question for a password says why it is asked, where it is asked for
/// a password that is saved (3.0; the SSH core's audit, with the sign-ins
/// that cannot be made ready: test/providers/sign_in_not_loaded_test.dart).
///
/// The question had a place for such a word and nothing ever gave it one:
/// a saved password that this device's secure storage did not hand over
/// was asked for with no word of why.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  /// The question for [request], opened from a button as a session opens it.
  Future<void> open(WidgetTester tester, PasswordPromptRequest request, {bool recording = false}) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => PasswordPromptDialog(request: request)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(en.passwordPromptTitle), findsOneWidget);
  }

  PasswordPromptRequest asked({String? why}) => PasswordPromptRequest(
        host: 'web-01.example.com',
        username: 'deploy',
        errorHint: why,
        completer: Completer<PasswordPromptResult?>(),
      );

  testWidgets('with why it is asked: the reason is shown above the field, and what is typed is what is answered',
      (tester) async {
    final request = asked(why: en.connSavedPasswordUnreadable);
    await open(tester, request);
    expect(find.text('The saved password could not be read on this device, so it is asked for here.'), findsOneWidget);
    expect(find.byIcon(LucideIcons.alertCircle), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'not-a-real-password');
    await tester.tap(find.text(en.commonConnect));
    await tester.pumpAndSettle();
    final answer = await request.completer.future;
    expect(answer?.password, 'not-a-real-password');
    expect(answer?.saveToIdentity, isFalse);
    expect(find.text(en.passwordPromptTitle), findsNothing);
  });

  testWidgets('with nothing to say of why: no such line, and closing it answers with nothing', (tester) async {
    final request = asked();
    await open(tester, request);
    expect(find.text(en.connSavedPasswordUnreadable), findsNothing);
    expect(find.byIcon(LucideIcons.alertCircle), findsNothing);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(await request.completer.future, isNull);
  });

  testWidgets('who it is for: user@host, and the host alone where there is no user (a remote screen\'s VNC '
      'password, 4.0), never "@Demo desktop"', (tester) async {
    await open(tester, asked());
    expect(find.text('deploy@web-01.example.com'), findsOneWidget);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();

    final screen = PasswordPromptRequest(
      host: 'Demo desktop',
      username: '',
      completer: Completer<PasswordPromptResult?>(),
    );
    await open(tester, screen);
    expect(find.text('Demo desktop'), findsOneWidget);
    expect(find.text('@Demo desktop'), findsNothing);
    expect(find.byKey(const ValueKey('password-prompt-username')), findsNothing);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
  });

  testWidgets('where the user name is asked for too (an RDP host with no key): its field comes first, and Connect '
      'answers only once both are typed', (tester) async {
    final request = PasswordPromptRequest(
      host: 'office-pc',
      username: '',
      errorHint: en.screenRdpAccountWhy,
      completer: Completer<PasswordPromptResult?>(),
      offerSave: false,
      askUsername: true,
    );
    await open(tester, request);
    expect(find.text(en.screenRdpAccountWhy), findsOneWidget);
    expect(find.text(en.passwordPromptSaveToIdentity), findsNothing);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    expect(find.descendant(of: find.byKey(const ValueKey('password-prompt-username')), matching: fields), findsOneWidget);
    // The password alone: not answered.
    await tester.enterText(fields.last, 'not-a-real-password');
    await tester.tap(find.text(en.commonConnect));
    await tester.pumpAndSettle();
    expect(request.completer.isCompleted, isFalse);
    expect(find.text(en.passwordPromptTitle), findsOneWidget);
    // With the name: both go, the name without the spaces around it.
    await tester.enterText(fields.first, r' CORP\alex ');
    await tester.tap(find.text(en.commonConnect));
    await tester.pumpAndSettle();
    final answer = await request.completer.future;
    expect((answer?.username, answer?.password), (r'CORP\alex', 'not-a-real-password'));
  });

  testWidgets('recording mode: the user name typed for an RDP host is drawn as bullets, and what is answered is what '
      'was typed; with the mode off it is shown', (tester) async {
    for (final recording in [true, false]) {
      final request = PasswordPromptRequest(
        host: 'office-pc',
        username: '',
        completer: Completer<PasswordPromptResult?>(),
        offerSave: false,
        askUsername: true,
      );
      await open(tester, request, recording: recording);
      final fields = find.byType(TextField);
      await tester.enterText(fields.first, r'CORP\alex');
      await tester.enterText(fields.last, 'not-a-real-password');
      await tester.pump();
      final name = tester.widget<EditableText>(
          find.descendant(of: find.byKey(const ValueKey('password-prompt-username')), matching: find.byType(EditableText)));
      final drawn = name.controller
          .buildTextSpan(context: tester.element(find.byType(EditableText).first), withComposing: false)
          .toPlainText();
      expect(drawn, recording ? '\u2022' * 9 : r'CORP\alex', reason: 'recording: $recording');
      // An account's name is nothing a keyboard corrects, suggests from or learns, recording or
      // not; and while recording no autofill bar lists saved names over the dialog.
      expect((name.autocorrect, name.enableSuggestions, name.enableIMEPersonalizedLearning), (false, false, false));
      expect(name.autofillHints, recording ? isNull : [AutofillHints.username]);
      await tester.tap(find.text(en.commonConnect));
      await tester.pumpAndSettle();
      expect((await request.completer.future)?.username, r'CORP\alex');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
