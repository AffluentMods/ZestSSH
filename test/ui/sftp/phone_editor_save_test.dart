import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';

import '../../helpers/code_editor_text.dart';

/// A file that is edited on a phone (3.0, the SSH core's audit), with the
/// real screens and the file service played by the test.
///
/// The editor was handed the text and a way to save it, and nothing else:
/// a file that had changed on the host since it was read was saved over
/// without a word, where a computer asks first, and the list behind the
/// editor went on showing the file as it had been.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  const notes = '/home/demo/notes.txt';

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// The phone's file screen on [sftp], with notes.txt opened in the editor.
  Future<ProviderContainer> editing(WidgetTester tester, _Sftp sftp) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: SftpBrowserScreen(sftp: sftp, connectionLabel: 'web-01'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(SftpBrowserScreen)));
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.sftpEditInEditor));
    await tester.pumpAndSettle();
    expect(find.byType(TextEditorScreen), findsOneWidget);
    return container;
  }

  Future<void> typeAndSave(WidgetTester tester, String text) async {
    editorCode(tester).text = text;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text(en.save));
    await tester.pump();
    await tester.pump();
  }

  AppNotification last(ProviderContainer c) => c.read(notificationCenterProvider).history.first;

  testWidgets('what the editor holds is saved as it is, and the folder is listed again', (tester) async {
    final sftp = _Sftp()..holds(notes, 'old words\n');
    final container = await editing(tester, sftp);
    expect(editorCode(tester).text, 'old words\n');
    expect(sftp.listings, 1);

    // (With a letter that is more than one byte.)
    final words = 'caf${String.fromCharCode(0xE9)} words\n';
    await typeAndSave(tester, words);
    await tester.pumpAndSettle();

    expect(sftp.saved, [(notes, words)]);
    expect(last(container).severity, NotificationSeverity.success);
    expect(last(container).title, en.editorSaved('notes.txt'));
    expect(sftp.listings, 2, reason: 'the list behind the editor shows the file as it is now');
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('a file that changed on the host since it was read is not saved over without asking: it can be left, '
      'saved anyway, or read again', (tester) async {
    final sftp = _Sftp()..holds(notes, 'old words\n');
    await editing(tester, sftp);

    // Somebody else changes it on the host.
    sftp.holds(notes, 'theirs\n', later: 60);
    await typeAndSave(tester, 'mine\n');
    expect(find.text(en.textEditorFileChangedTitle), findsOneWidget);
    expect(sftp.saved, isEmpty);

    // Left as it is.
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(sftp.saved, isEmpty);
    expect(editorCode(tester).text, 'mine\n');

    // Saved anyway.
    await tester.tap(find.text(en.save));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.textEditorSaveAnyway));
    await tester.pumpAndSettle();
    expect(sftp.saved, [(notes, 'mine\n')]);

    // Changed again, and read again: the editor has what the host has, and nothing was saved.
    sftp.holds(notes, 'theirs again\n', later: 60);
    await typeAndSave(tester, 'mine again\n');
    expect(find.text(en.textEditorFileChangedTitle), findsOneWidget);
    await tester.tap(find.text(en.textEditorReload));
    await tester.pumpAndSettle();
    expect(editorCode(tester).text, 'theirs again\n');
    expect(sftp.saved, hasLength(1));
    // Read with the same limit as when it was opened: an editor's four megabytes.
    expect(sftp.readUpTo, [4 * 1024 * 1024, 4 * 1024 * 1024]);

    // From there it is saved without a question.
    await typeAndSave(tester, 'ours\n');
    await tester.pumpAndSettle();
    expect(find.text(en.textEditorFileChangedTitle), findsNothing);
    expect(sftp.saved.last, (notes, 'ours\n'));
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('when a file was changed last is asked of the host before the file is read, and not taken from the '
      'list, which may be older than the file', (tester) async {
    final sftp = _Sftp()..holds(notes, 'old words\n');
    // The list was read an hour before the file was changed.
    sftp.listedAs[notes] = sftp.changed[notes]! - 3600;
    await editing(tester, sftp);
    expect(sftp.asked, ['when $notes', 'read $notes']);

    await typeAndSave(tester, 'new words\n');
    await tester.pumpAndSettle();
    expect(find.text(en.textEditorFileChangedTitle), findsNothing, reason: 'nothing changed since it was read');
    expect(sftp.saved, [(notes, 'new words\n')]);
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('a host that does not say when a file was changed: the file opens, and is saved without a question',
      (tester) async {
    final sftp = _Sftp()..holds(notes, 'old words\n');
    sftp.saysWhen = false;
    await editing(tester, sftp);

    await typeAndSave(tester, 'new words\n');
    await tester.pumpAndSettle();
    expect(sftp.saved, [(notes, 'new words\n')]);
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('a save that fails says why, and the editor keeps the text', (tester) async {
    final error = SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');
    final sftp = _Sftp()
      ..holds(notes, 'old words\n')
      ..saveFails = error;
    final container = await editing(tester, sftp);

    await typeAndSave(tester, 'new words\n');
    await tester.pumpAndSettle();

    final notice = last(container);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.title, "Not saved. Permission denied: your account can't write \"notes.txt\" on the server.");
    expect(notice.details, contains('Details:\n  $error'));
    expect(editorCode(tester).text, 'new words\n');
    expect(sftp.saved, isEmpty);
    await tester.pump(const Duration(seconds: 12));
  });
}

/// An SFTP connection with one folder of text files, played by the test.
class _Sftp implements SftpService {
  /// What the host holds, and when each file was changed last (in seconds).
  final files = <String, String>{};
  final changed = <String, int>{};

  /// What the list says of when a file was changed, where that is not when
  /// it was.
  final listedAs = <String, int>{};

  /// Whether the host says when a file was changed at all.
  var saysWhen = true;

  /// How many times the folder was listed.
  var listings = 0;

  /// What was asked of the host for a file, in order.
  final asked = <String>[];

  /// The most bytes each read was to take.
  final readUpTo = <int?>[];

  /// What was saved: the path, and the text.
  final saved = <(String, String)>[];
  Object? saveFails;

  /// The host holds [text] under [path], changed [later] seconds after it was before.
  void holds(String path, String text, {int later = 0}) {
    files[path] = text;
    changed[path] = (changed[path] ?? 1760000000) + later;
  }

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async {
    listings++;
    return [
      for (final MapEntry(key: path, value: text) in files.entries)
        SftpEntry(
          name: path.split('/').last,
          path: path,
          isDirectory: false,
          size: utf8.encode(text).length,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch((listedAs[path] ?? changed[path]!) * 1000),
        ),
    ];
  }

  @override
  Future<SftpFileAttrs?> statOrNull(String path) async {
    asked.add('when $path');
    if (!saysWhen) return null;
    return SftpFileAttrs(size: utf8.encode(files[path]!).length, modifyTime: changed[path]);
  }

  @override
  Future<Uint8List> downloadFile(String remotePath, {SftpProgressCallback? onProgress, int? maxBytes}) async {
    asked.add('read $remotePath');
    readUpTo.add(maxBytes);
    return Uint8List.fromList(utf8.encode(files[remotePath]!));
  }

  @override
  Future<void> uploadFile(String remotePath, Uint8List data) async {
    final fails = saveFails;
    if (fails != null) throw fails;
    final text = utf8.decode(data);
    saved.add((remotePath, text));
    holds(remotePath, text, later: 5);
  }

  // The editor's tabs (3.4) ask whether the connection is up, the file's
  // hash and who may write it: this host is up and has no shell to ask.
  @override
  bool get isOpen => true;

  @override
  Future<String?> sha256Remote(String remotePath) async => null;

  @override
  Future<RemoteFileAccess?> fileAccess(String remotePath) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
