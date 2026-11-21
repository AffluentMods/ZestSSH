// A terminal on a phone or a tablet takes a keyboard's letters through the
// text input connection. That connection goes when something else takes the
// focus (a menu, a dialog), and it was opened again only when the terminal
// was asked to take the focus, not when the focus came back by itself as
// the dialog closed: Enter and the arrows (plain keys) then arrived and the
// letters went nowhere until a tap (seen on a tablet with a keyboard, 21
// November 2026). It is connected again now, without bringing the on-screen
// keyboard up.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('the focus back from a dialog: letters arrive again, and no on-screen keyboard comes up', (tester) async {
    final typed = <String>[];
    final terminal = Terminal()..onOutput = typed.add;
    final focus = FocusNode(debugLabel: 'terminal');
    addTearDown(focus.dispose);
    late BuildContext page;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          page = context;
          return TerminalView(terminal, focusNode: focus, hardwareKeyboardOnly: false, keyboardOnTap: false);
        }),
      ),
    ));
    // Asked to take the keyboard, as the app does for the terminal in front.
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'a', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(typed.join(), 'a');
    tester.testTextInput.hide();

    // A dialog takes the focus, and gives it back as it closes.
    final closed = showDialog<void>(
      context: page,
      builder: (context) => AlertDialog(
        content: const Text('a question'),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );
    await tester.pumpAndSettle();
    expect(focus.hasPrimaryFocus, isFalse);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await closed;
    expect(focus.hasPrimaryFocus, isTrue, reason: 'the focus came back by itself');

    expect(tester.testTextInput.hasAnyClients, isTrue, reason: 'connected again, so a keyboard\'s letters arrive');
    expect(tester.testTextInput.isVisible, isFalse, reason: 'the on-screen keyboard is left as it was');
    typed.clear();
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'b', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(typed.join(), 'b');
    // Plain keys arrived before as well, and still do.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(typed.join(), 'b\r');
  });

  testWidgets('a view built anew while its focus node has the focus: letters still arrive', (tester) async {
    final typed = <String>[];
    final terminal = Terminal()..onOutput = typed.add;
    final focus = FocusNode(debugLabel: 'pane');
    addTearDown(focus.dispose);
    Widget app(Key key) => MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, key: key, focusNode: focus, hardwareKeyboardOnly: false, keyboardOnTap: false),
          ),
        );
    await tester.pumpWidget(app(const ValueKey('first')));
    focus.requestFocus();
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.hide();

    // Drawn again as another view (as tmux's panes are by Resync panes): the
    // node keeps the focus, so no change of focus comes.
    await tester.pumpWidget(app(const ValueKey('second')));
    await tester.pump();
    expect(focus.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: 'the new view is connected');
    expect(tester.testTextInput.isVisible, isFalse, reason: 'and brought no on-screen keyboard up');
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'c', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(typed.join(), 'c');
  });
}
