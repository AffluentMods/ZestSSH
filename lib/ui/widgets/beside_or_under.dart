import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Words and a control (a button, a switch, a choice) in a row: the control
/// beside the words where they keep [minWordsWidth] of room (at the text size
/// the app is drawn at, and as much more as the text grows), and under them,
/// at the start, where they would not. Beside the words on a phone's narrow
/// row, a control left them a few letters a line or broke a long word (found
/// 17 October 2026). Beside them, the two are centred on each other.
class BesideOrUnder extends MultiChildRenderObjectWidget {
  BesideOrUnder({
    super.key,
    required Widget words,
    required Widget control,
    this.minWordsWidth = 200,
    this.gap = 12,
    this.underGap = 8,
  }) : super(children: [words, control]);

  /// The least room the words keep beside the control.
  final double minWordsWidth;

  /// Between the words and the control beside them.
  final double gap;

  /// Between the words and the control under them.
  final double underGap;

  double _minWords(BuildContext context) => minWordsWidth * MediaQuery.textScalerOf(context).scale(16) / 16;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderBesideOrUnder(
        minWordsWidth: _minWords(context),
        gap: gap,
        underGap: underGap,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(BuildContext context, RenderBesideOrUnder renderObject) {
    renderObject
      ..minWordsWidth = _minWords(context)
      ..gap = gap
      ..underGap = underGap
      ..textDirection = Directionality.of(context);
  }
}

class _Slot extends ContainerBoxParentData<RenderBox> {}

/// The render object of [BesideOrUnder]: its first child is the words, its
/// second the control.
class RenderBesideOrUnder extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _Slot>, RenderBoxContainerDefaultsMixin<RenderBox, _Slot> {
  RenderBesideOrUnder({
    required double minWordsWidth,
    required double gap,
    required double underGap,
    required TextDirection textDirection,
  })  : _minWordsWidth = minWordsWidth,
        _gap = gap,
        _underGap = underGap,
        _textDirection = textDirection;

  double _minWordsWidth;
  set minWordsWidth(double value) {
    if (value == _minWordsWidth) return;
    _minWordsWidth = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _underGap;
  set underGap(double value) {
    if (value == _underGap) return;
    _underGap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// Whether the control stood beside the words at the last layout.
  bool get controlBeside => _beside;
  bool _beside = true;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _Slot) child.parentData = _Slot();
  }

  RenderBox get _words => firstChild!;
  RenderBox get _control => lastChild!;

  bool _fitsBeside(double width, double controlWidth) =>
      !width.isFinite || width - controlWidth - _gap >= _minWordsWidth;

  /// The two sizes and where they stand, for [constraints]: [size] lays a
  /// child out (or measures it dry).
  ({Size size, bool beside, Offset words, Offset control}) _arrange(
      BoxConstraints constraints, Size Function(RenderBox child, BoxConstraints constraints) size) {
    final width = constraints.maxWidth;
    final control = size(_control, BoxConstraints(maxWidth: width));
    final rtl = _textDirection == TextDirection.rtl;
    if (_fitsBeside(width, control.width)) {
      final wordsBox = width.isFinite
          ? BoxConstraints.tightFor(width: width - control.width - _gap)
          : const BoxConstraints();
      final words = size(_words, wordsBox);
      final total = words.width + _gap + control.width;
      final height = math.max(words.height, control.height);
      final row = width.isFinite ? width : total;
      return (
        size: constraints.constrain(Size(row, height)),
        beside: true,
        words: Offset(rtl ? row - words.width : 0, (height - words.height) / 2),
        control: Offset(rtl ? 0 : row - control.width, (height - control.height) / 2),
      );
    }
    final words = size(_words, BoxConstraints.tightFor(width: width));
    return (
      size: constraints.constrain(Size(width, words.height + _underGap + control.height)),
      beside: false,
      words: Offset.zero,
      control: Offset(rtl ? width - control.width : 0, words.height + _underGap),
    );
  }

  @override
  void performLayout() {
    final arranged = _arrange(constraints, (child, c) {
      child.layout(c, parentUsesSize: true);
      return child.size;
    });
    (_words.parentData! as _Slot).offset = arranged.words;
    (_control.parentData! as _Slot).offset = arranged.control;
    _beside = arranged.beside;
    size = arranged.size;
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _arrange(constraints, (child, c) => child.getDryLayout(c)).size;

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(_words.getMinIntrinsicWidth(double.infinity), _control.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _words.getMaxIntrinsicWidth(double.infinity) + _gap + _control.getMaxIntrinsicWidth(double.infinity);

  double _height(double width, double Function(RenderBox child, double width) of) {
    final control = math.min(_control.getMaxIntrinsicWidth(double.infinity), width);
    if (_fitsBeside(width, control)) {
      return math.max(of(_words, width.isFinite ? width - control - _gap : width), of(_control, control));
    }
    return of(_words, width) + _underGap + of(_control, width);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _height(width, (c, w) => c.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) => _height(width, (c, w) => c.getMaxIntrinsicHeight(w));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
