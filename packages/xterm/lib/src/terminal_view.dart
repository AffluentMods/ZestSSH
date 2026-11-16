import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';

import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/gesture/gesture_handler.dart';
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/src/ui/keyboard_visibility.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/scroll_handler.dart';
import 'package:xterm/src/ui/shortcut/actions.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

class TerminalView extends StatefulWidget {
  const TerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.backgroundOpacity = 1,
    this.focusNode,
    this.autofocus = false,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapUp,
    this.mouseCursor = SystemMouseCursors.text,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.alwaysShowCursor = false,
    this.cursorBlink = false,
    this.hideCursor = false,
    this.hideCursorWhileOutput = false,
    this.deleteDetection = false,
    this.personalizedLearning = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
    this.smoothScrollDuration = const Duration(milliseconds: 120),
    this.showScrollToBottomButton = true,
    this.enableUrlDetection = false,
    this.onUrlTap,
    this.urlColor = const Color(0xFF5599DD),
    this.altIsMeta,
    this.keyboardOnTap = true,
    this.onKeyboardInput,
    this.onKeyboardPaste,
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  final TerminalController? controller;

  /// The theme to use for this terminal.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  final TextScaler? textScaler;

  /// Padding around the inner [Scrollable] widget.
  final EdgeInsets? padding;

  /// Scroll controller for the inner [Scrollable] widget.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Opacity of the terminal background. Set to 0 to make the terminal
  /// background transparent.
  final double backgroundOpacity;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// Function called when the user lets go of the middle button where it was
  /// pressed (a middle click). Not called when the program in the terminal
  /// takes the mouse: the click is its own then.
  final void Function(TapUpDetails, CellOffset)? onTertiaryTapUp;

  /// The mouse cursor for mouse pointers that are hovering over the terminal.
  /// [SystemMouseCursors.text] by default.
  final MouseCursor mouseCursor;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Whether to always show the cursor. This is useful for debugging.
  /// [false] by default.
  final bool alwaysShowCursor;

  /// Whether the cursor blinks while this view has keyboard focus. The cursor
  /// is shown solid whenever the view is unfocused, and any key input or
  /// terminal output shows it and restarts the blink period so it never
  /// blinks off while typing. [false] by default.
  final bool cursorBlink;

  /// Never draw the cursor, whatever the program asks (ZestSSH, 4.0: a
  /// person's choice for full-screen programs). [false] by default.
  final bool hideCursor;

  /// Hide the cursor while output is arriving that moves it about (a
  /// full-screen program redrawing in pieces), and draw it again once no
  /// output has come for [RenderTerminal.cursorOutputQuiet]. Output that
  /// moves it a cell or two along its line (what is typed, echoed) leaves it
  /// shown. [false] by default.
  final bool hideCursorWhileOutput;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Prefered on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Whether the on-screen keyboard may learn from what is typed into the
  /// terminal. [false] by default: an Android keyboard is then asked not
  /// to, which some answer with a private mode of their own.
  final bool personalizedLearning;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  final bool simulateScroll;

  /// Duration of the smooth scroll animation when auto-scrolling to the bottom
  /// on new output. Set to [Duration.zero] to disable smooth scrolling and use
  /// jump scrolling. Defaults to 120ms.
  final Duration smoothScrollDuration;

  /// Whether to show a floating "scroll to bottom" button when the user has
  /// scrolled up and new output arrives. Defaults to true.
  final bool showScrollToBottomButton;

  /// Whether to automatically detect and highlight URLs in terminal output.
  /// When enabled, http:// and https:// URLs are underlined. Use [onUrlTap]
  /// to handle clicks. [false] by default.
  final bool enableUrlDetection;

  /// Called when the user Ctrl+Clicks (desktop) or long-presses (mobile) on
  /// a detected URL. The callback receives the URL string so the parent app
  /// can open it.
  final void Function(String url)? onUrlTap;

  /// The color used for URL underlines. Defaults to a muted blue.
  final Color urlColor;

  /// Whether Alt (Option on a Mac, an iPad and an iPhone) held with a key
  /// that types a character sends ESC and that character, as Meta. Null:
  /// everywhere but on a Mac, where Option types its layout's special
  /// characters unless told otherwise (Terminal.app's and iTerm2's default).
  final bool? altIsMeta;

  /// Whether a tap on the terminal asks for the on-screen keyboard. False
  /// while a hardware keyboard is typed on: the tap gives the terminal the
  /// keyboard's input, and the on-screen one stays down
  /// ([TerminalViewState.requestKeyboard] still brings it up).
  final bool keyboardOnTap;

