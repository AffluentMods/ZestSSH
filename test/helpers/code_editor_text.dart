import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// The file editor's code (3.4: a re_editor CodeEditor) as the tests read
/// and set it: the current tab's controller, with its selection as offsets
/// into the whole text, as a TextField's were.
CodeLineEditingController editorCode(WidgetTester tester) =>
    tester.widget<CodeEditor>(find.byType(CodeEditor).first).controller!;

extension FlatCode on CodeLineEditingController {
  List<int> get _starts {
    final lines = text.split('\n');
    final starts = <int>[0];
    for (final l in lines) {
      starts.add(starts.last + l.length + 1);
    }
    return starts;
  }

  int _offset(int index, int column) => _starts[index] + column;

  CodeLinePosition _position(int offset) {
    final starts = _starts;
    var i = 0;
    while (i + 1 < starts.length - 1 && starts[i + 1] <= offset) {
      i++;
    }
    return CodeLinePosition(index: i, offset: offset - starts[i]);
  }

  /// The selection, as offsets into [text].
  TextSelection get flatSelection {
    final s = selection;
    return TextSelection(baseOffset: _offset(s.baseIndex, s.baseOffset), extentOffset: _offset(s.extentIndex, s.extentOffset));
  }

  set flatSelection(TextSelection s) {
    final a = _position(s.baseOffset);
    final b = _position(s.extentOffset);
    selection = CodeLineSelection(baseIndex: a.index, baseOffset: a.offset, extentIndex: b.index, extentOffset: b.offset);
  }

  /// The text set as [value] says, with its selection.
  set flatValue(TextEditingValue value) {
    text = value.text;
    flatSelection = value.selection;
  }
}
