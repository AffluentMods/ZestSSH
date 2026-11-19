// Remote screens (4.0): the app's keys that show one of a remote's displays
// (Alt and a digit unless changed in Settings, Keyboard shortcuts), caught
// before the remote has them, in a tab, in full screen and in a window of
// the screen's own.
import 'package:flutter/services.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';

/// The actions that show displays 1 to 4, in order.
const screenDisplayActions = [
  ShortcutAction.screenDisplay1,
  ShortcutAction.screenDisplay2,
  ShortcutAction.screenDisplay3,
  ShortcutAction.screenDisplay4,
];

/// Where [e] goes down on one of [keys] (the key of display 1 first; null:
/// none is set), that display is shown on [c] and true is said: the key is
/// the app's. False, and the key is the remote's, where [c]'s remote has one
/// display or fewer than the key names.
bool showDisplayForKey(List<ShortcutKey?> keys, ScreenController c, KeyEvent e) {
  if (e is! KeyDownEvent) return false;
  final d = c.displays.value;
  if (!d.several) return false;
  for (var i = 0; i < keys.length; i++) {
    final k = keys[i];
    if (k == null || !k.matches(e)) continue;
    if (i >= d.list.length) return false;
    c.showDisplay(i);
    return true;
  }
  return false;
}
