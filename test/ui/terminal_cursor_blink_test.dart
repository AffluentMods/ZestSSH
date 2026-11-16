import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The vendored xterm cursor blink (`TerminalView.cursorBlink`). The timer
/// lives on the render object; these tests drive it with fake time. The
/// vendored package has no test directory of its own, so the focused test
/// lives here, next to the other xterm-facing app tests.

/// One blink phase, mirrors RenderTerminal.cursorBlinkInterval.
const _phase = Duration(milliseconds: 530);

Future<TerminalViewState> _pump(
  WidgetTester tester, {
  required Terminal terminal,
  required FocusNode focusNode,
  bool cursorBlink = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 200,
          child: TerminalView(
            terminal,
            focusNode: focusNode,
            autofocus: true,
            cursorBlink: cursorBlink,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.state<TerminalViewState>(find.byType(TerminalView));
}

void main() {
  testWidgets('focused cursor toggles every phase and stops solid on unfocus',
      (tester) async {
    final terminal = Terminal(maxLines: 100);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    final state =
        await _pump(tester, terminal: terminal, focusNode: focusNode);
    final render = state.renderTerminal;
    expect(focusNode.hasFocus, isTrue, reason: 'autofocus must land');
    expect(render.isCursorBlinking, isTrue);
    expect(render.cursorBlinkVisible, isTrue);

    await tester.pump(_phase);
    expect(render.cursorBlinkVisible, isFalse, reason: 'hidden phase');
    await tester.pump(_phase);
    expect(render.cursorBlinkVisible, isTrue, reason: 'shown phase');
    await tester.pump(_phase);
    expect(render.cursorBlinkVisible, isFalse);

    // Losing focus stops the timer and leaves the cursor shown.
    focusNode.unfocus();
    await tester.pump();
    expect(render.isCursorBlinking, isFalse);
    expect(render.cursorBlinkVisible, isTrue);
    await tester.pump(_phase * 3);
    expect(render.cursorBlinkVisible, isTrue,
        reason: 'an unfocused cursor never blinks');

    // Regaining focus starts it again.
    focusNode.requestFocus();
    await tester.pump();
    expect(render.isCursorBlinking, isTrue);
    await tester.pump(_phase);
    expect(render.cursorBlinkVisible, isFalse);

    // Tearing the view down cancels the timer (the binding would also fail
    // the test on a leaked periodic timer).
    await tester.pumpWidget(const SizedBox());
    expect(render.isCursorBlinking, isFalse);
  });

  testWidgets('key input and terminal output show the cursor and restart '
      'the phase', (tester) async {
    final terminal = Terminal(maxLines: 100);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    final state =
        await _pump(tester, terminal: terminal, focusNode: focusNode);
    final render = state.renderTerminal;

    await tester.pump(_phase);
    expect(render.cursorBlinkVisible, isFalse);

    // A keystroke while hidden shows the cursor at once and restarts the
    // period: it stays shown for a full phase from the keystroke, not from
    // the previous tick.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(render.cursorBlinkVisible, isTrue);
    await tester.pump(_phase - const Duration(milliseconds: 30));
    expect(render.cursorBlinkVisible, isTrue,
        reason: 'the period restarted at the keystroke');
    await tester.pump(const Duration(milliseconds: 60));
    expect(render.cursorBlinkVisible, isFalse);

    // Terminal output does the same.
    terminal.write('x');
    expect(render.cursorBlinkVisible, isTrue);
    await tester.pump(_phase - const Duration(milliseconds: 30));
    expect(render.cursorBlinkVisible, isTrue);
    await tester.pump(const Duration(milliseconds: 60));
    expect(render.cursorBlinkVisible, isFalse);
  });

  testWidgets('cursorBlink false (the default) never starts a timer',
      (tester) async {
    final terminal = Terminal(maxLines: 100);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    final state = await _pump(
      tester,
      terminal: terminal,
      focusNode: focusNode,
      cursorBlink: false,
    );
    final render = state.renderTerminal;
    expect(focusNode.hasFocus, isTrue);
    expect(render.isCursorBlinking, isFalse);
    await tester.pump(_phase * 3);
    expect(render.cursorBlinkVisible, isTrue);
  });
}
