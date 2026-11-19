import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The names of the keyboard shortcuts, in the app's language.
///
/// [ShortcutAction.label], [ShortcutAction.description] and
/// [ShortcutCategory.label] are the English they were written in; they were
/// what every language saw. Whatever shows a shortcut to a person asks here.

/// What [action] is called.
String shortcutName(AppLocalizations l, ShortcutAction action) => switch (action) {
      ShortcutAction.commandPalette => l.shortcutNameCommandPalette,
      ShortcutAction.quickConnect => l.shortcutNameQuickConnect,
      ShortcutAction.newConnection => l.hostsNewHost,
      ShortcutAction.settings => l.shortcutNameSettings,
      ShortcutAction.toggleFullscreen => l.shortcutNameToggleFullscreen,
      ShortcutAction.supportHub => l.shortcutNameSupportHub,
      ShortcutAction.lockApp => l.shortcutNameLockApp,
      ShortcutAction.closeTab => l.shortcutNameCloseTab,
      ShortcutAction.reopenLastTab => l.shortcutNameReopenLastTab,
      ShortcutAction.nextTab => l.shortcutNameNextTab,
      ShortcutAction.previousTab => l.shortcutNamePreviousTab,
      ShortcutAction.toggleSidebar => l.shortcutNameToggleSidebar,
      ShortcutAction.toggleHostPanel => l.shortcutNameToggleHostPanel,
      ShortcutAction.splitRight => l.shortcutNameSplitRight,
      ShortcutAction.splitDown => l.shortcutNameSplitDown,
      ShortcutAction.closeSplit => l.shortcutNameCloseSplit,
      ShortcutAction.maximizePane => l.shortcutNameMaximizePane,
      ShortcutAction.findInTerminal => l.shortcutNameFindInTerminal,
      ShortcutAction.copySelection => l.shortcutNameCopySelection,
      ShortcutAction.paste => l.shortcutNamePaste,
      ShortcutAction.zoomIn => l.shortcutNameZoomIn,
      ShortcutAction.zoomOut => l.shortcutNameZoomOut,
      ShortcutAction.resetZoom => l.shortcutNameResetZoom,
      ShortcutAction.openTmux => l.shortcutNameOpenTmux,
      ShortcutAction.dictate => l.terminalSpeechToText,
      ShortcutAction.toggleSftpPanel => l.shortcutNameToggleSftpPanel,
      ShortcutAction.toggleSessionInfo => l.shortcutNameToggleSessionInfo,
      ShortcutAction.toggleBroadcast => l.shortcutNameToggleBroadcast,
      ShortcutAction.toggleRecordingMode => l.shortcutNameToggleRecordingMode,
      ShortcutAction.screenDisplay1 ||
      ShortcutAction.screenDisplay2 ||
      ShortcutAction.screenDisplay3 ||
      ShortcutAction.screenDisplay4 =>
        l.shortcutNameScreenDisplay(action.screenDisplayIndex! + 1),
    };

/// What [action] does, in a line.
String shortcutHelp(AppLocalizations l, ShortcutAction action) => switch (action) {
      ShortcutAction.commandPalette => l.shortcutHelpCommandPalette,
      ShortcutAction.quickConnect => l.shortcutHelpQuickConnect,
      ShortcutAction.newConnection => l.shortcutHelpNewConnection,
      ShortcutAction.settings => l.shortcutHelpSettings,
      ShortcutAction.toggleFullscreen => l.shortcutHelpToggleFullscreen,
      ShortcutAction.supportHub => l.shortcutHelpSupportHub,
      ShortcutAction.lockApp => l.shortcutHelpLockApp,
      ShortcutAction.closeTab => l.shortcutHelpCloseTab,
      ShortcutAction.reopenLastTab => l.shortcutHelpReopenLastTab,
      ShortcutAction.nextTab => l.shortcutHelpNextTab,
      ShortcutAction.previousTab => l.shortcutHelpPreviousTab,
      ShortcutAction.toggleSidebar => l.shortcutHelpToggleSidebar,
      ShortcutAction.toggleHostPanel => l.shortcutHelpToggleHostPanel,
      ShortcutAction.splitRight => l.shortcutHelpSplitRight,
      ShortcutAction.splitDown => l.shortcutHelpSplitDown,
      ShortcutAction.closeSplit => l.shortcutHelpCloseSplit,
      ShortcutAction.maximizePane => l.shortcutHelpMaximizePane,
      ShortcutAction.findInTerminal => l.shortcutHelpFindInTerminal,
      ShortcutAction.copySelection => l.shortcutHelpCopySelection,
      ShortcutAction.paste => l.shortcutHelpPaste,
      ShortcutAction.zoomIn => l.shortcutHelpZoomIn,
      ShortcutAction.zoomOut => l.shortcutHelpZoomOut,
      ShortcutAction.resetZoom => l.shortcutHelpResetZoom,
      ShortcutAction.openTmux => l.shortcutHelpOpenTmux,
      ShortcutAction.dictate => l.shortcutHelpDictate,
      ShortcutAction.toggleSftpPanel => l.shortcutHelpToggleSftpPanel,
      ShortcutAction.toggleSessionInfo => l.shortcutHelpToggleSessionInfo,
      ShortcutAction.toggleBroadcast => l.shortcutHelpToggleBroadcast,
      ShortcutAction.toggleRecordingMode => l.shortcutHelpToggleRecordingMode,
      ShortcutAction.screenDisplay1 ||
      ShortcutAction.screenDisplay2 ||
      ShortcutAction.screenDisplay3 ||
      ShortcutAction.screenDisplay4 =>
        l.shortcutHelpScreenDisplay(action.screenDisplayIndex! + 1),
    };

/// What the group [category] is called.
String shortcutCategoryName(AppLocalizations l, ShortcutCategory category) => switch (category) {
      ShortcutCategory.general => l.shortcutCategoryGeneral,
      ShortcutCategory.tabs => l.shortcutCategoryTabs,
      ShortcutCategory.layout => l.shortcutCategoryLayout,
      ShortcutCategory.terminal => l.shortcutCategoryTerminal,
      ShortcutCategory.misc => l.shortcutCategoryMisc,
      ShortcutCategory.screens => l.shortcutCategoryScreens,
    };
