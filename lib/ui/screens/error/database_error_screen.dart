import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart' show resolveAppLocale;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart' show DatabaseNewerThanApp;
import 'package:zestssh/services/profiles/mac_keychain.dart' show KeychainAccessDenied;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/error/set_aside_action.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/file_manager.dart';

/// The report of a database that could not be opened at start, or of an
/// update of it that failed ([migration]): what failed, the error, whether
/// the copy made before was put back, and where the database is (a path that
/// names the account's folder: the report says `<app data>` for it, the
/// folders the app writes to being learnt first). macOS not letting ZestSSH
/// read its keys is said as that, with its code (3.3.2).
Future<String> databaseFailureReport({
  required bool migration,
  required Object error,
  StackTrace? stack,
  String? databasePath,
  bool backupRestored = false,
}) async {
  await ErrorReport.prime();
  return ErrorReport.build(
    what: error is KeychainAccessDenied
        ? ErrorCodes.withCode(gl10n.macKeychainDeniedTitle, ErrorCodes.macKeychainDenied)
        : error is DatabaseNewerThanApp
            ? gl10n.databaseNewerTitle
            : migration
            ? gl10n.migrationErrorUpdateFailed
            : gl10n.databaseErrorTitle,
    where: migration ? 'Updating the database at start' : 'Opening the database at start',
    error: error,
    stack: stack,
    details: [
      if (migration) 'Backup restored: ${backupRestored ? 'yes' : 'no'}',
      'Database: ${databasePath ?? 'unknown'}',
    ].join('\n'),
  );
}

/// Standalone error screen shown when the database fails to open.
///
/// This runs as its own MaterialApp (no Riverpod, no database) so it can
/// display even when the normal app infrastructure is broken. It is shown on
/// every platform, so the layout is a single centered card with a bounded
/// width - it must read as an intentional desktop dialog on a 2560px monitor,
/// not a mobile column stretched edge to edge.
///
/// 3.0: what stands behind the failure is the report of it
/// ([report], scrubbed: the database's path named the account's folder),
/// with Copy details; on a computer the database's folder can be shown, and
/// support written to; a reset that fails says so.
class DatabaseErrorApp extends StatelessWidget {
  /// The report of the failure (`ErrorReport.build`).
  final String report;

  /// Where the database is, for Show in folder (never shown as text).
  final String? databasePath;

  final VoidCallback onRetry;

  /// Sets the database's files aside, its key kept, and starts again (a phone); a
  /// failure is said on the screen. Null where it must not be offered (resetOffered
  /// in profile_boot.dart): on a computer, whose Set aside does it and Put it back
  /// undoes, while a move holds the only copy, and wherever the failure may pass.
  final Future<void> Function()? onReset;

  /// Opens another profile instead of this one (guest data): null where there
  /// is none to open. A profile that cannot open never stops the others.
  final VoidCallback? onOpenOther;

  /// Moves what did not open to a folder of its own and starts fresh, deleting
  /// nothing: the way out of a move whose database does not open. Null on a phone.
  final Future<void> Function()? onSetAside;

  /// Opens a link, and shows a file in its folder (a test's own stand in).
  final Future<bool> Function(Uri uri)? launch;
  final Future<void> Function(String path)? reveal;

  /// What stopped it is macOS not letting ZestSSH read its own keys, the
  /// database's key among them (3.3.2): the screen says that and what to do, and
  /// never offers Reset, which would delete data that is only waiting for a yes.
  final bool keychainDenied;

  /// The data was written by a newer ZestSSH ([DatabaseNewerThanApp]): the
  /// screen says to update the app and never offers Reset (nor does the
  /// start offer Set aside: dataStaysAsItIs in profile_boot.dart).
  final bool newerData;

  const DatabaseErrorApp({
    super.key,
    required this.report,
    this.databasePath,
    required this.onRetry,
    required this.onReset,
    this.onOpenOther,
    this.onSetAside,
    this.launch,
    this.reveal,
    this.keychainDenied = false,
    this.newerData = false,
  });

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
      home: WindowBarOver(child: _DatabaseErrorScreen(app: this)),
    );
  }
}

class _DatabaseErrorScreen extends StatefulWidget {
  final DatabaseErrorApp app;

  const _DatabaseErrorScreen({required this.app});

  @override
  State<_DatabaseErrorScreen> createState() => _DatabaseErrorScreenState();
}

class _DatabaseErrorScreenState extends State<_DatabaseErrorScreen> {
  bool _resetting = false;

  /// The report of a reset that failed, shown under the buttons.
  String? _resetFailure;

