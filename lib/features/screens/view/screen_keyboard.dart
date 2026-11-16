// Remote screens (4.0): a hardware keyboard, and the keys other parts of the
// tab send (the toolbar's Ctrl+Alt+Del, a phone's key bar, the soft keyboard's
// text), to the remote as key events.
//
// Each key goes as its keysym and, where the local layout agrees with a US
// layout on that key, its scancode too. A server that takes scancodes (QEMU's
// extended key events) then presses the very key, which keeps shortcuts and
// games right; where the layouts differ (AZERTY's A, German's Z, AltGr's @, a
// dead key's é), only the character's keysym goes, and the server finds the
// key for it in its own layout. Named keys (Enter, arrows, modifiers, F-keys)
// are the same everywhere and always go with their scancode.
//
// A key up sends what its key down sent; the keys held are let go when the
// view loses focus or is hidden. F8 opens the screen menu on computers (as in
// TigerVNC) and is never sent by accident.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import 'keysyms.dart';

/// The modifiers a phone's key bar can hold for the next key.
enum ScreenModifier {
  ctrl(ScreenKey.controlLeft),
  alt(ScreenKey.altLeft),
  shift(ScreenKey.shiftLeft),
  superKey(ScreenKey.superLeft);

  const ScreenModifier(this.key);

  final ScreenKey key;
}

/// What a session's key call takes.
typedef ScreenKeySend = void Function(int keysym, int scancode, bool down);

class ScreenKeyboard {
  ScreenKeyboard(this._send);

  final ScreenKeySend _send;

  /// Keys go to the remote (false: view only; F8 still opens the menu).
  bool enabled = true;

  /// Scancodes go with keys where the layouts agree (true), or never: the
  /// keysyms alone, for a server that gets a non-US layout wrong.
  bool sendScancodes = true;

  /// Called on [menuKey] (computers: the screen menu, which also lets the
  /// keyboard go). Null: the key goes to the remote like any key.
  VoidCallback? onMenuKey;

  /// The key that opens the screen menu: F8 unless Settings, Remote screens
  /// says another.
  LogicalKeyboardKey menuKey = LogicalKeyboardKey.f8;

  /// Asked first on [menuKey] (4.0, relative mouse): true where the
  /// pointer was held and is let go by it. The key is then that and nothing
  /// more: the menu opens on the next press. Read before anything is sent to
  /// the remote, as the menu key is.
  bool Function()? onReleaseKey;

  /// Called on Ctrl+Alt+Right (true: the next of the remote's displays) and
  /// Ctrl+Alt+Left (false: the one before), which then never reach the
  /// remote (4.0). Null, as it is while the remote has one display:
  /// the keys go to the remote like any keys.
  void Function(bool next)? onDisplayKey;

  /// A Mac's Command key goes to the remote as Ctrl (4.0), so
  /// Cmd+C is the remote's Ctrl+C. Off: it goes as the Super (Windows)
  /// key, as it always did. A key held while this changes is let go as
  /// what it was sent as.
  bool commandAsControl = false;

  /// Modifiers a phone's key bar holds for the next key: pressed around it.
  final latched = ValueNotifier<Set<ScreenModifier>>(const {});

  /// A key went with the [latched] modifiers: the bar lets go of the ones
  /// held for one key.
  VoidCallback? onLatchedUsed;

  // What each held key sent at its key down, the modifiers lifted for it
  // (AltGr's Ctrl and Alt), and the latched ones pressed for it.
  final Map<PhysicalKeyboardKey, ScreenKey> _down = {};
  final Map<PhysicalKeyboardKey, List<ScreenKey>> _lifted = {};
  final Map<PhysicalKeyboardKey, List<ScreenKey>> _latchedFor = {};
  final Set<PhysicalKeyboardKey> _menuKeys = {};

  /// The keys held now, as sent.
  Iterable<ScreenKey> get held => _down.values;

  bool _holds(Set<int> keysyms) => _down.values.any((k) => keysyms.contains(k.keysym));
  bool get _ctrl => _holds(const {0xffe3, 0xffe4});
  bool get _alt => _holds(const {0xffe9, 0xffea});
  bool get _meta => _holds(const {0xffeb, 0xffec, 0xffe7, 0xffe8});
  bool get _shift => _holds(const {0xffe1, 0xffe2});

