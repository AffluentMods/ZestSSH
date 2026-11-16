import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'default_bindings.dart';
import 'shortcut_action.dart';
import 'shortcut_key.dart';

/// The app's keys on a phone's and a tablet's screens, for a keyboard plugged
/// in or paired (checked with an external keyboard on Android and an iPad:
/// there were none, the keys lived only in a computer's shell).
///
/// They are a computer's default keys ([defaultShortcutBindings]) where those
/// mean something on a phone's screens, with Ctrl on Android and Cmd in its
/// place on an iPad and an iPhone, where Cmd is the app's key and never
/// reaches a shell. Next and previous session keep Ctrl+Tab and
/// Ctrl+Shift+Tab there too: Cmd+Tab is the system's app switcher. A phone
/// has no Settings page of its own for keys, so they are not changed there.
/// There is no command palette on a phone's screens, so none of its key.
enum TabletShortcut {
  nextSession(ShortcutAction.nextTab),
  previousSession(ShortcutAction.previousTab),
  find(ShortcutAction.findInTerminal),
  zoomIn(ShortcutAction.zoomIn),
  zoomOut(ShortcutAction.zoomOut),
  resetZoom(ShortcutAction.resetZoom),
  closeSession(ShortcutAction.closeTab),
  newConnection(ShortcutAction.newConnection),
  quickConnect(ShortcutAction.quickConnect),
  settings(ShortcutAction.settings);

  const TabletShortcut(this.action);

  /// The action of a computer's whose default key this is.
  final ShortcutAction action;

  /// This shortcut's key on [platform] (the one the app runs on unless
  /// told).
  ShortcutKey keyOn([TargetPlatform? platform]) {
    final base = defaultShortcutBindings[action]!;
    final apple = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
    if (!apple || !base.ctrl || this == nextSession || this == previousSession) return base;
    return ShortcutKey(keyId: base.keyId, shift: base.shift, alt: base.alt, meta: true);
  }

  /// Whether a terminal types something for this key, so that it stays the
  /// terminal's where the keyboard is in one: Ctrl and a letter, the
  /// shell's (Ctrl+T transposes two characters there, quick connect's key
  /// on Android).
  bool typedByTerminalOn([TargetPlatform? platform]) {
    final key = keyOn(platform);
    if (!key.ctrl || key.shift || key.alt || key.meta) return false;
    return key.keyId >= LogicalKeyboardKey.keyA.keyId && key.keyId <= LogicalKeyboardKey.keyZ.keyId;
  }
}

/// The shortcut among [among] that [event] is the key of, or null. Only a
/// key's press (and, for zoom, its repeat while held) counts.
TabletShortcut? tabletShortcutFor(
  KeyEvent event, {
  Iterable<TabletShortcut> among = TabletShortcut.values,
  TargetPlatform? platform,
}) {
  if (event is KeyUpEvent) return null;
  for (final shortcut in among) {
    if (event is KeyRepeatEvent &&
        shortcut != TabletShortcut.zoomIn &&
        shortcut != TabletShortcut.zoomOut) {
      continue;
    }
    if (shortcut.keyOn(platform).matches(event)) return shortcut;
  }
  return null;
}

/// Whether the keyboard is in a text field (a search, a form), whose keys
/// are its own: an app shortcut does not act then.
bool textFieldHasKeyboard() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText || context.findAncestorStateOfType<EditableTextState>() != null;
}
