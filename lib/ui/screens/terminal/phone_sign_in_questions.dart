import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart' show dbReadyProvider;
import 'package:zestssh/providers/desktop_providers.dart'
    show HostKeyAutoAcceptEvent, HostKeyProvenanceEvent, hostKeyAutoAcceptProvider, hostKeyProvenanceProvider;
import 'package:zestssh/providers/security_providers.dart' show isAppLockedProvider;
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/providers/settings_providers.dart' show notifySecurityAlertsProvider;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/passphrase_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/server_question_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/sign_in_link_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/host_address.dart';

/// A phone's sign-in questions, wherever they come from: a host's key to
/// trust, a password, a key's passphrase, a server's own question (3.0, found
/// 16 October 2026 while comparing the five versions). A session's terminal
/// screen alone asked them, so one that Install key or a workflow's Run asked
/// (they open no terminal) was shown to nobody: a password gave up after two
/// minutes, a host's key waited for good and came up in the next terminal
/// opened; and a tablet showing two terminals asked the same question twice.
/// Now the app asks each once, above whatever is on screen (a computer's shell
/// does the same). Never while the app is locked, or over its lock screen:
/// what waits then is asked once the app is open and its screens are back,
/// and a question its lock took away is asked again.
class PhoneSignInQuestions extends ConsumerStatefulWidget {
  const PhoneSignInQuestions({super.key, required this.router, required this.child});

  /// The app's router: its navigator shows the questions, and a move of its
  /// is when what waits is asked again.
  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<PhoneSignInQuestions> createState() => _PhoneSignInQuestionsState();
}

