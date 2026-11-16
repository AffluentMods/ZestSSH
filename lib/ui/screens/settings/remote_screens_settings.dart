import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/model/screen_options.dart' show ScreenScaling;
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart' show ScreenTouchMode;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/screens/settings/widgets/setting_control_tile.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

/// A phone's Settings, Remote screens (4.0): how a finger drives a screen
/// when it opens (a host switched from its bar keeps its own), the scaling a
/// new screen is saved with, what recording mode does to the picture, and
/// whether a screen of one's own space shares the clipboard by default. A
/// computer's Settings has the same rows, and the screen menu's key, in its
/// own Remote screens section.
class RemoteScreensSettingsScreen extends ConsumerWidget {
  const RemoteScreensSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ResponsiveScaffold(
      title: l10n.settingsScreensSection,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          SettingsSection(
            title: null,
            child: Column(
              children: [
                SettingChoiceTile<ScreenTouchMode>(
                  key: const ValueKey('screen-settings-touch'),
                  title: FoldedHelpTitle(setting: l10n.settingsScreenTouchDefault, help: l10n.settingsScreenTouchDefaultDesc),
                  leading: const PhoneIconTile(LucideIcons.pointer),
                  value: ref.watch(screenTouchDefaultProvider),
                  choices: [for (final m in ScreenTouchMode.values) (m, screenTouchModeNameIn(l10n, m))],
                  onChanged: (v) => ref.read(screenTouchDefaultProvider.notifier).set(v),
                ),
                SettingChoiceTile<ScreenScaling>(
                  key: const ValueKey('screen-settings-scaling'),
                  title: FoldedHelpTitle(setting: l10n.settingsScreenScalingDefault, help: l10n.settingsScreenScalingDefaultDesc),
                  leading: const PhoneIconTile(LucideIcons.maximize2),
                  value: ref.watch(screenScalingDefaultProvider),
                  choices: [for (final s in ScreenScaling.values) (s, screenScalingNameIn(l10n, s))],
                  onChanged: (v) => ref.read(screenScalingDefaultProvider.notifier).set(v),
                ),
                SettingChoiceTile<ScreenRecordingBehaviour>(
                  key: const ValueKey('screen-settings-recording'),
                  title: FoldedHelpTitle(setting: l10n.settingsScreenRecording, help: l10n.settingsScreenRecordingDesc),
                  leading: const PhoneIconTile(LucideIcons.eyeOff),
                  value: ref.watch(screenRecordingBehaviourProvider),
                  choices: [for (final b in ScreenRecordingBehaviour.values) (b, b.nameIn(l10n))],
                  onChanged: (v) => ref.read(screenRecordingBehaviourProvider.notifier).set(v),
                ),
                SwitchListTile(
                  key: const ValueKey('screen-settings-clipboard'),
                  secondary: const PhoneIconTile(LucideIcons.clipboard),
                  title: FoldedHelpTitle(setting: l10n.settingsScreenClipboardDefault, help: l10n.settingsScreenClipboardDefaultDesc),
                  value: ref.watch(screenClipboardDefaultProvider),
                  onChanged: (v) => ref.read(screenClipboardDefaultProvider.notifier).set(v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
