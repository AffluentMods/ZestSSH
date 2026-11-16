import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The two-step sign-in dialogs (3.0): the second step at sign-in,
/// setting an authenticator up, and the recovery codes shown once.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// A screen whose button runs [onOpen] with a live context.
  Future<void> pumpHost(
    WidgetTester tester,
    Future<void> Function(BuildContext context) onOpen, {
    bool recording = false,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// What a footer button keyed [key] does when tapped: null while it is
  /// off (the dialogs are the app's own, 3.4: their buttons are the shell's).
  VoidCallback? tapOf(WidgetTester tester, String key) => tester
      .widget<GestureDetector>(
          find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(GestureDetector)).first)
      .onTap;

  /// The other ways of the second step, shown in the dialog's place.
  Future<void> otherWays(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('two-step-other-ways')));
    await tester.pumpAndSettle();
  }

  test('why the second step asks again, in words', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    const refused = SocketException('Connection refused');
    // A recovery code that could not be used because nothing answered, or
    // because the service answered with a fault of its own.
    expect(secondStepErrorText(l10n, SecondStepError.unavailable, refused),
        '${l10n.cloudNotResponding} (ZS-1101)');
    expect(
        secondStepErrorText(l10n, SecondStepError.unavailable,
            const RecoveryCodesException(502)),
        '${l10n.cloudFault(502)} (ZS-1103)');
    // An answer that is no fault of the service, and no cause at all (the
    // sign-in service's own code): the sentence there always was.
    expect(
        secondStepErrorText(l10n, SecondStepError.unavailable,
            const RecoveryCodesException(404)),
        l10n.twoStepErrorUnavailable);
    expect(secondStepErrorText(l10n, SecondStepError.unavailable),
        l10n.twoStepErrorUnavailable);
    // A cause says nothing about the other reasons.
    expect(secondStepErrorText(l10n, SecondStepError.wrongCode, refused),
        l10n.twoStepErrorWrongCode);
    expect(secondStepErrorText(l10n, SecondStepError.tooManyAttempts, refused),
        l10n.twoStepErrorTooMany);
    expect(
        secondStepErrorText(l10n, SecondStepError.recoveryCodeInvalid, refused),
        l10n.twoStepErrorRecoveryInvalid);
  });

  group('the second step at sign-in', () {
    testWidgets('takes six digits from the authenticator', (tester) async {
      SecondStepAnswer? answer;
      await pumpHost(tester, (context) async {
        answer = await showSecondStepPrompt(
            context, const SecondStepChallenge(email: 'a@example.com'));
      });
      final l10n = AppLocalizations.of(
          tester.element(find.byType(SecondStepPromptDialog)))!;
      expect(find.text(l10n.twoStepPromptBody), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('two-step-code')), '12345');
      await tester.pump();
      expect(tapOf(tester, 'two-step-send'), isNull, reason: 'five digits is not a code');
      await tester.enterText(
          find.byKey(const ValueKey('two-step-code')), '12a34 56');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('two-step-send')));
      await tester.pumpAndSettle();

      expect(answer, isA<AuthenticatorCodeAnswer>());
      expect((answer! as AuthenticatorCodeAnswer).code, '123456');
    });

    testWidgets('a lost authenticator takes a recovery code with the address, '
        'filled in', (tester) async {
      SecondStepAnswer? answer;
      await pumpHost(tester, (context) async {
        answer = await showSecondStepPrompt(
            context, const SecondStepChallenge(email: 'a@example.com'));
      });
      // The other ways, in this dialog's place (they were links under the
      // fields; the dialog rules, 3.4): one dialog throughout.
      await otherWays(tester);
      expect(find.byType(ZestDialogShell), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('two-step-use-recovery')));
      await tester.pumpAndSettle();
      expect(find.byType(ZestDialogShell), findsOneWidget);
      final l10n = AppLocalizations.of(
          tester.element(find.byType(SecondStepPromptDialog)))!;
      expect(find.text(l10n.twoStepRecoveryBody), findsOneWidget,
          reason: 'what a recovery code does is said before it is used');
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('two-step-email')))
              .controller!
              .text,
          'a@example.com');

      await tester.enterText(
          find.byKey(const ValueKey('two-step-recovery-code')), 'ABCDE FGHJK');
      await tester.pump();
      await tester.tap(find.text(l10n.twoStepRecoverAction));
      await tester.pumpAndSettle();

      expect(answer, isA<RecoveryCodeAnswer>());
      final recovery = answer! as RecoveryCodeAnswer;
      expect(recovery.email, 'a@example.com');
      expect(recovery.code, 'abcde-fghjk');
    });

    testWidgets('says why it asks again', (tester) async {
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(context,
            const SecondStepChallenge(error: SecondStepError.wrongCode));
      });
      final l10n = AppLocalizations.of(
          tester.element(find.byType(SecondStepPromptDialog)))!;
      expect(find.text(l10n.twoStepErrorWrongCode), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();

      // A refused recovery code reopens on the recovery form.
      await tester.pumpWidget(const SizedBox());
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(
            context,
            const SecondStepChallenge(
                email: 'a@example.com',
                error: SecondStepError.recoveryCodeInvalid));
      });
      expect(find.text(l10n.twoStepErrorRecoveryInvalid), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-recovery-code')),
          findsOneWidget);
    });

    testWidgets(
        'a recovery code ZestSSH Cloud could not check says how the service '
        'stands, with its code', (tester) async {
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(
            context,
            const SecondStepChallenge(
                email: 'a@example.com',
                error: SecondStepError.unavailable,
                cause: RecoveryCodesException(503)));
      });
      final l10n = AppLocalizations.of(
          tester.element(find.byType(SecondStepPromptDialog)))!;
      expect(find.text('${l10n.cloudFault(503)} (ZS-1103)'), findsOneWidget);
      expect(find.text(l10n.twoStepErrorUnavailable), findsNothing);
      // On the recovery form as well: it is the same failure.
      await otherWays(tester);
      await tester.tap(find.byKey(const ValueKey('two-step-use-recovery')));
      await tester.pumpAndSettle();
      expect(find.text('${l10n.cloudFault(503)} (ZS-1103)'), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();

      // The sign-in service's own code that could not be checked: the
      // sentence there always was.
      await tester.pumpWidget(const SizedBox());
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(context,
            const SecondStepChallenge(error: SecondStepError.unavailable));
      });
      expect(find.text(l10n.twoStepErrorUnavailable), findsOneWidget);
    });

    testWidgets('cancel answers nothing', (tester) async {
      var answered = false;
      SecondStepAnswer? answer = const AuthenticatorCodeAnswer('x');
      await pumpHost(tester, (context) async {
        answer = await showSecondStepPrompt(
            context, const SecondStepChallenge());
        answered = true;
      });
      final l10n = AppLocalizations.of(
          tester.element(find.byType(SecondStepPromptDialog)))!;
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(answered, isTrue);
      expect(answer, isNull);
    });
  });

  group('a passkey at sign-in (3.3)', () {
    testWidgets('an account with passkeys this device can use is asked for one first', (tester) async {
      SecondStepAnswer? answer;
      await pumpHost(tester, (context) async {
        answer = await showSecondStepPrompt(
            context, const SecondStepChallenge(email: 'a@example.com', authenticator: true, passkey: true));
      });
      final l10n = AppLocalizations.of(tester.element(find.byType(SecondStepPromptDialog)))!;
      expect(find.text(l10n.twoStepPasskeyBody), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-code')), findsNothing, reason: 'no code asked for a passkey');
      // Use your passkey is the main button, in the footer (it stood in the
      // body); the authenticator is among the other ways.
      expect(find.byKey(const ValueKey('two-step-use-passkey')), findsOneWidget);
      await otherWays(tester);
      expect(find.byKey(const ValueKey('two-step-use-authenticator')), findsOneWidget);
      await tester.tap(find.text(l10n.back));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('two-step-use-passkey')));
      await tester.pumpAndSettle();
      expect(answer, isA<PasskeyAnswer>());
    });

    testWidgets('only the bridge (no authenticator): never "enter a code"', (tester) async {
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(context, const SecondStepChallenge(authenticator: false, passkey: true));
      });
      expect(find.byKey(const ValueKey('two-step-use-passkey')), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-code')), findsNothing);
      await otherWays(tester);
      expect(find.byKey(const ValueKey('two-step-use-authenticator')), findsNothing);
    });

    testWidgets('why the last passkey did not work, with its code; a closed window as a word, not an error',
        (tester) async {
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(
            context,
            const SecondStepChallenge(
                passkey: true,
                authenticator: true,
                passkeyFailure: PasskeyStepFailure('passkey-paused', retryAfter: Duration(minutes: 30))));
      });
      final l10n = AppLocalizations.of(tester.element(find.byType(SecondStepPromptDialog)))!;
      expect(find.text(l10n.passkeyErrorPaused(l10n.waitMinutes(30))), findsOneWidget);
      expect(find.text(l10n.twoStepErrorCode('passkey-paused')), findsOneWidget);
      // Choosing another way lets it be.
      await otherWays(tester);
      await tester.tap(find.byKey(const ValueKey('two-step-use-authenticator')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.passkeyErrorPaused(l10n.waitMinutes(30))), findsNothing);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(
            context, const SecondStepChallenge(passkey: true, passkeyFailure: PasskeyStepFailure('cancelled')));
      });
      expect(find.byKey(const ValueKey('two-step-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-error')), findsNothing);
    });

    testWidgets('passkeys this device cannot use: said, and the other ways offered', (tester) async {
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(
            context, const SecondStepChallenge(authenticator: true, passkey: false, passkeyElsewhere: true));
      });
      final l10n = AppLocalizations.of(tester.element(find.byType(SecondStepPromptDialog)))!;
      expect(find.text(l10n.twoStepPasskeysNotHere), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-code')), findsOneWidget);
      await otherWays(tester);
      expect(find.byKey(const ValueKey('two-step-use-passkey-instead')), findsNothing);
      await tester.tap(find.text(l10n.back));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();

      // No authenticator either: the recovery code, with the same word.
      await tester.pumpWidget(const SizedBox());
      await pumpHost(tester, (context) async {
        await showSecondStepPrompt(
            context, const SecondStepChallenge(authenticator: false, passkey: false, passkeyElsewhere: true));
      });
      expect(find.text(l10n.twoStepPasskeysNotHereNoCode), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-recovery-code')), findsOneWidget);
    });

    testWidgets("no second step and no recovery code: the account's recovery, with the address", (tester) async {
      SecondStepAnswer? answer;
      await pumpHost(tester, (context) async {
        answer = await showSecondStepPrompt(context, const SecondStepChallenge(email: 'a@example.com'));
      });
      await otherWays(tester);
      await tester.tap(find.byKey(const ValueKey('two-step-locked-out')));
      await tester.pumpAndSettle();
      expect(answer, isA<LockedOutAnswer>());
      expect((answer! as LockedOutAnswer).email, 'a@example.com');
    });
  });

  group('setting an authenticator up', () {
    AuthenticatorSetup setup() => AuthenticatorSetup(
          qrUrl: 'otpauth://totp/ZestSSH:a%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=ZestSSH',
          key: 'JBSWY3DPEHPK3PXP',
        );

    testWidgets('shows the QR code and the key, and turns on with a good code',
        (tester) async {
      final tried = <String>[];
      TwoStepSetupResult? result;
      await pumpHost(tester, (context) async {
        result = await TwoStepSetupDialog.show(
          context,
          start: () async => setup(),
          finish: (_, code) async {
            tried.add(code);
            if (code != '654321') {
              throw FirebaseAuthException(code: 'invalid-verification-code');
            }
          },
        );
      });
      final l10n = AppLocalizations.of(
          tester.element(find.byType(TwoStepSetupDialog)))!;
      expect(find.text(l10n.twoStepScanQr), findsOneWidget);
      expect(find.text('JBSW Y3DP EHPK 3PXP'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('two-step-setup-code')), '111111');
      await tester.pump();
      await tester.tap(find.text(l10n.twoStepVerify));
      await tester.pumpAndSettle();
      expect(find.text(l10n.twoStepErrorWrongCode), findsOneWidget);
      expect(result, isNull, reason: 'a wrong code keeps the dialog open');

      await tester.enterText(
          find.byKey(const ValueKey('two-step-setup-code')), '654321');
      await tester.pump();
      await tester.tap(find.text(l10n.twoStepVerify));
      await tester.pumpAndSettle();
      expect(tried, ['111111', '654321']);
      expect(result, TwoStepSetupResult.done);
    });

    testWidgets('a stale sign-in sends the person back to sign in again',
        (tester) async {
      TwoStepSetupResult? result;
      await pumpHost(tester, (context) async {
        result = await TwoStepSetupDialog.show(
          context,
          start: () async =>
              throw FirebaseAuthException(code: 'requires-recent-login'),
          finish: (_, __) async {},
        );
      });
      await tester.pumpAndSettle();
      expect(result, TwoStepSetupResult.needsSignIn);
    });

    testWidgets('recording mode hides the QR code and the key', (tester) async {
      await pumpHost(
        tester,
        (context) => TwoStepSetupDialog.show(
          context,
          start: () async => setup(),
          finish: (_, __) async {},
        ),
        recording: true,
      );
      final l10n = AppLocalizations.of(
          tester.element(find.byType(TwoStepSetupDialog)))!;
      expect(find.text('JBSW Y3DP EHPK 3PXP'), findsNothing);
      expect(find.text(l10n.twoStepHiddenWhileRecording), findsWidgets);
    });
  });

  group('recovery codes', () {
    final codes = [for (var i = 0; i < 10; i++) 'abcd$i-efgh$i'];

    testWidgets('are all shown, and Done waits until the person says they '
        'saved them', (tester) async {
      await pumpHost(
        tester,
        (context) => showRecoveryCodes(context,
            codes: codes, email: 'a@example.com'),
      );
      for (final code in codes) {
        expect(find.text(code), findsOneWidget);
      }
      expect(tapOf(tester, 'two-step-codes-done'), isNull);
      await tester.tap(find.byKey(const ValueKey('two-step-codes-saved')));
      await tester.pump();
      expect(tapOf(tester, 'two-step-codes-done'), isNotNull);
      await tester.tap(find.byKey(const ValueKey('two-step-codes-done')));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryCodesDialog), findsNothing);
    });

    testWidgets('Escape (after Tab) does not close them before "I saved them" is ticked, as their X does not '
        '(found in a security review)', (tester) async {
      await pumpHost(
        tester,
        (context) => showRecoveryCodes(context,
            codes: codes, email: 'a@example.com'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryCodesDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('two-step-codes-saved')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryCodesDialog), findsNothing, reason: 'saved: Escape closes it, as the X would');
    });

    testWidgets('are hidden while recording mode is on', (tester) async {
      await pumpHost(
        tester,
        (context) => showRecoveryCodes(context,
            codes: codes, email: 'a@example.com'),
        recording: true,
      );
      for (final code in codes) {
        expect(find.text(code), findsNothing);
      }
    });
  });
}
