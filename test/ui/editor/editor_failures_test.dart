import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/ui/screens/editor/editor_codec.dart';
import 'package:zestssh/ui/screens/editor/editor_reply.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';

/// A file editor's save, reload and pop-out that fail say why in the app's
/// language with what was thrown to copy (3.0). A save
/// that failed said to check permissions whatever it was, a reload put the
/// raw error in a sentence, and a popped-out editor's save came back from
/// the main window as "error: " and the raw error (as "read-only" for a file
/// that had no way to be saved), its reload as nothing, so a reload that
/// failed, or read an empty file, said nothing.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  SftpStatusError denied() => SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');

  Future<EditorFailure> failure(void Function() read) async {
    try {
      read();
    } on EditorFailure catch (e) {
      return e;
    }
    fail('it did not fail');
  }

  group('between a popped-out editor and the main window', () {
    /// The main window's side of a popped-out tab of notes.txt.
    EditorBridge bridgeOf({Future<void> Function(String)? onSave, Future<String?> Function()? onReload}) => EditorBridge(
          source: TextEditorSource(fileName: 'notes.txt', initialText: 'old', onSave: onSave, onReload: onReload),
          encoding: EditorEncoding.utf8,
          lineBreak: EditorLineBreak.lf,
        );

    test('a save that works is read as one', () async {
      String? saved;
      final bridge = bridgeOf(onSave: (c) async => saved = c);
      EditorReply.readSave(await EditorReply.answerSave(bridge, 'new text'));
      expect(saved, 'new text');
    });

    test('a save that fails comes back said in the app\'s language, with what was thrown', () async {
      final error = denied();
      final bridge = bridgeOf(onSave: (_) async => throw error);
      final reply = await EditorReply.answerSave(bridge, 'new text');
      final e = await failure(() => EditorReply.readSave(reply));
      expect(e.said, "Permission denied: your account can't write \"notes.txt\" on the server.");
      expect(e.thrown, '$error');
      expect(e.toString(), '$error');
    });

    test('a file that cannot be saved, or an editor not known any more, says so', () async {
      for (final bridge in [null, bridgeOf()]) {
        final reply = await EditorReply.answerSave(bridge, 'x');
        final e = await failure(() => EditorReply.readSave(reply));
        expect(e.said, "This file is open read-only, so it can't be saved.");
        expect(e.thrown, 'The file has no way to be saved');
      }
    });

    test('a reload brings back what it read, an empty file too', () async {
      for (final text in ['', 'line one\nline two']) {
        final bridge = bridgeOf(onReload: () async => text);
        expect(EditorReply.readReload(await EditorReply.answerReload(bridge)), text);
      }
    });

    test('a reload that fails says why: not UTF-8 any more, or what was thrown, or that nothing was read', () async {
      Future<EditorFailure> reload(Future<String?> Function()? onReload) async {
        final reply = await EditorReply.answerReload(bridgeOf(onReload: onReload));
        return failure(() => EditorReply.readReload(reply));
      }

      final notText = await reload(() async => throw const FormatException('Unexpected extension byte'));
      expect(notText.said, en.sftpNotUtf8('notes.txt'));
      expect(notText.thrown, contains('Unexpected extension byte'));

      final gone = await reload(() async => throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file'));
      expect(gone.said, 'The server no longer has "notes.txt".');

      final nothing = await reload(() async => null);
      expect(nothing.said, 'The operation failed.');
      expect(nothing.thrown, 'Nothing was read');

      final none = await reload(null);
      expect(none.said, 'The operation failed.');
      expect(none.thrown, 'The file has no way to be read again');
      final noBridge = await EditorReply.answerReload(null);
      final unknown = await failure(() => EditorReply.readReload(noBridge));
      expect(unknown.said, 'The operation failed.');
    });

    test('an answer that is not one is read as a failure, never as a save', () async {
      for (final reply in <Object?>[null, '', 'ok', 'error: read-only', '{"said": ""}', '[1]', 7]) {
        final e = await failure(() => EditorReply.readSave(reply));
        expect(e.said, 'The operation failed.', reason: '$reply');
        expect(e.thrown, contains('Unexpected answer'), reason: '$reply');
        await failure(() => EditorReply.readReload(reply));
      }
    });
  });

  test('what is said: the main window\'s words, text not UTF-8, else what was thrown', () {
    expect(editorFailureSaid(const EditorFailure('Said there.', 'raw'), name: 'notes.txt', op: SftpOp.upload),
        'Said there.');
    expect(editorFailureSaid(const FormatException('x'), name: 'notes.txt', op: SftpOp.download),
        en.sftpNotUtf8('notes.txt'));
    expect(editorFailureSaid(const FormatException('bad input'), name: 'notes.txt', op: SftpOp.upload), 'bad input');
    expect(editorFailureSaid(denied(), name: 'notes.txt', op: SftpOp.upload),
        "Permission denied: your account can't write \"notes.txt\" on the server.");
  });

  group('the editor', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Future<ProviderContainer> open(
      WidgetTester tester, {
      Future<void> Function(String)? onSave,
      Future<String?> Function()? onReload,
      Future<DateTime?> Function()? fetchRemoteModified,
      DateTime? originalModified,
      bool popOut = false,
    }) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: TextEditorScreen(
            fileName: 'notes.txt',
            initialContent: 'alpha',
            popOutEnabled: popOut,
            onSave: onSave,
            onReload: onReload,
            fetchRemoteModified: fetchRemoteModified,
            originalModified: originalModified,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(tester.element(find.byType(TextEditorScreen)));
    }

    Future<void> editAndSave(WidgetTester tester) async {
      editorCode(tester).text = 'alpha beta';
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a save that fails says why, with what was thrown to copy', (tester) async {
      final error = denied();
      final container = await open(tester, onSave: (_) async => throw error);
      await editAndSave(tester);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.severity, NotificationSeverity.error);
      expect(notice.title, "Not saved. Permission denied: your account can't write \"notes.txt\" on the server.");
      expect(notice.details, contains('Details:\n  $error'));
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a popped-out editor says what the main window said', (tester) async {
      final container = await open(tester, onSave: (_) async => throw const EditorFailure('Said there.', 'Thrown there'));
      await editAndSave(tester);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, 'Not saved. Said there.');
      expect(notice.details, contains('Thrown there'));
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a reload that fails says why, with what was thrown to copy', (tester) async {
      final opened = DateTime(2026, 10, 1, 12);
      final container = await open(
        tester,
        onSave: (_) async {},
        onReload: () async => throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file'),
        originalModified: opened,
        fetchRemoteModified: () async => opened.add(const Duration(minutes: 5)),
      );
      await editAndSave(tester);
      // The file changed on the server: reload it.
      await tester.tap(find.text('Reload'));
      await tester.pumpAndSettle();
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, 'Not reloaded. The server no longer has "notes.txt".');
      expect(notice.details, contains('No such file'));
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a window that could not be opened says so with what was thrown', (tester) async {
      const windows = MethodChannel('mixin.one/flutter_multi_window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'createWindow') throw PlatformException(code: 'failed', message: 'No window today');
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, null));
      final container = await open(tester, onSave: (_) async {}, popOut: true);
      await tester.tap(find.byTooltip('Open in a separate window'));
      await tester.pump();
      await tester.pump();
      expect(EditorWindows.instance.lastDetachError, isA<PlatformException>());
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, 'Could not open a new window');
      expect(notice.details, contains('No window today'));
      // The editor stays open, its text kept.
      expect(find.byType(TextEditorScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a window that opens is told whether its file can be saved and read again', (tester) async {
      const windows = MethodChannel('mixin.one/flutter_multi_window');
      final made = <Map<String, dynamic>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, (call) async {
        if (call.method == 'createWindow') {
          made.add(jsonDecode(call.arguments as String) as Map<String, dynamic>);
          return 7;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, null));
      // A file that can be saved but not read again, then one read-only that
      // can be read again.
      await open(tester, onSave: (_) async {}, popOut: true);
      await tester.tap(find.byTooltip('Open in a separate window'));
      await tester.pump();
      await tester.pump();
      await open(tester, onReload: () async => 'again', popOut: true);
      await tester.tap(find.byTooltip('Open in a separate window'));
      await tester.pump();
      await tester.pump();
      expect(EditorWindows.instance.lastDetachError, isNull);
      expect(made, hasLength(2));
      // The tab a window is handed (its first, fetched once it starts).
      EditorTabSnapshot tab(int i) => EditorWindows.instance.bridge(made[i]['editKey'] as String)!.pending!;
      expect([tab(0).canSave, tab(0).canReload], [true, false]);
      expect([tab(1).canSave, tab(1).canReload], [false, true]);
      // The main window knows the file by its name, for what it says.
      for (final window in made) {
        expect(EditorWindows.instance.bridge(window['editKey'] as String)!.fileName, 'notes.txt');
      }
      EditorWindows.instance.reset();
      await tester.pumpAndSettle();
    });
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      expect(t.editorNotSaved('x'), isNot(en.editorNotSaved('x')), reason: '$locale');
      expect(t.editorNotSaved('x'), contains('x'));
      expect(t.editorNotReloaded('x'), isNot(en.editorNotReloaded('x')), reason: '$locale');
      expect(t.editorNotReloaded('x'), contains('x'));
      expect(t.editorReadOnly, isNot(en.editorReadOnly), reason: '$locale');
    }
  });
}
