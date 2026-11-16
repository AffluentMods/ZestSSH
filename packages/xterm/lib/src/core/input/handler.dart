import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/input/keytab/keytab.dart';
import 'package:xterm/src/core/input/keytab/keytab_record.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/core/platform.dart';

/// The key event received from the keyboard, along with the state of the
/// modifier keys and state of the terminal. Typically consumed by the
/// [TerminalInputHandler] to produce a escape sequence that can be recognized
/// by the terminal.
///
/// See also:
/// - [TerminalInputHandler]
class TerminalKeyboardEvent {
  final TerminalKey key;

  final bool shift;

  final bool ctrl;

  final bool alt;

  final TerminalState state;

  final bool altBuffer;

  final TerminalTargetPlatform platform;

  /// Whether Alt (Option on a Mac, an iPad and an iPhone) is Meta: held with
  /// a key that types a character, it sends ESC and that character. Unless
  /// told, it is on everywhere but on a Mac, where Option types the special
  /// characters of its layout (as Terminal.app and iTerm2 have it until told
  /// otherwise).
  final bool altIsMeta;

  /// The character the key typed, as the keyboard's layout makes it, where
  /// that is known and Alt did not change it (a Windows or Linux keyboard's
  /// Alt+Shift+7 on a German layout is '/'). Null where it is not: the key's
  /// own character on a US layout is used then ([AltInputHandler]).
  final String? character;

  TerminalKeyboardEvent({
    required this.key,
    required this.shift,
    required this.ctrl,
    required this.alt,
    required this.state,
    required this.altBuffer,
    required this.platform,
    bool? altIsMeta,
    this.character,
  }) : altIsMeta = altIsMeta ?? platform != TerminalTargetPlatform.macos;

  TerminalKeyboardEvent copyWith({
    TerminalKey? key,
    bool? shift,
    bool? ctrl,
    bool? alt,
    TerminalState? state,
    bool? altBuffer,
    TerminalTargetPlatform? platform,
    bool? altIsMeta,
    String? character,
  }) {
    return TerminalKeyboardEvent(
      key: key ?? this.key,
      shift: shift ?? this.shift,
      ctrl: ctrl ?? this.ctrl,
      alt: alt ?? this.alt,
      state: state ?? this.state,
      altBuffer: altBuffer ?? this.altBuffer,
      platform: platform ?? this.platform,
      altIsMeta: altIsMeta ?? this.altIsMeta,
      character: character ?? this.character,
    );
  }
}

/// TerminalInputHandler contains the logic for translating a [TerminalKeyboardEvent]
/// into escape sequences that can be recognized by the terminal.
abstract class TerminalInputHandler {
  /// Translates a [TerminalKeyboardEvent] into an escape sequence. If the event
  /// cannot be translated, null is returned.
  String? call(TerminalKeyboardEvent event);
}

/// A [TerminalInputHandler] that chains multiple handlers together. If any
/// handler returns a non-null value, it is returned. Otherwise, null is
/// returned.
class CascadeInputHandler implements TerminalInputHandler {
  final List<TerminalInputHandler> _handlers;

  const CascadeInputHandler(this._handlers);

  @override
  String? call(TerminalKeyboardEvent event) {
    for (var handler in _handlers) {
      final result = handler(event);
      if (result != null) {
        return result;
      }
    }
    return null;
  }
}

/// The default input handler for the terminal. That is composed of a
/// [KeytabInputHandler], a [CtrlInputHandler], and a [AltInputHandler].
///
/// It's possible to override the default input handler behavior by chaining
/// another input handler before or after the default input handler using
/// [CascadeInputHandler].
///
/// See also:
///  * [CascadeInputHandler]
const defaultInputHandler = CascadeInputHandler([
  KeytabInputHandler(),
  CtrlInputHandler(),
  AltInputHandler(),
]);

/// A [TerminalInputHandler] that translates key events according to a keytab
/// file. If no keytab is provided, [Keytab.defaultKeytab] is used.
class KeytabInputHandler implements TerminalInputHandler {
  const KeytabInputHandler([this.keytab]);

  final Keytab? keytab;

  @override
  String? call(TerminalKeyboardEvent event) {
    final keytab = this.keytab ?? Keytab.defaultKeytab;

    final record = keytab.find(
      event.key,
      ctrl: event.ctrl,
      alt: event.alt,
      shift: event.shift,
      newLineMode: event.state.lineFeedMode,
      appCursorKeys: event.state.cursorKeysMode,
      appKeyPad: event.state.appKeypadMode,
      appScreen: event.altBuffer,
      macos: event.platform == TerminalTargetPlatform.macos,
    );

    if (record == null) {
      return null;
    }

    // An entry that names an operation (Konsole's scrollLineUp and the like)
    // is nothing to type: its name went to the host as if typed.
    if (record.action.type != KeytabActionType.input) {
      return null;
    }

    var result = record.action.unescapedValue();
    result = insertModifiers(event, result);
    return result;
  }

  String insertModifiers(TerminalKeyboardEvent event, String action) {
    String? code;

    if (event.shift && event.alt && event.ctrl) {
      code = '8';
    } else if (event.ctrl && event.alt) {
      code = '7';
    } else if (event.shift && event.ctrl) {
      code = '6';
    } else if (event.ctrl) {
      code = '5';
    } else if (event.shift && event.alt) {
      code = '4';
    } else if (event.alt) {
      code = '3';
    } else if (event.shift) {
      code = '2';
    }

    if (code != null) {
      return action.replaceAll('*', code);
    }

    return action;
  }
}

