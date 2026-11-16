import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart' show resolveAppLocale;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/linux_keyring.dart';
import 'package:zestssh/services/profiles/keychain.dart' show keychainDenials;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/error/set_aside_action.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/profiles/profile_move.dart' show ProfileMoveFailed;
import 'package:zestssh/services/profiles/windows_keychain.dart' show KeychainFileFailed;

/// The app's window as it starts: whether one has been shown, and the screen of
/// a failure before it. Each try of a start is its own: a Try again (the person's,
/// or the look at a keyring that was unlocked) that fails again is said again. It
/// was only logged, and the screen went on saying the app goes on by itself.
class StartupWindow {
  StartupWindow({required this.show, required this.start, this.state = linuxKeyringState, this.wayOut, this.beforeSaying});

  /// Puts an app on screen (runApp; a test's own stands in).
  final void Function(Widget app) show;

  /// Starts the app again.
  final VoidCallback start;

  /// Asks the system about its keyring (a test's own stands in).
  final Future<KeyringState> Function() state;

  /// What the screen can offer besides Try again for this failure, where anything
  /// (startWayOut): asked as it fails, as only then is it known.
  final Future<Future<void> Function()?> Function(Object error)? wayOut;

  /// Run before the failure is said (a start for a command ends the program here).
  final Future<void> Function()? beforeSaying;

  /// Whether the app has shown a window of its own: until then a failure has
  /// nowhere to be said.
  bool shown = false;

  void showApp(Widget app) {
    shown = true;
    show(app);
  }

  /// [error] stopped the start: said, where nothing is on screen yet.
  Future<void> failed(Object error, StackTrace stack) async {
    if (shown) return;
    shown = true;
    await beforeSaying?.call();
    show(await startupErrorAppFor(error, stack, onRetry: retry, state: state, onSetAside: await wayOut?.call(error)));
  }

  /// The person chose Try again: what macOS said no to in this run is asked about
  /// again (3.3.2), as at a new start of the app.
  void retry() {
    shown = false;
    keychainDenials?.tryAgain();
    start();
  }
}

/// The screen for [error], which stopped the app before its window could
/// open, with its report (the folders the app writes to are learnt first,
/// so that a path in it says `<app data>`). A failure of the system's keyring
/// is told by asking the system, once ([keyringProblemOf]). [onSetAside] is the way
/// out where there is one (startWayOut): nothing is deleted, and the app starts fresh.
Future<StartupErrorApp> startupErrorAppFor(
  Object error,
  StackTrace stack, {
  required VoidCallback onRetry,
  Future<KeyringState> Function() state = linuxKeyringState,
  Future<void> Function()? onSetAside,
}) async {
  await ErrorReport.prime();
  final keyring = await keyringProblemOf(error, state: state);
  return StartupErrorApp(
    report: ErrorReport.build(
      what: switch (keyring) {
        KeyringProblem.locked => gl10n.keyringLockedTitle,
        KeyringProblem.missing => gl10n.keyringMissingTitle,
        KeyringProblem.macDenied => ErrorCodes.withCode(gl10n.macKeychainDeniedTitle, ErrorCodes.macKeychainDenied),
        // A move that stopped goes on at the next start: its code says so, and
        // what not to do meanwhile.
        null => switch (error) {
            ProfileMoveFailed() => ErrorCodes.withCode(gl10n.startupErrorTitle, ErrorCodes.profileMoveStopped),
            KeychainFileFailed() => ErrorCodes.withCode(gl10n.startupErrorTitle, ErrorCodes.keychainFile),
            _ => gl10n.startupErrorTitle,
          },
      },
      where: 'Starting the app',
      error: error,
      stack: stack,
    ),
    onRetry: onRetry,
    keyring: keyring,
    onSetAside: onSetAside,
    keychainDoesNotOpen: error is KeychainFileFailed && error.step == 'does-not-open',
  );
}

/// What is shown when the app fails before its window could open (3.0):
/// reading its settings, its keychain, or setting up the window.
/// Such a failure left a blank window, or the starting screen, for good.
///
/// Like the database's own error screen it runs as its own MaterialApp, with
/// nothing of the app behind it: what failed, Try again, a way to write to
/// support, and the details to copy ([report], scrubbed).
///
/// A Linux keyring that stopped it ([keyring]) is said as that, with what to
/// do, not as a failure of the app: a locked one is waited for, and the app goes
/// on by itself once it is unlocked.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({
    super.key,
    required this.report,
    required this.onRetry,
    this.onSetAside,
    this.keychainDoesNotOpen = false,
    this.launch,
    this.keyring,
    this.keyringUnlocked = linuxKeyringUnlocked,
  });

  /// The report of the failure (`ErrorReport.build`).
  final String report;

  /// Starts the app again.
  final VoidCallback onRetry;

  /// What did not open goes to a folder of its own, and the app starts fresh.
  final Future<void> Function()? onSetAside;

  /// What is set aside is the keychain's file, and it says so.
  final bool keychainDoesNotOpen;

  /// Opens a link (a test's own stands in).
  final Future<bool> Function(Uri uri)? launch;

  /// What stopped it, where that was the system's keyring.
  final KeyringProblem? keyring;

  /// Whether the keyring is unlocked now (a test's own stands in).
  final Future<bool?> Function() keyringUnlocked;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZestSSH',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      localeListResolutionCallback: resolveAppLocale,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.dark(
          primary: AppColors.brandOrange,
          surface: AppColors.surface,
          error: AppColors.error,
        ),
      ),
      home: WindowBarOver(
        child: _StartupErrorScreen(
          report: report,
          onRetry: onRetry,
          onSetAside: onSetAside,
          keychainDoesNotOpen: keychainDoesNotOpen,
          launch: launch,
          keyring: keyring,
          keyringUnlocked: keyringUnlocked,
        ),
      ),
    );
  }
}

