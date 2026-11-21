import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The pages a phone's Settings opens, for its search (3.0 UI), and what a
/// result opens: a page, or (Backups, General's language, Reset all settings)
/// a row of one that opens its own sheet or question.
enum PhoneSettingsPage {
  account,
  plan,
  security,
  backups,
  language,
  appearance,
  terminal,
  keyboardRow,
  notifications,
  sftp,
  screens,
  automation,
  data,
  about,
  reset;

  /// The name of the page the setting is on, as its row in Settings says it
  /// (the groups of 4.0: a computer's pages' names).
  String nameIn(AppLocalizations l10n) => switch (this) {
        account => l10n.settingsAccount,
        plan => l10n.settingsPagePlan,
        security => l10n.settingsPageSecurityPrivacy,
        backups => l10n.settingsPageBackupsData,
        language => l10n.settingsInlineSectionGeneral,
        appearance => l10n.settingsMobAppearance,
        terminal => l10n.settingsPageTerminalSsh,
        keyboardRow => l10n.settingsPageKeyboardMouse,
        notifications => l10n.settingsNotifications,
        sftp => l10n.settingsPageFiles,
        screens => l10n.settingsScreensSection,
        automation => l10n.settingsMobAutomation,
        data => l10n.settingsPageBackupsData,
        about => l10n.settingsAbout,
        reset => l10n.settingsInlineResetAllSettings,
      };

  /// The icon of the page's row in Settings.
  IconData get icon => switch (this) {
        account => LucideIcons.userCircle,
        plan => LucideIcons.crown,
        security => LucideIcons.shieldCheck,
        backups => LucideIcons.archive,
        language => LucideIcons.languages,
        appearance => LucideIcons.palette,
        terminal => LucideIcons.terminal,
        keyboardRow => LucideIcons.keyboard,
        notifications => LucideIcons.bell,
        sftp => LucideIcons.folderOpen,
        screens => LucideIcons.monitor,
        automation => LucideIcons.play,
        data => LucideIcons.archive,
        about => LucideIcons.info,
        reset => LucideIcons.rotateCcw,
      };
}

/// One setting a phone's Settings can find: the page it is on, its name, and
/// what the page says about it, each in the language on screen.
class PhoneSetting {
  const PhoneSetting(this.page, this.name, [this.about]);

  final PhoneSettingsPage page;
  final String Function(AppLocalizations) name;
  final String Function(AppLocalizations)? about;
}

typedef _P = PhoneSettingsPage;

