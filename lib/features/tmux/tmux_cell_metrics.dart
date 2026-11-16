import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart';

/// Measure one terminal cell for [style] exactly the way xterm's painter does
/// (a run of ten `m` glyphs laid out with the same text style and scaler), so
/// the client size reported to tmux and the pixel rectangles the panes are
/// placed in agree with what the terminal view will actually draw.
Size measureTerminalCell(TerminalStyle style, TextScaler textScaler) {
  const test = 'mmmmmmmmmm';
  final textStyle = style.toTextStyle();
  final builder = ui.ParagraphBuilder(textStyle.getParagraphStyle());
  builder.pushStyle(textStyle.getTextStyle(textScaler: textScaler));
  builder.addText(test);
  final paragraph = builder.build();
  paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));
  final size = Size(paragraph.maxIntrinsicWidth / test.length, paragraph.height);
  paragraph.dispose();
  return size;
}
