import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/widgets/lockout_recovery_dialog.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/file_manager.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart';

// Two-step sign-in dialogs (3.0; passkeys since 3.3): the
// second step at sign-in (a passkey, the authenticator's code, a recovery
// code, or the way to recover an account that lost them all), setting an
// authenticator up, and the recovery codes shown once.

/// How long a copied secret stays on the clipboard.
const _clipboardLife = Duration(seconds: 45);

/// What the person is told of [error]. [cause] is what was caught where a
/// recovery code could not be used (SecondStepChallenge.cause): ZestSSH
/// Cloud checks those, so where it or the way to it was what stopped that,
/// how it stands is said, with its code.
String secondStepErrorText(AppLocalizations l10n, SecondStepError error,
        [Object? cause]) =>
    switch (error) {
      SecondStepError.wrongCode => l10n.twoStepErrorWrongCode,
      SecondStepError.tooManyAttempts => l10n.twoStepErrorTooMany,
      SecondStepError.recoveryCodeInvalid => l10n.twoStepErrorRecoveryInvalid,
      SecondStepError.unavailable =>
        (cause == null ? null : cloudStopped(l10n, cause)) ??
            l10n.twoStepErrorUnavailable,
    };

InputDecoration _fieldDecoration({String? label, String? hint}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    filled: true,
    fillColor: AppColors.surfaceContainer,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppColors.brandOrange),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
  );
}

