import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' show TerminalResizeHold;
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/theme/app_colors.dart';

class PaneTreeView extends ConsumerWidget {
  final PaneNode node;
  final Widget Function(PaneLeaf leaf, bool isFocused) leafBuilder;

  /// Told where a divider was let go (or that it was double-clicked back to
  /// even): the split, and the share of its first side. Whoever keeps the
  /// tree writes it there, so the divider is where it was left when the tab
  /// is come back to, and after a restart. Left out, a dragged divider is
  /// kept on screen only.
  final void Function(PaneSplit split, double ratio)? onRatioChanged;

  const PaneTreeView({
    required this.node,
    required this.leafBuilder,
    this.onRatioChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentNode = node;

    if (currentNode is PaneLeaf) {
      final focusedId = ref.watch(focusedPaneProvider);
      final isFocused = focusedId == currentNode.id;

      // Use Listener (not GestureDetector) so the focus-pane update is a
      // pure observer of pointer events. A GestureDetector with onTap
      // competes in the gesture arena against TerminalView's internal tap
      // handler - when the parent wins, TerminalView's `_focusNode.requestFocus()`
      // never fires, so the user has to click TWICE to start typing
      // (first click registers the pane focus, second click reaches xterm).
      // Listener.onPointerDown fires unconditionally without claiming the
      // gesture, letting xterm's tap handler win on the very first click.
      //
      // The provider write is DEFERRED to the next frame. Writing
      // focusedPaneProvider synchronously here flips `isFocused` and rebuilds
      // the pane subtree DURING the pointer-down - which drops the in-flight
      // tap/drag on an unfocused pane's controls (an SFTP row, the pane close
      // button, a header button), so the user had to click twice: once to
      // focus, once to act. Deferring lets the current gesture complete on the
      // stable tree first; focus + the accent border update one frame later
      // (~16 ms, imperceptible). Keyboard focus is unaffected because
      // _TerminalPane grabs its own FocusNode synchronously.
      return Listener(
        onPointerDown: (_) {
          final id = currentNode.id;
          if (ref.read(focusedPaneProvider) == id) return; // already focused
          // Capture the notifier now (ref is valid in this handler); the
          // provider outlives this widget, so using it post-frame is safe even
          // if the pane is torn down by the gesture in between.
          final notifier = ref.read(focusedPaneProvider.notifier);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            notifier.state = id;
          });
        },
        child: leafBuilder(currentNode, isFocused),
      );
    }

    if (currentNode is PaneSplit) {
      // Keyed by the split itself: a divider someone dragged is that
      // split's, not whatever split comes to stand in the same place (the
      // divider of one tab used to carry over to the next tab's split).
      return _SplitPane(
        key: ValueKey(currentNode.id),
        split: currentNode,
        leafBuilder: leafBuilder,
        onRatioChanged: onRatioChanged,
      );
    }

    return const SizedBox.shrink();
  }
}

class _SplitPane extends ConsumerStatefulWidget {
  final PaneSplit split;
  final Widget Function(PaneLeaf leaf, bool isFocused) leafBuilder;
  final void Function(PaneSplit split, double ratio)? onRatioChanged;

  const _SplitPane({
    super.key,
    required this.split,
    required this.leafBuilder,
    this.onRatioChanged,
  });

  @override
  ConsumerState<_SplitPane> createState() => _SplitPaneState();
}

class _SplitPaneState extends ConsumerState<_SplitPane> {
  late double _ratio;

  /// Where the divider stood when the drag in hand began.
  double? _dragFrom;

  // Narrow gutter (§8): a terminal-friendly 6px hit target. The separator
  // itself is a hairline centred inside it, with a visible rest colour, a
  // hover state, and a resize cursor.
  static const double _dividerThickness = 6.0;

  // The line the panes meet at.
  static const double _kLine = 1.0;

  // How far a divider is dragged: neither side under 15 % of the split. One
  // that already stands further out (the first of eight columns is an
  // eighth) is dragged from where it stands, and no further out.
  static const double _minRatio = 0.15;
  static const double _maxRatio = 0.85;

  @override
  void initState() {
    super.initState();
    _ratio = widget.split.ratio;
  }

