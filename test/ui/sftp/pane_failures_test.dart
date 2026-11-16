import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_sync_service.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_mirror_preview_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_search_results_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_tail_viewer.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';

/// A computer's file pane, and the search, the followed file and the mirror it
/// opens, say why something failed in the app's language, with details to
/// copy that are a report naming no folder (3.0). The
/// pane copied the raw error as it was, a rename or a new file put it in a
/// sentence, a move's details named each item and a partial move had none, a
/// link that could not be read said nothing of why, a folder not there was
/// the English "Directory not found", the search and the followed file put
/// the raw error in a sentence, and a mirror that could not be planned again
/// had nothing to copy. After the home folder could not be found, Retry
/// listed an empty path instead of looking for it again. The English trash
/// dialog said "The the Recycle Bin is not available".
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  SftpStatusError denied() => SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');

  test('a local folder that is not there is said as one', () async {
    final dir = await Directory.systemTemp.createTemp('zestssh_gone_');
    addTearDown(() => dir.delete(recursive: true));
    final gone = '${dir.path}${Platform.pathSeparator}reports';
    Object? thrown;
    try {
      listLocalDirectory(gone);
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<PathNotFoundException>());
    expect(sftpErrorMessage(thrown!, name: 'reports', op: SftpOp.list), 'This device no longer has "reports".');
  });

  test('the English trash dialog says its reasons as sentences', () {
    expect(en.sftpTrashUnavailableBody('notes.txt', en.sftpTrashReasonNoBinOnDrive),
        'notes.txt\nThe Recycle Bin is not available on this drive, so it cannot be recovered from there. '
        'Delete it permanently instead?');
    final reasons = [
      en.sftpTrashReasonUnknown,
      en.sftpTrashReasonNoTrashSource,
      en.sftpTrashReasonCancelled,
      en.sftpTrashReasonSameSource,
      en.sftpTrashReasonRoot,
      en.sftpTrashReasonInvalidPath,
      en.sftpTrashReasonNoBinOnDrive,
      en.sftpTrashReasonFileNotFound,
      en.sftpTrashReasonPathNotFound,
      en.sftpTrashReasonAccessDenied,
      en.sftpTrashReasonInUse,
      en.sftpTrashReasonShellError('5'),
      en.sftpTrashReasonFinder,
      en.sftpTrashReasonGioFailed,
      en.sftpTrashReasonGioMissing,
      en.sftpTrashReasonNoPlatform,
    ];
    for (final reason in reasons) {
      expect(reason[0], reason[0].toUpperCase(), reason: reason);
      final body = en.sftpTrashUnavailableBody('notes.txt', reason);
      expect(body.toLowerCase(), isNot(contains('the the')), reason: body);
      expect(body, contains('\n$reason, so it cannot'), reason: body);
    }
  });

  group('the pane', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Future<ProviderContainer> open(WidgetTester tester, _Fs fs) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SftpPane(
              key: ObjectKey(fs),
              source: fs,
              sourceDescriptor: const LocalPaneSource(),
              paneSide: 0,
              onInterPaneDrop: (_, _) {},
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      return ProviderScope.containerOf(tester.element(find.byType(SftpPane)));
    }

    String copied(WidgetTester tester) => tester.widget<CopyDetailsButton>(find.byType(CopyDetailsButton)).detail;

    testWidgets('a home folder not found says why, and Retry looks for it again', (tester) async {
      final fs = _Fs()
        ..homeErrors.add(denied())
        ..listErrors['/srv/demo'] = [denied()];
      await open(tester, fs);
      expect(find.text("Permission denied: your account can't open \"Home\" on the server."), findsOneWidget);
      final report = copied(tester);
      expect(report, startsWith('ZestSSH error details\n'));
      expect(report, contains('Where: Files: finding the home folder\n'));
      expect(fs.listed, isEmpty);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(fs.homeAsked, 2);
      expect(fs.listed, ['/srv/demo']);
      // Home was found this time, its folder was not: Retry lists it again.
      expect(find.text("Permission denied: your account can't open \"demo\" on the server."), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(fs.homeAsked, 2);
      expect(fs.listed, ['/srv/demo', '/srv/demo']);
      expect(find.byType(CopyDetailsButton), findsNothing);
    });

    testWidgets('a folder not listed says why about it, with a report that names it not', (tester) async {
      final fs = _Fs()..listErrors['/srv/demo'] = [denied()];
      await open(tester, fs);
      expect(find.text("Permission denied: your account can't open \"demo\" on the server."), findsOneWidget);
      final report = copied(tester);
      expect(report, contains("What: Permission denied: your account can't open the item on the server.\n"));
      expect(report, contains('Where: Files: listing a folder\n'));
      expect(report, isNot(contains('"demo"')));

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(fs.homeAsked, 1);
      expect(fs.listed, ['/srv/demo', '/srv/demo']);
      expect(find.byType(CopyDetailsButton), findsNothing);
    });

    testWidgets('a name with what hides or moves text in it reads as what it is', (tester) async {
      final fs = _Fs()..dirs['/srv/demo'] = [_folder('backup\x15cmd\r'), _file('exe.txt\u{202E}gpj.scr'), _file('plain.txt')];
      await open(tester, fs);
      expect(find.textContaining('\x15'), findsNothing, reason: 'the row read "backup", and Ctrl-U and the rest stood behind it');
      expect(find.text(r'backup\x15cmd\r'), findsOneWidget);
      expect(find.textContaining('\u{202E}'), findsNothing);
      expect(find.text(r'exe.txt\u202egpj.scr'), findsOneWidget);
      expect(find.text('plain.txt'), findsOneWidget);
    });

    testWidgets('a rename that fails says why in its dialog', (tester) async {
      final fs = _Fs()
        ..dirs['/srv/demo'] = [_file('notes.txt')]
        ..renameErrors['/srv/demo/notes.txt'] = denied();
      await open(tester, fs);
      // (A row's tap lands once a double-tap is ruled out.)
      await tester.tap(find.text('notes.txt'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'renamed.txt');
      // (The dialog's title says Rename too; its button is the last.)
      await tester.tap(find.text('Rename').last);
      await tester.pump();
      await tester.pump();
      expect(find.text("Permission denied: your account can't rename \"notes.txt\" on the server."), findsOneWidget);
      expect(fs.renamed, isEmpty);
    });

    /// Drags the row [from] onto the folder row [onto], as a person does.
    Future<void> drag(WidgetTester tester, String from, String onto) async {
      final start = tester.getCenter(find.text(from));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(start + const Offset(0, 6));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text(onto)));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a move into a folder that fails says why, with what was thrown to copy', (tester) async {
      final error = denied();
      final fs = _Fs()
        ..dirs['/srv/demo'] = [_file('notes.txt'), _folder('archive')]
        ..renameErrors['/srv/demo/notes.txt'] = error;
      final container = await open(tester, fs);
      await drag(tester, 'notes.txt', 'archive');
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, "Permission denied: your account can't rename \"notes.txt\" on the server.");
      expect(notice.details, contains('Details:\n  $error'));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a move that moved some says how many failed, with what was thrown for each', (tester) async {
      final error = denied();
      final fs = _Fs()
        ..dirs['/srv/demo'] = [_file('notes.txt'), _file('todo.txt'), _folder('archive')]
        ..renameErrors['/srv/demo/todo.txt'] = error;
      final container = await open(tester, fs);
      await tester.tap(find.text('notes.txt'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('todo.txt'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await drag(tester, 'notes.txt', 'archive');
      expect(fs.renamed, ['/srv/demo/notes.txt -> /srv/demo/archive/notes.txt']);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.sftpMovedPartial(en.sftpMovedOne('notes.txt', 'archive'), 1));
      expect(notice.actionLabel, en.sftpDeleteUndo);
      expect(notice.details, contains('Details:\n  $error'));
      expect(notice.details, isNot(contains('todo')));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a new file that cannot be made says why in its dialog', (tester) async {
      final fs = _Fs()..writeErrors['/srv/demo/todo.txt'] = denied();
      await open(tester, fs);
      // Right-click where there are no rows.
      await tester.tapAt(tester.getCenter(find.byType(SftpPane)) + const Offset(0, 120),
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.sftpNewFileEllipsis));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'todo.txt');
      await tester.tap(find.text(en.create).last);
      await tester.pump();
      await tester.pump();
      expect(find.text("Permission denied: your account can't write \"todo.txt\" on the server."), findsOneWidget);
    });

    testWidgets('a link that cannot be read says so, with what reading it threw', (tester) async {
      final gone = SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
      final fs = _Fs()
        ..dirs['/srv/demo'] = [_file('current', symlink: true)]
        ..statErrors['/srv/demo/current'] = gone;
      final container = await open(tester, fs);
      await tester.tap(find.text('current'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.sftpLinkUnreachable);
      expect(notice.details, contains('No such file'));
      await tester.pump(const Duration(seconds: 8));
    });
  });

  testWidgets('a search that could not finish says why, with its report', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: SftpSearchResultsDialog(
          service: _Sftp(searchError: const SocketException('Connection reset by peer')),
          root: '/srv/demo',
          query: 'notes',
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('sftp-search-failed'))).data,
        'The search could not finish. The connection to the server was lost.');
    final report = tester.widget<ErrorDetailsPanel>(find.byType(ErrorDetailsPanel)).report;
    expect(report, contains('What: The connection to the server was lost.\n'));
    expect(report, contains('Where: Files: searching subfolders\n'));
    expect(report, contains('Error: '));
  });

  testWidgets('a file that could not be followed says why, with its report', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SftpTailViewer(
            service: _Sftp(tailError: denied()),
            path: '/srv/demo/app.log',
            fileName: 'app.log',
            hostLabel: 'web-01',
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('sftp-tail-failed'))).data,
        "This file could not be followed. Permission denied: your account can't read \"app.log\" on the server.");
    final report = tester.widget<ErrorDetailsPanel>(find.byType(ErrorDetailsPanel)).report;
    expect(report, contains("What: Permission denied: your account can't read the item on the server.\n"));
    expect(report, contains('Where: Files: following a file\n'));
  });

  testWidgets('a file whose lines ended by themselves says why, as the host said it, behind what it showed',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Future<void> open(_Sftp service) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SftpTailViewer(
              service: service,
              path: '/srv/demo/app.log',
              fileName: 'app.log',
              hostLabel: 'web-01',
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    const cannot = "tail: cannot open '/srv/demo/app.log' for reading: Permission denied";
    await open(_Sftp(tailSaid: cannot));
    expect(tester.widget<Text>(find.byKey(const ValueKey('sftp-tail-said'))).data,
        'This file could not be followed. $cannot');

    // With lines before it: they stay, and the reason stands behind them.
    await open(_Sftp(tailLines: const ['one', 'two'], tailSaid: 'tail: /srv/demo/app.log: file truncated'));
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('sftp-tail-said'))).data,
        'This file could not be followed. tail: /srv/demo/app.log: file truncated');
    expect(tester.getTopLeft(find.byKey(const ValueKey('sftp-tail-said'))).dy,
        greaterThan(tester.getTopLeft(find.text('two')).dy));

    // Nothing said: the lines, and that it ended.
    await open(_Sftp(tailLines: const ['one']));
    expect(find.text('one'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp-tail-said')), findsNothing);
  });

  testWidgets('a mirror that could not be planned again has its details to copy', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: SftpMirrorPreviewDialog(
          sourceLabel: 'site',
          destPath: '/srv/demo/site',
          initialPlan: const SyncPlan(items: [], caseCollisions: []),
          initialOptions: const SftpSyncOptions(),
          onReplan: (_) async => throw const SocketException('Connection reset by peer'),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(CopyDetailsButton), findsNothing);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.pump();
    expect(find.text(en.sftpSyncReplanFailed), findsOneWidget);
    final report = tester.widget<CopyDetailsButton>(find.byType(CopyDetailsButton)).detail;
    expect(report, contains('What: ${en.sftpSyncReplanFailed}\n'));
    expect(report, contains('Where: Files: planning a mirror again\n'));
    expect(report, contains('Connection reset by peer'));
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      expect(t.sftpSearchStopped('x'), isNot(en.sftpSearchStopped('x')), reason: '$locale');
      expect(t.sftpSearchStopped('x'), contains('x'));
      expect(t.sftpTailStopped('x'), isNot(en.sftpTailStopped('x')), reason: '$locale');
      expect(t.sftpTailStopped('x'), contains('x'));
    }
  });
}

