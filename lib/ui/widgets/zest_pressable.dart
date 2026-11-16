import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/zest_a11y.dart' show ZestFocusRing, ZestHover;

/// The least target a control takes where [context] is (4.0):
/// a finger's 48 where the app is touch sized, a mouse's
/// 32 otherwise.
double minTapTarget(BuildContext context) => touchSizedAt(context) ? 48 : 32;

/// Something drawn by hand that is pressed like a button: reached with Tab,
/// pressed with Enter or Space, said to a screen reader as a button with its
/// name and state, ringed in the accent (2 px, outside it, so nothing moves)
/// while the keyboard is on it, and pressed anywhere in at least
/// [minTapTarget] square around it (the look of [child] does not change: the
/// space around it takes the press).
///
/// Before it, the app's hand-drawn buttons were a GestureDetector alone: a
/// keyboard could not reach them, a screen reader heard no button, and a
/// chevron of 16 by 12 was the whole of its target.
class ZestPressable extends StatefulWidget {
  const ZestPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onTapDown,
    this.onActivate,
    this.onLongPress,
    this.onDoubleTap,
    this.onSecondaryTapUp,
    this.onContextMenu,
    this.semanticActions = const {},
    this.semanticLabel,
    this.semanticHint,
    this.selected,
    this.toggled,
    this.checked,
    this.expanded,
    this.button = true,
    this.link = false,
    this.inGroup = false,
    this.excludeChildSemantics = false,
    this.minSize,
    this.borderRadius = 8,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.mouseCursor,
    this.ring = true,
  });

  final Widget child;

  /// Null (and [onTapDown] and [onActivate] null): turned off (said so, not
  /// reached with Tab).
  final VoidCallback? onTap;

  /// On the press itself, before a possible double tap (a computer's host
  /// row opens its panel on the press).
  final VoidCallback? onTapDown;

  /// What Enter, Space and a screen reader's double tap do; where null,
  /// [onTap], else [onTapDown].
  final VoidCallback? onActivate;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final GestureTapUpCallback? onSecondaryTapUp;

  /// What a right click opens, from the keyboard (Shift+F10, the menu key).
  final VoidCallback? onContextMenu;

  /// A screen reader's actions on it besides a tap (Connect, More actions).
  final Map<CustomSemanticsAction, VoidCallback> semanticActions;

  /// What a screen reader says it is; null: the words inside it.
  final String? semanticLabel;
  final String? semanticHint;

  /// Its state, said where it has one.
  final bool? selected;
  final bool? toggled;
  final bool? checked;
  final bool? expanded;

  /// Said as a button (false for a row that is a link or a tile with its own
  /// role).
  final bool button;

  /// Said as a link (it opens a page outside the app).
  final bool link;

  /// One of a group of which one is picked (a radio's choices, a swatch).
  final bool inGroup;

  /// The words of [child] left out (where [semanticLabel] says them all).
  final bool excludeChildSemantics;

  /// The least target, square; null: [minTapTarget]. Zero for none.
  final double? minSize;

  /// The ring's corners follow [child]'s.
  final double borderRadius;

  /// Told when a mouse comes onto it and leaves it.
  final ValueChanged<bool>? onHover;

  /// Told when the keyboard comes onto it and leaves it (what shows only
  /// under a hovering pointer shows then too).
  final ValueChanged<bool>? onFocusChange;

  final FocusNode? focusNode;
  final bool autofocus;
  final MouseCursor? mouseCursor;

  /// The accent ring under the keyboard (off where [child] draws its own).
  final bool ring;

  @override
  State<ZestPressable> createState() => _ZestPressableState();
}

class _ZestPressableState extends State<ZestPressable> {
  bool _focusRing = false;

  VoidCallback? get _activate => widget.onActivate ?? widget.onTap ?? widget.onTapDown;

  bool get _enabled => _activate != null;

  @override
  Widget build(BuildContext context) {
    final min = widget.minSize ?? minTapTarget(context);
    Widget body = widget.child;
    if (widget.ring) body = ZestFocusRing(show: _focusRing, radius: widget.borderRadius, child: body);
    if (min > 0) {
      body = ConstrainedBox(
        constraints: BoxConstraints(minWidth: min, minHeight: min),
        child: Center(widthFactor: 1, heightFactor: 1, child: body),
      );
    }
    body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: widget.onTapDown == null ? null : (_) => widget.onTapDown!(),
      onLongPress: widget.onLongPress,
      onDoubleTap: widget.onDoubleTap,
      onSecondaryTapUp: widget.onSecondaryTapUp,
      excludeFromSemantics: true,
      child: body,
    );
    body = Semantics(
      button: widget.button && !widget.link,
      link: widget.link,
      inMutuallyExclusiveGroup: widget.inGroup ? true : null,
      enabled: _enabled,
      selected: widget.selected,
      toggled: widget.toggled,
      checked: widget.checked,
      expanded: widget.expanded,
      label: widget.semanticLabel,
      hint: widget.semanticHint,
      onTap: _activate,
      onLongPress: widget.onLongPress,
      customSemanticsActions: widget.semanticActions.isEmpty ? null : widget.semanticActions,
      excludeSemantics: widget.excludeChildSemantics,
      child: body,
    );
    final menu = widget.onContextMenu;
    // Hover from the mouse itself (ZestHover): a FocusableActionDetector does
    // not report it while the app is in touch mode.
    return ZestHover(
      onHover: widget.onHover,
      child: FocusableActionDetector(
      enabled: _enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: widget.mouseCursor ?? (_enabled ? SystemMouseCursors.click : MouseCursor.defer),
      onShowFocusHighlight: (f) {
        if (f != _focusRing) setState(() => _focusRing = f);
        widget.onFocusChange?.call(f);
      },

      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
        const SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
        if (menu != null) const SingleActivator(LogicalKeyboardKey.f10, shift: true): const ContextMenuIntent(),
        if (menu != null) const SingleActivator(LogicalKeyboardKey.contextMenu): const ContextMenuIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          _activate?.call();
          return null;
        }),
        if (menu != null)
          ContextMenuIntent: CallbackAction<ContextMenuIntent>(onInvoke: (_) {
            menu();
            return null;
          }),
      },
      child: body,
      ),
    );
  }
}

/// Opens what a right click opens, from the keyboard (Shift+F10, the menu
/// key).
class ContextMenuIntent extends Intent {
  const ContextMenuIntent();
}

/// The middle of what [context] draws, in global coordinates: where a menu a
/// right click would open opens from the keyboard or a screen reader.
Offset globalCentreOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  return box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
}

/// [TapUpDetails] at [globalCentreOf] [context].
TapUpDetails tapUpAtCentre(BuildContext context) =>
    TapUpDetails(kind: PointerDeviceKind.mouse, globalPosition: globalCentreOf(context));
