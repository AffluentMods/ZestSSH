import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_gutter.dart';

import '../../helpers/code_editor_text.dart';

/// Found while reading the editor for 3.4: with wrap on (the
/// default) the gutter gave every line one row, so once a long line wrapped
/// onto more rows, the numbers below it no longer stood beside their lines.
/// In the redesign each number stands level with the first row of its own
/// line, and a wrapped line's further rows have none.
void main() {
  const long = 'proxy_set_header X-Forwarded-For '
      r'$proxy_add_x_forwarded_for; # a long line that wraps, as a comment '
      'often does, onto a second and a third row of the window';
  const content = '$long\nsecond\nthird';

  Future<void> open(WidgetTester tester, String text) async {
    SharedPreferences.setMockInitialValues({});
    final saved = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(760, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(saved)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: TextEditorScreen(fileName: 'site.conf', initialContent: text, onSave: (_) async {}, popOutEnabled: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The gutter stands beside the code from its top to its bottom, so a
  /// number drawn at a line's place in it is beside that line.
  void besideTheCode(WidgetTester tester) {
    final gutter = tester.getRect(find.byKey(const ValueKey('editor-gutter')));
    final code = tester.getRect(find.byType(CodeEditor));
    expect(gutter.top, code.top);
    expect(gutter.bottom, code.bottom);
  }

  EditorGutterPainter gutter(WidgetTester tester) =>
      tester.widget<CustomPaint>(find.byKey(const ValueKey('editor-gutter'))).painter! as EditorGutterPainter;

  testWidgets('each number stands level with the first row of its own line after a wrapped line', (tester) async {
    await open(tester, content);
    besideTheCode(tester);
    final painter = gutter(tester);
    final paragraphs = painter.notifier.value!.paragraphs;
    final row = paragraphs.first.preferredLineHeight;
    expect(paragraphs.first.height, greaterThan(row * 1.5), reason: 'line 1 wraps onto more than one row');
    final middles = {for (final (line, middle) in painter.painted) line: middle};
    expect(middles.keys.take(3), [1, 2, 3], reason: 'no number for a wrapped row');
    for (var i = 0; i < 3; i++) {
      expect(middles[i + 1], closeTo(paragraphs[i].offset.dy + row / 2, 0.5));
    }
    // The old gutter put line 2's number one row under line 1's.
    expect(middles[2]! - middles[1]!, closeTo(paragraphs.first.height, 0.5));
    expect(middles[2]! - middles[1]!, greaterThan(row * 1.5));
  });

  testWidgets('with wrap off every line is one row', (tester) async {
    await open(tester, content);
    await tester.tap(find.byKey(const ValueKey('editor-tool-wrap')));
    await tester.pumpAndSettle();
    final painter = gutter(tester);
    final row = painter.notifier.value!.paragraphs.first.preferredLineHeight;
    final middles = {for (final (line, middle) in painter.painted) line: middle};
    expect(middles[2]! - middles[1]!, closeTo(row, 0.5));
  });

  testWidgets('the bar beside changed lines marks the lines that differ from the save', (tester) async {
    await open(tester, 'one\ntwo\nthree\nfour');
    expect(gutter(tester).barred, isEmpty);
    editorCode(tester).text = 'one\nTWO\nthree\nfour';
    await tester.pumpAndSettle();
    expect(gutter(tester).barred, [2]);
    expect(find.text('1 unsaved line'), findsOneWidget);
  });

  testWidgets('two edits apart mark their own two lines, not every line between them', (tester) async {
    await open(tester, 'one\ntwo\nthree\nfour\nfive\n');
    editorCode(tester).text = 'one\nTWO\nthree\nfour\nFIVE\n';
    await tester.pumpAndSettle();
    expect(gutter(tester).barred, [2, 5]);
    expect(find.text('2 unsaved lines'), findsOneWidget);
    // A line put in counts the lines from it to the last change.
    editorCode(tester).text = 'one\nnew\ntwo\nthree\nfour\nfive\n';
    await tester.pumpAndSettle();
    expect(gutter(tester).barred, [2]);
  });
}