  /// Called when the on-screen keyboard or an input method typed into the
  /// terminal through the text input (text, a deletion, its Enter), never
  /// for a key event. (A hardware keyboard's letters come that way as well,
  /// on a phone and a tablet, a moment after their key events.)
  final VoidCallback? onKeyboardInput;

  /// Called when the on-screen keyboard or an input method committed a paste
  /// and no typing ([Terminal.isCommittedPaste]), with the text as it came: for
  /// the paste whoever shows this view goes by, with its questions. Not set,
  /// it goes to [Terminal.paste].
  final void Function(String text)? onKeyboardPaste;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView> {
  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();

  String? _composingText;

  late TerminalController _controller;

  late ScrollController _scrollController;

  /// Whether the scroll-to-bottom button should be visible.
  final _showScrollToBottom = ValueNotifier<bool>(false);

  /// Whether an animated scroll is currently in progress.
  bool _isAnimatingScroll = false;

  RenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as RenderTerminal;

  /// Scroll so that buffer line [line] is about the middle of the view, as
  /// far as the scroll bounds let it (a find's current match). Returns false
  /// where nothing is laid out to scroll yet. (ZestSSH: a find showed a
  /// match's place in the count only.)
  bool scrollToLine(int line) {
    if (!_scrollController.hasClients) return false;
    final pos = _scrollController.position;
    final lineHeight = renderTerminal.lineHeight;
    final target = (line * lineHeight + lineHeight / 2 - pos.viewportDimension / 2)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() >= 0.5) _scrollController.jumpTo(target);
    return true;
  }