class _StartupErrorScreen extends StatefulWidget {
  const _StartupErrorScreen({
    required this.report,
    required this.onRetry,
    required this.onSetAside,
    required this.keychainDoesNotOpen,
    required this.launch,
    required this.keyring,
    required this.keyringUnlocked,
  });

  final String report;
  final VoidCallback onRetry;
  final Future<void> Function()? onSetAside;
  final bool keychainDoesNotOpen;
  final Future<bool> Function(Uri uri)? launch;
  final KeyringProblem? keyring;
  final Future<bool?> Function() keyringUnlocked;

  @override
  State<_StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<_StartupErrorScreen> {
  /// How often a locked keyring is looked at while its box may be open.
  static const _keyringLook = Duration(seconds: 2);

  Timer? _look;
  bool _looking = false;

  /// The person is asked in the system's own box, often in front of this
  /// screen. Once they have answered it, the app goes on by itself.
  void _startLooking() {
    _look?.cancel();
    _look = widget.keyring == KeyringProblem.locked ? Timer.periodic(_keyringLook, (_) => _lookAtKeyring()) : null;
  }

  @override
  void initState() {
    super.initState();
    _startLooking();
  }

  @override
  void didUpdateWidget(_StartupErrorScreen old) {
    super.didUpdateWidget(old);
    // The failure of another try of the start, in the same place on screen.
    if (widget.report != old.report || widget.keyring != old.keyring) _startLooking();
  }

  @override
  void dispose() {
    _look?.cancel();
    super.dispose();
  }

  Future<void> _lookAtKeyring() async {
    if (_looking) return;
    _looking = true;
    final unlocked = await widget.keyringUnlocked();
    _looking = false;
    if (unlocked == true && mounted && (_look?.isActive ?? false)) {
      _look?.cancel();
      widget.onRetry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final keyring = widget.keyring;
    final report = widget.report;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: ConstrainedBox(
              // A dialog's width on a wide window, not a column across it.
              constraints: const BoxConstraints(maxWidth: 460),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.divider),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 40,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.brandOrange.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          keyring == null ? LucideIcons.alertTriangle : LucideIcons.keyRound,
                          size: 36,
                          color: AppColors.accentInk,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      switch (keyring) {
                        KeyringProblem.locked => l10n.keyringLockedTitle,
                        KeyringProblem.missing => l10n.keyringMissingTitle,
                        KeyringProblem.macDenied => l10n.macKeychainDeniedTitle,
                        null => l10n.startupErrorTitle,
                      },
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: AppColors.onBackground,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      switch (keyring) {
                        KeyringProblem.locked => l10n.keyringLockedBody,
                        KeyringProblem.missing => l10n.keyringMissingBody,
                        // Its code where it can be read out (ZS-1913).
                        KeyringProblem.macDenied =>
                          ErrorCodes.withCode(l10n.macKeychainDeniedBody, ErrorCodes.macKeychainDenied),
                        null => l10n.startupErrorBody,
                      },
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14.5, color: AppColors.onBackground, height: 1.55),
                    ),
                    if (keyring == KeyringProblem.locked || keyring == KeyringProblem.macDenied) ...[
                      const SizedBox(height: 12),
                      Text(
                        keyring == KeyringProblem.macDenied ? l10n.macKeychainDeniedWhy : l10n.keyringLockedHowTo,
                        key: const ValueKey('startup-keyring-how-to'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: AppColors.onSurfaceVariant, height: 1.5),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const ValueKey('startup-error-retry'),
                      onPressed: widget.onRetry,
                      icon: const Icon(LucideIcons.refreshCw, size: 19),
                      label: Text(keyring == KeyringProblem.macDenied ? l10n.macKeychainTryAgain : l10n.retry),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandOrange,
                        foregroundColor: AppColors.onBrand(AppColors.brandOrange),
                        minimumSize: const Size.fromHeight(46),
                        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 15, fontWeight: FontWeight.w600),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                      ),
                    ),
                    if (widget.onSetAside != null) ...[
                      const SizedBox(height: 8),
                      SetAsideAction(
                        buttonKey: const ValueKey('startup-error-set-aside'),
                        onSetAside: widget.onSetAside!,
                        title: widget.keychainDoesNotOpen ? l10n.keychainSetAsideTitle : null,
                        body: widget.keychainDoesNotOpen
                            ? ErrorCodes.withCode(l10n.keychainSetAsideBody, ErrorCodes.keychainFile)
                            : null,
                      ),
                    ],
                    const SizedBox(height: 8),
                    // (Where the build names somebody to write to.)
                    if (kSupportEmail != '')
                    OutlinedButton.icon(
                      key: const ValueKey('startup-error-support'),
                      onPressed: () => writeToSupportWithDetails(context, report, launch: widget.launch),
                      icon: const Icon(LucideIcons.mail, size: 18),
                      label: Text(l10n.migrationErrorContactSupport),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.onSurfaceVariant,
                        side: BorderSide(color: AppColors.divider),
                        minimumSize: const Size.fromHeight(44),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ErrorDetailsPanel(report: report),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
