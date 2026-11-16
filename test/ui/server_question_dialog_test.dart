import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/ui/screens/terminal/widgets/server_question_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

/// The dialog that shows an SSH server's own sign-in question (a 2FA code),
/// and the queue that shows several one at a time.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ServerQuestion question(List<ServerPrompt> prompts,
          {String name = '', String instruction = ''}) =>
      ServerQuestion(
        name: name,
        instruction: instruction,
        prompts: prompts,
        round: 1,
        withdrawn: Completer<void>().future,
      );

  ServerQuestionRequest request(List<ServerPrompt> prompts,
          {String name = '', String instruction = ''}) =>
      ServerQuestionRequest(
        host: 'bastion.example',
        port: 22,
        username: 'alice',
        question: question(prompts, name: name, instruction: instruction),
      );

  /// A screen whose button runs [onOpen] with a live context and ref.
  Future<void> pumpHost(WidgetTester tester,
      void Function(BuildContext context, WidgetRef ref) onOpen) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => onOpen(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
  }

  Future<void> open(WidgetTester tester, ServerQuestionRequest r) async {
    await pumpHost(
      tester,
      (context, _) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ServerQuestionDialog(request: r),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the server\'s words with the warning, hides secret '
      'answers, and sends them in order', (tester) async {
    final r = request(const [
      ServerPrompt('Verification code:', echo: false),
      ServerPrompt('Passcode or option (1-3):', echo: true),
    ], name: 'Duo two-factor', instruction: 'Choose how to verify.');
    await open(tester, r);

    expect(find.text('Sign-in step'), findsOneWidget);
    expect(find.textContaining('come from the server, not from ZestSSH'),
        findsOneWidget);
    expect(find.text('Duo two-factor'), findsOneWidget);
    expect(find.text('Choose how to verify.'), findsOneWidget);
    expect(find.text('Verification code:'), findsOneWidget);
    expect(find.text('Passcode or option (1-3):'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).obscureText, isTrue);
    expect(tester.widget<TextField>(fields.at(0)).enableSuggestions, isFalse);
    expect(tester.widget<TextField>(fields.at(1)).obscureText, isFalse);

    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), '1');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in step'), findsNothing);
    expect(await r.answer, ['123456', '1']);
  });

  testWidgets('Cancel answers nothing and closes', (tester) async {
    final r = request(const [ServerPrompt('Verification code:', echo: false)]);
    await open(tester, r);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Sign-in step'), findsNothing);
    expect(await r.answer, isNull);
  });

  testWidgets('a question the sign-in no longer wants closes by itself',
      (tester) async {
    final r = request(const [ServerPrompt('Verification code:', echo: false)]);
    await open(tester, r);
    expect(find.text('Sign-in step'), findsOneWidget);
    r.cancel(); // what a withdrawn question does
    await tester.pumpAndSettle();
    expect(find.text('Sign-in step'), findsNothing);
  });

  testWidgets('recording mode masks the host the question is for',
      (tester) async {
    SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
    prefs = await SharedPreferences.getInstance();
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerAddresses(['bastion.example']);
    addTearDown(() => Redactor.instance
      ..clearNames()
      ..enabled = false);

    await open(tester,
        request(const [ServerPrompt('Verification code:', echo: false)]));
    expect(find.textContaining('bastion.example'), findsNothing);
  });

  testWidgets('questions from several connections are shown one at a time '
      'and each gets its own answer', (tester) async {
    final askers = Provider<List<ServerQuestionAsker>>((ref) => [
          serverQuestionAsker(ref,
              host: 'one.example', port: 22, username: 'alice'),
          serverQuestionAsker(ref,
              host: 'two.example', port: 22, username: 'bob'),
        ]);
    late Future<List<String>?> first;
    late Future<List<String>?> second;
    late WidgetRef widgetRef;

    await pumpHost(tester, (context, ref) {
      widgetRef = ref;
      final ask = ref.read(askers);
      first = ask[0](question(
          const [ServerPrompt('Verification code:', echo: false)]));
      second = ask[1](question(
          const [ServerPrompt('Token code:', echo: false)]));
      showServerQuestions(context, ref, isMounted: () => true);
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Verification code:'), findsOneWidget);
    expect(find.text('Token code:'), findsNothing);
    await tester.enterText(find.byType(TextField), '111111');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Token code:'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '222222');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(await first, ['111111']);
    expect(await second, ['222222']);
    expect(widgetRef.read(serverQuestionQueueProvider), isEmpty);
  });
}
