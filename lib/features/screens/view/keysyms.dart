// Remote screens (4.0): Flutter's keys to what a screen engine sends. Two
// units travel with every key: the X keysym (what the key means; the VNC key
// event's unit) and the scancode (where the key is; XT set 1 in QEMU's
// numbering, for VNC's QEMU extended key event and RDP). Named keys come from a
// table, characters from their code point (Latin-1 as it is, the rest as
// 0x01000000 plus the code point, as X defines). The tables are the spike's
// (packages/zest_native/example/lib/keysyms.dart), with the keypad, the lock
// keys and F13 to F24 added.
import 'package:flutter/services.dart';

/// One key as a screen engine takes it: its X [keysym] and its [scancode]
/// (0 when it has none).
class ScreenKey {
  const ScreenKey(this.keysym, this.scancode);

  final int keysym;
  final int scancode;

  static const enter = ScreenKey(0xff0d, 0x1c);
  static const backspace = ScreenKey(0xff08, 0x0e);
  static const tab = ScreenKey(0xff09, 0x0f);
  static const escape = ScreenKey(0xff1b, 0x01);
  static const space = ScreenKey(0x20, 0x39);
  static const delete = ScreenKey(0xffff, 0xd3);
  static const insert = ScreenKey(0xff63, 0xd2);
  static const home = ScreenKey(0xff50, 0xc7);
  static const end = ScreenKey(0xff57, 0xcf);
  static const pageUp = ScreenKey(0xff55, 0xc9);
  static const pageDown = ScreenKey(0xff56, 0xd1);
  static const left = ScreenKey(0xff51, 0xcb);
  static const up = ScreenKey(0xff52, 0xc8);
  static const right = ScreenKey(0xff53, 0xcd);
  static const down = ScreenKey(0xff54, 0xd0);
  static const printScreen = ScreenKey(0xff61, 0xb7);
  static const shiftLeft = ScreenKey(0xffe1, 0x2a);
  static const controlLeft = ScreenKey(0xffe3, 0x1d);
  static const controlRight = ScreenKey(0xffe4, 0x9d);
  static const altLeft = ScreenKey(0xffe9, 0x38);

  /// The Windows or Super key (Super_L: X keeps Meta for another key).
  static const superLeft = ScreenKey(0xffeb, 0xdb);

  /// F1 to F24.
  static ScreenKey f(int n) {
    RangeError.checkValueInInterval(n, 1, 24, 'n');
    const scancodes = [
      0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58, // F1 to F12
      0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x76, // F13 to F24
    ];
    return ScreenKey(0xffbe + n - 1, scancodes[n - 1]);
  }

  @override
  bool operator ==(Object other) => other is ScreenKey && other.keysym == keysym && other.scancode == scancode;

  @override
  int get hashCode => Object.hash(keysym, scancode);

  @override
  String toString() => 'ScreenKey(0x${keysym.toRadixString(16)}, 0x${scancode.toRadixString(16)})';
}

