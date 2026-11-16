import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_tool_setup.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

// Settings, Password managers (3.0), on a desktop: where each tool
// is (found, or set here when it is somewhere else), KeePassXC's database,
// and forgetting what unlocked Bitwarden or KeePassXC right now. None of it
// is secret or synced.

class PasswordManagerSettingsPanel extends ConsumerWidget {
  const PasswordManagerSettingsPanel({super.key});

  Future<String?> _pickFile(String title, {List<String>? extensions}) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: title,
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
      withData: false,
    );
    return picked?.files.single.path;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final managers = ref.watch(passwordManagersProvider);
    if (managers == null) return const SizedBox.shrink();
    final settings = ref.watch(passwordManagerSettingsProvider);
    final notifier = ref.read(passwordManagerSettingsProvider.notifier);
    final kpx = settings.keePassXc;
    final small = TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary);

    // Each tool as the places that need it show it (set up in place,
    // Settings using the same pieces): where it is,
    // with Choose and Find it to change it, or what to do when it is not
    // there.
    Widget toolRow(PasswordManagerKind kind) {
      return Padding(
        key: ValueKey('pm-settings-${kind.code}'),
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(passwordManagerName(kind),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
              ),
            ),
            Expanded(child: PasswordManagerToolSetup(kind: kind, manage: true, withDatabase: false)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.pmSettingsIntro, style: small),
        const SizedBox(height: 12),
        for (final kind in PasswordManagerKind.values) toolRow(kind),
        const SizedBox(height: 6),
        Text(l10n.pmSettingsKeePassXcDatabase,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                kpx?.path ?? l10n.pmSettingsNoDatabase,
                key: const ValueKey('pm-settings-kpx-path'),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontFamily: kpx == null ? null : 'JetBrainsMono', color: AppColors.v3TextSecondary),
              ),
            ),
            TextButton(
              key: const ValueKey('pm-settings-kpx-choose'),
              onPressed: () async {
                final picked = await _pickFile(l10n.pmSettingsChooseDatabase, extensions: const ['kdbx']);
                if (picked != null) {
                  await notifier.setKeePassXc(
                      KeePassXcDatabase(path: picked, keyFile: kpx?.keyFile, noPassword: kpx?.noPassword ?? false));
                }
              },
              child: Text(l10n.pmSettingsChoose),
            ),
            if (kpx != null)
              TextButton(
                key: const ValueKey('pm-settings-kpx-remove'),
                onPressed: () => unawaited(notifier.setKeePassXc(null)),
                child: Text(l10n.pmSettingsRemove),
              ),
          ],
        ),
        if (kpx != null) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  kpx.keyFile == null ? l10n.pmSettingsNoKeyFile : l10n.pmSettingsKeyFile(kpx.keyFile!),
                  key: const ValueKey('pm-settings-kpx-keyfile'),
                  overflow: TextOverflow.ellipsis,
                  style: small,
                ),
              ),
              TextButton(
                onPressed: () async {
                  final picked = await _pickFile(l10n.pmSettingsChooseKeyFile);
                  if (picked != null) {
                    await notifier.setKeePassXc(KeePassXcDatabase(path: kpx.path, keyFile: picked, noPassword: kpx.noPassword));
                  }
                },
                child: Text(l10n.pmSettingsChoose),
              ),
              if (kpx.keyFile != null)
                TextButton(
                  onPressed: () =>
                      unawaited(notifier.setKeePassXc(KeePassXcDatabase(path: kpx.path, noPassword: false))),
                  child: Text(l10n.pmSettingsRemove),
                ),
            ],
          ),
          if (kpx.keyFile != null)
            SwitchListTile(
              key: const ValueKey('pm-settings-kpx-nopassword'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: kpx.noPassword,
              title: Text(l10n.pmSettingsKeyFileOnly, style: const TextStyle(fontSize: 12.5)),
              onChanged: (v) =>
                  unawaited(notifier.setKeePassXc(KeePassXcDatabase(path: kpx.path, keyFile: kpx.keyFile, noPassword: v))),
            ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: Text(l10n.pmSettingsForgetHelp, style: small)),
            OutlinedButton.icon(
              key: const ValueKey('pm-settings-forget'),
              onPressed: () {
                managers.lock();
                showTopSnackBar(context, l10n.pmSettingsForgotten, isSuccess: true);
              },
              icon: const Icon(LucideIcons.lock, size: 14),
              label: Text(l10n.pmSettingsForget),
            ),
          ],
        ),
        if (Platform.isWindows) ...[
          const SizedBox(height: 8),
          Text(l10n.pmSettingsWindowsExeOnly, style: small),
        ],
      ],
    );
  }
}
