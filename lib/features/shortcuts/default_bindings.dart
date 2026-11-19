import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'shortcut_action.dart';
import 'shortcut_key.dart';

/// Built-in default bindings for every [ShortcutAction].
///
/// Match the conventions in `desktop_shell.dart`'s existing
/// hardcoded `LogicalKeyboardKey.X` checks - when the dispatcher
/// rolls out, every action keeps the binding it had before, so
/// users won't notice a change unless they explicitly rebind.
final Map<ShortcutAction, ShortcutKey> defaultShortcutBindings = {
  // ── General ──────────────────────────────────────────────────
  // Ctrl+Shift+K (not bare Ctrl+K) so bash readline's kill-to-end-of-line
  // (Ctrl+K → 0x0B) isn't shadowed for power users. Ctrl+Shift+P stays
  // wired as a legacy alias in desktop_shell._hardwareKeyHandler for the
  // VS Code muscle memory crowd.
  ShortcutAction.commandPalette: ShortcutKey(
    keyId: LogicalKeyboardKey.keyK.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.quickConnect: ShortcutKey(
    keyId: LogicalKeyboardKey.keyT.keyId,
    ctrl: true,
  ),
  ShortcutAction.newConnection: ShortcutKey(
    keyId: LogicalKeyboardKey.keyN.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.settings: ShortcutKey(
    keyId: LogicalKeyboardKey.comma.keyId,
    ctrl: true,
  ),
  ShortcutAction.toggleFullscreen: ShortcutKey(
    keyId: LogicalKeyboardKey.f11.keyId,
  ),
  // Only where the keyboard is not in a terminal: there F1 is the program's
  // own (mc's and htop's help), as every key is.
  ShortcutAction.supportHub: ShortcutKey(
    keyId: LogicalKeyboardKey.f1.keyId,
  ),
  // Ctrl+Shift+L, not bare Ctrl+L: that clears a terminal's screen (readline,
  // and most programs), so it stays the terminal's (Control on a Mac as well,
  // as every chord here is).
  ShortcutAction.lockApp: ShortcutKey(
    keyId: LogicalKeyboardKey.keyL.keyId,
    ctrl: true,
    shift: true,
  ),

  // ── Tabs ─────────────────────────────────────────────────────
  // Ctrl+Shift+W (not bare Ctrl+W) for the same reason command-palette avoids
  // bare Ctrl+K: bare Ctrl+W is a live terminal input (readline delete-word,
  // 0x17; nano's Where-Is search), and the terminal-focus gate that is meant
  // to let it through is not perfectly reliable. Ctrl+Shift+W never reaches
  // the pty, and it is the close-tab chord terminal emulators use anyway.
  ShortcutAction.closeTab: ShortcutKey(
    keyId: LogicalKeyboardKey.keyW.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.reopenLastTab: ShortcutKey(
    keyId: LogicalKeyboardKey.keyT.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.nextTab: ShortcutKey(
    keyId: LogicalKeyboardKey.tab.keyId,
    ctrl: true,
  ),
  ShortcutAction.previousTab: ShortcutKey(
    keyId: LogicalKeyboardKey.tab.keyId,
    ctrl: true,
    shift: true,
  ),

  // ── Layout / panes ───────────────────────────────────────────
  ShortcutAction.toggleSidebar: ShortcutKey(
    keyId: LogicalKeyboardKey.keyB.keyId,
    ctrl: true,
  ),
  ShortcutAction.toggleHostPanel: ShortcutKey(
    keyId: LogicalKeyboardKey.keyH.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.splitRight: ShortcutKey(
    keyId: LogicalKeyboardKey.keyD.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.splitDown: ShortcutKey(
    keyId: LogicalKeyboardKey.keyE.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.closeSplit: ShortcutKey(
    keyId: LogicalKeyboardKey.backslash.keyId,
    ctrl: true,
  ),
  ShortcutAction.maximizePane: ShortcutKey(
    keyId: LogicalKeyboardKey.keyM.keyId,
    ctrl: true,
    shift: true,
  ),

  // ── Terminal ─────────────────────────────────────────────────
  ShortcutAction.findInTerminal: ShortcutKey(
    keyId: LogicalKeyboardKey.keyF.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.copySelection: ShortcutKey(
    keyId: LogicalKeyboardKey.keyC.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.paste: ShortcutKey(
    keyId: LogicalKeyboardKey.keyV.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.zoomIn: ShortcutKey(
    keyId: LogicalKeyboardKey.equal.keyId,
    ctrl: true,
  ),
  ShortcutAction.zoomOut: ShortcutKey(
    keyId: LogicalKeyboardKey.minus.keyId,
    ctrl: true,
  ),
  ShortcutAction.resetZoom: ShortcutKey(
    keyId: LogicalKeyboardKey.digit0.keyId,
    ctrl: true,
  ),
  ShortcutAction.openTmux: ShortcutKey(
    keyId: LogicalKeyboardKey.keyX.keyId,
    ctrl: true,
    shift: true,
  ),
  // Ctrl+Shift+Space: no terminal input (a terminal sends nothing of its own
  // for it), so it works from inside the terminal it types into.
  ShortcutAction.dictate: ShortcutKey(
    keyId: LogicalKeyboardKey.space.keyId,
    ctrl: true,
    shift: true,
  ),

  // ── Misc / SFTP ──────────────────────────────────────────────
  ShortcutAction.toggleSftpPanel: ShortcutKey(
    keyId: LogicalKeyboardKey.keyS.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.toggleSessionInfo: ShortcutKey(
    keyId: LogicalKeyboardKey.keyI.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.toggleBroadcast: ShortcutKey(
    keyId: LogicalKeyboardKey.keyB.keyId,
    ctrl: true,
    shift: true,
  ),
  ShortcutAction.toggleRecordingMode: ShortcutKey(
    keyId: LogicalKeyboardKey.keyR.keyId,
    ctrl: true,
    shift: true,
  ),

  // ── Remote screens ───────────────────────────────────────────
  ShortcutAction.screenDisplay1: _displayKey(LogicalKeyboardKey.digit1),
  ShortcutAction.screenDisplay2: _displayKey(LogicalKeyboardKey.digit2),
  ShortcutAction.screenDisplay3: _displayKey(LogicalKeyboardKey.digit3),
  ShortcutAction.screenDisplay4: _displayKey(LogicalKeyboardKey.digit4),
};

/// The key that shows a remote's display: Alt and the digit (Ctrl and a
/// digit picks a tab), and on a Mac Control, Option and the digit, since
/// Option and a digit types a character there on many layouts (# on a
/// British one).
ShortcutKey _displayKey(LogicalKeyboardKey digit) => defaultTargetPlatform == TargetPlatform.macOS
    ? ShortcutKey(keyId: digit.keyId, ctrl: true, alt: true)
    : ShortcutKey(keyId: digit.keyId, alt: true);
