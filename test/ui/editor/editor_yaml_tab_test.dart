import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';

/// Found while reading the editor for 3.4: Tab typed a tab
/// character in a YAML file, which YAML does not allow in its indentation,
/// so the file no longer loaded. Tab types two spaces there now, and still
/// a tab in a file indented with tabs.
void main() {
  // The code editor takes Tab itself on a computer, and decides which it is
  // once per test file: every test here is a computer's (a phone's Tab is
  // in editor_phone_test).
  final computer = TargetPlatformVariant.only(TargetPlatform.windows);

  Future<void> open(WidgetTester tester, String fileName) async {
    SharedPreferences.setMockInitialValues({});
    final saved = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
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
            initialContent: 'app:\n',
            onSave: (_) async {},
            popOutEnabled: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The editor's text after Tab is pressed at its end.
  Future<String> tabAtTheEnd(WidgetTester tester) async {
    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
    final code = editorCode(tester);
    code.flatSelection = TextSelection.collapsed(offset: code.text.length);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 150));
    return code.text;
  }

  for (final name in ['config.yaml', 'compose.yml']) {
    testWidgets('Tab types two spaces in $name', (tester) async {
      await open(tester, name);
      final text = await tabAtTheEnd(tester);
      expect(text, 'app:\n  ');
      expect(text.contains('\t'), isFalse);
    }, variant: computer);
  }

  testWidgets('Tab still types a tab in a file that may hold one', (tester) async {
    await open(tester, 'Makefile');
    expect(await tabAtTheEnd(tester), 'app:\n\t');
  }, variant: computer);

  testWidgets('a file indented with four spaces gets four', (tester) async {
    await open(tester, 'notes.txt');
    expect(await tabAtTheEnd(tester), 'app:\n    ');
  }, variant: computer);
}
