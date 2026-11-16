import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/passphrase_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/server_question_dialog.dart';
import 'package:zestssh/ui/widgets/paste_question.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The sign-in prompts and the terminal's questions in the app's dialog (the
/// dialog rules of 3.4): each was a Material AlertDialog. They keep
/// what they did: every answer is a button, so Escape leaves a prompt where
/// it is; the close button is the safe answer; a prompt answers once.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<BuildContext> host(WidgetTester tester, {bool recording = false}) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(builder: (ctx) {
          context = ctx;
          return const Scaffold();
        }),
      ),
    ));
    return context;
  }

  Future<void> escape(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  Finder closeButton() => find.byTooltip(l10n.close);

  HostKeyVerification key({required bool changed}) => HostKeyVerification(
        host: 'web-01.example.com',
        port: 22,
        hostKey: SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List(51)),
        fingerprint: 'SHA256:Kq3v8Xb0YQm4cJ1sT9fH2nW6pL5rZ7aE0dG3uV8iO1k',
        isChanged: changed,
        expectedFingerprint: changed ? 'SHA256:x9Lm2Qp7Rt4Vw1Ys6Bn3Cd8Fg0Hj5Kl2Mn7Pq4St9U' : null,
        completer: Completer<bool>(),
      );

  group('the password prompt', () {
    testWidgets('is the shell; Escape leaves it; Connect answers once with what was typed', (tester) async {
      final context = await host(tester);
      final request = PasswordPromptRequest(
          host: 'web-01.example.com', username: 'deploy', completer: Completer<PasswordPromptResult?>());
      unawaited(showPasswordPrompt(context, request));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      await escape(tester);
      expect(find.byType(PasswordPromptDialog), findsOneWidget, reason: 'every answer is a button');
      expect(request.completer.isCompleted, isFalse);

      await tester.enterText(find.byType(TextField), 'correct horse');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(PasswordPromptDialog), findsNothing);
      final answer = await request.completer.future;
      expect(answer?.password, 'correct horse');
    });

    testWidgets('its close button is Cancel: it answers no password', (tester) async {
      final context = await host(tester);
      final request = PasswordPromptRequest(
          host: 'web-01.example.com', username: 'deploy', completer: Completer<PasswordPromptResult?>());
      unawaited(showPasswordPrompt(context, request));
      await tester.pumpAndSettle();
      await tester.tap(closeButton());
      await tester.pumpAndSettle();
      expect(find.byType(PasswordPromptDialog), findsNothing);
      expect(request.completer.isCompleted, isTrue);
      expect(await request.completer.future, isNull);
    });

    testWidgets('the passphrase prompt: the shell, Unlock in the footer, Escape leaves it', (tester) async {
      final context = await host(tester);
      final request = PassphrasePromptRequest(
          host: 'web-01.example.com', username: 'deploy', completer: Completer<PassphrasePromptResult?>());
      unawaited(showPassphrasePrompt(context, request));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('zest-dialog-primary')), matching: find.text(l10n.passphrasePromptUnlock)),
          findsOneWidget);
      await escape(tester);
      expect(find.byType(PassphrasePromptDialog), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(await request.completer.future, isNull);
    });
  });

  group("a host's key", () {
    testWidgets("a new host's: the same question on a computer as on a phone; Escape leaves it, the close button "
        'is Reject', (tester) async {
      final context = await host(tester);
      bool? answer = true;
      var answered = false;
      unawaited(askHostKeyTrust(context, key(changed: false)).then((v) {
        answer = v;
        answered = true;
      }));
      await tester.pumpAndSettle();
      expect(find.byType(NewHostKeyDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(l10n.terminalReject), findsOneWidget);
      expect(find.text(l10n.hostKeyTrustAndConnect), findsOneWidget);
      await escape(tester);
      expect(answered, isFalse, reason: 'Escape is no answer: the key is not left half asked');
      await tester.tap(closeButton());
      await tester.pumpAndSettle();
      expect(answered, isTrue);
      expect(answer, isFalse);

      unawaited(askHostKeyTrust(context, key(changed: false)).then((v) => answer = v));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('host-key-new-trust')));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });

    testWidgets('a changed one: red, the warning in its amber sentence, the safe answer the main button and '
        'focused, trusting the key the red one beside it', (tester) async {
      final context = await host(tester);
      bool? answer;
      unawaited(askHostKeyTrust(context, key(changed: true)).then((v) => answer = v));
      await tester.pumpAndSettle();
      final shell = tester.widget<ZestDialogShell>(find.byType(ZestDialogShell));
      expect(shell.tone, ZestDialogTone.destructive);
      expect(shell.autofocusPrimary, isTrue);
      expect(shell.primaryBrand, isTrue, reason: 'the safe answer is not drawn as the dangerous one');
      expect(shell.secondaryDanger, isTrue);
      expect(tester.widget(find.byKey(const ValueKey('host-key-changed'))), isA<ZestCallout>());
      expect(find.byType(ZestCallout), findsOneWidget);
      await escape(tester);
      expect(find.byType(HostKeyChangedDialog), findsOneWidget, reason: 'Escape is no answer');
      await tester.tap(find.byKey(const ValueKey('host-key-changed-cancel')));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
    });
  });

  testWidgets("a server's question: the shell, Send in the footer; Escape leaves it, its close button cancels",
      (tester) async {
    final context = await host(tester);
    final request = ServerQuestionRequest(
      host: 'bastion.example.com',
      port: 22,
      username: 'deploy',
      question: ServerQuestion(
        name: 'Two-factor',
        instruction: 'Enter the code from your authenticator app.',
        prompts: const [ServerPrompt('Verification code:', echo: false)],
        round: 1,
        withdrawn: Completer<void>().future,
      ),
    );
    unawaited(showServerQuestionDialog(context, request));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await escape(tester);
    expect(find.byType(ServerQuestionDialog), findsOneWidget);
    expect(request.isOpen, isTrue);
    await tester.tap(closeButton());
    await tester.pumpAndSettle();
    expect(find.byType(ServerQuestionDialog), findsNothing);
    expect(await request.answer, isNull);
  });

  testWidgets('a paste that runs its lines: what runs is the amber sentence; Paste in the footer', (tester) async {
    final context = await host(tester);
    bool? pasted;
    unawaited(showPasteQuestion(context, 'uptime\nwhoami\n', runs: true).then((v) => pasted = v));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.descendant(of: find.byType(ZestCallout), matching: find.text(l10n.terminalPasteRunsLines(2))),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
    await tester.pumpAndSettle();
    expect(pasted, isTrue);
  });

  testWidgets('recording mode before a secret shows: Cancel is the main button and focused; turning the mode off '
      'is the red one beside it', (tester) async {
    final context = await host(tester, recording: true);
    bool? go;
    unawaited(confirmRevealWhileRecording(context).then((v) => go = v));
    await tester.pumpAndSettle();
    final shell = tester.widget<ZestDialogShell>(find.byType(ZestDialogShell));
    expect(shell.autofocusPrimary, isTrue);
    expect(shell.secondaryDanger, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recording-reveal-cancel')));
    await tester.pumpAndSettle();
    expect(go, isFalse);
  });

  testWidgets('Telnet: red, as it exposes what is typed, with the risk in its amber sentence', (tester) async {
    final context = await host(tester);
    unawaited(confirmUnencryptedConnection(context));
    await tester.pumpAndSettle();
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.destructive);
    expect(find.descendant(of: find.byType(ZestCallout), matching: find.text(l10n.desktopShellTelnetWarning)),
        findsOneWidget);
    expect(find.text(l10n.desktopShellTelnetAdvice), findsOneWidget);
  });

  testWidgets('closing the app with sessions open is an ordinary question: nothing amber', (tester) async {
    final context = await host(tester);
    unawaited(confirmCloseWithSessions(context, 2));
    await tester.pumpAndSettle();
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.neutral);
    expect(find.byType(ZestCallout), findsNothing);
  });
}
