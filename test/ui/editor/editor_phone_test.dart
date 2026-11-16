import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';

/// The editor on a phone (3.4, as
/// designed): its own layout, nothing drawn under the system's bars (3.3), the
/// actions at the bottom in thumb reach (Save, Find, Undo, Redo, More), the
/// keys row above the keyboard in a fixed order, and the More sheet.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  /// The editor on a phone 390 by 844 whose status bar takes 47 and whose
  /// navigation bar takes 34.
  Future<void> open(
    WidgetTester tester, {
    String fileName = 'config.yaml',
    String text = 'app:\n  name: shop\n',
    Future<void> Function(String content)? onSave,
    Size size = const Size(390, 844),
    double top = 47,
    double bottom = 34,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final saved = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: top, bottom: bottom);
    tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(saved)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: TextEditorScreen(
            fileName: fileName,
            hostLabel: 'web-01',
            filePath: '/home/deploy/app/$fileName',
            initialContent: text,
            onSave: onSave ?? (_) async {},
            popOutEnabled: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The keyboard comes up over the bottom 300 of the screen, and the code
  /// takes it.
  Future<void> type(WidgetTester tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
  }

  testWidgets('nothing is drawn under the status bar or the navigation bar, which stay black with light icons', (tester) async {
    await open(tester);
    expect(tester.getRect(find.byKey(const ValueKey('editor-phone-top'))).top, greaterThanOrEqualTo(47));
    expect(tester.getRect(find.byKey(const ValueKey('editor-phone-bar'))).bottom, lessThanOrEqualTo(844 - 34));
    final scaffold = tester.widget<Scaffold>(
      find.descendant(of: find.byType(TextEditorScreen), matching: find.byType(Scaffold)).first,
    );
    expect(scaffold.backgroundColor, AppColors.systemBarsBlack);
    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.descendant(of: find.byType(TextEditorScreen), matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).first,
    );
    expect(region.value.statusBarIconBrightness, Brightness.light);
    expect(region.value.systemNavigationBarIconBrightness, Brightness.light);
    expect(region.value.systemNavigationBarColor, AppColors.systemBarsBlack);
  });

  testWidgets('the bottom bar has Save, Find, Undo, Redo and More, Save only once there is something to save', (tester) async {
    final saved = <String>[];
    await open(tester, onSave: (t) async => saved.add(t));
    for (final key in ['save', 'find', 'undo', 'redo', 'more']) {
      expect(find.byKey(ValueKey('editor-phone-$key')), findsOneWidget, reason: key);
    }
    final save = find.byKey(const ValueKey('editor-phone-save'));
    expect(tester.widget<InkWell>(save).onTap, isNull, reason: 'nothing to save yet');
    editorCode(tester).text = 'app:\n  name: store\n';
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(save).onTap, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, ['app:\n  name: store\n']);
    // Undo is there for what was typed.
    expect(tester.widget<InkWell>(find.byKey(const ValueKey('editor-phone-undo'))).onTap, isNotNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Find opens the find bar, and Find again closes it', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('editor-phone-find')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-find-bar')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('editor-find-field')), 'name');
    await tester.pumpAndSettle();
    expect(find.text(en.editorMatchCount(1, 1)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-phone-find')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-find-bar')), findsNothing);
  });

  testWidgets('with the keyboard up, the keys row sits above it in its fixed order, and its keys type', (tester) async {
    await open(tester);
    await type(tester);
    expect(find.byKey(const ValueKey('editor-keys-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-phone-bar')), findsNothing, reason: 'the keys row takes its place');
    expect(tester.getRect(find.byKey(const ValueKey('editor-keys-row'))).bottom, lessThanOrEqualTo(844 - 300));
    expect(find.byKey(const ValueKey('editor-phone-done')), findsOneWidget);
    // Tab, Esc, Undo, Redo, the brackets, then the arrows, left to right.
    final order = ['tab', 'esc', 'undo', 'redo', '{', '}', '[', ']', '(', ')', 'left', 'up', 'down', 'right'];
    final xs = [for (final k in order) tester.getTopLeft(find.byKey(ValueKey('editor-key-$k'), skipOffstage: false)).dx];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i], greaterThan(xs[i - 1]), reason: '${order[i]} after ${order[i - 1]}');
    }
    final code = editorCode(tester);
    code.flatSelection = TextSelection.collapsed(offset: code.text.length);
    await tester.pump(const Duration(milliseconds: 150));
    // YAML: Tab is two spaces.
    await tester.tap(find.byKey(const ValueKey('editor-key-tab')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('editor-key-{')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(code.text, 'app:\n  name: shop\n  {');
    // The row slides sideways to the arrows.
    await tester.ensureVisible(find.byKey(const ValueKey('editor-key-left'), skipOffstage: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-key-left')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(code.flatSelection, TextSelection.collapsed(offset: code.text.length - 1));
    // And back to Undo.
    await tester.drag(find.byKey(const ValueKey('editor-keys-row')), const Offset(600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-key-undo')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(code.text, isNot(contains('{')));
    // Done puts the keyboard away.
    await tester.tap(find.byKey(const ValueKey('editor-phone-done')));
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-phone-bar')), findsOneWidget);
  });

  testWidgets('More opens one sheet with go to line, wrap, text size, encoding, line endings, language and close tab', (tester) async {
    await open(tester, text: List.generate(60, (i) => 'line ${i + 1}').join('\n'));
    await tester.tap(find.byKey(const ValueKey('editor-phone-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-more-sheet')), findsOneWidget);
    expect(find.text(en.editorLineOf(1, 60)), findsOneWidget);
    for (final words in [en.editorWrapLines, en.editorTextSize, en.editorEncodingTitle, en.editorLineEndingsTitle, en.editorLanguageTitle, en.editorCloseTab]) {
      expect(find.text(words), findsOneWidget, reason: words);
    }
    expect(find.text('UTF-8'), findsOneWidget);
    expect(find.text('LF'), findsOneWidget);
    // Text size, bigger.
    final before = int.parse(tester.widget<Text>(find.descendant(
      of: find.ancestor(of: find.byKey(const ValueKey('editor-sheet-bigger')), matching: find.byType(Row)).first,
      matching: find.byType(Text),
    )).data!);
    await tester.tap(find.byKey(const ValueKey('editor-sheet-bigger')));
    await tester.pumpAndSettle();
    expect(find.text('${before + 1}'), findsOneWidget);
    // Wrap off.
    await tester.tap(find.byKey(const ValueKey('editor-sheet-wrap')));
    await tester.pumpAndSettle();
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).wordWrap, isFalse);
    // Go to line asks for one.
    await tester.tap(find.byKey(const ValueKey('editor-sheet-line')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorGoToLineLabel(60)), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '42');
    await tester.tap(find.text(en.editorGoToLineAction));
    await tester.pumpAndSettle();
    expect(editorCode(tester).selection.extentIndex, 41);
  });

  testWidgets('on a computer, the tabs and the toolbar are at the top as before', (tester) async {
    await open(tester, size: const Size(1200, 800), top: 0, bottom: 0);
    expect(find.byKey(const ValueKey('editor-phone-bar')), findsNothing);
    expect(tester.getRect(find.byKey(const ValueKey('editor-tabs'))).top, 0);
    expect(tester.getRect(find.byKey(const ValueKey('editor-save'))).top, lessThan(100));
    expect(find.byKey(const ValueKey('editor-status')), findsOneWidget);
  });
}