  @override
  void didUpdateWidget(covariant _SplitPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.split.ratio != widget.split.ratio) {
      _ratio = widget.split.ratio;
    }
  }

  void _onDragUpdate(DragUpdateDetails details, double totalSize) {
    final delta = widget.split.axis == Axis.horizontal
        ? details.delta.dx
        : details.delta.dy;
    final from = _dragFrom ??= _ratio;
    final least = from < _minRatio ? from : _minRatio;
    final most = from > _maxRatio ? from : _maxRatio;
    setState(() {
      _ratio = (_ratio + delta / totalSize).clamp(least, most);
    });
  }

  /// The divider was let go: where it stands is the split's share now.
  /// (One that was only pressed, or brought back to where it stood, is not
  /// said.)
  void _onDragEnd() {
    _dragFrom = null;
    if ((_ratio - widget.split.ratio).abs() > 1e-9) {
      widget.onRatioChanged?.call(widget.split, _ratio);
    }
  }

  /// A double click puts the divider back where both sides share evenly:
  /// by the panes each holds along the split, as when a pane is added.
  void _evenOut() {
    final split = widget.split;
    final even = evenPaneShare(split.first, split.second, split.axis);
    if (even == null || (even == _ratio && even == split.ratio)) return;
    setState(() => _ratio = even);
    widget.onRatioChanged?.call(split, even);
  }

  @override
  Widget build(BuildContext context) {
    final axis = widget.split.axis;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalSize = axis == Axis.horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        // The panes meet at a 1px line; the divider's 6px hit area lies over
        // it, half on each side (it took 6px of its own between the panes,
        // which showed as a grey band).
        final firstSize = (_ratio * totalSize - _kLine / 2).clamp(0.0, totalSize);
        final secondSize = (totalSize - firstSize - _kLine).clamp(0.0, totalSize);

        final firstChild = SizedBox(
          width: axis == Axis.horizontal ? firstSize : null,
          height: axis == Axis.vertical ? firstSize : null,
          child: PaneTreeView(
            node: widget.split.first,
            leafBuilder: widget.leafBuilder,
            onRatioChanged: widget.onRatioChanged,
          ),
        );

        final secondChild = SizedBox(
          width: axis == Axis.horizontal ? secondSize : null,
          height: axis == Axis.vertical ? secondSize : null,
          child: PaneTreeView(
            node: widget.split.second,
            leafBuilder: widget.leafBuilder,
            onRatioChanged: widget.onRatioChanged,
          ),
        );

        final line = SizedBox(
          width: axis == Axis.horizontal ? _kLine : null,
          height: axis == Axis.vertical ? _kLine : null,
          child: ColoredBox(color: AppColors.v3BorderDefault),
        );

        final divider = _PaneDivider(
          axis: axis,
          thickness: _dividerThickness,
          onDragUpdate: (details) => _onDragUpdate(details, totalSize),
          onDragEnd: _onDragEnd,
          onDoubleTap: _evenOut,
        );
        final at = firstSize + _kLine / 2 - _dividerThickness / 2;

        return Stack(
          children: [
            Positioned.fill(
              child: axis == Axis.horizontal
                  ? Row(children: [firstChild, line, secondChild])
                  : Column(children: [firstChild, line, secondChild]),
            ),
            if (axis == Axis.horizontal)
              Positioned(left: at, top: 0, bottom: 0, width: _dividerThickness, child: divider)
            else
              Positioned(top: at, left: 0, right: 0, height: _dividerThickness, child: divider),
          ],
        );
      },
    );
  }
}

class _PaneDivider extends StatefulWidget {
  final Axis axis;
  final double thickness;
  final void Function(DragUpdateDetails details) onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDoubleTap;

  const _PaneDivider({
    required this.axis,
    required this.thickness,
    required this.onDragUpdate,
    this.onDragEnd,
    this.onDoubleTap,
  });

  @override
  State<_PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<_PaneDivider> {
  bool _isHovered = false;

  /// The terminals keep their rows and columns while the divider is
  /// dragged, and lay their text out for the new size once it is let go.
  bool _holding = false;

  void _hold() {
    if (_holding) return;
    _holding = true;
    TerminalResizeHold.hold();
  }

  void _release() {
    if (!_holding) return;
    _holding = false;
    TerminalResizeHold.release();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.axis == Axis.horizontal;
    final cursor =
        isHorizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow;

    // At rest the line between the panes shows through (this hit area is
    // laid over it); on hover it turns the accent and thickens slightly so
    // the resize affordance is obvious.
    final lineThickness = _isHovered ? 2.0 : 1.0;
    final lineColor = _isHovered ? AppColors.brandOrange : Colors.transparent;

    return MouseRegion(
      cursor: cursor,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // From where it was pressed: the divider stays under the pointer.
        // (Counted from where the drag was told apart from a click, it
        // trails the pointer by what was moved until then.)
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: (_) => _hold(),
        onPanUpdate: widget.onDragUpdate,
        // (Also how a drag the system takes away ends: one that was
        // under way ends, one that had not begun moved nothing.)
        onPanEnd: (_) {
          _release();
          widget.onDragEnd?.call();
        },
        onPanCancel: _release,
        onDoubleTap: widget.onDoubleTap,
        child: SizedBox(
          width: isHorizontal ? widget.thickness : double.infinity,
          height: isHorizontal ? double.infinity : widget.thickness,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: isHorizontal ? lineThickness : double.infinity,
              height: isHorizontal ? double.infinity : lineThickness,
              color: lineColor,
            ),
          ),
        ),
      ),
    );
  }
}
