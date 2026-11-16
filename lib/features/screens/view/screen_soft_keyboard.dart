// Remote screens (4.0): a phone's soft keyboard. An input method commits text
// and deletions into an editing value, not keys; this client keeps that value
// at two spaces, compares each change with them (what went becomes BackSpace
// keys, what came becomes text) and puts the two spaces back. Visible-password
// input, so keyboards neither compose nor correct nor learn what is typed on a
// remote machine (the spike's, day 4; Gboard checked on the emulator).
import 'package:flutter/services.dart';

import 'keysyms.dart';
import 'screen_keyboard.dart';

class ScreenSoftKeyboard with TextInputClient {
  ScreenSoftKeyboard(this.keyboard);

  final ScreenKeyboard keyboard;

  /// RDP: characters on US keys go as their scancodes ([ScreenKeyboard.typeText]).
  bool usScancodes = false;

  TextInputConnection? _connection;

  static const _base = TextEditingValue(text: '  ', selection: TextSelection.collapsed(offset: 2));
  TextEditingValue _value = _base;

  bool get shown => _connection?.attached ?? false;

  /// Shows the keyboard ([appearance]: the app's theme's brightness).
  void show({Brightness appearance = Brightness.dark}) {
    if (!shown) {
      _connection = TextInput.attach(
        this,
        TextInputConfiguration(
          inputType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          enableDeltaModel: false,
          inputAction: TextInputAction.newline,
          keyboardAppearance: appearance,
        ),
      );
      _value = _base;
      _connection!.setEditingState(_base);
    }
    _connection!.show();
  }

  void hide() {
    _connection?.close();
    _connection = null;
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    // Compared with the two spaces, not with a value still composing: the
    // composed text is sent once, when it is committed.
    final old = _base.text, now = value.text;
    // Still composing (a keyboard that ignores visible-password): wait for the commit.
    if (value.composing.isValid && !value.composing.isCollapsed) {
      _value = value;
      return;
    }
    var p = 0;
    while (p < old.length && p < now.length && old.codeUnitAt(p) == now.codeUnitAt(p)) {
      p++;
    }
    final deleted = old.length - p;
    final inserted = now.substring(p);
    if (deleted > 0) keyboard.backspace(deleted);
    if (inserted.isNotEmpty) keyboard.typeText(inserted, usScancodes: usScancodes);
    if (now != _base.text || value.selection != _base.selection) {
      _value = _base;
      _connection?.setEditingState(_base);
    } else {
      _value = value;
    }
  }

  @override
  void performAction(TextInputAction action) => keyboard.tapKey(ScreenKey.enter);

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
  }
}
