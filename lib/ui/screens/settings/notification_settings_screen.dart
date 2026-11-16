import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_providers.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../theme/zest_tokens.dart';
import '../../../utils/platform_utils.dart';
import '../../widgets/responsive_scaffold.dart';
import 'reachability_checks_setting.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// Dedicated notification settings screen (Design: mobile notifications, Step
/// 5). One destination with two doors: reached from the Settings tab and from
/// the notifications overflow.
///
/// The switches of what a phone tells of (each reads and writes the settings
/// the rest of the app uses, and sync carries them): a server's resources and
/// whether it can be reached, a session's connection lost, and security alerts
/// (a key's certificate running out; on a computer a server's host key
/// changed too). (3.0, 16 October 2026: security alerts had no switch on a
/// phone, nor did sync carry a computer's, so a phone told of every
/// certificate always; and "Transfer complete" was here, which a phone tells
/// of on the screen of the transfer itself, so it changed nothing here.)
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);

    return ResponsiveScaffold(
      // Named as the row that opens it (Settings' Notifications).
      title: l10n.settingsNotifications,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _Section(
            title: l10n.notificationsSettingsServerMonitor,
            child: Column(
              children: [
                SwitchListTile(
                  title: FoldedHelpTitle(setting: l10n.notificationsResourceAlerts, help: l10n.notificationsResourceAlertsDesc),
                  secondary: const PhoneIconTile(LucideIcons.bellRing),
                  value: ref.watch(monitorAlertsEnabledProvider),
                  onChanged: (v) => updater.setMonitorAlertsEnabled(v),
                ),
                SwitchListTile(
                  key: const ValueKey('settings-reach-checks'),
                  title: FoldedHelpTitle(setting: l10n.settingsServerHealthChecks, help: l10n.settingsServerHealthChecksDesc),
                  secondary: const PhoneIconTile(LucideIcons.activity),
                  value: ref.watch(healthChecksEnabledProvider),
                  onChanged: (v) => setReachabilityChecks(context, ref, v),
                ),
                // How often, under the switch it belongs to: indented to its
                // words, its value at the end with a chevron (it read as a
                // row of words with no control).
                if (ref.watch(healthChecksEnabledProvider))
                  ListTile(
                    key: const ValueKey('settings-reach-interval'),
                    leading: const SizedBox(width: 36),
                    title: Text(l10n.settingsInlineCheckInterval),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          reachabilityCheckIntervalLabel(l10n, ref.watch(healthCheckIntervalProvider)),
                          style: TextStyle(fontSize: 14, color: ZestTokens.textSecondary),
                        ),
                        const SizedBox(width: 4),
                        const Icon(LucideIcons.chevronRight, size: 18),
                      ],
                    ),
                    onTap: () => showReachabilityIntervalPicker(context, ref),
                  ),
              ],
            ),
          ),
          _Section(
            title: l10n.notificationsSettingsSessions,
            child: SwitchListTile(
              title: FoldedHelpTitle(setting: l10n.settingsConnectionLost, help: l10n.settingsConnectionLostDesc),
              secondary: const PhoneIconTile(LucideIcons.wifiOff),
              value: ref.watch(notifyConnectionLostProvider),
              onChanged: (v) => updater.setNotifyConnectionLost(v),
            ),
          ),
          _Section(
            title: l10n.settingsSecurity,
            child: SwitchListTile(
              key: const ValueKey('settings-security-alerts'),
              title: FoldedHelpTitle(setting: l10n.notifPrefsSecurityAlerts, help: l10n.notifPrefsSecurityAlertsDesc),
              secondary: const PhoneIconTile(LucideIcons.shield),
              value: ref.watch(notifySecurityAlertsProvider),
              onChanged: (v) => updater.setNotifySecurityAlerts(v),
            ),
          ),
        ],
      ),
    );
  }

}

/// Section header matching the app's settings sub-screens (orange bar + label).
class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  // The 3.0 look every phone settings page shares (widgets/settings_section.dart).
  @override
  Widget build(BuildContext context) => SettingsSection(title: title, child: child);
}