/// A [TerminalInputHandler] that translates ctrl + key events into escape
/// sequences. For example, ctrl + a becomes ^A.
///
/// Besides the letters, the keys xterm gives a control character of their
/// own (ZestSSH: they sent nothing): Ctrl+[ is ESC, Ctrl+\ 0x1C (SIGQUIT in a
/// shell), Ctrl+] 0x1D (telnet's and many a REPL's escape), Ctrl+/ and Ctrl+_
/// 0x1F (undo in readline and emacs), Ctrl+2, Ctrl+@ and Ctrl+Space NUL
/// (emacs' mark), Ctrl+^ 0x1E, and Ctrl+3 to Ctrl+8 the old terminals' row
/// of them: 0x1B, 0x1C, 0x1D, 0x1E, 0x1F and DEL.
class CtrlInputHandler implements TerminalInputHandler {
  const CtrlInputHandler();

  /// The keys that mean a control character with Ctrl alone.
  static const _plain = <TerminalKey, int>{
    TerminalKey.bracketLeft: 0x1b,
    TerminalKey.backslash: 0x1c,
    TerminalKey.bracketRight: 0x1d,
    TerminalKey.slash: 0x1f,
    TerminalKey.digit2: 0x00,
    TerminalKey.digit3: 0x1b,
    TerminalKey.digit4: 0x1c,
    TerminalKey.digit5: 0x1d,
    TerminalKey.digit6: 0x1e,
    TerminalKey.digit7: 0x1f,
    TerminalKey.digit8: 0x7f,
  };

  /// The keys that mean one with Ctrl and Shift, the characters a US layout
  /// types with Shift on them: @ (Shift+2), ^ (Shift+6) and _ (Shift+-).
  static const _shifted = <TerminalKey, int>{
    TerminalKey.digit2: 0x00,
    TerminalKey.digit6: 0x1e,
    TerminalKey.minus: 0x1f,
  };

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!event.ctrl || event.alt) {
      return null;
    }

    final key = event.key;

    if (event.shift) {
      final code = _shifted[key];
      return code == null ? null : String.fromCharCode(code);
    }

    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      final input = key.index - TerminalKey.keyA.index + 1;
      return String.fromCharCode(input);
    }

    final code = _plain[key];
    return code == null ? null : String.fromCharCode(code);
  }
}

/// A [TerminalInputHandler] that translates alt + key events into escape
/// sequences. For example, alt + a becomes ^[a, and alt + shift + a ^[A.
///
/// ESC and the character the key types: lowercase unless Shift is held, for
/// letters, digits and punctuation, with or without Shift (ZestSSH: it sent
/// ESC and an uppercase letter for every letter, and nothing for the rest, so
/// Alt+b went to the shell as Alt+Shift+B and Alt+. did nothing). Only where
/// Alt is Meta ([TerminalKeyboardEvent.altIsMeta]): on a Mac, unless told,
/// Option types its layout's characters instead.
class AltInputHandler implements TerminalInputHandler {
  const AltInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!event.alt || event.ctrl || !event.altIsMeta) {
      return null;
    }

    final typed = event.character;
    final char = typed != null && _printable(typed) ? typed : altKeyCharacter(event.key, shift: event.shift);
    if (char == null) {
      return null;
    }
    return '\x1b$char';
  }

  /// One character of printable ASCII, a space included.
  static bool _printable(String text) =>
      text.length == 1 && text.codeUnitAt(0) >= 0x20 && text.codeUnitAt(0) <= 0x7e;
}

/// The character [key] types on a US layout, with Shift or without: a
/// letter, a digit, a space or a punctuation mark. Null for any other key.
/// (For Alt as Meta where the layout's own character is not known: Option
/// on a Mac or an iPad makes another of it.)
String? altKeyCharacter(TerminalKey key, {required bool shift}) {
  if (key.index >= TerminalKey.keyA.index && key.index <= TerminalKey.keyZ.index) {
    return String.fromCharCode((shift ? 0x41 : 0x61) + key.index - TerminalKey.keyA.index);
  }
  final pair = _usKeys[key];
  if (pair == null) return null;
  return shift ? pair[1] : pair[0];
}

/// What a key that is no letter types on a US layout, without Shift and with
/// it.
const _usKeys = <TerminalKey, String>{
  TerminalKey.digit1: '1!',
  TerminalKey.digit2: '2@',
  TerminalKey.digit3: '3#',
  TerminalKey.digit4: r'4$',
  TerminalKey.digit5: '5%',
  TerminalKey.digit6: '6^',
  TerminalKey.digit7: '7&',
  TerminalKey.digit8: '8*',
  TerminalKey.digit9: '9(',
  TerminalKey.digit0: '0)',
  TerminalKey.minus: '-_',
  TerminalKey.equal: '=+',
  TerminalKey.bracketLeft: '[{',
  TerminalKey.bracketRight: ']}',
  TerminalKey.backslash: r'\|',
  TerminalKey.semicolon: ';:',
  TerminalKey.quote: '\'"',
  TerminalKey.backquote: '`~',
  TerminalKey.comma: ',<',
  TerminalKey.period: '.>',
  TerminalKey.slash: '/?',
  TerminalKey.space: '  ',
};
