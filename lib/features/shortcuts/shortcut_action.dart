/// All user-rebindable shortcut actions.
///
/// Adding a new entry here is a 3-step process:
///   1. Add the enum value + label / description / category
///   2. Add a default binding in `defaultShortcutBindings`
///   3. Update the call-site in `desktop_shell.dart` to dispatch
///      via `ref.read(shortcutDispatcherProvider).matches(event, X)`
///
/// We deliberately don't try to make EVERY internal key-event handler
/// rebindable - modal dialogs (Esc to dismiss, Enter to confirm) and
/// terminal-internal keystrokes stay fixed because rebinding them
/// would break basic interaction. Only "global" / chrome-wide
/// shortcuts are exposed.
enum ShortcutAction {
  // ── General ──────────────────────────────────────────────────
  commandPalette('Command palette',
      'Open the universal command + search palette',
      ShortcutCategory.general),
  quickConnect('Quick connect',
      'Open the connect-to-host dialog', ShortcutCategory.general),
  newConnection(
      'New host', 'Add a new host', ShortcutCategory.general),
  settings('Settings', 'Open the settings panel', ShortcutCategory.general),
  toggleFullscreen('Toggle fullscreen',
      'Show / hide the desktop window chrome', ShortcutCategory.general),
  supportHub('Support Hub',
      'Open your tickets, bug reports and ideas in one page',
      ShortcutCategory.general),
  // The app lock's own (4.0): only while it is on.
  lockApp('Lock ZestSSH', 'Lock the app now, until it is unlocked again',
      ShortcutCategory.general),

  // ── Tabs ─────────────────────────────────────────────────────
  closeTab('Close tab', 'Close the currently active tab', ShortcutCategory.tabs),
  reopenLastTab(
      'Reopen last closed tab',
      'Bring back the most recently dismissed tab',
      ShortcutCategory.tabs),
  nextTab(
      'Next tab', 'Cycle to the next tab', ShortcutCategory.tabs),
  previousTab(
      'Previous tab', 'Cycle to the previous tab', ShortcutCategory.tabs),

  // ── Layout / panes ───────────────────────────────────────────
  toggleSidebar('Toggle sidebar', 'Show / hide the left-rail sidebar',
      ShortcutCategory.layout),
  toggleHostPanel('Toggle Hosts panel',
      'Slide the Hosts fast-connect panel in / out', ShortcutCategory.layout),
  splitRight('Split right',
      'Split the active pane horizontally', ShortcutCategory.layout),
  splitDown('Split down',
      'Split the active pane vertically', ShortcutCategory.layout),
  closeSplit('Close split',
      'Close the active split pane', ShortcutCategory.layout),
  maximizePane('Maximize pane',
      'Toggle the active pane to full size', ShortcutCategory.layout),

  // ── Terminal ─────────────────────────────────────────────────
  findInTerminal('Find in terminal',
      'Open the terminal find bar', ShortcutCategory.terminal),
  copySelection('Copy', 'Copy the selected terminal text',
      ShortcutCategory.terminal),
  paste('Paste', 'Paste from clipboard', ShortcutCategory.terminal),
  zoomIn('Zoom in', 'Increase the terminal font size',
      ShortcutCategory.terminal),
  zoomOut('Zoom out', 'Decrease the terminal font size',
      ShortcutCategory.terminal),
  resetZoom('Reset zoom', 'Restore the default terminal font size',
      ShortcutCategory.terminal),
  openTmux('Open tmux',
      'Attach to a tmux session on the active connection, or start one',
      ShortcutCategory.terminal),
  // Speech to text into the terminal in front (4.0): where a recogniser is
  // (Windows, macOS; not Linux), and with Squeezed, as the phone's mic.
  dictate('Speech to text',
      'Type what you say into the terminal; nothing runs until you press Enter',
      ShortcutCategory.terminal),

  // ── Misc / SFTP ──────────────────────────────────────────────
  toggleSftpPanel('Toggle SFTP panel',
      'Slide the SFTP file browser in / out', ShortcutCategory.misc),
  toggleSessionInfo('Toggle session info',
      'Slide the session diagnostics panel in / out', ShortcutCategory.misc),
  toggleBroadcast('Toggle broadcast mode',
      'Send keystrokes to every visible pane at once',
      ShortcutCategory.misc),
  toggleRecordingMode('Toggle recording mode',
      'Mask host names, addresses and keys in the app chrome',
      ShortcutCategory.misc);

  const ShortcutAction(this.label, this.description, this.category);

  /// Human-readable label shown in the settings UI and command
  /// palette. Stable enough to be searchable.
  final String label;

  /// One-line explanation. Lives next to the binding chip.
  final String description;

  /// Used to group shortcuts on the settings page.
  final ShortcutCategory category;
}

/// The actions offered here: speech to text only where something listens
/// ([voice], voiceInputSupportedProvider: not on Linux).
List<ShortcutAction> shortcutActionsOffered({required bool voice}) =>
    [for (final a in ShortcutAction.values) if (voice || a != ShortcutAction.dictate) a];

/// Top-level grouping for the shortcuts UI. Keep this list short -
/// each category becomes a section header on the settings page.
enum ShortcutCategory {
  general('General'),
  tabs('Tabs'),
  layout('Layout & panes'),
  terminal('Terminal'),
  misc('Misc');

  const ShortcutCategory(this.label);
  final String label;
}
