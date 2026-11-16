import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:re_editor/re_editor.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';

/// The file editor's nano keys, pressed for real: Ctrl+A/E line start and
/// end, Ctrl+K cuts lines (in a row they collect), Ctrl+U pastes them back,
/// Alt+U undoes, Ctrl+Shift+A selects all, and the status bar chip switches
/// back to the standard keys (Ctrl+A selects all again).
void main() {
  // The code editor takes its own keys (select all, undo) on a computer
  // only, and decides which it is once per test file: every test here is a
  // computer's.
  final computer = TargetPlatformVariant.only(TargetPlatform.windows);

  late List<String> clipboard;

  setUp(() {
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  Future<CodeLineEditingController> open(WidgetTester tester, String text,
      {Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    final saved = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(saved)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: TextEditorScreen(
          fileName: 'notes.txt',
          initialContent: text,
          popOutEnabled: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
    return editorCode(tester);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key,
      {bool control = false, bool shift = false, bool alt = false}) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(key);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Past the code editor's caret start on a phone (a test's platform),
    // which waits 100 ms.
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('Ctrl+A and Ctrl+E go to the start and end of the line',
      (tester) async {
    final c = await open(tester, 'alpha\nbravo charlie\ndelta');
    c.flatSelection = const TextSelection.collapsed(offset: 9);
    await press(tester, LogicalKeyboardKey.keyE, control: true);
    expect(c.flatSelection, const TextSelection.collapsed(offset: 19));
    await press(tester, LogicalKeyboardKey.keyA, control: true);
    expect(c.flatSelection, const TextSelection.collapsed(offset: 6));
  }, variant: computer);

  testWidgets('Ctrl+K cuts lines, collecting a run, and Ctrl+U puts them back',
      (tester) async {
    final c = await open(tester, 'one\ntwo\nthree\nfour');
    c.flatSelection = const TextSelection.collapsed(offset: 5);
    await press(tester, LogicalKeyboardKey.keyK, control: true);
    await press(tester, LogicalKeyboardKey.keyK, control: true);
    expect(c.text, 'one\nfour');
    expect(clipboard.last, 'two\nthree\n', reason: 'the run is on the clipboard too');

    // Paste the collected lines on a new last line (key presses do not
    // type text in a widget test, so the line break is set directly).
    c.flatValue = const TextEditingValue(
        text: 'one\nfour\n', selection: TextSelection.collapsed(offset: 9));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyU, control: true);
    expect(c.text, 'one\nfour\ntwo\nthree\n');

    // A cut after something else starts a new run.
    c.flatSelection = const TextSelection.collapsed(offset: 0);
    await press(tester, LogicalKeyboardKey.keyK, control: true);
    expect(clipboard.last, 'one\n');
  }, variant: computer);

  testWidgets('Alt+U undoes a cut', (tester) async {
    final c = await open(tester, 'keep\ncut me\nkeep');
    c.flatSelection = const TextSelection.collapsed(offset: 6);
    await tester.pump(const Duration(seconds: 1));
    await press(tester, LogicalKeyboardKey.keyK, control: true);
    expect(c.text, 'keep\nkeep');
    await tester.pump(const Duration(seconds: 1));
    await press(tester, LogicalKeyboardKey.keyU, alt: true);
    expect(c.text, 'keep\ncut me\nkeep');
  }, variant: computer);

  testWidgets('Ctrl+Shift+A selects all while nano keys are on',
      (tester) async {
    final c = await open(tester, 'abc\ndef');
    await press(tester, LogicalKeyboardKey.keyA, control: true, shift: true);
    expect(c.flatSelection, const TextSelection(baseOffset: 0, extentOffset: 7));
  }, variant: computer);

  testWidgets('the chip switches to standard keys, and it is remembered',
      (tester) async {
    final c = await open(tester, 'abc\ndef');
    await tester.tap(find.byKey(const ValueKey('editor-nano-keys')));
    await tester.pump();
    final saved = await SharedPreferences.getInstance();
    expect(saved.getBool('editor_nano_keys'), isFalse);

    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
    c.flatSelection = const TextSelection.collapsed(offset: 5);
    await press(tester, LogicalKeyboardKey.keyA, control: true);
    expect(c.flatSelection, const TextSelection(baseOffset: 0, extentOffset: 7),
        reason: 'standard Ctrl+A selects all');
    await press(tester, LogicalKeyboardKey.keyK, control: true);
    expect(c.text, 'abc\ndef', reason: 'no nano cut with standard keys');
  }, variant: computer);

  testWidgets('a device that turned them off opens with standard keys',
      (tester) async {
    final c = await open(tester, 'abc\ndef', prefs: {'editor_nano_keys': false});
    c.flatSelection = const TextSelection.collapsed(offset: 5);
    await press(tester, LogicalKeyboardKey.keyE, control: true);
    expect(c.flatSelection, isNot(const TextSelection.collapsed(offset: 7)));
  }, variant: computer);

  testWidgets('Ctrl+G lists the keys', (tester) async {
    await open(tester, 'abc');
    await press(tester, LogicalKeyboardKey.keyG, control: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-keys-list')), findsOneWidget);
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.editorKeyCut), findsOneWidget);
  }, variant: computer);
}