  /// Scroll the viewport by [delta] pixels, clamped to the scroll bounds.
  /// Returns true if the offset actually moved (false if already at an
  /// edge). Drives drag-select auto-scroll from the gesture layer.
  bool scrollByPixels(double delta) {
    if (!_scrollController.hasClients) return false;
    final pos = _scrollController.position;
    final target =
        (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < 0.5) return false;
    _scrollController.jumpTo(target);
    return true;
  }

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    _scrollController.addListener(_onScrollControllerChanged);
    super.initState();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    if (oldWidget.focusNode != widget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
    }
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScrollControllerChanged);
    _showScrollToBottom.dispose();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _shortcutManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Scrollable(
      key: _scrollableKey,
      controller: _scrollController,
      viewportBuilder: (context, offset) {
        return _TerminalView(
          key: _viewportKey,
          terminal: widget.terminal,
          controller: _controller,
          offset: offset,
          padding: MediaQuery.of(context).padding,
          autoResize: widget.autoResize,
          textStyle: widget.textStyle,
          textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
          theme: widget.theme,
          focusNode: _focusNode,
          cursorType: widget.cursorType,
          alwaysShowCursor: widget.alwaysShowCursor,
          cursorBlink: widget.cursorBlink,
          hideCursor: widget.hideCursor,
          hideCursorWhileOutput: widget.hideCursorWhileOutput,
          onEditableRect: _onEditableRect,
          composingText: _composingText,
          enableUrlDetection: widget.enableUrlDetection,
          urlColor: widget.urlColor,
          onScrollStateChanged: _onRenderScrollStateChanged,
        );
      },
    );

    child = TerminalScrollGestureHandler(
      terminal: widget.terminal,
      simulateScroll: widget.simulateScroll,
      getCellOffset: (offset) => renderTerminal.getCellOffset(offset),
      getLineHeight: () => renderTerminal.lineHeight,
      child: child,
    );

    if (!widget.hardwareKeyboardOnly) {
      child = CustomTextEdit(
        key: _customTextEditKey,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        inputType: widget.keyboardType,
        keyboardAppearance: widget.keyboardAppearance,
        deleteDetection: widget.deleteDetection,
        personalizedLearning: widget.personalizedLearning,
        showKeyboard: widget.keyboardOnTap,
        onInsert: _onInsert,
        onDelete: () {
          widget.onKeyboardInput?.call();
          _resetCursorBlink();
          _scrollToBottom();
          widget.terminal.keyInput(TerminalKey.backspace);
        },
        onComposing: _onComposing,
        onAction: (action) {
          widget.onKeyboardInput?.call();
          _resetCursorBlink();
          _scrollToBottom();
          if (action == TextInputAction.done || action == TextInputAction.newline) {
            widget.terminal.keyInput(TerminalKey.enter);
          }
        },
        onKeyEvent: _handleKeyEvent,
        readOnly: widget.readOnly,
        child: child,
      );
    } else if (!widget.readOnly) {
      // Only listen for key input from a hardware keyboard.
      child = CustomKeyboardListener(
        child: child,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onInsert: _onInsert,
        onComposing: _onComposing,
        onKeyEvent: _handleKeyEvent,
      );
    }

    child = TerminalActions(
      terminal: widget.terminal,
      controller: _controller,
      child: child,
    );

    child = KeyboardVisibilty(
      onKeyboardShow: _onKeyboardShow,
      child: child,
    );

    child = TerminalGestureHandler(
      terminalView: this,
      terminalController: _controller,
      onTapUp: _onTapUp,
      onSingleTapUp: _onSingleTapUp,
      onTapDown: _onTapDown,
      onSecondaryTapDown:
          widget.onSecondaryTapDown != null ? _onSecondaryTapDown : null,
      onSecondaryTapUp:
          widget.onSecondaryTapUp != null ? _onSecondaryTapUp : null,
      onTertiaryTapUp:
          widget.onTertiaryTapUp != null ? _onTertiaryTapUp : null,
      onUrlLongPress: widget.enableUrlDetection ? _onUrlLongPress : null,
      onUrlClick: widget.enableUrlDetection ? _onUrlClick : null,
      readOnly: widget.readOnly,
      child: child,
    );

    child = MouseRegion(
      cursor: widget.mouseCursor,
      child: child,
    );

    child = Container(
      color: widget.theme.background.withOpacity(widget.backgroundOpacity),
      padding: widget.padding,
      child: child,
    );

    if (widget.showScrollToBottomButton) {
      child = Stack(
        children: [
          child,
          _buildScrollToBottomButton(),
        ],
      );
    }

    return child;
  }

  Widget _buildScrollToBottomButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: _showScrollToBottom,
      builder: (context, show, _) {
        return AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          right: 16,
          bottom: show ? 16 : -48,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Material(
              color: widget.theme.foreground.withValues(alpha: 0.15),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _scrollToBottom,
                child: Icon(
                  Icons.keyboard_arrow_down,
                  color: widget.theme.foreground.withValues(alpha: 0.8),
                  size: 22,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Brings up the on-screen keyboard, whatever [TerminalView.keyboardOnTap]
  /// says (a key that asks for it).
  void requestKeyboard() {
    _customTextEditKey.currentState?.requestKeyboard(show: true);
  }

  void closeKeyboard() {
    _customTextEditKey.currentState?.closeKeyboard();
  }

  Rect get cursorRect {
    return renderTerminal.cursorOffset & renderTerminal.cellSize;
  }

  Rect get globalCursorRect {
    return renderTerminal.localToGlobal(renderTerminal.cursorOffset) &
        renderTerminal.cellSize;
  }

  void _onTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapUp?.call(details, offset);
  }

  /// Ctrl+click (Command+click on a Mac) on a link opens it. This was written
  /// into [_onTapUp], which nothing ever calls (the gesture detector takes an
  /// `onTapUp` and does not use it, here as in the package this comes from):
  /// on a computer a link was underlined and could not be opened.
  void _onUrlClick(Offset localPosition) {
    if (widget.onUrlTap == null) return;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return;
    final url = renderTerminal.getUrlAt(localPosition);
    if (url != null) widget.onUrlTap!(url.url);
  }

  /// The finger (or pen) now on the terminal asks for the keyboard when it is
  /// let go as a tap ([_onSingleTapUp]).
  bool _keyboardOnRelease = false;

  /// A press on the terminal: a selection there is cleared, or the terminal
  /// takes the keyboard. A mouse's click takes it as the button goes down,
  /// as it always did on a computer. A finger's waits for the tap to end:
  /// the press may yet be a long one, which selects a word, or the start of
  /// a scroll, and neither brings the on-screen keyboard up. (It came up
  /// a moment after every finger went down: on a phone whose keyboard was
  /// closed with Back, a long press to copy a word brought it up over the
  /// text, in 3.0.0.)
  void _onTapDown(TapDownDetails details) {
    _keyboardOnRelease = false;
    if (_controller.selection != null) {
      _controller.clearSelection();
    } else {
      if (!widget.hardwareKeyboardOnly) {
        if (_keyboardWaitsForRelease(details.kind)) {
          _keyboardOnRelease = true;
        } else {
          _customTextEditKey.currentState?.requestKeyboard(show: widget.keyboardOnTap);
        }
      } else {
        _focusNode.requestFocus();
      }
    }
  }

  /// A tap let go (no long press, no scroll, no double tap's second): the
  /// keyboard a finger's press left for now.
  void _onSingleTapUp(TapUpDetails details) {
    if (!_keyboardOnRelease) return;
    _keyboardOnRelease = false;
    _customTextEditKey.currentState?.requestKeyboard(show: widget.keyboardOnTap);
  }

  /// Whether a press of [kind] takes the keyboard only when its tap ends: a
  /// finger's and a pen's. A mouse's, a trackpad's and one of no known kind
  /// take it as they go down.
  static bool _keyboardWaitsForRelease(PointerDeviceKind? kind) =>
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  void _onSecondaryTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapDown?.call(details, offset);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapUp?.call(details, offset);
  }

  void _onTertiaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTertiaryTapUp?.call(details, offset);
  }

  /// Handles long-press URL activation on mobile. Returns true if a URL was
  /// found at the long-press position and the callback was invoked.
  bool _onUrlLongPress(Offset localPosition) {
    if (widget.onUrlTap == null) return false;
    final url = renderTerminal.getUrlAt(localPosition);
    if (url != null) {
      widget.onUrlTap!(url.url);
      return true;
    }
    return false;
  }

  bool get hasInputConnection {
    return _customTextEditKey.currentState?.hasInputConnection == true;
  }

  void _onInsert(String text) {
    if (!widget.hardwareKeyboardOnly) widget.onKeyboardInput?.call();
    _resetCursorBlink();

    if (Terminal.isCommittedPaste(text)) {
      final paste = widget.onKeyboardPaste;
      if (paste != null) {
        paste(text);
      } else {
        widget.terminal.paste(text);
      }
      _scrollToBottom();
      return;
    }

    final key = charToTerminalKey(text.trim());

    // On mobile platforms there is no guarantee that virtual keyboard will
    // generate hardware key events. So we need first try to send the key
    // as a hardware key event. If it fails, then we send it as a text input.
    final consumed = key == null ? false : widget.terminal.keyInput(key);

    if (!consumed) {
      widget.terminal.textInput(text);
    }

    _scrollToBottom();
  }

  void _onComposing(String? text) {
    setState(() => _composingText = text);
  }

  KeyEventResult _handleKeyEvent(FocusNode focusNode, KeyEvent event) {
    _resetCursorBlink();
    final resultOverride = widget.onKeyEvent?.call(focusNode, event);
    if (resultOverride != null && resultOverride != KeyEventResult.ignored) {
      return resultOverride;
    }

    // ignore: invalid_use_of_protected_member
    final shortcutResult = _shortcutManager.handleKeypress(
      focusNode.context!,
      event,
    );

    if (shortcutResult != KeyEventResult.ignored) {
      return shortcutResult;
    }

    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);

    if (key == null) {
      return KeyEventResult.ignored;
    }

    final keys = HardwareKeyboard.instance;

    // Shift+PgUp and Shift+PgDn page through the history here, as in xterm,
    // where the program is not full screen; a full-screen program (the
    // alternate screen: vim, less, tmux) has no history here and is sent
    // them. (They were sent to the shell, which typed 2~.)
    if ((key == TerminalKey.pageUp || key == TerminalKey.pageDown) &&
        keys.isShiftPressed &&
        !keys.isControlPressed &&
        !keys.isAltPressed &&
        !keys.isMetaPressed &&
        !widget.terminal.isUsingAltBuffer) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) _scrollPage(key == TerminalKey.pageUp ? -1 : 1);
      return KeyEventResult.handled;
    }

    final altIsMeta = widget.altIsMeta ?? defaultTargetPlatform != TargetPlatform.macOS;
    final handled = widget.terminal.keyInput(
      key,
      ctrl: keys.isControlPressed,
      alt: keys.isAltPressed,
      shift: keys.isShiftPressed,
      altIsMeta: altIsMeta,
      character: keys.isAltPressed ? _altBaseCharacter(event) : null,
    );

    if (handled) {
      _scrollToBottom();
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// The character a key held with Alt typed in the keyboard's own layout,
  /// where Alt left it as it is (Windows, Linux, Android: Alt+Shift+7 on a
  /// German layout is '/'). Null on a Mac and an iPad, where Option makes
  /// another character of it: the key's own is taken there.
  String? _altBaseCharacter(KeyEvent event) {
    if (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS) return null;
    final c = event.character;
    if (c == null || c.length != 1) return null;
    final code = c.codeUnitAt(0);
    return code >= 0x20 && code <= 0x7e ? c : null;
  }

  /// Scrolls the history by a page less a line, [direction] up (-1) or down.
  void _scrollPage(int direction) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final lineHeight = renderTerminal.lineHeight;
    final page = (pos.viewportDimension - lineHeight).clamp(lineHeight, double.infinity);
    scrollByPixels(direction * page);
  }

  void _onKeyboardShow() {
    if (_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  void _onScrollControllerChanged() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final isAtBottom =
        position.pixels >= position.maxScrollExtent - 1.0;
    if (isAtBottom) {
      _showScrollToBottom.value = false;
    }
  }

  void _onRenderScrollStateChanged() {
    if (!mounted) return;
    final rt = renderTerminal;
    _showScrollToBottom.value = rt.hasNewOutput && !rt.isAtBottom;
  }

  void _onEditableRect(Rect rect, Rect caretRect) {
    _customTextEditKey.currentState?.setEditableRect(rect, caretRect);
  }

  /// Key input shows the cursor and restarts its blink period (see
  /// [TerminalView.cursorBlink]). Terminal output does the same through the
  /// render object's own terminal listener.
  void _resetCursorBlink() {
    final render = _viewportKey.currentContext?.findRenderObject();
    if (render is RenderTerminal) render.resetCursorBlink();
  }

  void _scrollToBottom() {
    final position = _scrollableKey.currentState?.position;
    if (position == null) return;

    final duration = widget.smoothScrollDuration;
    if (duration == Duration.zero || _isAnimatingScroll) {
      position.jumpTo(position.maxScrollExtent);
      _showScrollToBottom.value = false;
      return;
    }

    // If the distance is very small, just jump to avoid unnecessary animation.
    final distance = position.maxScrollExtent - position.pixels;
    if (distance <= 0) {
      _showScrollToBottom.value = false;
      return;
    }

    // For very large jumps (e.g. thousands of lines), cap the animation
    // to avoid slow crawling. Jump most of the way, then animate the last bit.
    const maxAnimateDistance = 500.0;
    if (distance > maxAnimateDistance) {
      position.jumpTo(position.maxScrollExtent - maxAnimateDistance);
    }

    _isAnimatingScroll = true;
    position
        .animateTo(
      position.maxScrollExtent,
      duration: duration,
      curve: Curves.easeOutCubic,
    )
        .whenComplete(() {
      _isAnimatingScroll = false;
      _showScrollToBottom.value = false;
    });
  }
}

