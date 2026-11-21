import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
    this.personalizedLearning = false,
    this.showKeyboard = true,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  /// Whether the on-screen keyboard may learn from what is typed here (its
  /// dictionary, what it suggests later). Off, an Android keyboard is asked
  /// not to, which some answer with a private mode of their own. It means
  /// something on Android only.
  final bool personalizedLearning;

  /// Whether taking the focus asks for the on-screen keyboard. False while a
  /// hardware keyboard is typed on (a phone's or a tablet's terminal): the
  /// input is still connected, so an input method's composing goes on as
  /// before, and the keyboard is not asked to come up. [requestKeyboard]
  /// with show asks for it all the same.
  final bool showKeyboard;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
    _connectIfFocusedAlready();
  }

  /// Built anew while its focus node, which outlives it, has the focus
  /// already (tmux's panes drawn again by Resync panes, a pane moved in the
  /// tree): no change of focus comes to connect the input on, and the view
  /// before it closed its connection as it went. Connected a frame later,
  /// the on-screen keyboard left as it is: without it a keyboard's letters,
  /// which come through this connection on a phone or a tablet, went nowhere
  /// until a tap, while Enter (a plain key) still arrived (seen on a tablet
  /// with a keyboard, 21 November 2026).
  void _connectIfFocusedAlready() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.focusNode.hasFocus && !hasInputConnection) _openInputConnection(show: false);
    });
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
    if (widget.focusNode != oldWidget.focusNode) _connectIfFocusedAlready();

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }

    // What the keyboard may learn, or the keyboard asked for (the compact
    // one, a setting of the app), changed while it is up: it is told now,
    // and not when the terminal is next left and come back to.
    if ((widget.personalizedLearning != oldWidget.personalizedLearning || widget.inputType != oldWidget.inputType) &&
        hasInputConnection) {
      _connection!.updateConfig(_config);
    }
  }

  /// What the keyboard is told of this input: never to correct or suggest
  /// (a terminal takes what is typed as it is), and whether it may learn.
  TextInputConfiguration get _config => TextInputConfiguration(
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: widget.personalizedLearning,
      );

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  /// Takes the focus and connects the input; [show] asks for the on-screen
  /// keyboard as well (unless told, where [CustomTextEdit.showKeyboard] says).
  void requestKeyboard({bool? show}) {
    final wanted = show ?? widget.showKeyboard;
    if (widget.focusNode.hasFocus) {
      _openInputConnection(show: wanted);
    } else {
      _showOnFocus = wanted;
      widget.focusNode.requestFocus();
    }
  }

  /// What the focus being asked for by [requestKeyboard] is to do with the
  /// keyboard when it comes.
  bool? _showOnFocus;

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (_currentEditingState.composing.isCollapsed) {
      return widget.onKeyEvent(focusNode, event);
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus) {
      if (widget.focusNode.consumeKeyboardToken()) {
        _openInputConnection(show: _showOnFocus ?? widget.showKeyboard);
      } else {
        // The focus came back by itself (a menu or a dialog over the
        // terminal closed, the panes it stood behind went): connected
        // again, the on-screen keyboard left as it is. A keyboard's letters
        // come through this connection on a phone or a tablet, and with the
        // focus back but no connection Enter and the arrows arrived and the
        // letters went nowhere until a tap (seen on a tablet with a
        // keyboard, 21 November 2026).
        _openInputConnection(show: false);
      }
    } else {
      _closeInputConnectionIfNeeded();
    }
    _showOnFocus = null;
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection({bool show = true}) {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      if (show) _connection!.show();
    } else {
      _connection = TextInput.attach(this, _config);

      if (show) _connection!.show();

      // setEditableRect(Rect.zero, Rect.zero);

      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentEditingState = value;

    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    if (_currentEditingState.text.length < _initEditingState.text.length) {
      widget.onDelete();
    } else {
      final textDelta = _currentEditingState.text.substring(
        _initEditingState.text.length,
      );

      widget.onInsert(textDelta);
    }

    // Reset editing state if composing is done
    if (_currentEditingState.composing.isCollapsed &&
        _currentEditingState.text != _initEditingState.text) {
      _connection!.setEditingState(_initEditingState);
    }
  }

  @override
  void performAction(TextInputAction action) {
    // print('performAction $action');
    widget.onAction(action);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    // print('connectionClosed');
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
