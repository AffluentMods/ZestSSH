import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:zestssh/ui/screens/editor/editor_find.dart';

/// Find and replace in the file editor (3.4): match case, whole word, regex
/// and in the selection (it was plain, case-sensitive text only), and
/// Replace all as one step to undo.
void main() {
  const text = 'upstream app_backend {\n'
      '  server 10.50.0.11:8080;\n'
      '}\n'
      'proxy_pass http://app_backend;\n'
      'App_Backend is the old name\n';

  (CodeLineEditingController, EditorFindController) open([String t = text]) {
    final c = CodeLineEditingController.fromText(t);
    final f = EditorFindController(c);
    addTearDown(() {
      f.dispose();
      c.dispose();
    });
    return (c, f);
  }

  void look(EditorFindController f, String pattern) {
    f.findMode();
    f.findInputController.text = pattern;
  }

  test('ignores case unless asked, and counts the matches', () {
    final (_, f) = open();
    look(f, 'app_backend');
    expect(f.matchCount, 3);
    f.toggleCaseSensitive();
    expect(f.matchCount, 2);
  });

  test('whole word leaves a match inside a longer word', () {
    final (_, f) = open('server serverless server_name server\n');
    look(f, 'server');
    expect(f.matchCount, 4, reason: 'server_name is a word of its own to a regex, serverless is not');
    f.toggleWholeWord();
    expect(f.matchCount, 2);
  });

  test('a regex finds by pattern; one that does not read as one is said, and finds nothing', () {
    final (_, f) = open();
    look(f, r'10\.50\.0\.\d+');
    expect(f.matchCount, 0, reason: 'as plain text, it is not there');
    f.toggleRegex();
    expect(f.matchCount, 1);
    f.findInputController.text = '(unclosed';
    expect(f.badPattern, isTrue);
    expect(f.matchCount, 0);
  });

  test('next and previous go round', () {
    final (_, f) = open();
    look(f, 'app_backend');
    expect(f.currentIndex, 0);
    f.nextMatch();
    f.nextMatch();
    expect(f.currentIndex, 2);
    f.nextMatch();
    expect(f.currentIndex, 0);
    f.previousMatch();
    expect(f.currentIndex, 2);
  });

  test('in the selection: only what was selected is searched and replaced', () {
    final (c, f) = open('a = 1\na = 2\na = 3\n');
    look(f, 'a');
    expect(f.matchCount, 3);
    c.selection = const CodeLineSelection(baseIndex: 1, baseOffset: 0, extentIndex: 2, extentOffset: 5);
    f.toggleInSelection();
    expect(f.matchCount, 2);
    f.replaceInputController.text = 'b';
    f.replaceAllMatches();
    expect(c.text, 'a = 1\nb = 2\nb = 3\n');
  });

  test('Replace replaces the current match and moves to the next', () {
    final (c, f) = open();
    look(f, 'app_backend');
    f.toggleCaseSensitive();
    f.replaceInputController.text = 'shop_backend';
    f.replaceMatch();
    expect(c.text, contains('upstream shop_backend {'));
    expect(c.text, contains('http://app_backend'));
    expect(f.matchCount, 1);
  });

  test('Replace all is one step to undo', () {
    final (c, f) = open();
    look(f, 'app_backend');
    f.replaceInputController.text = 'shop_backend';
    f.replaceAllMatches();
    expect(c.text, isNot(contains('app_backend')));
    expect('shop_backend'.allMatches(c.text), hasLength(3));
    c.undo();
    expect(c.text, text);
  });

  test('closing forgets the selection it searched in', () {
    final (c, f) = open('a\na\n');
    look(f, 'a');
    c.selection = const CodeLineSelection(baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 1);
    f.toggleInSelection();
    expect(f.matchCount, 1);
    f.close();
    expect(f.isOpen, isFalse);
    look(f, 'a');
    expect(f.inSelection, isFalse);
    expect(f.matchCount, 2);
  });
}
