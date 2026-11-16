import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A control whose target reaches [grow] past what it draws (4.0
/// accessibility pass: "the visual can be smaller, the hit area not"). A
/// press in the margin goes to the control as a press at its nearest edge,
/// and a screen reader's box for it takes the margin in too, so the guideline
/// checks and a finger see the same target. Nothing is laid out differently:
/// the margin lies over what is around it (the gap between two keys, the
/// padding of a bar), which must not take presses of its own there.
///
/// It makes its own node for a screen reader: what is inside it (a label, a
/// button, its actions) is said as one control.
class HitArea extends SingleChildRenderObjectWidget {
  const HitArea({super.key, required this.grow, required super.child});

  final EdgeInsets grow;

  @override
  RenderHitArea createRenderObject(BuildContext context) => RenderHitArea(grow);

  @override
  void updateRenderObject(BuildContext context, RenderHitArea renderObject) => renderObject.grow = grow;
}

class RenderHitArea extends RenderProxyBox {
  RenderHitArea(this._grow);

  EdgeInsets _grow;
  EdgeInsets get grow => _grow;
  set grow(EdgeInsets value) {
    if (value == _grow) return;
    _grow = value;
    markNeedsSemanticsUpdate();
  }

  Rect get _target => _grow.inflateRect(Offset.zero & size);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!_target.contains(position)) return false;
    final inside = Offset(
      position.dx.clamp(0, size.width > 0 ? size.width - 0.01 : 0).toDouble(),
      position.dy.clamp(0, size.height > 0 ? size.height - 0.01 : 0).toDouble(),
    );
    if (child != null && child!.hitTest(result, position: inside)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  Rect get semanticBounds => _target;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
  }
}
