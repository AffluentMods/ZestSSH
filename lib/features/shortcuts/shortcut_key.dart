import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A single key combination - modifiers + a logical key.
///
/// Stored on disk as a JSON string (see [toJson] / [fromJson]) so the
/// settings page can persist user overrides without bringing along
/// a Drift table for what's effectively a tiny static map.
@immutable
class ShortcutKey {
  const ShortcutKey({
    required this.keyId,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  /// `LogicalKeyboardKey.keyId`. We persist the numeric id rather
  /// than the [LogicalKeyboardKey] object because it's stable across
  /// SDK versions, easy to round-trip via JSON, and works on every
  /// platform.
  final int keyId;

  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;

  /// True if [event]'s logical key + modifier mask matches this
  /// binding. Pulled out so dispatch is a single tight loop in the
  /// hot path.
  ///
  /// On an iPad (4.0: a keyboard on a tablet's large screen, the computer's
  /// shell) Cmd is the app's key, as everywhere on iPadOS: a binding with
  /// Ctrl is matched by Cmd in its place too, and by Ctrl still.
  bool matches(KeyEvent event, {TargetPlatform? platform}) {
    if (event.logicalKey.keyId != keyId) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed != shift) return false;
    if (keys.isAltPressed != alt) return false;
    if (keys.isControlPressed == ctrl && keys.isMetaPressed == meta) return true;
    return ctrl &&
        !meta &&
        commandIsControlOn(platform) &&
        keys.isMetaPressed &&
        !keys.isControlPressed;
  }

  /// Compact, platform-correct label, e.g. "Ctrl+Shift+P" (or "⇧⌘P" on
  /// macOS).
  ///
  /// Delegates to the single [formatShortcutKey] formatter so every
  /// surface that shows a binding renders it identically. Do not build
  /// shortcut strings by hand anywhere else - route through this getter
  /// or `shortcutBindingProvider`.
  String get displayLabel => formatShortcutKey(this);

  Map<String, dynamic> toJson() => {
        'keyId': keyId,
        if (ctrl) 'ctrl': true,
        if (shift) 'shift': true,
        if (alt) 'alt': true,
        if (meta) 'meta': true,
      };

  static ShortcutKey? fromJson(Map<String, dynamic> json) {
    final id = json['keyId'];
    if (id is! int) return null;
    return ShortcutKey(
      keyId: id,
      ctrl: json['ctrl'] == true,
      shift: json['shift'] == true,
      alt: json['alt'] == true,
      meta: json['meta'] == true,
    );
  }

  /// Build a binding from a live [KeyEvent]. Used by the rebind
  /// dialog - the user presses the new combo, we capture the
  /// current modifier mask + key.
  ///
  /// Returns null if the event is just a modifier press (Ctrl alone)
  /// - those aren't valid bindings on their own.
  static ShortcutKey? fromKeyEvent(KeyEvent event) {
    if (_isModifierKey(event.logicalKey)) return null;
    final keys = HardwareKeyboard.instance;
    return ShortcutKey(
      keyId: event.logicalKey.keyId,
      ctrl: keys.isControlPressed,
      shift: keys.isShiftPressed,
      alt: keys.isAltPressed,
      meta: keys.isMetaPressed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ShortcutKey &&
        other.keyId == keyId &&
        other.ctrl == ctrl &&
        other.shift == shift &&
        other.alt == alt &&
        other.meta == meta;
  }

  @override
  int get hashCode => Object.hash(keyId, ctrl, shift, alt, meta);
}

/// The single source of truth for turning a [ShortcutKey] into display
/// text. Every surface that shows a binding - the title-bar search hint,
/// the help overlay, tooltips, and every context menu - formats through
/// this (directly, via [ShortcutKey.displayLabel], or via the
/// `shortcutBindingProvider` family), so a rebinding shows up identically
/// everywhere.
///
/// Platform-correct: on macOS the modifiers collapse to their symbols
/// (⌃ ⌥ ⇧ ⌘, in that order, a Mac's own) with no "+" separator; on every
/// other platform they render as words joined by "+", e.g. "Ctrl+Shift+K",
/// in the order every Windows / Linux keymap uses: Ctrl → Shift → Alt → Cmd.
///
/// [platform] defaults to [defaultTargetPlatform]; pass it explicitly only
/// in tests.
String formatShortcutKey(ShortcutKey key, {TargetPlatform? platform}) {
  final mac = _apple(platform);
  final parts = <String>[];
  // An iPad's binding of Ctrl is said by Cmd, its key there, in Cmd's place
  // (4.0).
  final ctrlIsCmd = commandIsControlOn(platform) && !key.meta;
  if (key.ctrl && !ctrlIsCmd) parts.add('Ctrl');
  if (mac && key.alt) parts.add('Alt');
  if (key.shift) parts.add('Shift');
  if (!mac && key.alt) parts.add('Alt');
  if (key.meta || (key.ctrl && ctrlIsCmd)) parts.add('Cmd');
  parts.add(_keyDisplayName(key.keyId));
  return formatComboString(parts.join('+'), platform: platform);
}

/// Apply platform-correct rendering to an already-joined combo *string*.
///
/// Used for the handful of hints that aren't backed by a [ShortcutKey]
/// (pane-navigation arrows, layout presets, the "Ctrl+1-9" tab range).
/// On macOS the word modifiers collapse to their symbols; elsewhere the
/// string is returned unchanged. Ctrl is the Control key (⌃) on a Mac too:
/// the app's key handlers take Control there as everywhere
/// ([ShortcutKey.matches]), so a label says the key that works (it said ⌘,
/// which did nothing for most of them).
String formatComboString(String combo, {TargetPlatform? platform}) {
  if (!_apple(platform)) return combo;
  return combo
      .replaceAll('Ctrl', '⌃')
      .replaceAll('Cmd', '⌘')
      .replaceAll('Meta', '⌘')
      .replaceAll('Alt', '⌥')
      .replaceAll('Option', '⌥')
      .replaceAll('Shift', '⇧')
      .replaceAll('+', '');
}

/// Whether Cmd stands for Ctrl in the app's keys on [platform] (the one the
/// app runs on unless told): on an iPad and an iPhone, where Cmd is the app's
/// key and never reaches a shell (4.0). A Mac keeps Control, as its labels
/// say ([formatComboString]).
bool commandIsControlOn([TargetPlatform? platform]) => (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;

/// A Mac's or an iPad's: modifiers said by their symbols.
bool _apple(TargetPlatform? platform) {
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.macOS || p == TargetPlatform.iOS;
}

/// True for keys that are *just* a modifier - pressing Ctrl alone
/// shouldn't be capturable as a binding.
bool _isModifierKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight;
}

/// Pretty key names. Flutter's `keyLabel` gives "ESCAPE" / "ARROW UP"
/// for special keys which look ugly in a binding chip - so we
/// override the most common ones with shorter / glyph forms.
///
/// We look up by [LogicalKeyboardKey].keyId at runtime instead of
/// hardcoding numeric IDs (those are an implementation detail of
/// the Flutter SDK and have shifted between versions).
String _keyDisplayName(int keyId) {
  final override = _displayOverrides[keyId];
  if (override != null) return override;

  // Function keys - F1..F12 (and F13+ if a fancy keyboard).
  for (var i = 1; i <= 24; i++) {
    final fk = _functionKey(i);
    if (fk != null && fk.keyId == keyId) return 'F$i';
  }

  // Numpad digits - render as Num0..Num9.
  for (var i = 0; i <= 9; i++) {
    final nk = _numpadKey(i);
    if (nk != null && nk.keyId == keyId) return 'Num$i';
  }

  // Fall back to Flutter's metadata, capitalised.
  final lk = LogicalKeyboardKey.findKeyByKeyId(keyId);
  if (lk != null) {
    final l = lk.keyLabel.trim();
    if (l.isNotEmpty) {
      // Single letter / digit → uppercase.
      if (l.length == 1) return l.toUpperCase();
      // Multi-word name → title case for readability.
      return l
          .split(' ')
          .map((w) =>
              w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
          .join(' ');
    }
  }
  return '?';
}

/// Override map for keys whose default rendering looks bad as a
/// binding chip. Built lazily at first call so the keys above are
/// computed from the real LogicalKeyboardKey constants.
final Map<int, String> _displayOverrides = {
  LogicalKeyboardKey.enter.keyId: 'Enter',
  LogicalKeyboardKey.numpadEnter.keyId: 'NumEnter',
  LogicalKeyboardKey.tab.keyId: 'Tab',
  LogicalKeyboardKey.escape.keyId: 'Esc',
  LogicalKeyboardKey.backspace.keyId: 'Backspace',
  LogicalKeyboardKey.delete.keyId: 'Del',
  LogicalKeyboardKey.space.keyId: 'Space',
  LogicalKeyboardKey.comma.keyId: ',',
  LogicalKeyboardKey.period.keyId: '.',
  LogicalKeyboardKey.minus.keyId: '-',
  LogicalKeyboardKey.equal.keyId: '=',
  LogicalKeyboardKey.backslash.keyId: r'\',
  LogicalKeyboardKey.slash.keyId: '/',
  LogicalKeyboardKey.semicolon.keyId: ';',
  LogicalKeyboardKey.quote.keyId: "'",
  LogicalKeyboardKey.backquote.keyId: '`',
  LogicalKeyboardKey.bracketLeft.keyId: '[',
  LogicalKeyboardKey.bracketRight.keyId: ']',
  LogicalKeyboardKey.arrowUp.keyId: '↑',
  LogicalKeyboardKey.arrowDown.keyId: '↓',
  LogicalKeyboardKey.arrowLeft.keyId: '←',
  LogicalKeyboardKey.arrowRight.keyId: '→',
  LogicalKeyboardKey.home.keyId: 'Home',
  LogicalKeyboardKey.end.keyId: 'End',
  LogicalKeyboardKey.pageUp.keyId: 'PgUp',
  LogicalKeyboardKey.pageDown.keyId: 'PgDn',
  LogicalKeyboardKey.insert.keyId: 'Ins',
};

LogicalKeyboardKey? _functionKey(int n) {
  switch (n) {
    case 1: return LogicalKeyboardKey.f1;
    case 2: return LogicalKeyboardKey.f2;
    case 3: return LogicalKeyboardKey.f3;
    case 4: return LogicalKeyboardKey.f4;
    case 5: return LogicalKeyboardKey.f5;
    case 6: return LogicalKeyboardKey.f6;
    case 7: return LogicalKeyboardKey.f7;
    case 8: return LogicalKeyboardKey.f8;
    case 9: return LogicalKeyboardKey.f9;
    case 10: return LogicalKeyboardKey.f10;
    case 11: return LogicalKeyboardKey.f11;
    case 12: return LogicalKeyboardKey.f12;
    case 13: return LogicalKeyboardKey.f13;
    case 14: return LogicalKeyboardKey.f14;
    case 15: return LogicalKeyboardKey.f15;
    case 16: return LogicalKeyboardKey.f16;
    case 17: return LogicalKeyboardKey.f17;
    case 18: return LogicalKeyboardKey.f18;
    case 19: return LogicalKeyboardKey.f19;
    case 20: return LogicalKeyboardKey.f20;
    case 21: return LogicalKeyboardKey.f21;
    case 22: return LogicalKeyboardKey.f22;
    case 23: return LogicalKeyboardKey.f23;
    case 24: return LogicalKeyboardKey.f24;
  }
  return null;
}

LogicalKeyboardKey? _numpadKey(int n) {
  switch (n) {
    case 0: return LogicalKeyboardKey.numpad0;
    case 1: return LogicalKeyboardKey.numpad1;
    case 2: return LogicalKeyboardKey.numpad2;
    case 3: return LogicalKeyboardKey.numpad3;
    case 4: return LogicalKeyboardKey.numpad4;
    case 5: return LogicalKeyboardKey.numpad5;
    case 6: return LogicalKeyboardKey.numpad6;
    case 7: return LogicalKeyboardKey.numpad7;
    case 8: return LogicalKeyboardKey.numpad8;
    case 9: return LogicalKeyboardKey.numpad9;
  }
  return null;
}
