import 'dart:io';
import 'dart:typed_data';

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
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/sudo_retry.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

import '../../helpers/fake_sudo_host.dart';

/// Retry with sudo on a computer (3.4): in a
/// host's pane, a rename, a move into a folder, a new folder and a delete
/// that the host refused with "Permission denied" say "Not allowed", and
/// Retry with sudo runs the same as root with the password typed once; a
/// transfer between the panes is done again as the command that does it.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  SftpStatusError denied() => SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> open(WidgetTester tester, _RootFs fs) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SftpPane(
              key: ObjectKey(fs),
              source: fs,
              sourceDescriptor: RemotePaneSource(sessionId: 's1', hostLabel: 'web-01', service: _NoSftp()),
              paneSide: 0,
              onInterPaneDrop: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(SftpPane)));
  }

  AppNotification notice(ProviderContainer c) => c.read(notificationCenterProvider).history.first;

  /// Retry with sudo, from the notice, and the password typed into its dialog.
  Future<void> retryWith(WidgetTester tester, ProviderContainer c, String password) async {
    final n = notice(c);
    expect(n.actionLabel, en.sftpSudoRetry);
    n.onAction!();
    await tester.pumpAndSettle();
    expect(find.text(en.sftpSudoTitle), findsOneWidget);
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('sftp-sudo-password')), matching: find.byType(TextField)),
      password,
    );
    await tester.tap(find.byKey(const ValueKey('sftp-sudo-run')));
    await tester.pumpAndSettle();
  }

  testWidgets('a rename refused says Not allowed, and Retry with sudo renames with mv', (tester) async {
    final host = FakeSudoHost();
    final fs = _RootFs(host)
      ..dirs['/etc/nginx'] = [_file('nginx.conf')]
      ..renameErrors['/etc/nginx/nginx.conf'] = denied();
    final c = await open(tester, fs);
    await tester.tap(find.text('nginx.conf'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'nginx.conf.bak');
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    expect(find.text(en.sftpNewNameLabel), findsNothing, reason: 'the rename dialog closed');
    expect(notice(c).title, "Not allowed: you don't have permission for /etc/nginx/nginx.conf.");
    final listed = fs.listed.length;
    await retryWith(tester, c, 'hunter2');
    expect(host.commands.single, endsWith("sh '/etc/nginx/nginx.conf' '/etc/nginx/nginx.conf.bak'"));
    expect(host.commands.single, contains('exec mv -- '));
    expect(host.stdins.single, 'hunter2\n');
    expect(fs.listed.length, greaterThan(listed), reason: 'the folder is listed again');
    expect(notice(c).title, en.sftpSudoDone(en.sftpItemCount(1)));
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('a new folder refused fails in Activity and offers Retry with sudo, which runs mkdir', (tester) async {
    final host = FakeSudoHost();
    final fs = _RootFs(host)
      ..dirs['/etc/nginx'] = [_file('nginx.conf')]
      ..mkdirErrors['/etc/nginx/sites'] = denied();
    final c = await open(tester, fs);
    await tester.tap(find.byKey(const ValueKey('sftp-toolbar-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'sites');
    await tester.tap(find.text(en.create).last);
    await tester.pumpAndSettle();
    final row = c.read(sftpTransfersProvider).single;
    expect(row.status, TransferStatus.failed);
    expect(notice(c).title, "Not allowed: you don't have permission for /etc/nginx/sites.");
    await retryWith(tester, c, 'hunter2');
    expect(host.commands.single, "env LC_ALL=C sudo -k -S -p '' -- mkdir -- '/etc/nginx/sites'");
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('a delete refused offers Retry with sudo once for all of it: rm, rm -r for a folder', (tester) async {
    final host = FakeSudoHost();
    final fs = _RootFs(host)
      ..dirs['/etc/nginx'] = [_file('old.conf'), _folder('cache')]
      ..deleteErrors['/etc/nginx/old.conf'] = denied()
      ..deleteErrors['/etc/nginx/cache'] = denied();
    final c = await open(tester, fs);
    await tester.tap(find.text('old.conf'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('cache'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.delete).last);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(notice(c).title, "Not allowed: you don't have permission for ${en.sftpItemCount(2)}.");
    await retryWith(tester, c, 'wrong');
    expect(find.text('${en.editorSudoWrongPassword} (ZS-1601)'), findsOneWidget);
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('sftp-sudo-password')), matching: find.byType(TextField)),
      'hunter2',
    );
    await tester.tap(find.byKey(const ValueKey('sftp-sudo-run')));
    await tester.pumpAndSettle();
    final asRoot = host.commands.skip(1).toList();
    expect(
      asRoot,
      unorderedEquals([
        "env LC_ALL=C sudo -k -S -p '' -- rm -- '/etc/nginx/old.conf'",
        "env LC_ALL=C sudo -k -S -p '' -- rm -r -- '/etc/nginx/cache'",
      ]),
    );
    expect(host.stdins.skip(1), everyElement('hunter2\n'));
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('what this computer refuses offers no sudo', (tester) async {
    final host = FakeSudoHost();
    final fs = _RootFs(host, remote: false)
      ..dirs['/etc/nginx'] = [_file('nginx.conf')]
      ..renameErrors['/etc/nginx/nginx.conf'] = denied();
    await open(tester, fs);
    await tester.tap(find.text('nginx.conf'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'b.conf');
    await tester.tap(find.text('Rename').last);
    await tester.pump();
    await tester.pump();
    expect(
      find.text("Permission denied: your account can't rename \"nginx.conf\" on the server."),
      findsOneWidget,
      reason: 'said in its dialog, as before',
    );
    expect(host.commands, isEmpty);
  });

  group('a transfer between the panes, done again as root', () {
    TransferItem item(String from, String to) => TransferItem(
      id: 'x',
      localPath: from,
      remotePath: to,
      fileName: 'f',
      direction: TransferDirection.upload,
      totalBytes: 1,
    );

    test('an upload, a download, a copy within one host; none between two hosts', () {
      final local = LocalPaneFileSource();
      final web = _RootFs(FakeSudoHost());
      expect(
        sudoOpForTransfer(local, web, item('C:/demo/site.conf', '/etc/site.conf')),
        isA<SudoUpload>().having((o) => o.remotePath, 'to', '/etc/site.conf'),
      );
      expect(
        sudoOpForTransfer(web, local, item('/etc/shadow', 'C:/demo/shadow')),
        isA<SudoDownload>().having((o) => o.localPath, 'to', 'C:/demo/shadow'),
      );
      expect(sudoOpForTransfer(web, web, item('/etc/a', '/srv/a')), isA<SudoCopy>());
    });

    test('a folder the host would not make: copied with cp -rp on one host; uploaded as folders and files', () async {
      final web = _RootFs(FakeSudoHost());
      expect(
        sudoOpsForFolder(web, web, '/srv/site', '/var/www/site', const {})!.single.shown,
        'cp -rp /srv/site /var/www/site',
      );
      final other = _RootFs(FakeSudoHost(), backend: 'other');
      expect(sudoOpsForFolder(web, other, '/srv/site', '/var/www/site', const {}), isNull, reason: 'two hosts');
      expect(
        sudoOpsForFolder(web, LocalPaneFileSource(), '/srv/site', 'C:/demo/site', const {}),
        isNull,
        reason: 'a download of a folder the host would not list',
      );

      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_tree_');
      addTearDown(() => dir.delete(recursive: true));
      Directory('${dir.path}/css').createSync();
      File('${dir.path}/index.html').writeAsStringSync('<p>');
      File('${dir.path}/css/site.css').writeAsStringSync('p{}');
      Directory('${dir.path}/node_modules').createSync();
      File('${dir.path}/node_modules/x.js').writeAsStringSync('x');
      final ops = sudoOpsForFolder(LocalPaneFileSource(), web, dir.path, '/var/www/site', {
        '${dir.path}${Platform.pathSeparator}node_modules',
      })!;
      expect(ops.map((o) => o.shown), [
        'mkdir /var/www/site',
        'mkdir /var/www/site/css',
        'cp site.css /var/www/site/css/site.css',
        'cp index.html /var/www/site/index.html',
      ]);
    });
  });
}

PaneFileEntry _file(String name) => PaneFileEntry(name: name, path: '/etc/nginx/$name', isDirectory: false, size: 4);

PaneFileEntry _folder(String name) => PaneFileEntry(name: name, path: '/etc/nginx/$name', isDirectory: true, size: 0);

/// A host's folder whose renames, new folders and deletes fail as told, and
/// whose sudo is [host]'s ([remote] false: this computer, which has none).
class _RootFs extends PaneFileSource {
  _RootFs(this.host, {this.remote = true, this.backend = 'web-01'});

  final FakeSudoHost host;
  final bool remote;
  final String backend;
  final Map<String, List<PaneFileEntry>> dirs = {};
  final Map<String, Object> renameErrors = {};
  final Map<String, Object> mkdirErrors = {};
  final Map<String, Object> deleteErrors = {};
  final List<String> listed = [];

  @override
  SudoFileOps? sudoOps() => remote ? host.ops() : null;

  @override
  bool sharesBackendWith(PaneFileSource other) => other is _RootFs && other.backend == backend;

  @override
  String get sourceId => 'root-fs-$backend';
  @override
  bool get isPosix => true;
  @override
  Future<String> homeDirectory() async => '/etc/nginx';
  @override
  Future<List<PaneFileEntry>> list(String path, {bool includeHidden = true}) async {
    listed.add(path);
    return [...?dirs[path]];
  }

  @override
  Future<PaneFileEntry?> stat(String path) async => null;
  @override
  Future<void> rename(String oldPath, String newPath) async {
    final e = renameErrors[oldPath];
    if (e != null) throw e;
  }

  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {
    final e = mkdirErrors[path];
    if (e != null) throw e;
  }

  @override
  Future<void> deleteFile(String path) async {
    final e = deleteErrors[path];
    if (e != null) throw e;
  }

  @override
  Future<void> deleteDirectoryRecursive(
    String path, {
    void Function(String deletedPath)? onDeleted,
    bool Function()? isCancelled,
  }) async {
    final e = deleteErrors[path];
    if (e != null) throw e;
  }

  @override
  Future<int> countEntriesRecursive(String path) async => 0;
  @override
  Future<void> chmod(String path, int mode) async {}
  @override
  Future<void> chmodRecursive(
    String path,
    int mode, {
    void Function(String path)? onDone,
    bool Function()? isCancelled,
  }) async {}
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async => Uint8List(0);
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    int? maxBytes,
    bool bulk = false,
  }) async {}
  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    bool bulk = false,
  }) async {}
}

/// The pane's host, which these tests never reach.
class _NoSftp implements SftpService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
