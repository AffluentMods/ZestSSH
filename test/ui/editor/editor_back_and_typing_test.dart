import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';

/// Found while reading the editor for 3.4: back on Android and a
/// swipe back on an iPhone closed it with changes unsaved, past the question
/// its own close button asks; and a phone keyboard's typing aids rewrote what
/// was typed (a straight quote into a curly one, two hyphens into a long
/// dash) in config files and scripts. The redesign (3.4) keeps both: back
/// asks "Save changes to nginx.conf?", and the code editor asks the keyboard
/// for no corrections, smart quotes or smart dashes.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  /// The editor, opened over a page as it is in the app.
  Future<void> open(WidgetTester tester, {List<String>? saves}) async {
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
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-editor'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TextEditorScreen(
                      fileName: 'nginx.conf',
                      initialContent: 'server {}',
                      onSave: (text) async => saves?.add(text),
                      popOutEnabled: false,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-editor')));
    await tester.pumpAndSettle();
  }

  Future<void> change(WidgetTester tester, String text) async {
    editorCode(tester).text = text;
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('back with nothing changed closes the editor', (tester) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextEditorScreen), findsNothing);
  });

  testWidgets('back with changes not saved asks first, and Cancel keeps them', (tester) async {
    await open(tester);
    await change(tester, 'server { listen 80; }');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveChangesTitle('nginx.conf')), findsOneWidget);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(TextEditorScreen), findsOneWidget);
    expect(editorCode(tester).text, 'server { listen 80; }');
  });

  testWidgets("back with changes, then Don't save, closes it", (tester) async {
    await open(tester);
    await change(tester, 'changed');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-dont-save')));
    await tester.pumpAndSettle();
    expect(find.byType(TextEditorScreen), findsNothing);
  });

  testWidgets('back with changes, then Save, saves and closes it', (tester) async {
    final saves = <String>[];
    await open(tester, saves: saves);
    await change(tester, 'server { listen 443; }');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-save-and-close')));
    await tester.pumpAndSettle();
    expect(saves, ['server { listen 443; }']);
    expect(find.byType(TextEditorScreen), findsNothing);
    // The "Saved" notice goes.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('what is typed is what is saved: no keyboard aids in the text', (tester) async {
    await open(tester);
    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
    final setClient = tester.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient');
    final config = (setClient.arguments as List)[1] as Map;
    expect(config['autocorrect'], isFalse);
    expect(config['smartQuotesType'], '${SmartQuotesType.disabled.index}');
    expect(config['smartDashesType'], '${SmartDashesType.disabled.index}');
    expect(config['textCapitalization'], 'TextCapitalization.none');
  });
}
