import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SftpStatusCode, SftpStatusError;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sudo_runner.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/widgets/sudo_password_dialog.dart' show sudoWordsShown;
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/code_editor_text.dart';
import '../../helpers/fake_editor_source.dart';

/// Save as root (3.4: asks first, the
/// password typed each time and never stored). It shows only for a file the
/// login account may not write on a host with sudo; Save and Ctrl+S on such
/// a file ask the same; a save refused with Permission denied offers it; a
/// wrong password is said in the dialog, and the text stays.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const rootOwned = FileAccess(owner: 'root:root', mode: '644', writable: false, canSudo: true);

  FakeEditorSource nginx({FileAccess? access = rootOwned}) =>
      FakeEditorSource('/etc/nginx/nginx.conf', text: 'user www-data;\n', accessIs: access);

  Future<void> change(WidgetTester tester, String text) async {
    editorCode(tester).text = text;
    await tester.pump(const Duration(milliseconds: 150));
  }

  Future<void> typePassword(WidgetTester tester, String password) async {
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('editor-sudo-password')), matching: find.byType(TextField)),
      password,
    );
    await tester.tap(find.byKey(const ValueKey('editor-sudo-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('a root-owned file shows its owner and Save as root; a file the account may write does not', (tester) async {
    final root = nginx();
    final mine = FakeEditorSource('/home/deploy/app/config.yaml', text: 'a: 1\n',
        accessIs: const FileAccess(owner: 'deploy:deploy', mode: '644', writable: true, canSudo: true));
    await openEditorPage(tester, [root, mine]);
    await openFile(tester, root);
    expect(find.byKey(const ValueKey('editor-save-as-root')), findsOneWidget);
    expect(find.text('root:root 644'), findsOneWidget);
    await openFile(tester, mine);
    expect(find.byKey(const ValueKey('editor-save-as-root')), findsNothing);
    expect(find.text('deploy:deploy 644'), findsOneWidget);
  });

  testWidgets('a host without a shell or without sudo shows no Save as root', (tester) async {
    final sftpOnly = nginx(access: null);
    final noSudo = FakeEditorSource('/etc/hosts', text: '127.0.0.1 localhost\n',
        accessIs: const FileAccess(owner: 'root:root', mode: '644', writable: false, canSudo: false));
    await openEditorPage(tester, [sftpOnly, noSudo]);
    await openFile(tester, sftpOnly);
    expect(find.byKey(const ValueKey('editor-save-as-root')), findsNothing);
    await openFile(tester, noSudo);
    expect(find.byKey(const ValueKey('editor-save-as-root')), findsNothing);
  });

  testWidgets('Save on a root-owned file asks first, and the password typed is used for that save only', (tester) async {
    final f = nginx();
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    await change(tester, 'user nginx;\n');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveAsRootTitle('/etc/nginx/nginx.conf')), findsOneWidget);
    expect(find.text(en.editorSaveAsRootBody('root:root', 'web-01', '644')), findsOneWidget);
    expect(find.text(en.editorSudoPasswordHelp), findsOneWidget);
    expect(f.writes, isEmpty, reason: 'nothing written as the login account');
    await typePassword(tester, 'hunter2');
    expect(f.rootWrites, hasLength(1));
    expect(utf8.decode(f.rootWrites.single.$1), 'user nginx;\n');
    expect(f.rootWrites.single.$2, 'hunter2');
    expect(find.byKey(const ValueKey('editor-unsaved')), findsNothing);
    // Never kept: the next save asks again, with an empty field.
    await change(tester, 'user nginx nginx;\n');
    await tester.tap(find.byKey(const ValueKey('editor-save-as-root')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
        find.descendant(of: find.byKey(const ValueKey('editor-sudo-password')), matching: find.byType(TextField)));
    expect(field.controller!.text, isEmpty);
    expect(field.obscureText, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect([for (final k in prefs.getKeys()) '${prefs.get(k)}'].where((v) => v.contains('hunter2')), isEmpty);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(f.rootWrites, hasLength(1));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a wrong password is said in the dialog, which stays, as the text does', (tester) async {
    final f = nginx()..rootWriteFails = const SudoPasswordException();
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    await change(tester, 'user nginx;\n');
    await tester.tap(find.byKey(const ValueKey('editor-save-as-root')));
    await tester.pumpAndSettle();
    await typePassword(tester, 'wrong');
    expect(find.text('${en.editorSudoWrongPassword} (ZS-1601)'), findsOneWidget, reason: 'said with its code');
    expect(find.text(en.editorSaveAsRootTitle('/etc/nginx/nginx.conf')), findsOneWidget);
    expect(editorCode(tester).text, 'user nginx;\n');
    // An account that may not use sudo says what the host said.
    f.rootWriteFails = const SudoNotAllowedException('deploy is not in the sudoers file.');
    await typePassword(tester, 'right');
    expect(find.text('${en.editorSudoNotAllowed('deploy is not in the sudoers file.')} (ZS-1602)'), findsOneWidget);
    f.rootWriteFails = null;
    await typePassword(tester, 'right');
    expect(find.text(en.editorSaveAsRootTitle('/etc/nginx/nginx.conf')), findsNothing);
    expect(f.rootWrites.single.$2, 'right');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('an empty password is not sent', (tester) async {
    final f = nginx();
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    await change(tester, 'user nginx;\n');
    await tester.tap(find.byKey(const ValueKey('editor-save-as-root')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-sudo-save')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorSudoNeedsPassword), findsOneWidget);
    expect(f.rootWrites, isEmpty);
  });

  testWidgets('a save refused with Permission denied offers Save as root', (tester) async {
    final f = FakeEditorSource('/etc/motd', text: 'hi\n',
        accessIs: const FileAccess(owner: null, mode: null, writable: null, canSudo: true))
      ..writeFails = SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');
    await openEditorPage(tester, [f]);
    await openFile(tester, f);
    expect(find.byKey(const ValueKey('editor-save-as-root')), findsNothing, reason: 'not known to need it yet');
    await change(tester, 'hello\n');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveAsRootTitle('/etc/motd')), findsOneWidget);
    expect(find.text(en.editorSaveAsRootBodyUnknown('web-01')), findsOneWidget);
    await typePassword(tester, 'pw');
    expect(utf8.decode(f.rootWrites.single.$1), 'hello\n');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a phone has Save as root in its More sheet', (tester) async {
    final f = nginx();
    await openEditorPage(tester, [f], size: const Size(390, 844));
    await openFile(tester, f);
    await tester.tap(find.byKey(const ValueKey('editor-phone-more')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveAsRootSheet('root:root')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-sheet-root')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveAsRootTitle('/etc/nginx/nginx.conf')), findsOneWidget);
  });

  testWidgets("while the screen is recorded, Save as root names no host, folder or account, nor do sudo's words", (tester) async {
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..enabled = true;
    addTearDown(() => Redactor.instance
      ..enabled = false
      ..clearNames());
    final f = FakeEditorSource('/srv/northwind/app.conf', hostLabel: 'billing-prod', text: 'a\n',
        accessIs: const FileAccess(owner: 'deploy:www-data', mode: '640', writable: false, canSudo: true))
      ..rootWriteFails = const SudoNotAllowedException('deploy is not in the sudoers file.');
    await openEditorPage(tester, [f], prefs: {'recording_mode_enabled': true});
    await openFile(tester, f);
    expect(Redactor.instance.enabled, isTrue);
    await change(tester, 'b\n');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    await typePassword(tester, 'pw');
    final shown = [
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(Dialog), matching: find.byType(Text))))
        t.data ?? t.textSpan?.toPlainText() ?? '',
    ].join('\n');
    expect(shown, isNotEmpty);
    for (final leak in ['billing-prod', 'northwind', 'deploy']) {
      expect(shown, isNot(contains(leak)), reason: leak);
    }
    expect(sudoWordsShown('deploy is not in the sudoers file.'), isNot(contains('deploy')));
    Redactor.instance.enabled = false;
    expect(sudoWordsShown('deploy is not in the sudoers file.'), 'deploy is not in the sudoers file.');
    await tester.pump(const Duration(seconds: 3));
  });
}