class _TerminalView extends LeafRenderObjectWidget {
  const _TerminalView({
    super.key,
    required this.terminal,
    required this.controller,
    required this.offset,
    required this.padding,
    required this.autoResize,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.focusNode,
    required this.cursorType,
    required this.alwaysShowCursor,
    this.cursorBlink = false,
    this.hideCursor = false,
    this.hideCursorWhileOutput = false,
    this.onEditableRect,
    this.composingText,
    this.enableUrlDetection = false,
    this.urlColor = const Color(0xFF5599DD),
    this.onScrollStateChanged,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool autoResize;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final bool alwaysShowCursor;

  final bool cursorBlink;

  final bool hideCursor;

  final bool hideCursorWhileOutput;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  final bool enableUrlDetection;

  final Color urlColor;

  final VoidCallback? onScrollStateChanged;

  @override
  RenderTerminal createRenderObject(BuildContext context) {
    return RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      autoResize: autoResize,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      focusNode: focusNode,
      cursorType: cursorType,
      alwaysShowCursor: alwaysShowCursor,
      cursorBlink: cursorBlink,
      hideCursor: hideCursor,
      hideCursorWhileOutput: hideCursorWhileOutput,
      onEditableRect: onEditableRect,
      composingText: composingText,
      enableUrlDetection: enableUrlDetection,
      urlColor: urlColor,
    )..onScrollStateChanged = onScrollStateChanged;
  }

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..autoResize = autoResize
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..alwaysShowCursor = alwaysShowCursor
      ..cursorBlink = cursorBlink
      ..hideCursor = hideCursor
      ..hideCursorWhileOutput = hideCursorWhileOutput
      ..onEditableRect = onEditableRect
      ..composingText = composingText
      ..enableUrlDetection = enableUrlDetection
      ..urlColor = urlColor
      ..onScrollStateChanged = onScrollStateChanged;
  }
}