PaneFileEntry _file(String name, {bool symlink = false}) =>
    PaneFileEntry(name: name, path: '/srv/demo/$name', isDirectory: false, size: 4, isSymlink: symlink);

PaneFileEntry _folder(String name) => PaneFileEntry(name: name, path: '/srv/demo/$name', isDirectory: true, size: 0);

/// A source whose home folder, listings, renames and stats fail as told.
class _Fs extends PaneFileSource {
  final List<Object> homeErrors = [];
  final Map<String, List<Object>> listErrors = {};
  final Map<String, List<PaneFileEntry>> dirs = {};
  final Map<String, Object> renameErrors = {};
  final Map<String, Object> statErrors = {};
  final Map<String, Object> writeErrors = {};
  int homeAsked = 0;
  final List<String> listed = [];
  final List<String> renamed = [];

  @override
  String get sourceId => 'demo-fs';
  @override
  bool get isPosix => true;

  @override
  Future<String> homeDirectory() async {
    homeAsked++;
    if (homeErrors.isNotEmpty) throw homeErrors.removeAt(0);
    return '/srv/demo';
  }

  @override
  Future<List<PaneFileEntry>> list(String path, {bool includeHidden = true}) async {
    listed.add(path);
    final errors = listErrors[path];
    if (errors != null && errors.isNotEmpty) throw errors.removeAt(0);
    // (A list of its own: the pane sorts it.)
    return [...?dirs[path]];
  }

