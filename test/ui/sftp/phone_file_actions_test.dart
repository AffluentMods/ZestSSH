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
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../../helpers/code_editor_text.dart';

/// A phone's file actions that fail say why in the app's language, with what
/// was thrown to copy (3.0). Opening, deleting, a new
/// folder and a rename said to try again whatever it was, or glued the
/// reason to a sentence that had ended ("Delete failed. Please try again.:
/// The connection..."); deleting several gave each failure its own notice,
/// which the next replaced, and always ended in green with how many were
/// deleted; a file that is not UTF-8 text opened with every bad byte
/// replaced, so a save wrote it back damaged; and the delete questions were
/// plain dialogs, not the app's own.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  SftpStatusError denied() => SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');
  // A refusal other than Permission denied, which since 3.4 offers Retry with
  // sudo instead (phone_sudo_test.dart).
  SftpStatusError refused() => SftpStatusError(SftpStatusCode.failure, 'Read-only file system');
  final refusedSaid = en.sftpErrRefusedBecause('Read-only file system');

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> open(WidgetTester tester, _Sftp sftp) async {
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
    return ProviderScope.containerOf(tester.element(find.byType(SftpBrowserScreen)));
  }

  Future<void> action(WidgetTester tester, String file, String label) async {
    await tester.tap(find.text(file));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  AppNotification last(ProviderContainer c) => c.read(notificationCenterProvider).history.first;

  // 3.4: a file that is not UTF-8 opens in the
  // closest match (Windows-1252, where every byte reads as a letter), with a
  // notice, where it was refused; a save writes it back in that encoding, so
  // nothing is damaged.
  testWidgets('a file that is not UTF-8 text opens in the closest match, and is saved back in it', (tester) async {
    final sftp = _Sftp()
      ..entries.add(_file('legacy.txt'))
      ..files['/home/demo/legacy.txt'] = Uint8List.fromList([0x63, 0x61, 0x66, 0xe9, 0x0a]);
    await open(tester, sftp);
    await action(tester, 'legacy.txt', en.sftpEditInEditor);
    expect(find.byType(TextEditorScreen), findsOneWidget);
    expect(find.text(en.editorNotUtf8Title), findsOneWidget);
    expect(find.text(en.editorNotUtf8Body('Windows-1252')), findsOneWidget);
    expect(editorCode(tester).text, 'caf\u00e9\n');
    // And the phone is not left busy with it.
    expect(find.text(en.sftpOpening('legacy.txt')), findsNothing);
    editorCode(tester).text = 'caf\u00e9!\n';
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(sftp.uploaded['/home/demo/legacy.txt'], [0x63, 0x61, 0x66, 0xe9, 0x21, 0x0a]);
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('UTF-8 text opens', (tester) async {
    final sftp = _Sftp()
      ..entries.add(_file('notes.txt'))
      // "café" and a new line, in UTF-8.
      ..files['/home/demo/notes.txt'] = Uint8List.fromList([0x63, 0x61, 0x66, 0xc3, 0xa9, 0x0a]);
    await open(tester, sftp);
    await action(tester, 'notes.txt', en.sftpEditInEditor);
    expect(find.byType(TextEditorScreen), findsOneWidget);
    expect(editorCode(tester).text, 'caf\u00e9\n');
    expect(find.text(en.editorNotUtf8Title), findsNothing);
  });

  // A file's actions on a small phone (393 by 807, a Pixel 3a): every one
  // within reach, Delete last. The sheet was held to nine sixteenths of the
  // screen and cut off Properties and Delete (found in an
  // emulator check).
  testWidgets('on a small phone every action of a file is within reach, Delete too', (tester) async {
    final sftp = _Sftp()..entries.add(_file('notes.txt'));
    await open(tester, sftp);
    tester.view.physicalSize = const Size(393, 807);
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'nothing overflows');
    final delete = find.text(en.delete).last;
    expect(tester.getRect(delete).bottom, lessThanOrEqualTo(807));
    expect(find.text(en.sftpProperties).hitTestable(), findsOneWidget);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text(en.delete), findsWidgets, reason: 'its question asks');
  });

  // A link to a folder (`bin` to `usr/bin`) opens like the folder; a link to
  // a file has a file's actions. It showed a file's actions either way, so a
  // linked folder could not be opened (found in an
  // emulator check).
  testWidgets('a link to a folder opens it; a link to a file has its actions', (tester) async {
    final sftp = _Sftp()
      ..entries.addAll([
        const SftpEntry(name: 'bin', path: '/home/demo/bin', isDirectory: false, isSymlink: true, size: 7),
        const SftpEntry(name: 'latest.log', path: '/home/demo/latest.log', isDirectory: false, isSymlink: true, size: 9),
      ])
      // A folder, followed (S_IFDIR); the log's link leads to a plain file.
      ..stats['/home/demo/bin'] = SftpFileAttrs(mode: const SftpFileMode.value(0x4000 | 0x1ed))
      ..stats['/home/demo/latest.log'] = SftpFileAttrs(mode: const SftpFileMode.value(0x8000 | 0x1a4));
    await open(tester, sftp);

    await tester.tap(find.text('bin'));
    await tester.pumpAndSettle();
    expect(sftp.listed.last, '/home/demo/bin');
    expect(find.text(en.sftpEditInEditor), findsNothing);

    await tester.tap(find.text('latest.log'));
    await tester.pumpAndSettle();
    expect(find.text(en.sftpEditInEditor), findsOneWidget);
  });

  testWidgets('a file that could not be opened says why, with what was thrown', (tester) async {
    final error = denied();
    final sftp = _Sftp()
      ..entries.add(_file('notes.txt'))
      ..readErrors['/home/demo/notes.txt'] = error;
    final container = await open(tester, sftp);
    await action(tester, 'notes.txt', en.sftpEditInEditor);
    final notice = last(container);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.title, "Not opened. Permission denied: your account can't read \"notes.txt\" on the server.");
    expect(notice.details, contains('Details:\n  $error'));
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('a rename that fails says why in its dialog', (tester) async {
    final sftp = _Sftp()
      ..entries.add(_file('notes.txt'))
      ..renameErrors['/home/demo/notes.txt'] = refused();
    await open(tester, sftp);
    await action(tester, 'notes.txt', en.sftpRename);
    await tester.enterText(find.byType(TextField).last, 'renamed.txt');
    await tester.tap(find.text(en.sftpRename).last);
    await tester.pump();
    await tester.pump();
    expect(find.text(refusedSaid), findsOneWidget);
  });

  testWidgets('a new folder that cannot be made says why in its dialog', (tester) async {
    final sftp = _Sftp()..mkdirErrors['/home/demo/reports'] = refused();
    await open(tester, sftp);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.sftpNewFolder).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'reports');
    await tester.tap(find.text(en.create).last);
    await tester.pump();
    await tester.pump();
    expect(find.text(refusedSaid), findsOneWidget);
  });

  testWidgets('a delete that fails says why, asked in the app\'s own dialog', (tester) async {
    final error = refused();
    final sftp = _Sftp()
      ..entries.add(_file('notes.txt'))
      ..deleteErrors['/home/demo/notes.txt'] = error;
    final container = await open(tester, sftp);
    await action(tester, 'notes.txt', en.delete);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    await tester.tap(find.text(en.delete).last);
    await tester.pumpAndSettle();
    final notice = last(container);
    expect(notice.title, en.sftpNotDeleted(refusedSaid));
    expect(notice.details, contains('Details:\n  $error'));
    await tester.pump(const Duration(seconds: 12));
  });

  group('deleting several', () {
    Future<void> deleteSelected(WidgetTester tester, List<String> names) async {
      await tester.longPress(find.text(names.first));
      await tester.pumpAndSettle();
      for (final n in names.skip(1)) {
        await tester.tap(find.text(n));
        await tester.pump();
      }
      await tester.tap(find.byTooltip(en.sftpDeleteSelected));
      await tester.pumpAndSettle();
      expect(find.byType(ZestConfirmDialog), findsOneWidget);
      await tester.tap(find.text(en.delete).last);
      await tester.pumpAndSettle();
    }

    testWidgets('that all go says so', (tester) async {
      final sftp = _Sftp()..entries.addAll([_file('notes.txt'), _file('todo.txt')]);
      final container = await open(tester, sftp);
      await deleteSelected(tester, ['notes.txt', 'todo.txt']);
      final notice = last(container);
      expect(notice.severity, NotificationSeverity.success);
      expect(notice.title, en.sftpDeletedCount(2, 2));
      expect(container.read(notificationCenterProvider).history, hasLength(1));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('that some do not go says how many did, once, with what was thrown', (tester) async {
      final error = refused();
      final sftp = _Sftp()
        ..entries.addAll([_file('notes.txt'), _file('todo.txt')])
        ..deleteErrors['/home/demo/todo.txt'] = error;
      final container = await open(tester, sftp);
      await deleteSelected(tester, ['notes.txt', 'todo.txt']);
      final history = container.read(notificationCenterProvider).history;
      expect(history, hasLength(1));
      expect(history.single.severity, NotificationSeverity.warning);
      expect(history.single.title, en.sftpDeletedCount(1, 2));
      expect(history.single.details, contains('Details:\n  $error'));
      expect(history.single.details, isNot(contains('todo')));
      expect(sftp.deleted, ['/home/demo/notes.txt']);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('that none go says why for the one, as an error', (tester) async {
      final error = refused();
      final sftp = _Sftp()
        ..entries.addAll([_file('notes.txt'), _file('todo.txt')])
        ..deleteErrors['/home/demo/todo.txt'] = error;
      final container = await open(tester, sftp);
      await deleteSelected(tester, ['todo.txt']);
      final notice = last(container);
      expect(notice.severity, NotificationSeverity.error);
      expect(notice.title, en.sftpNotDeleted(refusedSaid));
      await tester.pump(const Duration(seconds: 12));
    });
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      for (final say in <String Function(AppLocalizations)>[
        (l) => l.sftpNotOpened('x'),
        (l) => l.sftpNotShared('x'),
        (l) => l.sftpNotDownloaded('x'),
        (l) => l.sftpNotUploaded('x'),
        (l) => l.sftpNotDeleted('x'),
      ]) {
        expect(say(t), isNot(say(en)), reason: '$locale');
        expect(say(t), contains('x'));
      }
    }
  });
}

SftpEntry _file(String name) => SftpEntry(name: name, path: '/home/demo/$name', isDirectory: false, size: 5);

/// An SFTP connection with one folder, whose reads, renames, new folders and
/// deletes fail as told.
class _Sftp implements SftpService {
  final List<SftpEntry> entries = [];
  final Map<String, Uint8List> files = {};
  final Map<String, Object> readErrors = {};
  final Map<String, Object> renameErrors = {};
  final Map<String, Object> mkdirErrors = {};
  final Map<String, Object> deleteErrors = {};
  final List<String> deleted = [];

  /// What a path is when followed (a link's target); none by default.
  final Map<String, SftpFileAttrs> stats = {};

  /// Each folder listed, in order.
  final List<String> listed = [];

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async {
    listed.add(path);
    return [for (final e in entries) if (!deleted.contains(e.path)) e];
  }

  // (When a file was changed last, which the editor is told: this host says
  // nothing of it, unless the test says what a path is.)
  @override
  Future<SftpFileAttrs?> statOrNull(String path) async => stats[path];

  @override
  Future<Uint8List> downloadFile(String remotePath, {SftpProgressCallback? onProgress, int? maxBytes}) async {
    final e = readErrors[remotePath];
    if (e != null) throw e;
    return files[remotePath] ?? Uint8List(0);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final e = renameErrors[oldPath];
    if (e != null) throw e;
  }

  @override
  Future<void> createDirectory(String remotePath) async {
    final e = mkdirErrors[remotePath];
    if (e != null) throw e;
  }

  @override
  Future<void> deleteFile(String remotePath) async {
    final e = deleteErrors[remotePath];
    if (e != null) throw e;
    deleted.add(remotePath);
  }

  /// What was saved, by path.
  final uploaded = <String, List<int>>{};

  @override
  Future<void> uploadFile(String remotePath, Uint8List data) async => uploaded[remotePath] = data;

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
