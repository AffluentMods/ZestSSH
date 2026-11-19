import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// One action of a [ZestButtonGroup].
@immutable
class ZestButtonGroupItem {
  const ZestButtonGroupItem({
    this.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.isLoading = false,
  });

  /// The key of the action's own button (tests and the keyboard find it by
  /// this).
  final Key? key;

  /// Already-localized label.
  final String label;
  final IconData? icon;

  /// Null: turned off.
  final VoidCallback? onPressed;

  /// A spinner in place of [icon]; the button stays drawn as on, and takes no
  /// press.
  final bool isLoading;
}

/// Related secondary actions joined in one outlined control, divided by
/// hairlines (the tests of a host beside its Save, in the editor's footer):
/// they read as one group, apart from the pane's one primary button.
///
/// Side by side where they fit the width they are given; one under the other
/// where they do not (a narrow pane, long words, a large text size). As tall
/// as a large [ZestButton] each, so the group lines up with Save; a finger's
/// 48 where the controls are touch sized.
class ZestButtonGroup extends StatelessWidget {
  const ZestButtonGroup({super.key, required this.items});

  final List<ZestButtonGroupItem> items;

  static const double _padX = 14;
  static const double _iconSize = 16;
  static const double _fontSize = 13;
  static const double _radius = 8;

  static TextStyle _style(Color color) =>
      TextStyle(fontSize: _fontSize, fontWeight: FontWeight.w600, color: color, height: 1.0);

  /// The width [item] needs on one line.
  static double _itemWidth(BuildContext context, ZestButtonGroupItem item) {
    final painter = TextPainter(
      // In the face the label is drawn in (the theme's, through the default
      // text style), so the measure is the label's.
      text: TextSpan(text: item.label, style: DefaultTextStyle.of(context).style.merge(_style(ZestTokens.textPrimary))),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    final glyph = item.icon != null || item.isLoading ? _iconSize + ZestSizing.buttonGap : 0;
    return width + glyph + 2 * _padX;
  }

  @override
  Widget build(BuildContext context) {
    final height = math.max(ZestSizing.buttonLarge, minTapTarget(context));
    return LayoutBuilder(builder: (context, constraints) {
      final widths = [for (final item in items) _itemWidth(context, item)];
      // Each hairline between two is 1 wide; the outline 1 on each side.
      final rowWidth = widths.fold<double>(0, (a, b) => a + b) + (items.length - 1) + 2;
      final horizontal = rowWidth <= constraints.maxWidth;
      final divider = ColoredBox(
        color: ZestTokens.borderStrong,
        child: horizontal
            ? SizedBox(width: 1, height: height)
            : const SizedBox(height: 1, width: double.infinity),
      );
      final children = <Widget>[];
      for (var i = 0; i < items.length; i++) {
        if (i > 0) children.add(divider);
        final segment = _GroupSegment(
          key: items[i].key,
          label: items[i].label,
          icon: items[i].icon,
          onPressed: items[i].onPressed,
          isLoading: items[i].isLoading,
          first: i == 0,
          last: i == items.length - 1,
          horizontal: horizontal,
          height: height,
        );
        children.add(horizontal ? segment : SizedBox(width: double.infinity, child: segment));
      }
      final maxSegment = widths.fold<double>(0, math.max) + 2;
      return Container(
        // One under the other: as wide as the widest, or the room there is.
        width: horizontal ? null : math.min(maxSegment, constraints.maxWidth),
        decoration: BoxDecoration(
          border: Border.all(color: ZestTokens.borderStrong),
          borderRadius: BorderRadius.circular(_radius),
        ),
        child: horizontal
            ? Row(mainAxisSize: MainAxisSize.min, children: children)
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
    });
  }
}

/// One button of a [ZestButtonGroup]: a ghost label in the group's outline,
/// with its own hover fill, focus ring and turned-off look.
class _GroupSegment extends StatefulWidget {
  const _GroupSegment({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.isLoading,
    required this.first,
    required this.last,
    required this.horizontal,
    required this.height,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool first;
  final bool last;
  final bool horizontal;

  /// The least height (the group's).
  final double height;

  @override
  State<_GroupSegment> createState() => _GroupSegmentState();
}

class _GroupSegmentState extends State<_GroupSegment> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.isLoading;
    // A running one stays drawn as on (its spinner says it runs); one turned
    // off is faded, as a turned-off ZestButton.
    final faded = widget.onPressed == null && !widget.isLoading;
    final fg = ZestTokens.textPrimary;
    // The inner corners square, the outer ones the group's (less its outline).
    const r = Radius.circular(ZestButtonGroup._radius - 1);
    final radius = widget.horizontal
        ? BorderRadius.horizontal(left: widget.first ? r : Radius.zero, right: widget.last ? r : Radius.zero)
        : BorderRadius.vertical(top: widget.first ? r : Radius.zero, bottom: widget.last ? r : Radius.zero);
    final glyph = widget.isLoading
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        : widget.icon == null
            ? null
            : Icon(widget.icon, size: ZestButtonGroup._iconSize, color: ZestTokens.textSecondary);
    Widget body = AnimatedContainer(
      duration: zestMotion(context, const Duration(milliseconds: 120)),
      constraints: BoxConstraints(minHeight: widget.height),
      padding: const EdgeInsets.symmetric(horizontal: ZestButtonGroup._padX, vertical: 4),
      decoration: BoxDecoration(
        color: _hover && enabled ? ZestTokens.textPrimary.withValues(alpha: 0.06) : Colors.transparent,
        borderRadius: radius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // One under the other: from the start, so the icons line up.
        mainAxisAlignment: widget.horizontal ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          if (glyph != null) ...[glyph, const SizedBox(width: ZestSizing.buttonGap)],
          Flexible(
            child: Text(
              widget.label,
              textAlign: widget.horizontal ? TextAlign.center : TextAlign.start,
              style: ZestButtonGroup._style(fg),
            ),
          ),
        ],
      ),
    );
    body = ZestPressable(
      onTap: enabled ? widget.onPressed : null,
      onHover: (h) => setState(() => _hover = h),
      // Its own height is the target's ([ZestButtonGroup] makes it a
      // finger's 48 where the controls are touch sized).
      minSize: 0,
      borderRadius: ZestButtonGroup._radius - 1,
      child: body,
    );
    return faded ? Opacity(opacity: 0.4, child: body) : body;
  }
}