Widget _errorLine(String text, {String code = '', AppLocalizations? l10n}) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertCircle, size: 15, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  key: const ValueKey('two-step-error'),
                  style: TextStyle(
                      fontSize: 12.5, height: 1.4, color: AppColors.error),
                ),
                // The code, small beside it, for a support request to quote.
                if (code.isNotEmpty && l10n != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: SelectableText(
                      l10n.twoStepErrorCode(code),
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

/// A word that is no error (the passkey window closed, say).
Widget _noteLine(String text) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              key: const ValueKey('two-step-note'),
              style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );

/// Six digits, nothing else.
final _sixDigits = RegExp(r'^[0-9]{6}$');

// ── The second step at sign-in ──────────────────────────────────────────

/// Asks for the second step with [showSecondStepPrompt] and remembers what
/// was answered, so the caller can tell a sign-in finished with a recovery
/// code (which turned two-step sign-in off) from one finished with the
/// authenticator.
class SecondStepAsker {
  SecondStepAsker(this.context);

  final BuildContext context;
  SecondStepAnswer? _last;

  /// Whether the last answer was a recovery code. After a sign-in that
  /// finished, that means two-step sign-in is now off.
  bool get usedRecoveryCode => _last is RecoveryCodeAnswer;

  Future<SecondStepAnswer?> call(SecondStepChallenge challenge) async {
    if (!context.mounted) return null;
    final answer = _last = await showSecondStepPrompt(context, challenge);
    // No second step and no recovery code left: the sign-in ends, and the
    // account's recovery is asked for instead.
    if (answer is LockedOutAnswer) {
      if (context.mounted) await showLockoutRecovery(context, email: answer.email ?? challenge.email);
      return null;
    }
    return answer;
  }
}

/// The second step of a sign-in: a passkey, the authenticator's code, or a
/// recovery code with the account's address. Null when the person backs out.
Future<SecondStepAnswer?> showSecondStepPrompt(
    BuildContext context, SecondStepChallenge challenge) {
  return AwayForSignIn.during(() => showZestModal<SecondStepAnswer>(
        context: context,
        size: ZestModalSize.compact,
        barrierDismissible: false,
        child: SecondStepPromptDialog(challenge: challenge),
      ));
}

class SecondStepPromptDialog extends StatefulWidget {
  const SecondStepPromptDialog({super.key, required this.challenge});

  final SecondStepChallenge challenge;

  @override
  State<SecondStepPromptDialog> createState() => _SecondStepPromptDialogState();
}

/// Which of the account's ways the second step shows.
enum _StepMode { passkey, code, recovery }

class _SecondStepPromptDialogState extends State<SecondStepPromptDialog> {
  final _code = TextEditingController();
  final _email = TextEditingController();
  final _recoveryCode = TextEditingController();
  late _StepMode _mode;

  /// Whether why the last passkey did not work is let be: choosing another
  /// way hides it, since it belongs to the passkey.
  bool _quiet = false;

  /// The other ways are shown, in this dialog's place, to choose one.
  bool _choosing = false;

  @override
  void initState() {
    super.initState();
    final c = widget.challenge;
    _mode = c.error == SecondStepError.recoveryCodeInvalid
        ? _StepMode.recovery
        : c.passkeyFailure != null && c.passkey
            ? _StepMode.passkey
            : c.error != null && c.authenticator
                ? _StepMode.code
                : c.passkey
                    ? _StepMode.passkey
                    : c.authenticator
                        ? _StepMode.code
                        : _StepMode.recovery;
    _email.text = c.email ?? '';
    for (final ctl in [_code, _email, _recoveryCode]) {
      ctl.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _code.dispose();
    _email.dispose();
    _recoveryCode.dispose();
    super.dispose();
  }

  void _choose(_StepMode mode) => setState(() {
        _mode = mode;
        _quiet = true;
        _choosing = false;
      });

  bool get _canSend => switch (_mode) {
        _StepMode.recovery => _email.text.trim().contains('@') &&
            _recoveryCode.text.replaceAll(RegExp('[^0-9A-Za-z]'), '').length == 10,
        _StepMode.code => _sixDigits.hasMatch(_code.text.trim()),
        _StepMode.passkey => true,
      };

  void _send() {
    if (!_canSend) return;
    Navigator.of(context).pop<SecondStepAnswer>(switch (_mode) {
      _StepMode.recovery => RecoveryCodeAnswer(
          email: _email.text.trim(),
          code: formatRecoveryCode(_recoveryCode.text),
        ),
      _StepMode.code => AuthenticatorCodeAnswer(_code.text.trim()),
      _StepMode.passkey => const PasskeyAnswer(),
    });
  }

  /// No second step and no recovery code either: the account's recovery.
  void _lockedOut() {
    final typed = _email.text.trim();
    Navigator.of(context)
        .pop<SecondStepAnswer>(LockedOutAnswer(email: typed.isNotEmpty ? typed : widget.challenge.email));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = widget.challenge.error;
    // An error from another way is not shown in this one.
    final showError = error != null &&
        switch (_mode) {
          _StepMode.recovery => error != SecondStepError.wrongCode,
          _StepMode.code => error != SecondStepError.recoveryCodeInvalid,
          _StepMode.passkey => false,
        };

    // In the app's dialog (the dialog rules, 3.4): the main button in the
    // footer (Use your passkey stood in the body), and the other ways behind
    // one link, bottom left, shown in this dialog's place (four links stood
    // under the fields).
    final passkey = _mode == _StepMode.passkey;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: _choosing
          ? LucideIcons.listChecks
          : switch (_mode) {
              _StepMode.recovery => LucideIcons.lifeBuoy,
              _StepMode.passkey => LucideIcons.fingerprint,
              _StepMode.code => LucideIcons.shieldCheck,
            },
      title: _choosing
          ? l10n.stepUpSignInAnotherWay
          : _mode == _StepMode.recovery
              ? l10n.twoStepRecoveryTitle
              : l10n.twoStepPromptTitle,
      body: _choosing
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _otherWays(l10n),
            )
          : AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: switch (_mode) {
                  _StepMode.passkey => _passkeyFields(l10n),
                  _StepMode.code => _codeFields(l10n, showError ? error : null),
                  _StepMode.recovery => _recoveryFields(l10n, showError ? error : null),
                },
              ),
            ),
      tertiaryKey: const ValueKey('two-step-other-ways'),
      tertiaryAction: _choosing
          ? null
          : (label: l10n.stepUpSignInAnotherWay, onPressed: () => setState(() => _choosing = true)),
      secondaryAction: _choosing
          ? (label: l10n.back, onPressed: () => setState(() => _choosing = false))
          : (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      primaryKey: ValueKey(passkey ? 'two-step-use-passkey' : 'two-step-send'),
      primaryAction: _choosing
          ? null
          : (
              label: switch (_mode) {
                _StepMode.passkey => l10n.twoStepUsePasskey,
                _StepMode.recovery => l10n.twoStepRecoverAction,
                _StepMode.code => l10n.profileContinue,
              },
              icon: passkey ? LucideIcons.fingerprint : null,
              onPressed: _canSend ? _send : null,
            ),
    );
  }

  /// The account's passkeys cannot be used on this device: said once, where
  /// another way is offered.
  Widget? _elsewhereNote(AppLocalizations l10n) {
    final c = widget.challenge;
    if (!c.passkeyElsewhere) return null;
    return _noteLine(c.authenticator ? l10n.twoStepPasskeysNotHere : l10n.twoStepPasskeysNotHereNoCode);
  }

  /// The other ways, to choose one: each a row (they were links under the
  /// fields).
  List<Widget> _otherWays(AppLocalizations l10n) {
    final c = widget.challenge;
    return [
      if (_mode != _StepMode.passkey && c.passkey)
        _WayRow(
            key: const ValueKey('two-step-use-passkey-instead'),
            icon: LucideIcons.fingerprint,
            label: l10n.twoStepUsePasskeyInstead,
            onTap: () => _choose(_StepMode.passkey)),
      if (_mode != _StepMode.code && c.authenticator)
        _WayRow(
            key: const ValueKey('two-step-use-authenticator'),
            icon: LucideIcons.shieldCheck,
            label: l10n.twoStepUseAuthenticator,
            onTap: () => _choose(_StepMode.code)),
      if (_mode != _StepMode.recovery)
        _WayRow(
            key: const ValueKey('two-step-use-recovery'),
            icon: LucideIcons.keyRound,
            label: l10n.twoStepUseRecoveryCodeAny,
            onTap: () => _choose(_StepMode.recovery)),
      _WayRow(
          key: const ValueKey('two-step-locked-out'),
          icon: LucideIcons.lifeBuoy,
          label: l10n.twoStepNoWayLeft,
          onTap: _lockedOut),
    ];
  }

  List<Widget> _passkeyFields(AppLocalizations l10n) {
    final failure = _quiet ? null : widget.challenge.passkeyFailure;
    final said = failure == null ? null : passkeyStepProblem(l10n, failure);
    return [
      Text(l10n.twoStepPasskeyBody, style: const TextStyle(fontSize: 13.5, height: 1.45)),
      if (said != null)
        said.quiet ? _noteLine(said.text) : _errorLine(said.text, code: said.code, l10n: l10n),
    ];
  }

  List<Widget> _codeFields(AppLocalizations l10n, SecondStepError? error) {
    final elsewhere = _elsewhereNote(l10n);
    return [
      Text(
        l10n.twoStepPromptBody,
        style: const TextStyle(fontSize: 13.5, height: 1.45),
      ),
      const SizedBox(height: 14),
      TextField(
        key: const ValueKey('two-step-code'),
        controller: _code,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        textAlign: TextAlign.center,
        style: const TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 22, letterSpacing: 6),
        decoration: _fieldDecoration(hint: '000000'),
        onSubmitted: (_) => _send(),
      ),
      if (error != null)
        _errorLine(secondStepErrorText(l10n, error, widget.challenge.cause)),
      ?elsewhere,
    ];
  }

  List<Widget> _recoveryFields(AppLocalizations l10n, SecondStepError? error) {
    final c = widget.challenge;
    final elsewhere = !c.authenticator && !c.passkey ? _elsewhereNote(l10n) : null;
    return [
      ?elsewhere,
      if (elsewhere != null) const SizedBox(height: 10),
      Text(
        l10n.twoStepRecoveryBody,
        style: const TextStyle(fontSize: 13, height: 1.45),
      ),
      const SizedBox(height: 14),
      TextField(
        key: const ValueKey('two-step-email'),
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.email],
        autocorrect: false,
        decoration: _fieldDecoration(label: l10n.twoStepEmailLabel),
      ),
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('two-step-recovery-code'),
        controller: _recoveryCode,
        autofocus: true,
        textInputAction: TextInputAction.done,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        inputFormatters: [LengthLimitingTextInputFormatter(24)],
        style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 16),
        decoration: _fieldDecoration(
            label: l10n.twoStepRecoveryCodeLabel, hint: 'xxxxx-xxxxx'),
        onSubmitted: (_) => _send(),
      ),
      if (error != null)
        _errorLine(secondStepErrorText(l10n, error, widget.challenge.cause)),
    ];
  }
}

