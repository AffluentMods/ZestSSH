import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../helpers/code_editor_text.dart';
import '../helpers/fake_editor_source.dart';

/// The text editor to a screen reader and a finger (4.0 accessibility pass):
/// every control named, its text readable, and on a phone every target 48 by
/// 48. Names here are made up.
void main() {
  testWidgets("a computer's editor: every control named, its text readable", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    debugTouchLayout = false;
    final semantics = tester.ensureSemantics();
    try {
      final a = FakeEditorSource('/srv/app/config.yaml', text: 'app:\n  name: shop\n');
      final b = FakeEditorSource('/srv/app/notes.txt', text: 'hello\n');
      await openEditorPage(tester, [a, b], theme: AppTheme.dark());
      await openFile(tester, a);
      await openFile(tester, b);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
      debugTouchLayout = null;
    }
  });

  testWidgets("a phone's editor: targets a finger takes, every control named", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugTouchLayout = true;
    final semantics = tester.ensureSemantics();
    try {
      final a = FakeEditorSource('/srv/app/config.yaml', text: 'app:\n  name: shop\n');
      await openEditorPage(tester, [a], size: const Size(400, 860), theme: AppTheme.dark());
      await openFile(tester, a);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
      debugTouchLayout = null;
    }
  });

  testWidgets('the code is a text field named for its file, read a line at a time as the caret moves', (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    final semantics = tester.ensureSemantics();
    final a = FakeEditorSource('/srv/app/config.yaml', text: 'app:\n  name: shop\n');
    await openEditorPage(tester, [a], theme: AppTheme.dark());
    await openFile(tester, a);
    final node = find.bySemanticsLabel(en.a11yEditorName('config.yaml'));
    expect(node, findsOneWidget);
    var data = tester.getSemantics(node).getSemanticsData();
    expect(data.flagsCollection.isTextField, isTrue);
    expect(data.value, en.a11yEditorLine(1, 3, 'app:'));
    editorCode(tester).flatSelection = const TextSelection.collapsed(offset: 8);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    data = tester.getSemantics(node).getSemanticsData();
    expect(data.value, en.a11yEditorLine(2, 3, '  name: shop'));
    expect(find.byType(TextEditorScreen), findsOneWidget);
    semantics.dispose();
  });
}
