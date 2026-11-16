import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/clear_all_data.dart';
import 'package:zestssh/services/sync/sync_disconnect.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Settings > Data > Clear all data, on a phone's Data page and in a
/// computer's settings: asks, with "DELETE" typed, then clears this device's
/// data ([clearAllDataOnThisDevice]). With sync set up here the question says
/// that it clears this device only and turns sync off on it, and it does.
Future<void> confirmClearAllData(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final syncOn = await ref.read(autoSyncServiceProvider).setUpHere();
  if (!context.mounted) return;
  final controller = TextEditingController();
  bool typed(TextEditingValue v) => v.text.trim().toUpperCase() == 'DELETE';
  // The shell: red for what deletes, the red main button in the footer, on
  // only once DELETE is typed (it was a plain dialog whose button did nothing
  // until then).
  final confirmed = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (ctx) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (ctx, value, _) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.destructive,
          icon: LucideIcons.trash2,
          title: l10n.settingsClearAllDataConfirmTitle,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.settingsClearAllDataConfirmMsg,
                style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
              ),
              if (syncOn) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.settingsClearAllDataSyncOn,
                  key: const ValueKey('clear-all-data-sync-on'),
                  style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
                ),
              ],
              const SizedBox(height: 14),
              ZestTextField(
                key: const ValueKey('clear-all-data-type'),
                controller: controller,
                label: l10n.settingsTypeDeleteToConfirm,
                hintText: 'DELETE',
                selectOnFocus: ZestFieldSelect.end,
                onSubmit: () {
                  if (typed(controller.value)) Navigator.pop(ctx, true);
                },
              ),
            ],
          ),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(ctx, false)),
          primaryKey: const ValueKey('clear-all-data-go'),
          primaryAction: (
            label: l10n.settingsClearAllData,
            icon: null,
            onPressed: typed(value) ? () => Navigator.pop(ctx, true) : null,
          ),
        ),
      ),
    ),
  );

  if (confirmed == true && context.mounted) {
    await clearAllDataOnThisDevice(
      tree: ref.read(treeDatabaseProvider),
      secureStorage: ref.read(secureStorageProvider),
      // Every Orchard's copy here: the Orchard itself stays in its Crates for
      // the team (clearing through the Orchard on screen would delete it for
      // everyone).
      forgetOrchards: () => ref.read(orchardDatabasesProvider.notifier).forgetAll(),
      turnSyncOff: syncOn
          ? () async {
              await disconnectSyncOnThisDevice(
                autoSync: ref.read(autoSyncServiceProvider),
                setup: ref.read(syncSetupStateServiceProvider),
                settings: ref.read(settingsServiceProvider),
                secureStorage: ref.read(secureStorageProvider),
                lockVault: ref.read(vaultSessionProvider.notifier).lock,
              );
              ref.read(syncStatusProvider.notifier).clear();
            }
          : null,
    );
    if (context.mounted) {
      showTopSnackBar(
        context,
        l10n.settingsAllDataCleared,
        isSuccess: true,
      );
    }
  }
}