/// One of the other ways of the second step, a row to choose.
class _WayRow extends StatelessWidget {
  const _WayRow({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 13.5, height: 1.35, color: AppColors.v3TextPrimary)),
              ),
              Icon(LucideIcons.chevronRight, size: 15, color: AppColors.v3TextTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Setting an authenticator up ─────────────────────────────────────────

enum TwoStepSetupResult {
  /// The authenticator is set up.
  done,

  /// Firebase wants a newer sign-in: sign in again and start over.
  needsSignIn,
}

/// Sets an authenticator up: a QR code (and the key, for an app that cannot
/// scan), then the code it shows. Pops [TwoStepSetupResult.done] when set up,
/// or null when the person backs out.
///
/// In the place of the account's passkeys ([inPlaceOfPasskeys]; one or the
/// other), it says that they stay until the code is entered, and once they
/// went ([passkeysGone]) that two-step sign-in is off until it is finished,
/// with a way to stop that says it stays off.
class TwoStepSetupDialog extends ConsumerStatefulWidget {
  const TwoStepSetupDialog({
    super.key,
    required this.start,
    required this.finish,
    this.canOpenInApp = false,
    this.inPlaceOfPasskeys = false,
    this.passkeysGone,
  });

  /// Makes the secret ([TwoStepAccount.start]).
  final Future<AuthenticatorSetup> Function() start;

  /// Checks the code and turns two-step sign-in on ([TwoStepAccount.finish]).
  final Future<void> Function(AuthenticatorSetup setup, String code) finish;

  /// Whether this device can hand the link to an authenticator app (phones
  /// and tablets).
  final bool canOpenInApp;

  /// It is set up in the place of the account's passkeys.
  final bool inPlaceOfPasskeys;

  /// Whether the passkeys went already: two-step sign-in is off until the
  /// setup is finished.
  final ValueListenable<bool>? passkeysGone;

  static Future<TwoStepSetupResult?> show(
    BuildContext context, {
    required Future<AuthenticatorSetup> Function() start,
    required Future<void> Function(AuthenticatorSetup setup, String code)
        finish,
    bool canOpenInApp = false,
    bool inPlaceOfPasskeys = false,
    ValueListenable<bool>? passkeysGone,
  }) {
    return AwayForSignIn.during(() => showZestModal<TwoStepSetupResult>(
          context: context,
          size: ZestModalSize.compact,
          barrierDismissible: false,
          child: TwoStepSetupDialog(
            start: start,
            finish: finish,
            canOpenInApp: canOpenInApp,
            inPlaceOfPasskeys: inPlaceOfPasskeys,
            passkeysGone: passkeysGone,
          ),
        ));
  }

  @override
  ConsumerState<TwoStepSetupDialog> createState() => _TwoStepSetupDialogState();
}

class _TwoStepSetupDialogState extends ConsumerState<TwoStepSetupDialog> {
  final _code = TextEditingController();
  AuthenticatorSetup? _setup;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
    widget.passkeysGone?.addListener(_passkeysWent);
    _begin();
  }

  @override
  void dispose() {
    widget.passkeysGone?.removeListener(_passkeysWent);
    _code.dispose();
    super.dispose();
  }

  void _passkeysWent() {
    if (mounted) setState(() {});
  }

  bool get _gone => widget.passkeysGone?.value == true;

  Future<void> _begin() async {
    try {
      final setup = await widget.start();
      if (mounted) setState(() => _setup = setup);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (e.code == 'requires-recent-login') {
        Navigator.of(context).pop(TwoStepSetupResult.needsSignIn);
        return;
      }
      AppLogger.warning('Two-step setup could not start: ${e.code}');
      final l10n = AppLocalizations.of(context)!;
      // The account holds a TOTP factor already (one or the other).
      setState(() => _error = isSecondFactorLimit(e) ? l10n.twoStepTooManySteps : l10n.twoStepSetupFailed);
    } catch (e) {
      AppLogger.warning('Two-step setup could not start: $e');
      if (mounted) {
        setState(
            () => _error = AppLocalizations.of(context)!.twoStepSetupFailed);
      }
    }
  }

  Future<void> _verify() async {
    final setup = _setup;
    if (setup == null || _busy || !_sixDigits.hasMatch(_code.text.trim())) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.finish(setup, _code.text.trim());
      if (mounted) Navigator.of(context).pop(TwoStepSetupResult.done);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (e.code == 'requires-recent-login') {
        Navigator.of(context).pop(TwoStepSetupResult.needsSignIn);
        return;
      }
      final known = SecondStepFlow.codeError(e);
      AppLogger.warning('Two-step setup refused: ${e.code}');
      setState(() {
        _busy = false;
        _error = known != null ? secondStepErrorText(l10n, known) : l10n.twoStepSetupFailed;
      });
    } catch (e) {
      AppLogger.warning('Two-step setup failed: $e');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l10n.twoStepSetupFailed;
        });
      }
    }
  }

  Future<void> _copyKey(String key) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await confirmRevealWhileRecording(context, ref)) return;
    await SecretClipboard.copy(key, life: _clipboardLife);
    if (mounted) showTopSnackBar(context, l10n.twoStepKeyCopied, isSuccess: true);
  }

  Future<void> _openInApp(AuthenticatorSetup setup) async {
    if (!await confirmRevealWhileRecording(context, ref)) return;
    try {
      await setup.openInApp();
    } catch (e) {
      AppLogger.warning('Opening the authenticator app failed: $e');
      if (mounted) {
        showTopSnackBar(
            context, AppLocalizations.of(context)!.twoStepOpenInAppFailed,
            isError: true, details: '$e');
      }
    }
  }

  // Escape closes it only as its X does: never while a code is being checked (the 3.4 security review, L7).
  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy, child: _dialog(context));

  Widget _dialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final setup = _setup;
    final recording = ref.watch(recordingModeProvider);

    Widget body;
    // Two-step sign-in is off until this is finished: the warning, in its
    // amber sentence (it was red, as an error).
    final passkeysNote = _gone
        ? Padding(padding: const EdgeInsets.only(bottom: 12), child: ZestCallout(l10n.twoStepGapNote))
        : widget.inPlaceOfPasskeys
            ? Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(l10n.authenticatorPasskeysStayNote,
                    key: const ValueKey('two-step-setup-passkeys-stay'),
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.textSecondary)),
              )
            : null;
    if (setup == null) {
      body = _error != null
          ? _errorLine(_error!)
          : const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?passkeysNote,
          Text(l10n.twoStepScanQr,
              style: const TextStyle(fontSize: 13.5, height: 1.45)),
          const SizedBox(height: 14),
          Center(
            child: recording
                ? _HiddenWhileRecording(
                    size: 196,
                    onShow: () => confirmRevealWhileRecording(context, ref),
                  )
                : Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    // A fixed size: the dialog measures its content first,
                    // and the QR widget cannot be measured that way.
                    child: SizedBox.square(
                      dimension: 176,
                      child: QrImageView(
                        data: setup.qrUrl,
                        version: QrVersions.auto,
                        size: 176,
                        gapless: true,
                        backgroundColor: Colors.white,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Text(l10n.twoStepEnterKey,
              style: TextStyle(
                  fontSize: 12.5, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: recording
                      ? Text(l10n.twoStepHiddenWhileRecording,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textSecondary))
                      : SelectableText(
                          groupKey(setup.key),
                          style: const TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 13.5,
                              letterSpacing: 0.5),
                        ),
                ),
                IconButton(
                  tooltip: l10n.twoStepCopyKey,
                  icon: const Icon(LucideIcons.copy, size: 17),
                  onPressed: () => _copyKey(setup.key),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(l10n.twoStepConfirmCode,
              style: const TextStyle(fontSize: 13.5, height: 1.45)),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('two-step-setup-code'),
            controller: _code,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 22, letterSpacing: 6),
            decoration: _fieldDecoration(hint: '000000'),
            onSubmitted: (_) => _verify(),
          ),
          if (_error != null) _errorLine(_error!),
          if (_busy) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3TextSecondary),
                ),
                const SizedBox(width: 8),
                Text(l10n.zestDialogWorking, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
              ],
            ),
          ],
        ],
      );
    }

    // In the app's dialog (the dialog rules, 3.4): Open in the authenticator
    // app is the side option, a link bottom left (it stood in the body).
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.shieldCheck,
      title: l10n.twoStepSetupTitle,
      onClose: _busy ? () {} : () => Navigator.of(context).pop(),
      body: body,
      tertiaryKey: const ValueKey('two-step-open-in-app'),
      tertiaryAction: widget.canOpenInApp && setup != null
          ? (label: l10n.twoStepOpenInApp, onPressed: _busy ? null : () => _openInApp(setup))
          : null,
      secondaryKey: const ValueKey('two-step-setup-cancel'),
      secondaryAction: (
        label: _gone ? l10n.twoStepGapStop : l10n.cancel,
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
      ),
      primaryKey: const ValueKey('two-step-setup-verify'),
      primaryAction: (
        label: widget.inPlaceOfPasskeys && !_gone ? l10n.authenticatorReplaceVerify : l10n.twoStepVerify,
        icon: null,
        onPressed: setup != null && !_busy && _sixDigits.hasMatch(_code.text.trim()) ? _verify : null,
      ),
    );
  }
}

