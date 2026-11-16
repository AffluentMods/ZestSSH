import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';

/// Popping the editor out with unsaved changes hands the text to the new
/// window and closes the in-app editor without asking to discard: the back
/// guard of 8b999b70 answered the pop-out's maybePop with "Discard?", which
/// reads as throwing the edits away though they are in the other window, and
/// Cancel left two editors on one file (found in a
/// UI review).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  const windows = MethodChannel('mixin.one/flutter_multi_window');

  /// The editor opened over a page, with [answer] for opening a window.
  Future<List<Map<String, dynamic>>> open(WidgetTester tester, {required Object? Function() answer}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final made = <Map<String, dynamic>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, (call) async {
      if (call.method == 'createWindow') {
        made.add(jsonDecode(call.arguments as String) as Map<String, dynamic>);
        return answer();
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, null));
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => TextEditorScreen(
                    fileName: 'notes.txt',
                    initialContent: 'alpha',
                    popOutEnabled: true,
                    onSave: (_) async {},
                  ),
                )),
                child: const Text('Open the file'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open the file'));
    await tester.pumpAndSettle();
    // A change not saved yet.
    editorCode(tester).text = 'alpha beta';
    await tester.pump();
    return made;
  }

  void forget(List<Map<String, dynamic>> made) => EditorWindows.instance.reset();

  testWidgets('a window that opens takes the unsaved text, and the editor here closes without asking',
      (tester) async {
    final made = await open(tester, answer: () => 7);
    await tester.tap(find.byTooltip('Open in a separate window'));
    await tester.pumpAndSettle();
    expect(made, hasLength(1));
    final tab = EditorWindows.instance.bridge(made.single['editKey'] as String)!.pending!;
    expect(tab.text, 'alpha beta');
    expect(tab.savedText, 'alpha', reason: 'the window shows it unsaved, as it was here');
    expect(find.text(en.editorSaveChangesTitle('notes.txt')), findsNothing,
        reason: 'nothing is thrown away: the text is in the new window');
    expect(find.byType(TextEditorScreen), findsNothing);
    expect(find.text('Open the file'), findsOneWidget);
    forget(made);
  });

  testWidgets('a window that does not open leaves the editor here, its text kept, and asks nothing',
      (tester) async {
    final made = await open(tester, answer: () => throw PlatformException(code: 'failed', message: 'No window today'));
    await tester.tap(find.byTooltip('Open in a separate window'));
    await tester.pump();
    await tester.pump();
    expect(find.text(en.editorSaveChangesTitle('notes.txt')), findsNothing);
    expect(find.byType(TextEditorScreen), findsOneWidget);
    expect(editorCode(tester).text, 'alpha beta');
    forget(made);
    await tester.pump(const Duration(seconds: 8));
  });
}
