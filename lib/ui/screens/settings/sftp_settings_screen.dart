import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/sftp_pins_provider.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../utils/platform_utils.dart';
import '../../widgets/responsive_scaffold.dart';
import 'widgets/setting_control_tile.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// "24-hour (14:30)" / "12-hour (2:30 PM)": the choice with an example
/// rendered by the format itself (Settings on desktop and mobile).
String sftpTimeFormatLabel(AppLocalizations l10n, SftpTimeFormat format) {
  final name = format == SftpTimeFormat.h12
      ? l10n.settingsSftpTime12h
      : l10n.settingsSftpTime24h;
  return '$name (${format.time(DateTime(2026, 1, 1, 14, 30))})';
}

/// Drill-down screen for the SFTP file browser behaviour. Reached from the
/// mobile settings root (SFTP category row). Mirrors the
/// [NotificationSettingsScreen] pattern: [ResponsiveScaffold] + [ListView]
/// with local [_Section] headers.
class SftpSettingsScreen extends ConsumerWidget {
  const SftpSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return ResponsiveScaffold(
      title: l10n.settingsPageFiles,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _Section(
            // The page's one section: its name is the page's own.
            title: null,
            child: Column(
              children: [
                // SFTP hidden files - ONE 3-level setting for both panes.
                SettingChoiceTile<SftpHiddenLevel>(
                  title: FoldedHelpTitle(setting: l10n.settingsMobHiddenFilesInBrowser, help: l10n.settingsMobHiddenFilesInBrowserDesc),
                  leading: const PhoneIconTile(LucideIcons.eyeOff),
                  value: ref.watch(sftpHiddenLevelProvider),
                  choices: [
                    (SftpHiddenLevel.systemOnly, l10n.settingsMobSystemFilesOnly),
                    (SftpHiddenLevel.hiddenAndSystem, l10n.settingsMobHiddenAndSystem),
                    (SftpHiddenLevel.none, l10n.none),
                  ],
                  onChanged: (v) => ref.read(sftpHiddenLevelProvider.notifier).setLevel(v),
                ),
                SettingChoiceTile<SftpTimeFormat>(
                  title: FoldedHelpTitle(setting: l10n.settingsSftpTimeFormat, help: l10n.settingsSftpTimeFormatDesc),
                  leading: const PhoneIconTile(LucideIcons.clock),
                  value: ref.watch(sftpTimeFormatProvider),
                  choices: [
                    for (final f in SftpTimeFormat.values) (f, sftpTimeFormatLabel(l10n, f)),
                  ],
                  onChanged: (v) => ref.read(sftpTimeFormatProvider.notifier).set(v),
                ),
                // Delete hold - the remote-delete undo window (delete safety
                // spec). Local deletes always go to the OS Recycle Bin; this
                // applies only to remote deletes.
                SettingChoiceTile<int>(
                  title: FoldedHelpTitle(setting: l10n.settingsDeleteHoldLabel, help: l10n.settingsDeleteHoldSubtitle),
                  leading: const PhoneIconTile(LucideIcons.timer),
                  value: ref.watch(sftpDeleteHoldSecondsProvider),
                  choices: [
                    (0, l10n.settingsDeleteHoldOff),
                    for (final s in const [5, 10, 30]) (s, l10n.settingsDeleteHoldSeconds(s)),
                  ],
                  onChanged: (v) => ref.read(sftpDeleteHoldSecondsProvider.notifier).setSeconds(v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
