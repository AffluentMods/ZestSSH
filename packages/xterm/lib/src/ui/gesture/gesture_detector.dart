import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/ui/press_slop.dart';

class TerminalGestureDetector extends StatefulWidget {
  const TerminalGestureDetector({
    super.key,
    this.child,
    this.onSingleTapUp,
    this.onTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressUp,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDoubleTapDown,
    this.onTripleTapDown,
  });

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onDoubleTapDown;

  /// A third press soon after a double one, where it was: a triple click
  /// (xterm selects the line).
  final GestureTapDownCallback? onTripleTapDown;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final GestureLongPressStartCallback? onLongPressStart;

  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;

  final GestureLongPressUpCallback? onLongPressUp;

  final GestureDragStartCallback? onDragStart;

  final GestureDragUpdateCallback? onDragUpdate;

  final GestureDragEndCallback? onDragEnd;

  @override
  State<TerminalGestureDetector> createState() =>
      _TerminalGestureDetectorState();
}

class _TerminalGestureDetectorState extends State<TerminalGestureDetector> {
  Timer? _doubleTapTimer;

  Offset? _lastTapOffset;

  // True if a second tap down of a double tap is detected. Used to discard
  // subsequent tap up / tap hold of the same tap.
  bool _isDoubleTap = false;

  // From the release of a double tap, for as long as a double tap may take:
  // a press here is the third of a triple one.
  Timer? _tripleTapTimer;

  // The press now down is a triple tap's third: its release starts nothing.
  bool _isTripleTap = false;

  // The down handler is force-run on success of a single tap and optimistically
  // run before a long press success.
  void _handleTapDown(TapDownDetails details) {
    widget.onTapDown?.call(details);

    if (_tripleTapTimer != null &&
        _isWithinDoubleTapTolerance(details.globalPosition)) {
      // The third press: the line. Its release is no single tap either.
      widget.onTripleTapDown?.call(details);
      _tripleTapTimer!.cancel();
      _tripleTapTimer = null;
      _lastTapOffset = null;
      _isDoubleTap = true;
      _isTripleTap = true;
      return;
    }

    if (_doubleTapTimer != null &&
        _isWithinDoubleTapTolerance(details.globalPosition)) {
      // If there was already a previous tap, the second down hold/tap is a
      // double tap down.
      widget.onDoubleTapDown?.call(details);

      _doubleTapTimer!.cancel();
      _doubleTapTimeout();
      _isDoubleTap = true;
    }
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_isDoubleTap) {
      widget.onSingleTapUp?.call(details);
      _lastTapOffset = details.globalPosition;
      _doubleTapTimer = Timer(kDoubleTapTimeout, _doubleTapTimeout);
    } else if (_isTripleTap) {
      _isTripleTap = false;
    } else if (widget.onTripleTapDown != null) {
      // The release of a double tap's second press: a third may follow.
      _lastTapOffset = details.globalPosition;
      _tripleTapTimer = Timer(kDoubleTapTimeout, () {
        _tripleTapTimer = null;
        _lastTapOffset = null;
      });
    }
    _isDoubleTap = false;
  }

  @override
  void dispose() {
    _doubleTapTimer?.cancel();
    _tripleTapTimer?.cancel();
    super.dispose();
  }

  void _doubleTapTimeout() {
    _doubleTapTimer = null;
    _lastTapOffset = null;
  }

  bool _isWithinDoubleTapTolerance(Offset secondTapOffset) {
    if (_lastTapOffset == null) {
      return false;
    }

    final Offset difference = secondTapOffset - _lastTapOffset!;
    return difference.distance <= kDoubleTapSlop;
  }

  @override
  Widget build(BuildContext context) {
    final gestures = <Type, GestureRecognizerFactory>{};

    gestures[TapGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
      () => TapGestureRecognizer(debugOwner: this),
      (TapGestureRecognizer instance) {
        instance
          ..onTapDown = _handleTapDown
          ..onTapUp = _handleTapUp
          ..onSecondaryTapDown = widget.onSecondaryTapDown
          ..onSecondaryTapUp = widget.onSecondaryTapUp
          ..onTertiaryTapDown = widget.onTertiaryTapDown
          ..onTertiaryTapUp = widget.onTertiaryTapUp;
      },
    );

    gestures[StillLongPressGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<StillLongPressGestureRecognizer>(
      // A press is a finger held still: one that moves more than a few
      // pixels before the press is taken is the start of a scroll, however
      // slow (Flutter's own 18 let a slow scroll become a selection and the
      // actions sheet).
      () => StillLongPressGestureRecognizer(
        debugOwner: this,
        supportedDevices: {
          PointerDeviceKind.touch,
          // PointerDeviceKind.mouse, // for debugging purposes only
        },
      ),
      (StillLongPressGestureRecognizer instance) {
        instance
          ..onLongPressStart = widget.onLongPressStart
          ..onLongPressMoveUpdate = widget.onLongPressMoveUpdate
          ..onLongPressUp = widget.onLongPressUp;
      },
    );

    gestures[PanGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
      () => PanGestureRecognizer(
        debugOwner: this,
        supportedDevices: <PointerDeviceKind>{PointerDeviceKind.mouse},
      ),
      (PanGestureRecognizer instance) {
        instance
          ..dragStartBehavior = DragStartBehavior.down
          ..onStart = widget.onDragStart
          ..onUpdate = widget.onDragUpdate
          ..onEnd = widget.onDragEnd;
      },
    );

    return RawGestureDetector(
      gestures: gestures,
      excludeFromSemantics: true,
      child: widget.child,
    );
  }
}

/// A long press of a finger held still: until the press is taken, a move of
/// more than [kTerminalPressSlop] from where the finger went down gives it up
/// to the scroll it is starting. After, the finger moves freely (it grows the
/// selection the press began).
class StillLongPressGestureRecognizer extends LongPressGestureRecognizer {
  StillLongPressGestureRecognizer({super.debugOwner, super.supportedDevices});

  bool _taken = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // A new press only: a second finger landing while a taken press grows
    // its selection does not make the first one give up.
    if (state == GestureRecognizerState.ready) _taken = false;
    super.addAllowedPointer(event);
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer == primaryPointer) _taken = true;
    super.acceptGesture(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    final start = initialPosition;
    if (!_taken &&
        event is PointerMoveEvent &&
        event.pointer == primaryPointer &&
        state == GestureRecognizerState.possible &&
        start != null &&
        (event.position - start.global).distance > kTerminalPressSlop) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      return;
    }
    super.handleEvent(event);
  }
}
