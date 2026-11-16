import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What a phone's and a tablet's terminal knows of a hardware keyboard
/// (Bluetooth, USB, a keyboard case) in this run of the app, for the row of
/// keys over the keyboard and for the on-screen keyboard (an audit of an
/// external keyboard on Android and an iPad, 22 October 2026: the row stayed,
/// and a tap on the terminal brought the on-screen keyboard up over half the
/// screen, with a keyboard on the desk).
///
/// The rule:
/// - A key only a hardware keyboard sends ([isHardwareKeyboardKey]) says one
///   is used. From then the row hides (where Settings has it hide
///   automatically), and a tap on the terminal gives it the keyboard's input
///   without bringing the on-screen keyboard up.
/// - The row comes back when the on-screen keyboard types something (text
///   that came with no hardware key just before it), and after a tap on the
///   terminal once no hardware key came for [quietForRow].
/// - Taps bring the on-screen keyboard up again once its person asked for it:
///   the row's Show keyboard key, a key of the row, or typing on the
///   on-screen keyboard. A hardware key starts it all over.
@immutable
class HardwareKeyboardUse {
  const HardwareKeyboardUse({this.lastKeyAt, this.rowBack = false, this.softWanted = false});

  /// When a hardware keyboard's key came last; null while none did.
  final DateTime? lastKeyAt;

  /// The row is shown again since that key.
  final bool rowBack;

  /// Taps bring the on-screen keyboard up again since that key.
  final bool softWanted;

  /// A hardware keyboard was used in this run of the app.
  bool get used => lastKeyAt != null;

  /// Whether the row of keys is hidden, where it hides automatically.
  bool get rowHidden => used && !rowBack;

  /// Whether a tap on the terminal brings the on-screen keyboard up.
  bool get keyboardOnTap => !used || softWanted;

  /// How long no hardware key has to come for a tap to bring the row back.
  static const quietForRow = Duration(seconds: 20);

  /// How soon after a hardware key the text it typed comes (the platform
  /// sends a hardware keyboard's letters as text as well, a moment later):
  /// text within it is the hardware keyboard's own.
  static const textOfKey = Duration(milliseconds: 400);

  HardwareKeyboardUse _with({bool? rowBack, bool? softWanted}) => HardwareKeyboardUse(
        lastKeyAt: lastKeyAt,
        rowBack: rowBack ?? this.rowBack,
        softWanted: softWanted ?? this.softWanted,
      );
}

/// The time it is, for [HardwareKeyboardUseNotifier]; a test's own clock.
@visibleForTesting
DateTime Function() hardwareKeyboardClock = DateTime.now;

class HardwareKeyboardUseNotifier extends StateNotifier<HardwareKeyboardUse> {
  HardwareKeyboardUseNotifier() : super(const HardwareKeyboardUse());

  /// A key event reached the terminal: a hardware keyboard's, where it is a
  /// key only one sends ([softKeyboardOpen]: Android's on-screen keyboard is
  /// up, see [isHardwareKeyboardKey]).
  void key(KeyEvent event, {bool softKeyboardOpen = false}) {
    if (!isHardwareKeyboardKey(event, softKeyboardOpen: softKeyboardOpen)) return;
    state = HardwareKeyboardUse(lastKeyAt: hardwareKeyboardClock());
  }

  /// The on-screen keyboard (or an input method) typed text into the
  /// terminal: the row is back, and taps bring that keyboard up. Not text
  /// that came right after a hardware key: that is the hardware keyboard's.
  void softText() {
    final last = state.lastKeyAt;
    if (last == null) return;
    if (hardwareKeyboardClock().difference(last) < HardwareKeyboardUse.textOfKey) return;
    if (state.rowBack && state.softWanted) return;
    state = state._with(rowBack: true, softWanted: true);
  }

  /// A tap on the terminal: the row is back where no hardware key came for
  /// [HardwareKeyboardUse.quietForRow].
  void tapped() {
    final last = state.lastKeyAt;
    if (last == null || state.rowBack) return;
    if (hardwareKeyboardClock().difference(last) < HardwareKeyboardUse.quietForRow) return;
    state = state._with(rowBack: true);
  }

  /// A key of the row was used, or its Show keyboard key: taps bring the
  /// on-screen keyboard up.
  void wantSoftKeyboard() {
    if (!state.used || (state.softWanted && state.rowBack)) return;
    state = state._with(rowBack: true, softWanted: true);
  }
}

final hardwareKeyboardUseProvider =
    StateNotifierProvider<HardwareKeyboardUseNotifier, HardwareKeyboardUse>((ref) => HardwareKeyboardUseNotifier());

/// Whether [event] is a key only a hardware keyboard sends. An on-screen
/// keyboard types text through the input connection, and of keys sends at
/// most Backspace, Enter, a space, the arrows (Gboard's cursor moves) and
/// the digits: those say nothing. A letter or a mark pressed as a key, a key
/// with Ctrl, Alt or Cmd held, a modifier alone, Escape, Tab, a function key,
/// a number pad's key and the keys of a computer's keyboard's middle block do.
///
/// The digits: Android's own way for a keyboard to type a character
/// (InputMethodService.sendKeyChar) sends 0 to 9 as key presses, not as
/// text, and Gboard, Samsung's keyboard and the others built on Android's
/// keyboard do the same on their number row and number page. A digit counted
/// as a hardware keyboard's (in 3.0.0: a number hid the row, a
/// letter brought it back, and a tap after a number brought no keyboard up).
/// A hardware keyboard still says so with its first letter, mark or Ctrl.
///
/// [softKeyboardOpen]: Android's on-screen keyboard is up (the view's
/// inset, as it settled). Android takes it down as a hardware keyboard is
/// typed on (unless its Settings keep it), and a keyboard of its own may
/// send other characters as keys too: while it is up, a character's key
/// says nothing either; Escape, Tab, a function key and a key with Ctrl,
/// Alt or Cmd still do. Not on an iPad: its on-screen keyboard sends no keys,
/// and with a hardware keyboard the bar of shortcuts it keeps is an inset.
bool isHardwareKeyboardKey(KeyEvent event, {bool softKeyboardOpen = false}) {
  if (event is! KeyDownEvent) return false;
  final keys = HardwareKeyboard.instance;
  if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return true;
  final key = event.logicalKey;
  final id = key.keyId;
  // A digit: an on-screen keyboard's as well (above).
  if (id >= 0x30 && id <= 0x39) return false;
  // A printable character's key (its id is the character): not the space,
  // and not with Android's on-screen keyboard up.
  if (id > 0x20 && id < 0x7f) return !softKeyboardOpen;
  return _hardwareOnly.contains(key) ||
      (id >= LogicalKeyboardKey.f1.keyId && id <= LogicalKeyboardKey.f24.keyId) ||
      (id >= LogicalKeyboardKey.numpad0.keyId && id <= LogicalKeyboardKey.numpad9.keyId);
}

final _hardwareOnly = <LogicalKeyboardKey>{
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.pageUp,
  LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.insert,
  LogicalKeyboardKey.capsLock,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};