class _HiddenWhileRecording extends StatelessWidget {
  const _HiddenWhileRecording({required this.size, required this.onShow});

  final double size;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.eyeOff, size: 22, color: AppColors.textSecondary),
          const SizedBox(height: 8),
          Text(
            l10n.twoStepHiddenWhileRecording,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          TextButton(onPressed: onShow, child: Text(l10n.twoStepShow)),
        ],
      ),
    );
  }
}

// ── Recovery codes, shown once ──────────────────────────────────────────

/// The recovery codes just made, shown once with copy and save. Done is
/// offered once the person says they saved them.
Future<void> showRecoveryCodes(
  BuildContext context, {
  required List<String> codes,
  required String email,
}) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    barrierDismissible: false,
    child: RecoveryCodesDialog(codes: codes, email: email),
  );
}

class RecoveryCodesDialog extends ConsumerStatefulWidget {
  const RecoveryCodesDialog(
      {super.key, required this.codes, required this.email});

  final List<String> codes;

  /// The account the codes belong to, written into the saved file.
  final String email;

  @override
  ConsumerState<RecoveryCodesDialog> createState() =>
      _RecoveryCodesDialogState();
}

class _RecoveryCodesDialogState extends ConsumerState<RecoveryCodesDialog> {
  bool _saved = false;