class _PhoneSignInQuestionsState extends ConsumerState<PhoneSignInQuestions> {
  bool _hostKeyDialogShowing = false;
  bool _serverQuestionsShowing = false;
  bool _signInNoticesShowing = false;
  bool _passwordDialogShowing = false;
  bool _passphraseDialogShowing = false;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onMoved);
    _onMoved();
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onMoved);
    super.dispose();
  }

  void _onMoved() => WidgetsBinding.instance.addPostFrameCallback((_) => _askWhatWaits());

  /// Where a question is shown: the navigator's, while the app is open and
  /// not on its lock screen; else null, and nothing is asked.
  BuildContext? get _at {
    if (!mounted || ref.read(isAppLockedProvider) || !ref.read(dbReadyProvider)) return null;
    final delegate = widget.router.routerDelegate;
    if (delegate.currentConfiguration.uri.path == Routes.securityLock) return null;
    final at = delegate.navigatorKey.currentContext;
    return at != null && at.mounted ? at : null;
  }

  /// Asks what waits: set before this listened, while the app was locked, or
  /// taken away with the screen it was asked over.
  void _askWhatWaits() {
    if (_at == null) return;
    final password = ref.read(passwordPromptProvider);
    if (password != null) _showPasswordPromptDialog(password);
    final passphrase = ref.read(passphrasePromptProvider);
    if (passphrase != null) _showPassphrasePromptDialog(passphrase);
    if (ref.read(hostKeyVerificationProvider) != null) _showHostKeyDialog();
    if (ref.read(serverQuestionProvider) != null) _showServerQuestions();
    if (ref.read(signInNoticeProvider) != null) _showSignInNotices();
    _tellKeysTrusted();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<HostKeyVerification?>(hostKeyVerificationProvider, (prev, next) {
      if (next != null) _showHostKeyDialog();
    });
    ref.listen<PasswordPromptRequest?>(passwordPromptProvider, (prev, next) {
      if (next != null) _showPasswordPromptDialog(next);
    });
    ref.listen<PassphrasePromptRequest?>(passphrasePromptProvider, (prev, next) {
      if (next != null) _showPassphrasePromptDialog(next);
    });
    ref.listen<ServerQuestionRequest?>(serverQuestionProvider, (prev, next) {
      if (next != null) _showServerQuestions();
    });
    ref.listen<SignInNoticeRequest?>(signInNoticeProvider, (prev, next) {
      if (next != null) _showSignInNotices();
    });
    // A host's key trusted with no question, told as a computer tells it (a
    // phone trusted it with no word).
    ref.listen<HostKeyAutoAcceptEvent?>(hostKeyAutoAcceptProvider, (prev, next) {
      if (next != null) _tellKeysTrusted();
    });
    ref.listen<HostKeyProvenanceEvent?>(hostKeyProvenanceProvider, (prev, next) {
      if (next != null) _tellKeysTrusted();
    });
    return widget.child;
  }

  // ─── Host keys trusted with no question ────────────────────────

  /// Tells of a host's key trusted with no question, each once, in a
  /// computer's words: a new host's, trusted because "Ask before trusting new
  /// host keys" is off (with the way to that setting), and one another device
  /// recorded, trusted here for the first time (with that device and the
  /// day). While the app is locked they wait, and are told once it is open.
  /// Recording mode masks the address, the fingerprint and the device.
  void _tellKeysTrusted() {
    final at = _at;
    if (at == null) return;
    final l10n = AppLocalizations.of(at)!;
    final accepted = ref.read(hostKeyAutoAcceptProvider);
    if (accepted != null) {
      ref.read(hostKeyAutoAcceptProvider.notifier).state = null;
      showTopSnackBar(
        at,
        l10n.desktopShellHostKeyAutoAccepted(Redactable.address(hostWithPort(accepted.host, accepted.port)).display,
            accepted.keyType, Redactable.fingerprint(accepted.fingerprint).display),
        duration: const Duration(seconds: 6),
        actionLabel: l10n.settingsTitle,
        onAction: () {
          final there = _at;
          if (there != null) SecuritySettingsScreen.show(there);
        },
      );
    }
    final adopted = ref.read(hostKeyProvenanceProvider);
    if (adopted != null) {
      ref.read(hostKeyProvenanceProvider.notifier).state = null;
      final d = adopted.recordedAt;
      final day = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final target = Redactable.address(hostWithPort(adopted.host, adopted.port)).display;
      final device = Redactable.host(adopted.device).display;
      showTopSnackBar(
        at,
        adopted.certificate
            ? l10n.ftpsCertificateProvenance(target, device, day)
            : l10n.desktopShellHostKeyProvenance(target, device, day),
        isWarning: true,
        duration: const Duration(seconds: 8),
      );
    }
  }

  // ─── Host Key Verification Dialog ──────────────────────────────

  /// Drain the host-key queue: show one prompt at a time and advance to the
  /// next pending verification after each answer, so every untrusted host in
  /// a multi-session connect gets its own prompt. A verification that arrives
  /// while a prompt is open waits in the queue and is shown next - never
  /// dropped (the old single-slot version dropped it and hung that session).
  Future<void> _showHostKeyDialog() async {
    if (_hostKeyDialogShowing || _at == null) return;
    _hostKeyDialogShowing = true;
    try {
      final queue = ref.read(hostKeyVerificationQueueProvider.notifier);
      HostKeyVerification? verification = queue.current;
      while (verification != null && mounted) {
        final at = _at;
        if (at == null) break;
        final accepted = await _askHostKey(at, verification);
        if (accepted == null) {
          // The dialog was TORN DOWN without an answer (the page under it was
          // replaced, e.g. by the lock-screen redirect), not answered: every
          // button pops an explicit bool and the barrier is not dismissible.
          // Leave the entry queued for the mount-time pending check instead of
          // resolving it, so no prompt is lost, nothing is trusted without an
          // explicit answer, and the NEXT prompt is not pushed on top of the
          // lock screen where a bystander could answer it.
          break;
        }
        queue.resolve(verification, accepted);
        verification = queue.current;
      }
    } finally {
      _hostKeyDialogShowing = false;
    }
  }

  /// Show ONE host-key prompt and return the user's answer, or null when the
  /// dialog was torn down before an answer (its page was replaced).
  Future<bool?> _askHostKey(BuildContext at, HostKeyVerification verification) async {
    // A CHANGED key on an already-trusted host is a distinct, security-critical
    // event: the dedicated warning dialog (both fingerprints, trust date,
    // verify command, inverted actions), told to the notification centre as
    // well. A new host's key: the first-connection question.
    if (verification.isChanged) {
      if (ref.read(notifySecurityAlertsProvider)) {
        // Recording mode: the host:port is masked at the source, since a
        // bare label is nothing the notification centre's scan can catch.
        final target = Redactable.address(
                hostWithPort(verification.host, verification.port))
            .display;
        ref.read(notificationCenterProvider.notifier).warning(
              AppLocalizations.of(at)!.terminalHostKeyChanged,
              body: AppLocalizations.of(at)!
                  .terminalHostKeyChangedBody(target),
            );
      }
    }
    // Both the app's dialogs (a phone's sheet), one on a phone as on a
    // computer ([askHostKeyTrust]).
    return askHostKeyTrust(at, verification);
  }

  /// Server sign-in questions (a 2FA code), one dialog at a time.
  Future<void> _showServerQuestions() async {
    final at = _at;
    if (_serverQuestionsShowing || at == null) return;
    _serverQuestionsShowing = true;
    try {
      await showServerQuestions(at, ref, isMounted: () => mounted && at.mounted);
    } finally {
      _serverQuestionsShowing = false;
    }
  }

  /// A login banner's link the sign-in waits on (Tailscale SSH's check), one
  /// dialog at a time.
  Future<void> _showSignInNotices() async {
    final at = _at;
    if (_signInNoticesShowing || at == null) return;
    _signInNoticesShowing = true;
    try {
      await showSignInNotices(at, ref, isMounted: () => mounted && at.mounted);
    } finally {
      _signInNoticesShowing = false;
    }
  }

  /// The password a sign-in asks for, one dialog at a time.
  Future<void> _showPasswordPromptDialog(PasswordPromptRequest request) async {
    final at = _at;
    if (_passwordDialogShowing || at == null) return;
    _passwordDialogShowing = true;
    try {
      await showPasswordPrompt(at, request);
    } catch (e) {
      // If the dialog fails (e.g., context no longer valid), complete
      // the completer to unblock the connection attempt.
      AppLogger.error('Failed to show password dialog', e);
      if (!request.completer.isCompleted) {
        request.completer.complete(null);
      }
    } finally {
      _passwordDialogShowing = false;
    }
  }

  /// A key's passphrase, one dialog at a time.
  Future<void> _showPassphrasePromptDialog(
      PassphrasePromptRequest request) async {
    final at = _at;
    if (_passphraseDialogShowing || at == null) return;
    _passphraseDialogShowing = true;
    try {
      await showPassphrasePrompt(at, request);
    } catch (e) {
      AppLogger.error('Failed to show passphrase dialog', e);
      if (!request.completer.isCompleted) {
        request.completer.complete(null);
      }
    } finally {
      _passphraseDialogShowing = false;
    }
  }
}
