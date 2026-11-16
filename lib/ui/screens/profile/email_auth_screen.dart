import 'package:lucide_icons/lucide_icons.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/sso_sign_in.dart' show profileNotOpened, refusedForAddress;
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';

/// Email + password sign-in / sign-up with mandatory email verification.
///
/// A new account is created signed-in but UNVERIFIED, and the backend treats
/// an unverified password account as inert (no sync, no entitlements) until the
/// user clicks the verification link. That gate is the anti-spam guarantee:
/// creating an address costs an attacker nothing they can use.

/// The shortest password a new ZestSSH account takes (12, where it was
/// 8); the website and the sign-in service ask the same.
const kMinAccountPasswordLength = 12;

class EmailAuthScreen extends ConsumerStatefulWidget {
  const EmailAuthScreen({super.key, this.createAccount = false});

  /// Opens at Create an account (the welcome screen's button) instead of at
  /// Sign in.
  final bool createAccount;

  @override
  ConsumerState<EmailAuthScreen> createState() => _EmailAuthScreenState();
}

enum _Mode { signIn, signUp }

class _EmailAuthScreenState extends ConsumerState<EmailAuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  late _Mode _mode = widget.createAccount ? _Mode.signUp : _Mode.signIn;
  bool _busy = false;
  bool _obscure = true;

  /// The eye held down: the password shows only while it is (as on the
  /// website's sign-in).
  bool _peek = false;
  String? _error;
  // Set once an account is signed in but the email is not yet verified.
  bool _pendingVerification = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _friendlyError(Object e) => emailAuthErrorText(e, AppLocalizations.of(context)!);

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    try {
      if (_mode == _Mode.signUp) {
        await AuthService.signUpWithEmail(email, password);
        if (!mounted) return;
        setState(() => _pendingVerification = true);
      } else {
        // An account with two-step sign-in answers its second step too.
        final asker = SecondStepAsker(context);
        final result = await AuthService.signInWithEmail(email, password,
            secondStep: asker.call);
        if (!mounted || result == null) return;
        if (AuthService.isEmailVerified) {
          if (asker.usedRecoveryCode) {
            showTopSnackBar(
                context, AppLocalizations.of(context)!.twoStepTurnedOffNotice,
                duration: const Duration(seconds: 8));
            context.pop();
          } else {
            await _finishSignedIn();
          }
        } else {
          setState(() => _pendingVerification = true);
        }
      }
    } on TwoStepTurnedOff {
      if (!mounted) return;
      setState(() =>
          _error = AppLocalizations.of(context)!.twoStepTurnedOffSignInAgain);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishSignedIn() async {
    if (!mounted) return;
    // An address that belongs to another account is refused by ZestSSH
    // Cloud: this device signs out again, and the person is told.
    if (await refusedForAddress(context, ref) || !mounted) return;
    if (await profileNotOpened(context, ref) || !mounted) return;
    showTopSnackBar(context, AppLocalizations.of(context)!.emailAuthSignedIn,
        isSuccess: true);
    context.pop();
  }

  Future<void> _resend() async {
    setState(() => _busy = true);
    try {
      await AuthService.sendEmailVerification();
      if (mounted) {
        showTopSnackBar(
            context, AppLocalizations.of(context)!.emailAuthVerificationEmailSent,
            isSuccess: true);
      }
    } catch (e) {
      if (mounted) showTopSnackBar(context, _friendlyError(e), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkVerified() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verified = await AuthService.refreshEmailVerified();
      if (!mounted) return;
      // Only accept the account we are actually verifying: the email match
      // stops a stale sign-in (e.g. a previous Google session) being let
      // through, and `verified` must be genuinely true.
      final matches = AuthService.currentUser?.email?.toLowerCase() ==
          _emailController.text.trim().toLowerCase();
      if (verified && matches) {
        await _finishSignedIn();
      } else {
        setState(() =>
            _error = AppLocalizations.of(context)!.emailAuthNotVerifiedYet);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useDifferentAccount() async {
    await AuthService.signOut();
    if (!mounted) return;
    setState(() {
      _pendingVerification = false;
      _error = null;
      _passwordController.clear();
    });
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() =>
          _error = AppLocalizations.of(context)!.emailAuthEnterEmailFirst);
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.sendPasswordResetEmail(email);
    } on FirebaseAuthException catch (e) {
      // Anti-enumeration: an unknown address gets the same reply as a known
      // one, so the reset form cannot be used to test which emails exist.
      if (e.code != 'user-not-found') {
        if (mounted) {
          showTopSnackBar(context, _friendlyError(e), isError: true, details: '$e');
          setState(() => _busy = false);
        }
        return;
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, _friendlyError(e), isError: true, details: '$e');
        setState(() => _busy = false);
      }
      return;
    }
    if (mounted) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.emailAuthResetLinkSent,
        isSuccess: true,
      );
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_pendingVerification
            ? l10n.emailAuthVerifyYourEmail
            : (_mode == _Mode.signUp
                ? l10n.emailAuthCreateAccount
                : l10n.emailAuthSignIn)),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _pendingVerification
                  ? _buildVerificationPending()
                  : _buildForm(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final l10n = AppLocalizations.of(context)!;
    final isSignUp = _mode == _Mode.signUp;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _emailController,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l10n.emailAuthEmailLabel,
              border: const OutlineInputBorder(),
            ),
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty || !t.contains('@') || !t.contains('.')) {
                return l10n.emailAuthEnterValidEmail;
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _passwordController,
            enabled: !_busy,
            obscureText: _obscure && !_peek,
            // Typing hides it again.
            onChanged: (_) {
              if (!_obscure || _peek) setState(() => _obscure = true);
            },
            autofillHints:
                isSignUp ? const [AutofillHints.newPassword] : const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.emailAuthPasswordLabel,
              border: const OutlineInputBorder(),
              helperText: isSignUp ? l10n.emailAuthPasswordMinHint : null,
              // A click shows or hides it; held down, it shows while held.
              // The tooltip shows on hover only: a long press is the peek.
              suffixIcon: TooltipTheme(
                data: const TooltipThemeData(triggerMode: TooltipTriggerMode.manual),
                child: GestureDetector(
                  key: const ValueKey('email-auth-password-eye'),
                  onLongPressStart: (_) => setState(() => _peek = true),
                  onLongPressEnd: (_) => setState(() => _peek = false),
                  onLongPressCancel: () => setState(() => _peek = false),
                  child: IconButton(
                    tooltip: _obscure && !_peek
                        ? AppLocalizations.of(context)!.zestDialogShow
                        : AppLocalizations.of(context)!.zestDialogHide,
                    icon: Icon(_obscure && !_peek ? LucideIcons.eye : LucideIcons.eyeOff),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ),
            validator: (v) {
              final t = v ?? '';
              if (isSignUp && t.length < kMinAccountPasswordLength) {
                return l10n.emailAuthPasswordTooShort;
              }
              if (t.isEmpty) return l10n.emailAuthEnterYourPassword;
              return null;
            },
          ),
          if (!isSignUp)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : _forgotPassword,
                child: Text(l10n.emailAuthForgotPassword),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: AppColors.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: ButtonSpinner(),
                  )
                : Text(isSignUp
                    ? l10n.emailAuthCreateAccount
                    : l10n.emailAuthSignIn),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _mode = isSignUp ? _Mode.signIn : _Mode.signUp;
                      _error = null;
                    }),
            child: Text(isSignUp
                ? l10n.emailAuthAlreadyHaveAccount
                : l10n.emailAuthNewHereCreateAccount),
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationPending() {
    final l10n = AppLocalizations.of(context)!;
    final email = _emailController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(LucideIcons.mailWarning,
            size: 64, color: AppColors.accentInk),
        const SizedBox(height: 16),
        Text(
          l10n.emailAuthCheckYourEmail,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        Text(
          l10n.emailAuthVerificationSentTo(email),
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _checkVerified,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.brandOrange,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: ButtonSpinner(),
                )
              : Text(l10n.emailAuthIveVerified),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _resend,
          child: Text(l10n.emailAuthResendEmail),
        ),
        TextButton(
          onPressed: _busy ? null : _useDifferentAccount,
          child: Text(l10n.emailAuthUseDifferentAccount),
        ),
      ],
    );
  }
}

/// What the email screen says for the failure [e] (one account per email
/// address, 3.0: a wrong password and an account made through Google or
/// Apple, which has none until one is set, read the same).
String emailAuthErrorText(Object e, AppLocalizations l10n) {
  if (e is FirebaseAuthException) {
    switch (e.code) {
      case 'email-already-in-use':
        return l10n.emailAuthErrorEmailInUse;
      case 'invalid-email':
        return l10n.emailAuthErrorInvalidEmail;
      case 'weak-password':
        return l10n.emailAuthErrorWeakPassword;
      // (With email enumeration protection on, a wrong password and an
      // address with no password both read invalid-login-credentials.)
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return l10n.emailAuthErrorIncorrectOrOtherWay;
      case 'user-disabled':
        return l10n.emailAuthErrorDisabled;
      case 'too-many-requests':
        return l10n.emailAuthErrorTooManyRequests;
      case 'network-request-failed':
        return l10n.emailAuthErrorNetwork;
      case 'operation-not-allowed':
        return l10n.emailAuthErrorNotEnabled;
      default:
        return e.message ?? l10n.emailAuthErrorGeneric;
    }
  }
  return l10n.emailAuthErrorGeneric;
}
