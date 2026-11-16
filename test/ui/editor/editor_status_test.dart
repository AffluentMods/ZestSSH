import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';
import '../../helpers/fake_editor_source.dart';

/// The editor's status bar tells the truth (3.4, screens 1 and 1b): the
/// file's real encoding, which can be read again in another or saved with
/// another; its real line endings, kept on save (CRLF stayed CRLF only by
/// luck, and showed as LF); indentation per file; Ln, Col, which goes to a
/// line; and the language. A save first looks at the file's hash on its
/// host, so a file put back from an older copy is caught.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Finder status(String key) => find.byKey(ValueKey('editor-status-$key'));
  String said(WidgetTester tester, String key) =>
      tester.widget<Text>(find.descendant(of: status(key), matching: find.byType(Text)).first).data!;

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('a YAML file in UTF-8 with LF says so, two spaces, YAML, and where the caret is', (tester) async {
    final f = FakeEditorSource('/home/deploy/app/config.yaml', text: 'app:\n  name: shop\n  port: 8080\n');
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    expect(said(tester, 'encoding'), 'UTF-8');
    expect(said(tester, 'eol'), 'LF');
    expect(said(tester, 'indent'), en.editorIndentSpaces(2));
    expect(said(tester, 'language'), 'YAML');
    editorCode(tester).flatSelection = const TextSelection.collapsed(offset: 12);
    await tester.pump(const Duration(milliseconds: 150));
    expect(said(tester, 'position'), en.editorLnCol(2, 8));
  });

  testWidgets('a Windows file says CRLF, and a save writes CRLF', (tester) async {
    final f = FakeEditorSource('/srv/app.ini', bytes: utf8.encode('[app]\r\nport=1\r\n'));
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    expect(said(tester, 'eol'), 'CRLF');
    editorCode(tester).text = '[app]\nport=2\n';
    await tester.pump(const Duration(milliseconds: 150));
    await save(tester);
    expect(f.writes.single, utf8.encode('[app]\r\nport=2\r\n'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('line endings changed from the status bar are saved, and count as a change', (tester) async {
    final f = FakeEditorSource('/srv/app.ini', bytes: utf8.encode('a\r\nb\r\n'));
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    await tester.tap(status('eol'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-eol-lf')));
    await tester.pumpAndSettle();
    expect(said(tester, 'eol'), 'LF');
    expect(find.byKey(const ValueKey('editor-unsaved')), findsOneWidget);
    await save(tester);
    expect(f.writes.single, utf8.encode('a\nb\n'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a file with a byte order mark keeps it', (tester) async {
    final f = FakeEditorSource('/srv/notes.txt', bytes: [0xEF, 0xBB, 0xBF, ...utf8.encode('x\n')]);
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    expect(said(tester, 'encoding'), 'UTF-8 with BOM');
    editorCode(tester).text = 'y\n';
    await tester.pump(const Duration(milliseconds: 150));
    await save(tester);
    expect(f.writes.single, [0xEF, 0xBB, 0xBF, ...utf8.encode('y\n')]);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Save with another encoding writes the file in it; a letter it has no byte for is said, and nothing is written', (tester) async {
    final f = FakeEditorSource('/srv/legacy.txt', text: 'café\n');
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    await tester.tap(status('encoding'));
    await tester.pumpAndSettle();
    expect(find.text(en.editorEncodingNow('UTF-8')), findsOneWidget);
    await tester.tap(find.text(en.editorSaveWith));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-encoding-windows1252')));
    await tester.pumpAndSettle();
    expect(said(tester, 'encoding'), 'Windows-1252');
    await save(tester);
    expect(f.writes.single, [0x63, 0x61, 0x66, 0xE9, 0x0A]);
    await tester.pump(const Duration(seconds: 3));

    editorCode(tester).text = 'café \u{1F600}\n';
    await tester.pump(const Duration(milliseconds: 150));
    await save(tester);
    expect(f.writes, hasLength(1), reason: 'nothing written');
    final notices = ProviderScope.containerOf(tester.element(find.byType(TextEditorScreen))).read(notificationCenterProvider);
    expect(notices.history.first.title, en.editorCannotEncode('\u{1F600}', 1, 'Windows-1252'));
    expect(editorCode(tester).text, 'café \u{1F600}\n', reason: 'the text stays');
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('Reopen with reads the file again in the encoding picked', (tester) async {
    final f = FakeEditorSource('/srv/latin9.txt', bytes: [0x70, 0x72, 0x69, 0x63, 0x65, 0x20, 0xA4, 0x0A]);
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    // Not UTF-8: it opened as Windows-1252, with the notice.
    expect(find.text(en.editorNotUtf8Title), findsOneWidget);
    expect(editorCode(tester).text, 'price ¤\n');
    await tester.tap(find.text(en.editorPickEncoding));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-encoding-latin9')));
    await tester.pumpAndSettle();
    expect(editorCode(tester).text, 'price €\n');
    expect(said(tester, 'encoding'), 'ISO-8859-15');
    expect(find.byKey(const ValueKey('editor-unsaved')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a file put back from an older copy (same time, other contents) is caught before a save', (tester) async {
    final f = FakeEditorSource('/srv/app.conf', text: 'workers 4\n');
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    f.changedElsewhere('workers 9\n', sameTime: true);
    editorCode(tester).text = 'workers 8\n';
    await tester.pump(const Duration(milliseconds: 150));
    await save(tester);
    expect(find.text(en.textEditorFileChangedTitle), findsOneWidget);
    expect(f.writes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('editor-conflict-reload')));
    await tester.pumpAndSettle();
    expect(editorCode(tester).text, 'workers 9\n');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Ln, Col goes to a line', (tester) async {
    final f = FakeEditorSource('/srv/long.txt', text: List.generate(80, (i) => 'line ${i + 1}').join('\n'));
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    await tester.tap(status('position'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '64');
    await tester.tap(find.text(en.editorGoToLineAction));
    await tester.pumpAndSettle();
    expect(editorCode(tester).selection.extentIndex, 63);
    expect(said(tester, 'position'), en.editorLnCol(64, 1));
  });

  testWidgets('the code wears the terminal theme by default; turned off it wears the app theme, and that is kept', (tester) async {
    final f = FakeEditorSource('/srv/notes.txt');
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    CodeEditorStyle style() => tester.widget<CodeEditor>(find.byType(CodeEditor)).style!;
    final terminalKeyword = style().codeTheme!.theme['keyword']!.color;
    await tester.tap(find.byKey(const ValueKey('editor-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-more-look')));
    await tester.pumpAndSettle();
    expect(style().backgroundColor, AppColors.v3Background);
    expect(style().codeTheme!.theme['keyword']!.color, AppColors.v3AccentInk);
    expect(style().codeTheme!.theme['keyword']!.color, isNot(terminalKeyword));
    expect((await SharedPreferences.getInstance()).getBool('editor_terminal_look'), isFalse);
    expect(said(tester, 'font'), 'JetBrains Mono 13px');
  });
}