  @override
  Future<PaneFileEntry?> stat(String path) async {
    final e = statErrors[path];
    if (e != null) throw e;
    for (final entries in dirs.values) {
      for (final entry in entries) {
        if (entry.path == path) return entry;
      }
    }
    return null;
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final e = renameErrors[oldPath];
    if (e != null) throw e;
    renamed.add('$oldPath -> $newPath');
  }

  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {}
  @override
  Future<void> deleteFile(String path) async {}
  @override
  Future<void> deleteDirectoryRecursive(String path,
      {void Function(String deletedPath)? onDeleted, bool Function()? isCancelled}) async {}
  @override
  Future<int> countEntriesRecursive(String path) async => 0;
  @override
  Future<void> chmod(String path, int mode) async {}
  @override
  Future<void> chmodRecursive(String path, int mode,
      {void Function(String path)? onDone, bool Function()? isCancelled}) async {}
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async => Uint8List(0);
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    final e = writeErrors[path];
    if (e != null) throw e;
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath,
      {PaneTransferProgress? onProgress, TransferCancelToken? cancelToken, int? maxBytes, bool bulk = false}) async {}
  @override
  Future<void> uploadFile(String localPath, String remotePath,
      {PaneTransferProgress? onProgress, TransferCancelToken? cancelToken, bool bulk = false}) async {}
}

/// An SFTP connection whose search and following of a file fail as told.
class _Sftp implements SftpService {
  _Sftp({this.searchError, this.tailError, this.tailLines = const [], this.tailSaid = ''});

  /// What following a file gives, and what the host said when the lines ended.
  final List<String> tailLines;
  final String tailSaid;

  final Object? searchError;
  final Object? tailError;

  @override
  Future<List<SftpEntry>> searchRecursive(
    String root,
    String query, {
    int maxResults = 500,
    int maxDepth = 12,
    bool Function()? isCancelled,
  }) async {
    if (searchError != null) throw searchError!;
    return const [];
  }

  @override
  Future<({Stream<String> lines, Future<void> Function() cancel, Future<String> said})> tailFile(
    String remotePath, {
    int initialLines = 200,
  }) async {
    if (tailError != null) throw tailError!;
    return (
      lines: Stream<String>.fromIterable(tailLines),
      cancel: () async {},
      said: Future<String>.value(tailSaid),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