  /// Where they were saved on a computer: said in this dialog, under the codes
  /// (it was a second dialog over this one).
  String? _savedPath;

  String get _plain => widget.codes.join('\n');

  String _document(AppLocalizations l10n) => [
        l10n.twoStepCodesFileTitle,
        l10n.twoStepCodesFileIntro(widget.email),
        '',
        ...widget.codes,
        '',
      ].join('\n');

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context)!;
    if (!await confirmRevealWhileRecording(context, ref)) return;
    final text = _plain;
    await SecretClipboard.copy(text, life: _clipboardLife);
    if (mounted) {
      showTopSnackBar(context, l10n.twoStepCodesCopied, isSuccess: true);
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (!await confirmRevealWhileRecording(context, ref)) return;
    final bytes = Uint8List.fromList(utf8.encode(_document(l10n)));
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: l10n.twoStepCodesSave,
        fileName: 'ZestSSH_Backup_Codes.txt',
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (path == null) return;
      // On a computer the picker only chooses the place: write it here, kept
      // to its owner (never left readable by another account), and say where.
      if (!Platform.isAndroid && !Platform.isIOS) {
        final file = File(path);
        await file.writeAsBytes(bytes, flush: true);
        if (!await restrictFileToOwner(file)) {
          try {
            await file.delete();
          } catch (_) {}
          if (mounted) showTopSnackBar(context, l10n.twoStepCodesNotPrivate, isError: true);
          return;
        }
        if (!mounted) return;
        setState(() {
          _saved = true;
          _savedPath = file.path;
        });
        return;
      }
      if (mounted) {
        setState(() => _saved = true);
        showTopSnackBar(context, l10n.twoStepCodesSaved, isSuccess: true);
      }
    } catch (e) {
      AppLogger.warning('Saving recovery codes failed: $e');
      if (mounted) {
        showTopSnackBar(context, l10n.twoStepCodesSaveFailed, isError: true, details: '$e');
      }
    }
  }

  // Escape closes it only as its X does: once the codes are said to be saved (the 3.4 security review, L7).
  @override
  Widget build(BuildContext context) => PopScope(canPop: _saved, child: _dialog(context));

  Widget _dialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final recording = ref.watch(recordingModeProvider);
    final saved = _savedPath;
    // In the app's dialog (the dialog rules, 3.4): Copy an icon on the codes,
    // Save as a file the side option, a link bottom left (both stood in the
    // body as buttons), and where they were saved said here, not in a second
    // dialog over this one. Done waits until they are saved.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.twoStepCodesTitle,
      onClose: _saved ? () => Navigator.of(context).pop() : () {},
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.twoStepCodesBody, style: const TextStyle(fontSize: 13, height: 1.5)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: recording
                      ? Center(
                          child: _HiddenWhileRecording(
                            size: 180,
                            onShow: () => confirmRevealWhileRecording(context, ref),
                          ),
                        )
                      : Wrap(
                          spacing: 22,
                          runSpacing: 8,
                          children: [
                            for (final code in widget.codes)
                              SizedBox(
                                width: 150,
                                child: SelectableText(
                                  code,
                                  style: const TextStyle(
                                    fontFamily: 'JetBrainsMono',
                                    fontSize: 15,
                                    letterSpacing: 0.6,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                // A small icon on the codes, as on a saved file's path.
                IconButton(
                  key: const ValueKey('two-step-codes-copy'),
                  tooltip: l10n.twoStepCodesCopy,
                  iconSize: 16,
                  color: AppColors.v3TextSecondary,
                  icon: const Icon(LucideIcons.copy),
                  onPressed: _copy,
                ),
              ],
            ),
          ),
          if (saved != null) ...[
            const SizedBox(height: 10),
            FileSavedBody(message: l10n.twoStepCodesSavedBody, path: saved, showInFolder: false),
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey('two-step-codes-saved'),
            value: _saved,
            onChanged: (v) => setState(() => _saved = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(l10n.twoStepCodesConfirm, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
      // Once saved on a computer, the side option shows the file instead.
      tertiaryKey: ValueKey(saved != null ? 'file-saved-show' : 'two-step-codes-save'),
      tertiaryAction: saved == null
          ? (label: l10n.twoStepCodesSave, onPressed: _save)
          : isDesktopPlatform
              ? (label: l10n.fileSavedShowInFolder, onPressed: () => unawaited(revealFileInFileManager(saved)))
              : null,
      primaryKey: const ValueKey('two-step-codes-done'),
      primaryAction: (label: l10n.done, icon: null, onPressed: _saved ? () => Navigator.of(context).pop() : null),
    );
  }
}
