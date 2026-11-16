import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/reachability_checks_setting.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Control over what reaches the notification panel, opened from the gear in
/// the notification header and from Settings > Notifications. It is the
/// single source of truth for the notification toggles, so both entry points
/// show the same full set: the app's dialog (3.4), a phone's sheet, with the
/// switches, which take effect at once, and Done in the footer. (A phone's
/// was a sheet of its own, with no Done.)
void showNotificationPrefsSheet(BuildContext context) {
  showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (ctx) {
        final l10n = AppLocalizations.of(ctx)!;
        return ZestDialogShell(
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.bell,
          title: l10n.notifPrefsTitle,
          subtitle: l10n.notifPrefsSubtitle,
          maxWidth: 480,
          maxHeight: 640,
          body: const _NotificationPrefsBody(),
          primaryKey: const ValueKey('notif-prefs-done'),
          primaryAction: (label: l10n.done, icon: null, onPressed: () => Navigator.of(ctx).pop()),
        );
      },
    ),
  );
}

class _NotificationPrefsBody extends ConsumerWidget {
  const _NotificationPrefsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);

    final tiles = <Widget>[
      SwitchListTile(
        dense: true,
        secondary: const Icon(LucideIcons.bellRing),
        title: Text(l10n.notifPrefsMonitorAlerts),
        subtitle: Text(l10n.notifPrefsMonitorAlertsDesc),
        value: ref.watch(monitorAlertsEnabledProvider),
        onChanged: (v) => updater.setMonitorAlertsEnabled(v),
      ),
      SwitchListTile(
        dense: true,
        secondary: const Icon(LucideIcons.wifiOff),
        title: Text(l10n.notifPrefsConnectionLost),
        subtitle: Text(l10n.notifPrefsConnectionLostDesc),
        value: ref.watch(notifyConnectionLostProvider),
        onChanged: (v) => updater.setNotifyConnectionLost(v),
      ),
      SwitchListTile(
        dense: true,
        secondary: const Icon(LucideIcons.cloud),
        title: Text(l10n.notifPrefsTransferComplete),
        subtitle: Text(l10n.notifPrefsTransferCompleteDesc),
        value: ref.watch(notifyTransferCompleteProvider),
        onChanged: (v) => updater.setNotifyTransferComplete(v),
      ),
      SwitchListTile(
        dense: true,
        secondary: const Icon(LucideIcons.alertCircle),
        title: Text(l10n.notifPrefsTransferFailed),
        subtitle: Text(l10n.notifPrefsTransferFailedDesc),
        value: ref.watch(notifyTransferFailedProvider),
        onChanged: (v) => updater.setNotifyTransferFailed(v),
      ),
      SwitchListTile(
        dense: true,
        secondary: const Icon(LucideIcons.shield),
        title: Text(l10n.notifPrefsSecurityAlerts),
        subtitle: Text(l10n.notifPrefsSecurityAlertsDesc),
        value: ref.watch(notifySecurityAlertsProvider),
        onChanged: (v) => updater.setNotifySecurityAlerts(v),
      ),
      SwitchListTile(
        key: const ValueKey('settings-reach-checks'),
        dense: true,
        secondary: const Icon(LucideIcons.activity),
        title: Text(l10n.notifPrefsServerHealthChecks),
        subtitle: Text(l10n.notifPrefsServerHealthChecksDesc),
        value: ref.watch(healthChecksEnabledProvider),
        onChanged: (v) => setReachabilityChecks(context, ref, v),
      ),
      SwitchListTile(
        dense: true,
        secondary: const Icon(LucideIcons.download),
        title: Text(l10n.notifPrefsUpdateAvailable),
        subtitle: Text(l10n.notifPrefsUpdateAvailableDesc),
        value: ref.watch(notifyUpdateAvailableProvider),
        onChanged: (v) => updater.setNotifyUpdateAvailable(v),
      ),
    ];

    // The shell is its header, and it scrolls as one.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: tiles,
    );
  }
}