final Map<LogicalKeyboardKey, int> _named = {
  LogicalKeyboardKey.enter: 0xff0d,
  LogicalKeyboardKey.numpadEnter: 0xff8d,
  LogicalKeyboardKey.backspace: 0xff08,
  LogicalKeyboardKey.tab: 0xff09,
  LogicalKeyboardKey.escape: 0xff1b,
  LogicalKeyboardKey.delete: 0xffff,
  LogicalKeyboardKey.insert: 0xff63,
  LogicalKeyboardKey.home: 0xff50,
  LogicalKeyboardKey.end: 0xff57,
  LogicalKeyboardKey.pageUp: 0xff55,
  LogicalKeyboardKey.pageDown: 0xff56,
  LogicalKeyboardKey.arrowLeft: 0xff51,
  LogicalKeyboardKey.arrowUp: 0xff52,
  LogicalKeyboardKey.arrowRight: 0xff53,
  LogicalKeyboardKey.arrowDown: 0xff54,
  LogicalKeyboardKey.shiftLeft: 0xffe1,
  LogicalKeyboardKey.shiftRight: 0xffe2,
  LogicalKeyboardKey.controlLeft: 0xffe3,
  LogicalKeyboardKey.controlRight: 0xffe4,
  LogicalKeyboardKey.capsLock: 0xffe5,
  LogicalKeyboardKey.altLeft: 0xffe9,
  LogicalKeyboardKey.altRight: 0xffea,
  LogicalKeyboardKey.altGraph: 0xfe03, // ISO_Level3_Shift
  LogicalKeyboardKey.metaLeft: 0xffeb,
  LogicalKeyboardKey.metaRight: 0xffec,
  LogicalKeyboardKey.contextMenu: 0xff67,
  LogicalKeyboardKey.printScreen: 0xff61,
  LogicalKeyboardKey.scrollLock: 0xff14,
  LogicalKeyboardKey.numLock: 0xff7f,
  LogicalKeyboardKey.pause: 0xff13,
  LogicalKeyboardKey.f1: 0xffbe,
  LogicalKeyboardKey.f2: 0xffbf,
  LogicalKeyboardKey.f3: 0xffc0,
  LogicalKeyboardKey.f4: 0xffc1,
  LogicalKeyboardKey.f5: 0xffc2,
  LogicalKeyboardKey.f6: 0xffc3,
  LogicalKeyboardKey.f7: 0xffc4,
  LogicalKeyboardKey.f8: 0xffc5,
  LogicalKeyboardKey.f9: 0xffc6,
  LogicalKeyboardKey.f10: 0xffc7,
  LogicalKeyboardKey.f11: 0xffc8,
  LogicalKeyboardKey.f12: 0xffc9,
  LogicalKeyboardKey.f13: 0xffca,
  LogicalKeyboardKey.f14: 0xffcb,
  LogicalKeyboardKey.f15: 0xffcc,
  LogicalKeyboardKey.f16: 0xffcd,
  LogicalKeyboardKey.f17: 0xffce,
  LogicalKeyboardKey.f18: 0xffcf,
  LogicalKeyboardKey.f19: 0xffd0,
  LogicalKeyboardKey.f20: 0xffd1,
  LogicalKeyboardKey.f21: 0xffd2,
  LogicalKeyboardKey.f22: 0xffd3,
  LogicalKeyboardKey.f23: 0xffd4,
  LogicalKeyboardKey.f24: 0xffd5,
  // The keypad by its keys' own keysyms, so a remote that tells them apart
  // (a spreadsheet, a game) sees the keypad. With Num Lock off the system
  // reports the arrows and Home or End instead, which the rows above take.
  LogicalKeyboardKey.numpad0: 0xffb0,
  LogicalKeyboardKey.numpad1: 0xffb1,
  LogicalKeyboardKey.numpad2: 0xffb2,
  LogicalKeyboardKey.numpad3: 0xffb3,
  LogicalKeyboardKey.numpad4: 0xffb4,
  LogicalKeyboardKey.numpad5: 0xffb5,
  LogicalKeyboardKey.numpad6: 0xffb6,
  LogicalKeyboardKey.numpad7: 0xffb7,
  LogicalKeyboardKey.numpad8: 0xffb8,
  LogicalKeyboardKey.numpad9: 0xffb9,
  LogicalKeyboardKey.numpadDecimal: 0xffae,
  LogicalKeyboardKey.numpadAdd: 0xffab,
  LogicalKeyboardKey.numpadSubtract: 0xffad,
  LogicalKeyboardKey.numpadMultiply: 0xffaa,
  LogicalKeyboardKey.numpadDivide: 0xffaf,
  LogicalKeyboardKey.numpadEqual: 0xffbd,
};

/// The keysym of a named key (Enter, the arrows, the modifiers, F1 to F24,
/// the keypad), or null for a key that types a character.
int? namedKeysym(LogicalKeyboardKey key) => _named[key];

/// The keysym of a character (Latin-1 as it is, the rest as 0x01000000 plus
/// the code point).
int keysymForChar(int ch) => (ch >= 0x20 && ch <= 0x7e) || (ch >= 0xa0 && ch <= 0xff) ? ch : 0x01000000 | ch;

/// Whether [ch] is a character a key types (not a control character).
bool isPrintable(int ch) => ch >= 0x20 && ch != 0x7f && !(ch >= 0x80 && ch < 0xa0);

