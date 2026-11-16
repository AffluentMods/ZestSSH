import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart' show resolveAppLocale;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/error/set_aside_action.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/file_manager.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Standalone error screen shown when a database migration fails.
///
/// This runs as its own MaterialApp (no Riverpod, no database) so it can
/// display even when the normal app infrastructure is broken.
///
/// If [backupRestored] is true, the user is told their previous data has
/// been restored from the pre-migration backup.
///
/// 3.0: what stands behind the failure is the report of it
/// ([report], scrubbed: it was the raw error with the database's path, which
/// names the account's folder, and that went to the clipboard and into the
/// mail to support), and on a computer the copy made before the update can
/// be shown in its folder.
class MigrationErrorApp extends StatelessWidget {
  /// The report of the failure (`ErrorReport.build`).
  final String report;
  final bool backupRestored;

  /// The copy of the database made before the update, for Show in folder
  /// (never shown as text).
  final String? backupPath;
  final VoidCallback onContinue;

  /// What did not open goes to a folder of its own, and the app starts fresh,
  /// deleting nothing: the way out where the copy from before could not be put
  /// back. Null on a phone.
  final Future<void> Function()? onSetAside;

  /// Opens a link, and shows a file in its folder (a test's own stand in).
  final Future<bool> Function(Uri uri)? launch;
  final Future<void> Function(String path)? reveal;

  const MigrationErrorApp({
    super.key,
    required this.report,
    required this.backupRestored,
    this.backupPath,
    required this.onContinue,
    this.onSetAside,
    this.launch,
    this.reveal,
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
      home: WindowBarOver(child: _MigrationErrorScreen(app: this)),
    );
  }
}

class _MigrationErrorScreen extends StatelessWidget {
  final MigrationErrorApp app;

  const _MigrationErrorScreen({required this.app});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final backup = app.backupPath;
    final outlined = OutlinedButton.styleFrom(
      foregroundColor: AppColors.onSurfaceVariant,
      side: BorderSide(color: AppColors.divider),
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: AppColors.brandOrange.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      LucideIcons.wrench,
                      size: 44,
                      color: AppColors.accentInk,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Title
                  Text(
                    l10n.migrationErrorUpdateFailed,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppColors.onBackground,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // What happened
                  Text(
                    app.backupRestored
                        ? l10n.migrationErrorDataRestoredMessage
                        : l10n.migrationErrorDataNotRestoredMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // What it means / what to do
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceDark,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.divider,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          app.backupRestored
                              ? LucideIcons.checkCircle2
                              : LucideIcons.info,
                          size: 18,
                          color: app.backupRestored
                              ? AppColors.success
                              : AppColors.accentInk,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            app.backupRestored
                                ? l10n.migrationErrorDataSafeDetail
                                : l10n.migrationErrorDataAffectedDetail,
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Continue button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('migration-error-continue'),
                      onPressed: app.onContinue,
                      icon: const Icon(LucideIcons.arrowRight),
                      label: Text(l10n.migrationErrorContinue),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandOrange,
                        foregroundColor: AppColors.onBrand(AppColors.brandOrange),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (app.onSetAside != null) ...[
                    SetAsideAction(
                      buttonKey: const ValueKey('migration-error-set-aside'),
                      onSetAside: app.onSetAside!,
                    ),
                    const SizedBox(height: 12),
                  ],

                  // The copy made before the update, on a computer.
                  if (backup != null && isDesktopPlatform) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: const ValueKey('migration-error-backup'),
                        onPressed: () => (app.reveal ?? revealFileInFileManager)(backup),
                        icon: const Icon(LucideIcons.folderOpen, size: 18),
                        label: Text(l10n.migrationErrorShowBackup),
                        style: outlined,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Contact Support button (where the build names somebody to write to)
                  if (kSupportEmail != '')
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey('migration-error-support'),
                      onPressed: () => writeToSupportWithDetails(context, app.report, launch: app.launch),
                      icon: const Icon(LucideIcons.mail, size: 18),
                      label: Text(l10n.migrationErrorContactSupport),
                      style: outlined,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // What stands behind it, to read or copy.
                  ErrorDetailsPanel(report: app.report),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