/// Every setting the phone's settings pages show, by page. A setting added to
/// one of those pages goes here too: test/ui/phone_settings_search_test.dart
/// fails otherwise.
final List<PhoneSetting> kPhoneSettingsIndex = [
  PhoneSetting(_P.account, (l) => l.settingsAccount, (l) => l.settingsPageAccountDesc),
  PhoneSetting(_P.plan, (l) => l.settingsPagePlan, (l) => l.settingsPagePlanDesc),

  PhoneSetting(_P.security, (l) => l.settingsPageSecurityPrivacy, (l) => l.settingsPageSecurityPrivacyDesc),
  PhoneSetting(_P.security, (l) => l.secSetAppLock, (l) => l.secSetAppLockSubtitle),
  PhoneSetting(_P.security, (l) => l.secSetChangePin, (l) => l.secSetChangePinSubtitle),
  PhoneSetting(_P.security, (l) => l.secSetIdleLock, (l) => l.secSetIdleLockDesc),
  PhoneSetting(_P.security, (l) => l.secSetLockShowSessions, (l) => l.secSetLockShowSessionsDesc),
  PhoneSetting(_P.security, (l) => l.secSetEncryptAtRest, (l) => l.secSetEncryptAtRestSubtitle),
  PhoneSetting(_P.security, (l) => l.secSetHwEncryption),
  PhoneSetting(_P.security, (l) => l.secSetTrustedHostKeys, (l) => l.secSetTrustedHostKeysSubtitle),
  PhoneSetting(_P.security, (l) => l.secSetAskBeforeTrusting, (l) => l.secSetAskBeforeTrustingSubtitle),
  PhoneSetting(_P.security, (l) => l.secSetClearAllKeys, (l) => l.secSetClearAllKeysSubtitle),
  PhoneSetting(_P.security, (l) => l.settingsInlineDangerousCommandProtection, (l) => l.settingsDangerousCommandDesc),
  PhoneSetting(_P.security, (l) => l.recModeName, (l) => l.recModeTooltipOff),
  PhoneSetting(_P.security, (l) => l.recModeLevelLabel, (l) => l.recModeLevelStrictDesc),

  PhoneSetting(_P.backups, (l) => l.settingsCatBackups, (l) => l.settingsMobAutoBackupSheetDesc),
  PhoneSetting(_P.language, (l) => l.settingsLanguage, (l) => l.settingsLanguageSubtitle),
  PhoneSetting(_P.language, (l) => l.largeLayoutLabel, (l) => l.largeLayoutDesc),

  PhoneSetting(_P.appearance, (l) => l.settingsMobAppearance, (l) => l.settingsMobAppearanceDesc),
  PhoneSetting(_P.appearance, (l) => l.appearanceApplyThemeToEntireApp, (l) => l.appearanceApplyThemeToEntireAppSubtitle),
  // The terminal's theme is found once, on the Terminal page, whose row of
  // that name opens every terminal theme; Appearance's grid of them (under
  // "Terminal-only themes" while one theme is the whole app's) is not a
  // second row of the search (it listed "Terminal theme" twice: found on a
  // Pixel 3a, as the font's rows below).
  // The terminal's font and its size are the Terminal page's alone, found
  // there once each; Appearance's row for them opens that page (the
  // search listed "Terminal font" and "Font").
  PhoneSetting(_P.appearance, (l) => l.appearanceFollowSystemTheme, (l) => l.appearanceFollowSystemThemeSubtitle),

  PhoneSetting(_P.terminal, (l) => l.settingsPageTerminalSsh, (l) => l.settingsPageTerminalSshDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsTerminalTheme),
  PhoneSetting(_P.terminal, (l) => l.settingsFont),
  PhoneSetting(_P.terminal, (l) => l.settingsFontSize),
  PhoneSetting(_P.terminal, (l) => l.settingsScrollbackLines),
  PhoneSetting(_P.terminal, (l) => l.settingsCursorBlink, (l) => l.settingsCursorBlinkDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsMobCursorShape),
  PhoneSetting(_P.terminal, (l) => l.settingsCursorVisibility, (l) => l.settingsCursorVisibilityDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsMobProgrammingLigatures, (l) => l.settingsMobProgrammingLigaturesDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsTerminalMargin),
  PhoneSetting(_P.terminal, (l) => l.settingsHapticFeedback, (l) => l.settingsHapticFeedbackDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsInlineTerminalBell),
  PhoneSetting(_P.terminal, (l) => l.settingsKeepAwake, (l) => l.settingsKeepAwakeDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsAutoExecuteSnippets, (l) => l.settingsAutoExecuteSnippetsDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsTmuxAutoDetect, (l) => l.settingsTmuxAutoDetectDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsOsc52Clipboard, (l) => l.settingsOsc52ClipboardDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsDefaultSnippetCategory),
  PhoneSetting(_P.terminal, (l) => l.transcriptsTitle, (l) => l.transcriptsSettingsDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsKeepaliveInterval),
  PhoneSetting(_P.terminal, (l) => l.settingsSessionLogEnabled, (l) => l.settingsSessionLogEnabledDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsSessionLogTimestamps, (l) => l.settingsSessionLogTimestampsDesc),
  PhoneSetting(_P.terminal, (l) => l.settingsSessionLogBrowse, (l) => l.settingsSessionLogBrowseDesc),

  PhoneSetting(_P.keyboardRow, (l) => l.settingsPageKeyboardMouse, (l) => l.settingsPageKeyboardMousePhoneDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsExtraKeyboardRow, (l) => l.settingsExtraKeyboardRowDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsKeyboardRowPosition),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsAboveKeyboard, (l) => l.settingsAboveKeyboardDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsAboveTerminal, (l) => l.settingsAboveTerminalDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.hwKeysRowWhen),
  PhoneSetting(_P.keyboardRow, (l) => l.hwKeysRowAuto, (l) => l.hwKeysRowAutoDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.hwKeysRowAlways, (l) => l.hwKeysRowAlwaysDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.hwKeysRowMissing, (l) => l.hwKeysRowMissingDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsMobScrollableKeyRow, (l) => l.settingsMobScrollableKeyRowDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.keysRowStyle),
  PhoneSetting(_P.keyboardRow, (l) => l.keysRowStyleGrouped, (l) => l.keysRowStyleGroupedDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.keysRowStyleFlat, (l) => l.keysRowStyleFlatDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.keysRowSize),
  PhoneSetting(_P.keyboardRow, (l) => l.keysRowSizeSmall),
  PhoneSetting(_P.keyboardRow, (l) => l.keysRowSizeMedium),
  PhoneSetting(_P.keyboardRow, (l) => l.keysRowSizeLarge),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsMobCustomizeKeys, (l) => l.settingsMobCustomizeKeysDesc),
  // A hardware keyboard and a mouse (4.0: they were the Terminal page's).
  PhoneSetting(_P.keyboardRow, (l) => l.settingsVolumeKeyShortcuts, (l) => l.settingsVolumeKeyShortcutsDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsKeyboardIncognito, (l) => l.settingsKeyboardIncognitoDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsCompactKeyboard, (l) => l.settingsCompactKeyboardDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.hwKeysOptionMeta, (l) => l.hwKeysOptionMetaDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsInlineRightClickPaste, (l) => l.hwKeysRightClickDesc),
  PhoneSetting(_P.keyboardRow, (l) => l.settingsInlineMiddleClickPaste, (l) => l.hwKeysMiddleClickDesc),

  PhoneSetting(_P.notifications, (l) => l.settingsNotifications, (l) => l.settingsLinkNotificationsHelp),
  PhoneSetting(_P.notifications, (l) => l.notificationsResourceAlerts, (l) => l.notificationsResourceAlertsDesc),
  PhoneSetting(_P.notifications, (l) => l.settingsServerHealthChecks, (l) => l.settingsServerHealthChecksDesc),
  PhoneSetting(_P.notifications, (l) => l.settingsConnectionLost, (l) => l.settingsConnectionLostDesc),
  PhoneSetting(_P.notifications, (l) => l.notifPrefsSecurityAlerts, (l) => l.notifPrefsSecurityAlertsDesc),

  PhoneSetting(_P.sftp, (l) => l.settingsPageFiles, (l) => l.settingsMobSftpRowDesc),
  PhoneSetting(_P.sftp, (l) => l.settingsMobHiddenFilesInBrowser, (l) => l.settingsMobHiddenFilesInBrowserDesc),
  PhoneSetting(_P.sftp, (l) => l.settingsSftpTimeFormat, (l) => l.settingsSftpTimeFormatDesc),
  PhoneSetting(_P.sftp, (l) => l.settingsDeleteHoldLabel, (l) => l.settingsDeleteHoldSubtitle),
  PhoneSetting(_P.screens, (l) => l.settingsScreensSection, (l) => l.settingsScreensRowDesc),
  PhoneSetting(_P.screens, (l) => l.settingsScreenTouchDefault, (l) => l.settingsScreenTouchDefaultDesc),
  PhoneSetting(_P.screens, (l) => l.settingsScreenScalingDefault, (l) => l.settingsScreenScalingDefaultDesc),
  PhoneSetting(_P.screens, (l) => l.settingsScreenRecording, (l) => l.settingsScreenRecordingDesc),
  PhoneSetting(_P.screens, (l) => l.settingsScreenClipboardDefault, (l) => l.settingsScreenClipboardDefaultDesc),

  PhoneSetting(_P.automation, (l) => l.settingsMobAutomation, (l) => l.utilitiesAutomationDesc),
  PhoneSetting(_P.automation, (l) => l.settingsMobExternalAutomation, (l) => l.settingsMobExternalAutomationDesc),
  PhoneSetting(_P.automation, (l) => l.settingsMobWorkflows, (l) => l.settingsMobWorkflowsDesc),
  PhoneSetting(_P.automation, (l) => l.settingsMobScheduledTasks, (l) => l.settingsMobScheduledTasksDesc),
  PhoneSetting(_P.automation, (l) => l.settingsMobAutomationWizard, (l) => l.settingsMobAutomationWizardDesc),
  PhoneSetting(_P.automation, (l) => l.settingsMobAutomationHistory, (l) => l.settingsMobAutomationHistoryDesc),
  PhoneSetting(_P.automation, (l) => l.settingsMobAutomationGuide, (l) => l.settingsMobAutomationGuideDesc),
  PhoneSetting(_P.automation, (l) => l.settingsMobApiKeys),

  PhoneSetting(_P.data, (l) => l.settingsPageBackupsData, (l) => l.settingsPageBackupsDataDesc),
  PhoneSetting(_P.data, (l) => l.settingsMobImportData, (l) => l.settingsMobImportDataDesc),
  PhoneSetting(_P.data, (l) => l.settingsMobExportData, (l) => l.settingsMobExportDataDesc),
  PhoneSetting(_P.data, (l) => l.cloudAccTitle),
  PhoneSetting(_P.data, (l) => l.settingsClearAllData, (l) => l.settingsClearAllDataDesc),

  PhoneSetting(_P.about, (l) => l.settingsAbout),
  PhoneSetting(_P.reset, (l) => l.settingsInlineResetAllSettings, (l) => l.settingsResetAllHelp),
];

/// The settings whose name, page or words hold every word of [query], in the
/// language on screen; names that hold the words come first.
List<PhoneSetting> searchPhoneSettings(String query, AppLocalizations l10n) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final named = <PhoneSetting>[];
  final described = <PhoneSetting>[];
  for (final s in kPhoneSettingsIndex) {
    final name = '${s.name(l10n)} ${s.page.nameIn(l10n)}'.toLowerCase();
    final all = '$name ${s.about?.call(l10n) ?? ''}'.toLowerCase();
    if (words.every(name.contains)) {
      named.add(s);
    } else if (words.every(all.contains)) {
      described.add(s);
    }
  }
  return [...named, ...described];
}