  /// Ctrl and Alt held and neither Shift nor the Windows or Command key: by
  /// what was sent to the remote, or (view only, where no key is sent) by
  /// what the keyboard itself holds.
  bool get _ctrlAltAlone {
    if (enabled) return _ctrl && _alt && !_meta && !_shift;
    final k = HardwareKeyboard.instance;
    return k.isControlPressed && k.isAltPressed && !k.isMetaPressed && !k.isShiftPressed;
  }

  /// A key event from the view's Focus.
  KeyEventResult handle(KeyEvent e) {
    final physical = e.physicalKey;
    switch (e) {
      case KeyDownEvent():
        if (e.logicalKey == menuKey && onMenuKey != null && !_ctrl && !_alt && !_meta && !_shift) {
          _menuKeys.add(physical);
          if (!(onReleaseKey?.call() ?? false)) onMenuKey!();
          return KeyEventResult.handled;
        }
        if (onDisplayKey != null &&
            (e.logicalKey == LogicalKeyboardKey.arrowRight || e.logicalKey == LogicalKeyboardKey.arrowLeft) &&
            _ctrlAltAlone) {
          // Swallowed with its repeats and its key up, as the menu key is.
          _menuKeys.add(physical);
          onDisplayKey!(e.logicalKey == LogicalKeyboardKey.arrowRight);
          return KeyEventResult.handled;
        }
        if (!enabled) return KeyEventResult.ignored;
        // A key down for a key already down (a lost key up): let it go first.
        if (_down.containsKey(physical)) _up(physical);
        final k = _keyFor(e);
        if (k == null) return KeyEventResult.ignored;
        final latched = _pressLatched();
        if (latched.isNotEmpty) _latchedFor[physical] = latched;
        // AltGr on Windows comes as Ctrl and Alt held with a character: the
        // character goes alone, so the remote does not see Ctrl+Alt+@.
        if (k.scancode == 0 && _ctrl && _alt && _isCharacter(e)) {
          final lift = [for (final m in _down.values) if (_isCtrlOrAlt(m.keysym)) m];
          for (final m in lift) {
            _send(m.keysym, m.scancode, false);
          }
          _lifted[physical] = lift;
        }
        _down[physical] = k;
        _send(k.keysym, k.scancode, true);
        return KeyEventResult.handled;
      case KeyRepeatEvent():
        if (_menuKeys.contains(physical)) return KeyEventResult.handled;
        final held = _down[physical];
        if (held == null || !enabled) return KeyEventResult.ignored;
        _send(held.keysym, held.scancode, true);
        return KeyEventResult.handled;
      case KeyUpEvent():
        if (_menuKeys.remove(physical)) return KeyEventResult.handled;
        if (!_down.containsKey(physical)) return KeyEventResult.ignored;
        _up(physical);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _up(PhysicalKeyboardKey physical) {
    final k = _down.remove(physical);
    if (k == null) return;
    _send(k.keysym, k.scancode, false);
    // AltGr's modifiers back down, if they are still held here.
    final lifted = _lifted.remove(physical);
    if (lifted != null) {
      for (final m in lifted) {
        if (_down.values.contains(m)) _send(m.keysym, m.scancode, true);
      }
    }
    final latched = _latchedFor.remove(physical);
    if (latched != null) _releaseLatched(latched);
  }

  static bool _isCtrlOrAlt(int keysym) => const {0xffe3, 0xffe4, 0xffe9, 0xffea}.contains(keysym);

  static bool _isCharacter(KeyEvent e) {
    final c = e.character;
    return c != null && c.runes.length == 1 && isPrintable(c.runes.first);
  }

  ScreenKey? _keyFor(KeyEvent e) {
    if (commandAsControl) {
      final as = switch (e.logicalKey) {
        LogicalKeyboardKey.metaLeft => ScreenKey.controlLeft,
        LogicalKeyboardKey.metaRight => ScreenKey.controlRight,
        _ => null,
      };
      if (as != null) return sendScancodes ? as : ScreenKey(as.keysym, 0);
    }
    final named = namedKeysym(e.logicalKey);
    if (named != null) return ScreenKey(named, sendScancodes ? scancodeFor(e.physicalKey) : 0);
    int? ch;
    if (_isCharacter(e)) {
      ch = e.character!.runes.first;
    } else if (_ctrl || _alt || _meta) {
      // Ctrl+letter comes with a control character or none: the letter the
      // key has in the local layout.
      final id = e.logicalKey.keyId;
      if (id >= 0x20 && id <= 0x7e) ch = id;
    }
    // No character yet (a dead key waiting for the next one): nothing goes.
    if (ch == null) return null;
    final us = usCharsOf(e.physicalKey);
    final agrees = sendScancodes && us != null && (us.$1 == ch || us.$2 == ch);
    return ScreenKey(keysymForChar(ch), agrees ? scancodeFor(e.physicalKey) : 0);
  }

  List<ScreenKey> _pressLatched() {
    final mods = latched.value;
    if (mods.isEmpty) return const [];
    final pressed = <ScreenKey>[];
    for (final m in ScreenModifier.values) {
      if (!mods.contains(m) || _down.values.contains(m.key)) continue;
      _send(m.key.keysym, m.key.scancode, true);
      pressed.add(m.key);
    }
    return pressed;
  }

  void _releaseLatched(List<ScreenKey> pressed) {
    for (final k in pressed.reversed) {
      _send(k.keysym, k.scancode, false);
    }
    onLatchedUsed?.call();
  }

  /// Lets go of every key held (focus gone, the view hidden, the app locked).
  void releaseAll() {
    final keys = _down.keys.toList();
    for (final k in keys.reversed) {
      _up(k);
    }
    _menuKeys.clear();
  }

  /// One key pressed and let go, with the [latched] modifiers around it.
  void tapKey(ScreenKey key) {
    if (!enabled) return;
    final latched = _pressLatched();
    _send(key.keysym, key.scancode, true);
    _send(key.keysym, key.scancode, false);
    if (latched.isNotEmpty) _releaseLatched(latched);
  }

  /// Keys pressed in order and let go in reverse (Ctrl+Alt+Del).
  void sendChord(List<ScreenKey> keys) {
    if (!enabled) return;
    for (final k in keys) {
      _send(k.keysym, k.scancode, true);
    }
    for (final k in keys.reversed) {
      _send(k.keysym, k.scancode, false);
    }
  }

  /// Text typed as keys (the soft keyboard's, a paste as keys): each
  /// character's keysym, so the server adds the modifiers its layout needs.
  /// [usScancodes]: a character on a US key goes as that key's scancode, Shift
  /// added where it needs it (RDP, which drops keysyms without a scancode).
  /// The [latched] modifiers go with the first character only.
  void typeText(String text, {bool usScancodes = false}) {
    if (!enabled || text.isEmpty) return;
    var first = true;
    for (final ch in text.runes) {
      final latched = first ? _pressLatched() : const <ScreenKey>[];
      first = false;
      _typeChar(ch, usScancodes);
      if (latched.isNotEmpty) _releaseLatched(latched);
    }
  }

  void _typeChar(int ch, bool usScancodes) {
    ScreenKey? key;
    if (ch == 0x0a || ch == 0x0d) key = ScreenKey.enter;
    if (ch == 0x09) key = ScreenKey.tab;
    if (key != null) {
      _send(key.keysym, key.scancode, true);
      _send(key.keysym, key.scancode, false);
      return;
    }
    if (!isPrintable(ch)) return;
    final keysym = keysymForChar(ch);
    final us = usScancodes ? usKey(ch) : null;
    if (us == null) {
      _send(keysym, 0, true);
      _send(keysym, 0, false);
      return;
    }
    final (physical, shift) = us;
    final sc = scancodeFor(physical);
    final needShift = shift && !_shift;
    if (needShift) _send(ScreenKey.shiftLeft.keysym, ScreenKey.shiftLeft.scancode, true);
    _send(keysym, sc, true);
    _send(keysym, sc, false);
    if (needShift) _send(ScreenKey.shiftLeft.keysym, ScreenKey.shiftLeft.scancode, false);
  }

  /// BackSpace, [times] over.
  void backspace([int times = 1]) {
    if (!enabled) return;
    for (var i = 0; i < times; i++) {
      _send(ScreenKey.backspace.keysym, ScreenKey.backspace.scancode, true);
      _send(ScreenKey.backspace.keysym, ScreenKey.backspace.scancode, false);
    }
  }

  void dispose() => latched.dispose();
}
