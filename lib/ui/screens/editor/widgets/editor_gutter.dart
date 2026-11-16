import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/editor_look.dart';

/// The editor's line numbers, and an orange bar beside the lines changed
/// since the last save (3.4). The code editor lays every line out as one
/// paragraph, wrapped rows and all, and says where each is: each number is
/// drawn level with the first row of its own line, and a wrapped line's
/// further rows have none (the old gutter's numbers drifted below their
/// lines once a line wrapped).
class EditorGutter extends StatelessWidget {
  const EditorGutter({super.key, required this.doc, required this.notifier, required this.look});

  final EditorDocument doc;
  final CodeIndicatorValueNotifier notifier;
  final EditorLook look;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontFamily: look.fontFamily, fontSize: look.fontSize - 1, color: look.gutterText);
    final digits = math.max(3, '${doc.controller.lineCount}'.length);
    final probe = TextPainter(text: TextSpan(text: '0' * digits, style: style), textDirection: TextDirection.ltr)..layout();
    final width = probe.width + 22;
    probe.dispose();
    // As tall as the code (the paragraphs' places are the code's): with no
    // height of its own the row stood it in its middle, half a window below
    // its lines.
    return SizedBox(
      width: width,
      height: double.infinity,
      child: CustomPaint(
        key: const ValueKey('editor-gutter'),
        painter: EditorGutterPainter(
          doc: doc,
          notifier: notifier,
          style: style,
          activeStyle: style.copyWith(color: look.gutterActiveText),
          bar: look.changedBar,
          repaint: Listenable.merge([notifier, doc]),
        ),
      ),
    );
  }
}

@visibleForTesting
class EditorGutterPainter extends CustomPainter {
  EditorGutterPainter({
    required this.doc,
    required this.notifier,
    required this.style,
    required this.activeStyle,
    required this.bar,
    super.repaint,
  });

  final EditorDocument doc;
  final CodeIndicatorValueNotifier notifier;
  final TextStyle style;
  final TextStyle activeStyle;
  final Color bar;

  /// What the last paint drew: each line's number (from 1) with the middle
  /// of its first row, and the lines given the changed bar, for the tests.
  @visibleForTesting
  final List<(int line, double middle)> painted = [];
  @visibleForTesting
  final List<int> barred = [];

  @override
  void paint(Canvas canvas, Size size) {
    painted.clear();
    barred.clear();
    final value = notifier.value;
    if (value == null) return;
    final lines = doc.controller.codeLines;
    final barPaint = Paint()..color = bar;
    for (final p in value.paragraphs) {
      if (p.index >= lines.length) continue;
      final line = lines.index2lineIndex(p.index);
      final rowHeight = p.preferredLineHeight;
      final middle = p.offset.dy + rowHeight / 2;
      if (doc.isChangedLine(line)) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(3, p.offset.dy + 2, 3, p.height - 4), const Radius.circular(2)),
          barPaint,
        );
        barred.add(line + 1);
      }
      final tp = TextPainter(
        text: TextSpan(text: '${line + 1}', style: p.index == value.focusedIndex ? activeStyle : style),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - 10 - tp.width, middle - tp.height / 2));
      tp.dispose();
      painted.add((line + 1, middle));
    }
  }

  @override
  bool shouldRepaint(EditorGutterPainter oldDelegate) => true;
}