  Future<void> _confirmReset() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.databaseErrorResetTitle,
      body: l10n.databaseErrorResetBody,
      confirmLabel: l10n.databaseErrorDeleteEverything,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _resetting = true;
      _resetFailure = null;
    });
    try {
      await widget.app.onReset!();
    } catch (e, stack) {
      // (It did nothing anyone could see: setting the files aside failed unseen.)
      if (!mounted) return;
      setState(() => _resetFailure = ErrorReport.build(
            what: l10n.databaseErrorResetFailed,
            where: 'Setting the database aside to start again',
            error: e,
            stack: stack,
          ));
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final path = widget.app.databasePath;
    final keychain = widget.app.keychainDenied;
    final newer = widget.app.newerData;
    final onReset = keychain || newer ? null : widget.app.onReset;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: ConstrainedBox(
              // Bounded so the card reads as a dialog on a wide desktop window
              // rather than a full-bleed mobile column.
              constraints: const BoxConstraints(maxWidth: 460),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.divider, width: 1),
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
                    // Warning mark
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.brandOrange.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          keychain ? LucideIcons.keyRound : LucideIcons.alertTriangle,
                          size: 36,
                          color: AppColors.accentInk,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),

                    // Title
                    Text(
                      keychain
                          ? l10n.macKeychainDeniedTitle
                          : newer
                              ? l10n.databaseNewerTitle
                              : l10n.databaseErrorTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: AppColors.onBackground,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Description - primary message in the brightest body
                    // colour so it reads clearly above the dimmer tip below
                    // (textSecondary is aliased to onSurfaceVariant, so the
                    // message uses onBackground to actually stand apart).
                    Text(
                      keychain
                          ? ErrorCodes.withCode(l10n.macKeychainDeniedBody, ErrorCodes.macKeychainDenied)
                          : newer
                              ? l10n.databaseNewerBody
                              : l10n.databaseErrorDescription,
                      key: const ValueKey('database-error-description'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: AppColors.onBackground,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Guidance
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceDark,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.divider, width: 1),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(LucideIcons.lightbulb,
                              size: 18, color: AppColors.accentInk),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              keychain
                                  ? l10n.macKeychainDeniedWhy
                                  : newer
                                      ? l10n.databaseNewerGuidance
                                      : l10n.databaseErrorGuidance,
                              key: const ValueKey('database-error-guidance'),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: AppColors.textSecondary,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Primary action
                    FilledButton.icon(
                      key: const ValueKey('database-error-retry'),
                      onPressed: _resetting ? null : widget.app.onRetry,
                      icon: const Icon(LucideIcons.refreshCw, size: 19),
                      label: Text(keychain ? l10n.macKeychainTryAgain : l10n.retry),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandOrange,
                        foregroundColor: AppColors.onBrand(AppColors.brandOrange),
                        minimumSize: const Size.fromHeight(46),
                        textStyle: const TextStyle(
                            fontFamily: 'GeistSans',
                            fontSize: 15, fontWeight: FontWeight.w600),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                    ),
                    if (widget.app.onOpenOther != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        key: const ValueKey('database-error-open-other'),
                        onPressed: _resetting ? null : widget.app.onOpenOther,
                        child: Text(l10n.databaseErrorOpenOther),
                      ),
                    ],
                    if (widget.app.onSetAside != null) ...[
                      const SizedBox(height: 8),
                      SetAsideAction(
                        buttonKey: const ValueKey('database-error-set-aside'),
                        onSetAside: widget.app.onSetAside!,
                        enabled: !_resetting,
                        onBusy: (busy) => setState(() => _resetting = busy),
                      ),
                    ],
                    const SizedBox(height: 8),

                    // Ways to look further, side by side: the database's
                    // folder (on a computer) and support.
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (path != null && isDesktopPlatform)
                          TextButton.icon(
                            key: const ValueKey('database-error-folder'),
                            onPressed: () => (widget.app.reveal ?? revealFileInFileManager)(path),
                            icon: const Icon(LucideIcons.folderOpen, size: 17),
                            label: Text(l10n.fileSavedShowInFolder),
                            style: TextButton.styleFrom(foregroundColor: AppColors.onSurfaceVariant),
                          ),
                        // (Where the build names somebody to write to.)
                        if (kSupportEmail != '')
                        TextButton.icon(
                          key: const ValueKey('database-error-support'),
                          onPressed: () => writeToSupportWithDetails(context, widget.app.report, launch: widget.app.launch),
                          icon: const Icon(LucideIcons.mail, size: 17),
                          label: Text(l10n.migrationErrorContactSupport),
                          style: TextButton.styleFrom(foregroundColor: AppColors.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),

                    // Destructive action, deliberately quiet - a muted text
                    // button, not a second full-weight button competing with
                    // Retry. It stays discoverable but never invites a misclick.
                    if (onReset != null)
                      TextButton.icon(
                        key: const ValueKey('database-error-reset'),
                        onPressed: _resetting ? null : _confirmReset,
                        icon: _resetting
                            ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(LucideIcons.archive, size: 17),
                        label: Text(l10n.databaseErrorResetButton),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.error,
                          minimumSize: const Size.fromHeight(40),
                          textStyle: const TextStyle(
                              fontFamily: 'GeistSans',
                              fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ),
                    if (_resetFailure != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.databaseErrorResetFailed,
                        key: const ValueKey('database-error-reset-failed'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: AppColors.error, height: 1.45),
                      ),
                      ErrorDetailsPanel(key: const ValueKey('database-error-reset-details'), report: _resetFailure!),
                    ],
                    const SizedBox(height: 6),

                    // What stands behind it, to read or copy.
                    ErrorDetailsPanel(report: widget.app.report),
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