// USB HID keyboard usages (page 7, what Flutter's PhysicalKeyboardKey.usbHidUsage carries) to
// XT set 1 scancodes in QEMU's numbering: a key sent after an 0xE0 prefix has 0x80 added (Right
// Ctrl is 0xE0 0x1D, so 0x9D). Pause (0xE1 ...) has none.
const Map<int, int> _hidToXt = {
  0x04: 0x1e, 0x05: 0x30, 0x06: 0x2e, 0x07: 0x20, 0x08: 0x12, 0x09: 0x21, 0x0a: 0x22, 0x0b: 0x23, // a to h
  0x0c: 0x17, 0x0d: 0x24, 0x0e: 0x25, 0x0f: 0x26, 0x10: 0x32, 0x11: 0x31, 0x12: 0x18, 0x13: 0x19, // i to p
  0x14: 0x10, 0x15: 0x13, 0x16: 0x1f, 0x17: 0x14, 0x18: 0x16, 0x19: 0x2f, 0x1a: 0x11, 0x1b: 0x2d, // q to x
  0x1c: 0x15, 0x1d: 0x2c, // y, z
  0x1e: 0x02, 0x1f: 0x03, 0x20: 0x04, 0x21: 0x05, 0x22: 0x06, 0x23: 0x07, 0x24: 0x08, 0x25: 0x09, // 1 to 8
  0x26: 0x0a, 0x27: 0x0b, // 9, 0
  0x28: 0x1c, 0x29: 0x01, 0x2a: 0x0e, 0x2b: 0x0f, 0x2c: 0x39, // Enter, Escape, Backspace, Tab, Space
  0x2d: 0x0c, 0x2e: 0x0d, 0x2f: 0x1a, 0x30: 0x1b, 0x31: 0x2b, 0x32: 0x2b, // - = [ ] \ (non-US #)
  0x33: 0x27, 0x34: 0x28, 0x35: 0x29, 0x36: 0x33, 0x37: 0x34, 0x38: 0x35, 0x39: 0x3a, // ; ' ` , . / CapsLock
  0x3a: 0x3b, 0x3b: 0x3c, 0x3c: 0x3d, 0x3d: 0x3e, 0x3e: 0x3f, 0x3f: 0x40, // F1 to F6
  0x40: 0x41, 0x41: 0x42, 0x42: 0x43, 0x43: 0x44, 0x44: 0x57, 0x45: 0x58, // F7 to F12
  0x46: 0xb7, 0x47: 0x46, // PrintScreen, ScrollLock
  0x49: 0xd2, 0x4a: 0xc7, 0x4b: 0xc9, 0x4c: 0xd3, 0x4d: 0xcf, 0x4e: 0xd1, // Insert Home PgUp Delete End PgDn
  0x4f: 0xcd, 0x50: 0xcb, 0x51: 0xd0, 0x52: 0xc8, // Right Left Down Up
  0x53: 0x45, 0x54: 0xb5, 0x55: 0x37, 0x56: 0x4a, 0x57: 0x4e, 0x58: 0x9c, // NumLock, keypad / * - + Enter
  0x59: 0x4f, 0x5a: 0x50, 0x5b: 0x51, 0x5c: 0x4b, 0x5d: 0x4c, 0x5e: 0x4d, // keypad 1 to 6
  0x5f: 0x47, 0x60: 0x48, 0x61: 0x49, 0x62: 0x52, 0x63: 0x53, 0x67: 0x59, // keypad 7 8 9 0 . =
  0x64: 0x56, 0x65: 0xdd, // the key beside left Shift (ISO), Menu
  0x68: 0x64, 0x69: 0x65, 0x6a: 0x66, 0x6b: 0x67, 0x6c: 0x68, 0x6d: 0x69, // F13 to F18
  0x6e: 0x6a, 0x6f: 0x6b, 0x70: 0x6c, 0x71: 0x6d, 0x72: 0x6e, 0x73: 0x76, // F19 to F24
  0x87: 0x73, 0x88: 0x70, 0x89: 0x7d, 0x8a: 0x79, 0x8b: 0x7b, // Ro, Katakana/Hiragana, Yen, Henkan, Muhenkan
  0xe0: 0x1d, 0xe1: 0x2a, 0xe2: 0x38, 0xe3: 0xdb, // left Ctrl, Shift, Alt, Meta
  0xe4: 0x9d, 0xe5: 0x36, 0xe6: 0xb8, 0xe7: 0xdc, // right Ctrl, Shift, Alt, Meta
};

/// The key's scancode (QEMU's numbering), or 0 when it has none here.
int scancodeFor(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >> 16 != 0x07) return 0;
  return _hidToXt[usage & 0xffff] ?? 0;
}

// What a US layout types on each key that types a character: (plain, with Shift).
const Map<int, (int, int)> _usChars = {
  0x1e: (0x31, 0x21), 0x1f: (0x32, 0x40), 0x20: (0x33, 0x23), 0x21: (0x34, 0x24), 0x22: (0x35, 0x25), // 1 to 5
  0x23: (0x36, 0x5e), 0x24: (0x37, 0x26), 0x25: (0x38, 0x2a), 0x26: (0x39, 0x28), 0x27: (0x30, 0x29), // 6 to 0
  0x2c: (0x20, 0x20), 0x2d: (0x2d, 0x5f), 0x2e: (0x3d, 0x2b), 0x2f: (0x5b, 0x7b), 0x30: (0x5d, 0x7d), // space - = [ ]
  0x31: (0x5c, 0x7c), 0x33: (0x3b, 0x3a), 0x34: (0x27, 0x22), 0x35: (0x60, 0x7e), 0x36: (0x2c, 0x3c), // \ ; ' ` ,
  0x37: (0x2e, 0x3e), 0x38: (0x2f, 0x3f), // . /
};

/// What a US layout types on [key], plain and with Shift, or null for a key
/// that types no character there.
(int, int)? usCharsOf(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >> 16 != 0x07) return null;
  final u = usage & 0xffff;
  if (u >= 0x04 && u <= 0x1d) return (0x61 + u - 0x04, 0x41 + u - 0x04);
  return _usChars[u];
}

/// The key a character is on in a US layout, and whether it needs Shift; null
/// for a character no US key types.
(PhysicalKeyboardKey, bool)? usKey(int ch) {
  PhysicalKeyboardKey k(int usage) => PhysicalKeyboardKey(0x00070000 | usage);
  if (ch >= 0x61 && ch <= 0x7a) return (k(0x04 + ch - 0x61), false);
  if (ch >= 0x41 && ch <= 0x5a) return (k(0x04 + ch - 0x41), true);
  for (final MapEntry(key: usage, value: (plain, shifted)) in _usChars.entries) {
    if (plain == ch) return (k(usage), false);
    if (shifted == ch) return (k(usage), true);
  }
  return null;
}
