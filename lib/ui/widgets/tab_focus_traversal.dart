import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Makes Tab and Shift+Tab move focus everywhere, including out of
/// multi-line text fields.
///
/// Flutter maps Tab to focus traversal at the app root, but the mapping only
/// wins when the traversal action reports success; when it does not, the
/// key falls through to the platform text input and a multi-line field eats
/// it as a character, so a form stops walking at its first big field. This
/// widget sits between every field and the root (via `MaterialApp.builder`),
/// sees the key before the root shortcuts do, and moves focus itself.
///
/// Fields that genuinely need a tab character (the file editor, script
/// bodies) opt out by wrapping themselves in [KeepTabKeys]. The terminal
/// never reaches this handler: its own focus node consumes every key it
/// sends to the remote shell.
class TabMovesFocus extends StatelessWidget {
  const TabMovesFocus({super.key, required this.child});

  final Widget child;

  static KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      return KeyEventResult.ignored; // Ctrl+Tab and friends belong to the shell.
    }
    final focused = FocusManager.instance.primaryFocus;
    final context = focused?.context;
    if (focused == null || context == null) return KeyEventResult.ignored;
    if (context.findAncestorWidgetOfExactType<KeepTabKeys>() != null) {
      return KeyEventResult.ignored; // A real tab character is wanted here.
    }
    final moved =
        keys.isShiftPressed ? focused.previousFocus() : focused.nextFocus();
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}

/// Marks a subtree whose text fields want Tab to insert a tab character
/// instead of moving focus (a code or file editor). See [TabMovesFocus].
///
/// It does the insertion itself: this node sits below [TabMovesFocus] and
/// the root shortcuts, so it sees the key first, writes a tab at the caret
/// of the focused field, and stops the event there. Shift+Tab is left alone
/// and still walks focus backwards.
class KeepTabKeys extends StatelessWidget {
  const KeepTabKeys({super.key, this.types = '\t', required this.child});

  final Widget child;

  /// What Tab types: a tab character, or spaces where a file may hold no tab
  /// (YAML, whose indentation is spaces only).
  final String types;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    final editable = context?.findAncestorStateOfType<EditableTextState>();
    if (editable == null || editable.widget.readOnly) {
      return KeyEventResult.ignored;
    }
    final value = editable.textEditingValue;
    final selection = value.selection;
    if (!selection.isValid) return KeyEventResult.ignored;
    editable.userUpdateTextEditingValue(
      value.replaced(selection, types),
      SelectionChangedCause.keyboard,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}
