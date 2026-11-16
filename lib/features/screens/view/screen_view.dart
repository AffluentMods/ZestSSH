// Remote screens (4.0): the picture of a screen session, taking the pointer
// (mouse, trackpad, fingers) and the keys. The tab around it (computers:
// commit 11; phones: commit 12) owns the session and the controller, drives
// pause and resume, and opens the screen menu when [ScreenView.onMenuKey]
// fires (F8).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/haptics.dart';

import 'screen_controller.dart';
import 'screen_painter.dart';
import 'screen_pointer.dart' show ScreenButtons;

class ScreenView extends StatefulWidget {
  const ScreenView({
    super.key,
    required this.controller,
    this.focusNode,
    this.autofocus = true,
    this.onMenuKey,
    this.menuKey = LogicalKeyboardKey.f8,
    this.insets,
  });

  final ScreenController controller;

  /// The picture's focus: while it has it, every key goes to the remote. The
  /// tab's menu "Release keyboard" unfocuses it.
  final FocusNode? focusNode;
  final bool autofocus;

  /// F8 (computers): the tab opens the screen menu. Null (phones): F8 is a key.
  final VoidCallback? onMenuKey;

  /// The key that fires [onMenuKey] (Settings, Remote screens; F8 by default).
  final LogicalKeyboardKey menuKey;

  /// What the picture keeps clear at fit; the safe area by default.
  final EdgeInsets? insets;

  @override
  State<ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<ScreenView> {
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'remote screen'));
  late ScreenPainter _painter;

  // What the widgets around the painter show: rebuilt only when it changes,
  // not on every frame.
  (MouseCursor, bool, bool) _chrome = (SystemMouseCursors.basic, false, false);

  ScreenController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(ScreenView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChange);
      old.controller.keyboard.onMenuKey = null;
      old.controller.touch.onHold = null;
      _attach();
    } else {
      _c.keyboard.onMenuKey = widget.onMenuKey;
      _c.keyboard.menuKey = widget.menuKey;
    }
    if (old.focusNode != widget.focusNode && widget.focusNode != null) {
      _ownFocus?.dispose();
      _ownFocus = null;
    }
  }

  void _attach() {
    _painter = ScreenPainter(_c);
    _c.addListener(_onChange);
    _c.keyboard.onMenuKey = widget.onMenuKey;
    _c.keyboard.menuKey = widget.menuKey;
    _c.touch.onHold = () {
      if (mounted) hapticIn(context, Haptic.medium);
    };
    _chrome = _chromeNow();
  }

  (MouseCursor, bool, bool) _chromeNow() => (_c.mouseCursor, _c.hasPicture, _c.viewport.isZoomed);

  void _onChange() {
    final now = _chromeNow();
    if (now != _chrome && mounted) setState(() => _chrome = now);
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    if (_c.keyboard.onMenuKey == widget.onMenuKey) _c.keyboard.onMenuKey = null;
    _c.touch.onHold = null;
    _ownFocus?.dispose();
    super.dispose();
  }

  static bool _isTouch(PointerEvent e) =>
      e.kind == PointerDeviceKind.touch ||
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  void _down(PointerDownEvent e) {
    if (!_focus.hasFocus) _focus.requestFocus();
    if (_isTouch(e)) {
      _c.noteInput(touch: true);
      _c.touch.down(e);
    } else {
      _c.noteInput(touch: false);
      // Relative mouse: the press that takes the pointer is not a click, and
      // while it is held the buttons go with the movement.
      if (_c.takePointer()) return;
      if (_c.hold.held) {
        _c.hold.buttons(ScreenButtons.fromFlutter(e.buttons));
        return;
      }
      _c.mouse.event(e);
    }
  }

  /// The mouse while the pointer is held: where it is means nothing (the
  /// computer keeps it in the window), only its buttons do.
  bool _heldMouse(PointerEvent e) {
    if (!_c.hold.held) return false;
    _c.hold.buttons(ScreenButtons.fromFlutter(e.buttons));
    return true;
  }

  void _move(PointerMoveEvent e) {
    if (_isTouch(e)) return _c.touch.move(e);
    if (!_heldMouse(e)) _c.mouse.event(e);
  }

  void _up(PointerUpEvent e) {
    if (_isTouch(e)) return _c.touch.up(e);
    if (!_heldMouse(e)) _c.mouse.event(e);
  }

  void _cancel(PointerCancelEvent e) => _isTouch(e) ? _c.touch.up(e, cancelled: true) : _c.pointer.release();

  void _hover(PointerHoverEvent e) {
    _c.noteInput(touch: false);
    if (!_heldMouse(e)) _c.mouse.event(e);
  }

  void _signal(PointerSignalEvent e) {
    // The picture takes the wheel: nothing scrolls behind it.
    GestureBinding.instance.pointerSignalResolver.register(e, (e) => _c.mouse.signal(e));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (cursor, hasPicture, zoomed) = _chrome;
    return LayoutBuilder(
      builder: (context, constraints) {
        _c.layoutView(
          constraints.biggest,
          insets: widget.insets ?? MediaQuery.paddingOf(context),
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return Semantics(
          container: true,
          label: l10n.screenViewLabel,
          customSemanticsActions: {
            if (zoomed) CustomSemanticsAction(label: l10n.screenViewWholeScreen): _c.resetZoom,
          },
          child: Focus(
            focusNode: _focus,
            autofocus: widget.autofocus,
            onKeyEvent: (_, e) => _c.keyboard.handle(e),
            onFocusChange: (has) {
              if (!has) {
                _c.keyboard.releaseAll();
                // The picture no longer has the keyboard (another window, a
                // question of the app, the panel): the pointer goes with it.
                _c.releasePointer();
              }
            },
            child: MouseRegion(
              cursor: cursor,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _down,
                onPointerMove: _move,
                onPointerUp: _up,
                onPointerCancel: _cancel,
                onPointerHover: _hover,
                onPointerSignal: _signal,
                onPointerPanZoomStart: _c.mouse.panZoomStart,
                onPointerPanZoomUpdate: _c.mouse.panZoomUpdate,
                onPointerPanZoomEnd: _c.mouse.panZoomEnd,
                child: ColoredBox(
                  color: AppColors.screenLetterbox,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(key: const ValueKey('screen-picture'), painter: _painter),
                      if (!hasPicture)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              l10n.screenViewWaiting,
                              key: const ValueKey('screen-waiting'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.screenLetterboxInk, fontSize: 13),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
