import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/editor/nano_keys.dart';

/// The editor's nano-style edits: logical lines, as in nano and the shell.
void main() {
  TextEditingValue at(String text, int caret) => TextEditingValue(
      text: text, selection: TextSelection.collapsed(offset: caret));

  group('line start and end (Ctrl+A, Ctrl+E)', () {
    const text = 'first line\nsecond line\nthird';

    test('from the middle of a line', () {
      expect(NanoEdits.moveToLineEdge(at(text, 15), end: false).selection,
          const TextSelection.collapsed(offset: 11));
      expect(NanoEdits.moveToLineEdge(at(text, 15), end: true).selection,
          const TextSelection.collapsed(offset: 22));
    });

    test('the first and the last line', () {
      expect(NanoEdits.moveToLineEdge(at(text, 3), end: false).selection.baseOffset, 0);
      expect(NanoEdits.moveToLineEdge(at(text, 25), end: true).selection.baseOffset,
          text.length);
    });

    test('already at the edge stays there', () {
      expect(NanoEdits.moveToLineEdge(at(text, 11), end: false).selection.baseOffset, 11);
      expect(NanoEdits.moveToLineEdge(at(text, 10), end: true).selection.baseOffset, 10);
    });
  });

  group('cut a line (Ctrl+K)', () {
    test('the whole line goes, with its line break, wherever the caret is', () {
      final r = NanoEdits.cutLine(at('one\ntwo\nthree', 5));
      expect(r.cut, 'two\n');
      expect(r.value.text, 'one\nthree');
      expect(r.value.selection, const TextSelection.collapsed(offset: 4));
    });

    test('the last line keeps a line break in the cut, so pasting gives a line', () {
      final r = NanoEdits.cutLine(at('one\ntwo', 6));
      expect(r.cut, 'two\n');
      expect(r.value.text, 'one\n');
    });

    test('an empty line is cut too', () {
      final r = NanoEdits.cutLine(at('one\n\ntwo', 4));
      expect(r.cut, '\n');
      expect(r.value.text, 'one\ntwo');
    });

    test('a selection is cut as it is', () {
      final r = NanoEdits.cutLine(const TextEditingValue(
          text: 'one two three',
          selection: TextSelection(baseOffset: 4, extentOffset: 8)));
      expect(r.cut, 'two ');
      expect(r.value.text, 'one three');
      expect(r.value.selection, const TextSelection.collapsed(offset: 4));
    });

    test('nothing to cut changes nothing', () {
      expect(NanoEdits.cutLine(at('', 0)).cut, '');
      final end = NanoEdits.cutLine(at('one\n', 4));
      expect(end.cut, '');
      expect(end.value.text, 'one\n');
    });
  });

  test('paste (Ctrl+U) goes in at the caret, replacing a selection', () {
    final pasted = NanoEdits.paste(at('one\nthree', 4), 'two\n');
    expect(pasted.text, 'one\ntwo\nthree');
    expect(pasted.selection, const TextSelection.collapsed(offset: 8));
    final over = NanoEdits.paste(
        const TextEditingValue(
            text: 'a b c', selection: TextSelection(baseOffset: 2, extentOffset: 3)),
        'X');
    expect(over.text, 'a X c');
  });

  test('where a line starts, for Go to line', () {
    const text = 'a\nbb\nccc';
    expect(NanoEdits.offsetOfLine(text, 1), 0);
    expect(NanoEdits.offsetOfLine(text, 2), 2);
    expect(NanoEdits.offsetOfLine(text, 3), 5);
    expect(NanoEdits.offsetOfLine(text, 99), 5, reason: 'clamped to the last line');
  });
}
