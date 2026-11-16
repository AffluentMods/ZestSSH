import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// A short pane (a tab of sixteen terminals)
/// showed its top row cut in half under the pane's header: with more lines
/// than fit, the view was scrolled to the bottom by pixels, so what was too
/// little for a whole row was left above the first row shown, and a slice of
/// the row before that was drawn in the top margin. The view now scrolls in
/// whole rows: the first row shown starts at the top of the text, and the
/// rest is left under the last one.

Future<(ScrollController, RenderTerminal)> _pump(WidgetTester tester, double height) async {
  final terminal = Terminal(maxLines: 1000);
  for (var i = 0; i < 120; i++) {
    terminal.write('line $i\r\n');
  }
  terminal.write(r'$ ');
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  final key = GlobalKey<TerminalViewState>();
  await tester.pumpWidget(MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 400,
        height: height,
        child: TerminalView(terminal, key: key, scrollController: scroll, padding: const EdgeInsets.all(8)),
      ),
    ),
  ));
  await tester.pump();
  return (scroll, key.currentState!.renderTerminal);
}

void main() {
  for (final height in [97.0, 151.0, 203.5, 260.0]) {
    testWidgets('a view $height high with more lines than fit shows whole rows from its top', (tester) async {
      final (scroll, render) = await _pump(tester, height);
      final row = render.lineHeight;
      final pos = scroll.position;
      expect(pos.pixels, pos.maxScrollExtent, reason: 'it is at the bottom');
      final first = pos.pixels / row;
      expect(first, closeTo(first.roundToDouble(), 1e-6), reason: 'the first row shown starts at the top of the text');
      // The last row shown is the prompt, whole, inside the text area.
      final cursor = render.cursorOffset;
      expect(cursor.dy, greaterThanOrEqualTo(8));
      expect(cursor.dy + row, lessThanOrEqualTo(height - 8 + 1e-6), reason: 'the prompt is whole above the bottom margin');
    });
  }
}
