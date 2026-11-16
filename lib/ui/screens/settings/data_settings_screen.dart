import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart' show puttyImportHere;
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../router/routes.dart';
import '../../../services/key_import_service.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../utils/platform_utils.dart';
import '../../widgets/responsive_scaffold.dart';
import '../../widgets/top_snackbar.dart';
import '../backup/backup_actions.dart';
import '../identity/identity_edit_screen.dart' show InitialImportedKey;
import 'ssh_config_export.dart';
import 'package:zestssh/ui/screens/settings/clear_all_data_dialog.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart' show confirmResetAllSettings, phoneAutoBackupSummary, showPhoneAutoBackupConfig;
import 'package:zestssh/features/cloud_import/ui/cloud_accounts_view.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// Backups and data (4.0, the groups a computer's Settings has): automatic
/// backups (their row was the Settings root's), import, export, the cloud
/// accounts kept in sync, clearing this device's data, and resetting every
/// setting (it was at the end of the Settings root). Reached from the mobile
/// settings root. The import/export/clear helpers are
/// copies of the ones the desktop settings card still uses in
/// settings_screen.dart; the desktop path is untouched.
class DataSettingsScreen extends ConsumerStatefulWidget {
  const DataSettingsScreen({super.key});

  @override
  ConsumerState<DataSettingsScreen> createState() => _DataSettingsScreenState();
}

