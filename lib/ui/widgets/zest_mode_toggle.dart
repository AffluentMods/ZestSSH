import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';

/// One segment of a [ZestModeToggle].
///
/// A disabled segment ([enabled] == false) is never *silently* greyed - it must
/// carry a [disabledReason] (or fall back to the toggle's top-level reason) that
/// is surfaced as a tooltip.
class ZestModeSegment {
  const ZestModeSegment({
    required this.id,
    required this.label,
    this.enabled = true,
    this.disabledReason,
  });

  /// Stable identifier reported through [ZestModeToggle.onChanged].
  final String id;

  /// Already-localized segment label.
  final String label;

  /// Whether the segment can be selected.
  final bool enabled;

  /// Already-localized reason shown as a tooltip when [enabled] is false.
  final String? disabledReason;
}

/// 1.7 segmented mode control (promoted from the Port-Forwarding
/// Simple/Advanced pill). A short pill bar where the ACTIVE segment fills with
/// [ZestTokens.brandSubtle] and reads in [ZestTokens.brand]; inactive segments
/// are transparent in [ZestTokens.textSecondary].
///
/// Keyboard: each enabled segment is a tab stop; Left/Right arrows move focus
/// between segments (skipping disabled ones), Enter/Space selects.
class ZestModeToggle extends StatefulWidget {
  const ZestModeToggle({
    super.key,
    required this.segments,
    required this.selectedId,
    required this.onChanged,
    this.disabledReason,
  });

  final List<ZestModeSegment> segments;

  /// Id of the currently-active segment.
  final String selectedId;

  /// Fired with a segment's [ZestModeSegment.id] when it becomes selected.
  final ValueChanged<String> onChanged;

  /// Already-localized fallback tooltip for any disabled segment that does not
  /// supply its own [ZestModeSegment.disabledReason].
  final String? disabledReason;

  @override
  State<ZestModeToggle> createState() => _ZestModeToggleState();
}

class _ZestModeToggleState extends State<ZestModeToggle> {
  late List<FocusNode> _nodes;

  @override
  void initState() {
    super.initState();
    _nodes = _makeNodes(widget.segments.length);
  }

  @override
  void didUpdateWidget(covariant ZestModeToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segments.length != widget.segments.length) {
      for (final node in _nodes) {
        node.dispose();
      }
      _nodes = _makeNodes(widget.segments.length);
    }
  }

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  List<FocusNode> _makeNodes(int n) =>
      List<FocusNode>.generate(n, (_) => FocusNode());

  void _select(ZestModeSegment segment) {
    if (segment.enabled && segment.id != widget.selectedId) {
      widget.onChanged(segment.id);
    }
  }

  /// Move keyboard focus from [from] to the next enabled segment in [dir]
  /// (+1 right / -1 left), wrapping and skipping disabled segments.
  void _moveFocus(int from, int dir) {
    final n = widget.segments.length;
    for (var step = 1; step <= n; step++) {
      final idx = ((from + dir * step) % n + n) % n;
      if (widget.segments[idx].enabled) {
        _nodes[idx].requestFocus();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < widget.segments.length; i++) {
      if (i > 0) {
        children.add(Center(
          child: SizedBox(
            width: 1,
            height: 18,
            child: ColoredBox(color: ZestTokens.border),
          ),
        ));
      }
      final segment = widget.segments[i];
      final index = i;
      children.add(_Segment(
        segment: segment,
        active: segment.id == widget.selectedId,
        focusNode: _nodes[i],
        fallbackReason: widget.disabledReason,
        onActivate: () => _select(segment),
        onArrow: (dir) => _moveFocus(index, dir),
      ));
    }

    // 34 high (a segment 32 inside its edge, a mouse's least target), or
    // more where larger text needs it; 48 where a finger presses it. (A
    // fixed 30 cut the words off at a large text size.)
    return Container(
      constraints: BoxConstraints(minHeight: touchSizedAt(context) ? 48 : 34),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border, width: 1),
      ),
      child: IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}

/// Arrow-navigation intent carrying a direction (+1 right / -1 left).
class _ArrowIntent extends Intent {
  const _ArrowIntent(this.direction);

  final int direction;
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.segment,
    required this.active,
    required this.focusNode,
    required this.fallbackReason,
    required this.onActivate,
    required this.onArrow,
  });

  final ZestModeSegment segment;
  final bool active;
  final FocusNode focusNode;
  final String? fallbackReason;
  final VoidCallback onActivate;
  final ValueChanged<int> onArrow;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hovering = false;
  bool _focusRing = false; // keyboard focus only

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final disabled = !segment.enabled;
    final reason = segment.disabledReason ?? widget.fallbackReason;

    final Color foreground;
    final Color fill;
    if (widget.active) {
      foreground = ZestTokens.brandInk;
      fill = ZestTokens.brandSubtle;
    } else if (disabled) {
      foreground = ZestTokens.textPlaceholder;
      fill = Colors.transparent;
    } else {
      foreground =
          _hovering ? ZestTokens.textPrimary : ZestTokens.textSecondary;
      fill = _hovering ? ZestTokens.surfaceHover : Colors.transparent;
    }

    Widget pill = AnimatedContainer(
      duration: zestMotion(context, const Duration(milliseconds: 120)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        segment.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
          color: foreground,
          height: 1.0,
        ),
      ),
    );

    Widget interactive = FocusableActionDetector(
      focusNode: widget.focusNode,
      enabled: !disabled,
      mouseCursor:
          disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onShowHoverHighlight: (h) => setState(() => _hovering = h),
      onShowFocusHighlight: (f) => setState(() => _focusRing = f),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _ArrowIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _ArrowIntent(1),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate();
            return null;
          },
        ),
        _ArrowIntent: CallbackAction<_ArrowIntent>(
          onInvoke: (intent) {
            widget.onArrow(intent.direction);
            return null;
          },
        ),
      },
      // A button to a screen reader, said as picked where it is the mode in
      // use (it was a bare tap).
      child: Semantics(
        container: true,
        button: true,
        enabled: !disabled,
        selected: widget.active,
        inMutuallyExclusiveGroup: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: disabled ? null : widget.onActivate,
          child: pill,
        ),
      ),
    );

    // A disabled segment must announce WHY - never a silent grey.
    if (disabled && reason != null && reason.isNotEmpty) {
      interactive = Tooltip(message: reason, child: interactive);
    }
    // Inset focus ring - visible on keyboard focus, drawn over the pill so it
    // never overlaps neighbouring segments.
    return Stack(
      clipBehavior: Clip.none,
      // The segment as tall as the bar (48 where a finger presses it).
      fit: StackFit.passthrough,
      children: [
        interactive,
        if (_focusRing)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: ZestTokens.brand, width: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