class _DataSettingsScreenState extends ConsumerState<DataSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ResponsiveScaffold(
      title: l10n.settingsPageBackupsData,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _Section(
            // The page's one section: its name is the page's own.
            title: null,
            child: Column(
              children: [
                // Automatic backups: when, and where they go besides here.
                ListTile(
                  key: const ValueKey('settings-backups'),
                  title: Text(l10n.settingsCatBackups),
                  subtitle: Text(phoneAutoBackupSummary(ref, l10n)),
                  leading: const PhoneIconTile(LucideIcons.archive),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () => showPhoneAutoBackupConfig(context, ref),
                ),
                // Two entry points; each opens a chooser of methods. Both work
                // signed-out (a full .zest backup does not need Cloud Sync).
                ListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsMobImportData, help: l10n.settingsMobImportDataDesc),
                  leading: const PhoneIconTile(LucideIcons.download),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () => _showImportDataSheet(context, ref),
                ),
                ListTile(
                  title: FoldedHelpTitle(setting: l10n.settingsMobExportData, help: l10n.settingsMobExportDataDesc),
                  leading: const PhoneIconTile(LucideIcons.upload),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () => _showExportDataSheet(context, ref),
                ),
                // Cloud accounts kept in sync on this device (3.0).
                const CloudAccountsTiles(tiled: true),
                ListTile(
                  key: const ValueKey('data-clear-all'),
                  title: Text(l10n.settingsClearAllData, style: TextStyle(color: AppColors.error)),
                  subtitle: Text(l10n.settingsClearAllDataDesc),
                  leading: PhoneIconTile(LucideIcons.trash2,
                      color: AppColors.error),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () => _confirmClearAllData(context, ref),
                ),
                // Every setting back to its default; the data stays. It asks
                // first.
                ListTile(
                  key: const ValueKey('settings-reset'),
                  title: Text(l10n.settingsInlineResetAllSettings, style: TextStyle(color: AppColors.error)),
                  leading: PhoneIconTile(LucideIcons.rotateCcw, color: AppColors.error),
                  trailing: const Icon(LucideIcons.chevronRight),
                  onTap: () => confirmResetAllSettings(context, ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Data helpers (copied from settings_screen.dart; desktop keeps its own) ──

  /// Import chooser: every "bring data in" method in one sheet.
  void _showImportDataSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(l10n.settingsMobImportData,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              key: const ValueKey('import-data-file'),
              leading: const PhoneIconTile(LucideIcons.fileUp),
              title: Text(l10n.importFileAction),
              subtitle: Text(l10n.importFileDesc),
              onTap: () {
                Navigator.pop(ctx);
                openImportHosts(context, chooseFile: true);
              },
            ),
            ListTile(
              leading: const PhoneIconTile(LucideIcons.rotateCcw),
              title: Text(l10n.settingsMobRestoreFromBackup),
              subtitle: Text(l10n.settingsMobRestoreFromBackupDesc),
              onTap: () {
                Navigator.pop(ctx);
                runBackupImport(context, ref);
              },
            ),
            ListTile(
              leading: const PhoneIconTile(LucideIcons.fileText),
              title: Text(l10n.settingsMobSshConfigFile),
              subtitle: Text(l10n.settingsMobSshConfigFileDesc),
              onTap: () {
                Navigator.pop(ctx);
                context.push(Routes.sshConfigImport);
              },
            ),
            ListTile(
              leading: const PhoneIconTile(LucideIcons.downloadCloud),
              title: Text(l10n.cloudImpFromCloud),
              subtitle: Text(l10n.cloudImpFromCloudDesc),
              onTap: () {
                Navigator.pop(ctx);
                openImportHosts(context);
              },
            ),
            ListTile(
              key: const ValueKey('import-data-csv'),
              leading: const PhoneIconTile(LucideIcons.table),
              title: Text(l10n.cloudImpCsv),
              subtitle: Text(l10n.cloudImpCsvDesc),
              onTap: () {
                Navigator.pop(ctx);
                openCsvImport(context);
              },
            ),
            ListTile(
              leading: const PhoneIconTile(LucideIcons.keyRound),
              title: Text(l10n.settingsMobPuttyPrivateKey),
              onTap: () {
                Navigator.pop(ctx);
                _importPuttyKey(context, ref);
              },
            ),
            // PuTTY keeps its saved sessions in Windows' registry: offered
            // on Windows alone (a phone listed it and opened a page saying so).
            if (puttyImportHere)
              ListTile(
                key: const ValueKey('import-data-putty'),
                leading: const PhoneIconTile(LucideIcons.terminal),
                title: Text(l10n.settingsMobPuttySessions),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(Routes.puttyImport);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Export chooser: every "take data out" method in one sheet. All local -
  /// no sign-in required.
  void _showExportDataSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(l10n.settingsMobExportData,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const PhoneIconTile(LucideIcons.archive),
              title: Text(l10n.settingsMobFullBackup),
              subtitle: Text(l10n.settingsMobFullBackupDesc),
              onTap: () {
                Navigator.pop(ctx);
                runBackupExport(context, ref);
              },
            ),
            ListTile(
              leading: const PhoneIconTile(LucideIcons.fileUp),
              title: Text(l10n.settingsMobConnectionsAsSshConfig),
              subtitle: Text(l10n.settingsMobConnectionsAsSshConfigDesc),
              onTap: () {
                Navigator.pop(ctx);
                exportSshConfig(context, ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _importPuttyKey(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    // Read + convert the picked .ppk HERE, then hand the editor the finished
    // key. (The old code picked a file, threw it away, and opened a blank
    // identity screen - a dead end on every platform.)
    try {
      final file = result.files.first;
      final String content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        throw const FormatException('Could not read file');
      }

      final importService = KeyImportService();
      if (!importService.isPpkFormat(content)) {
        if (context.mounted) {
          showTopSnackBar(context, l10n.settingsMobNotPuttyKey, isError: true);
        }
        return;
      }
      // A key with a passphrase is imported where the passphrase is asked
      // for; here it is said so (it was refused as not supported).
      if (importService.isEncrypted(content)) {
        if (context.mounted) showTopSnackBar(context, l10n.keyImportHasPassphrase, isError: true);
        return;
      }
      final imported = importService.importPpkKey(content, null);
      if (context.mounted) {
        context.push(
          Routes.identityEdit,
          extra: InitialImportedKey(
            privatePem: imported.privatePem,
            fingerprint: imported.fingerprint,
            keyType: imported.keyType,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showTopSnackBar(
          context,
          KeyImportService.problemSaid(e, l10n),
          isError: true,
          details: '$e',
        );
      }
    }
  }

  Future<void> _confirmClearAllData(BuildContext context, WidgetRef ref) => confirmClearAllData(context, ref);
}

/// Section header matching the app's settings sub-screens (orange bar + label).
class _Section extends StatelessWidget {
  final String? title;
  final Widget child;

  const _Section({required this.title, required this.child});

  // The 3.0 look every phone settings page shares (widgets/settings_section.dart).
  @override
  Widget build(BuildContext context) => SettingsSection(title: title, child: child);
}
