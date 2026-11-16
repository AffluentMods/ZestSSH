import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;
import 'package:zestssh/utils/file_manager.dart' show debugRestrictFileToOwner;

import '../../helpers/fake_sudo_host.dart';

/// Retry with sudo on a phone (3.4): a rename, a
/// new folder, a delete, an upload and a download that the host refused with
/// "Permission denied" say "Not allowed" on the screen with Retry with sudo,
/// which asks for the password once for all that failed together and runs
/// the same as root.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() {
    L10nGlobal.update(en);
    debugTopSnackBarOnPhone = true;
    // (A file read as root is made the account's alone first: here, without
    // asking the system to, which takes longer than the test waits.)
    debugRestrictFileToOwner = (_) async => true;
  });
  tearDown(() {
    debugTopSnackBarOnPhone = null;
    debugRestrictFileToOwner = null;
  });

  SftpStatusError denied() => SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');

  late SharedPreferences prefs;
  late Directory downloads;
  late Directory temporary;
  late PathProviderPlatform before;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    downloads = Directory.systemTemp.createTempSync('zest_sudo_dl_');
    temporary = Directory.systemTemp.createTempSync('zest_sudo_tmp_');
    before = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(downloads.path, temporary.path);
  });
  tearDown(() {
    PathProviderPlatform.instance = before;
  });

  Future<void> open(WidgetTester tester, _Sftp sftp) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: SftpBrowserScreen(sftp: sftp, connectionLabel: 'web-01'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Retry with sudo on the notice, and [password] typed into its dialog.
  /// [io]: what runs touches this device's disk, so it is let run.
  Future<void> retryWith(WidgetTester tester, String password, {bool io = false}) async {
    await tester.tap(find.text(en.sftpSudoRetry));
    await tester.pumpAndSettle();
    expect(find.text(en.sftpSudoTitle), findsOneWidget);
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('sftp-sudo-password')), matching: find.byType(TextField)),
      password,
    );
    await tester.tap(find.byKey(const ValueKey('sftp-sudo-run')));
    for (var i = 0; io && i < 20 && find.text(en.sftpSudoTitle).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> action(WidgetTester tester, String file, String label) async {
    await tester.tap(find.text(file));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets('a rename refused: the dialog closes, Not allowed, and Retry with sudo runs mv', (tester) async {
    final host = FakeSudoHost();
    final sftp = _Sftp(host)
      ..entries.add(_file('nginx.conf'))
      ..renameErrors['/home/demo/nginx.conf'] = denied();
    await open(tester, sftp);
    await action(tester, 'nginx.conf', en.sftpRename);
    await tester.enterText(find.byType(TextField).last, 'nginx.conf.bak');
    await tester.tap(find.text(en.sftpRename).last);
    await settle(tester);
    expect(find.text("Not allowed: you don't have permission for /home/demo/nginx.conf."), findsOneWidget);
    await retryWith(tester, 'hunter2');
    expect(host.commands.single, endsWith("sh '/home/demo/nginx.conf' '/home/demo/nginx.conf.bak'"));
    expect(host.stdins.single, 'hunter2\n');
    expect(find.text(en.sftpSudoDone(en.sftpItemCount(1))), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a new folder refused: Retry with sudo runs mkdir', (tester) async {
    final host = FakeSudoHost();
    final sftp = _Sftp(host)..mkdirErrors['/home/demo/reports'] = denied();
    await open(tester, sftp);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.sftpNewFolder).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'reports');
    await tester.tap(find.text(en.create).last);
    await settle(tester);
    expect(find.text("Not allowed: you don't have permission for /home/demo/reports."), findsOneWidget);
    await retryWith(tester, 'hunter2');
    expect(host.commands.single, "env LC_ALL=C sudo -k -S -p '' -- mkdir -- '/home/demo/reports'");
    await finish(tester);
  });

  testWidgets('a delete that went in part says how much, and Retry with sudo deletes the rest: rm -r for a folder', (
    tester,
  ) async {
    final host = FakeSudoHost();
    final sftp = _Sftp(host)
      ..entries.addAll([_file('notes.txt'), _folder('cache')])
      ..deleteErrors['/home/demo/cache'] = denied();
    await open(tester, sftp);
    await tester.longPress(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cache'));
    await tester.pump();
    await tester.tap(find.byTooltip(en.sftpDeleteSelected));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.delete).last);
    await settle(tester);
    expect(find.text(en.sftpDeletedCount(1, 2)), findsOneWidget);
    await retryWith(tester, 'hunter2');
    expect(host.commands.single, "env LC_ALL=C sudo -k -S -p '' -- rm -r -- '/home/demo/cache'");
    await finish(tester);
  });

  testWidgets('an upload refused: one password for the file refused and the one after it, each through /tmp', (
    tester,
  ) async {
    final one = File('${temporary.path}/site.conf')..writeAsStringSync('a');
    final two = File('${temporary.path}/app.conf')..writeAsStringSync('b');
    FilePicker.platform = _Picker([
      PlatformFile(name: 'site.conf', path: one.path, size: 1),
      PlatformFile(name: 'app.conf', path: two.path, size: 1),
    ]);
    final host = FakeSudoHost();
    final sftp = _Sftp(host)..uploadErrors['/home/demo/site.conf'] = denied();
    await open(tester, sftp);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(en.sftpUploadFile));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle(tester);
    expect(find.text("Not allowed: you don't have permission for ${en.sftpItemCount(2)}."), findsOneWidget);
    await retryWith(tester, 'hunter2');
    expect(host.putFrom, [one.path, two.path]);
    expect(host.commands, hasLength(2));
    expect(host.commands.first, endsWith("sh '/tmp/.zestssh-edit-1' '/home/demo/site.conf'"));
    expect(host.commands.last, endsWith("sh '/tmp/.zestssh-edit-2' '/home/demo/app.conf'"));
    expect(host.removed, ['/tmp/.zestssh-edit-1', '/tmp/.zestssh-edit-2']);
    expect(host.stdins, everyElement('hunter2\n'));
    await finish(tester);
  });

  testWidgets('a download refused: Retry with sudo reads it with cat into the phone\'s file', (tester) async {
    final host = FakeSudoHost()..printed = 'root:x:0:0\n'.codeUnits;
    final sftp = _Sftp(host)
      ..entries.addAll([_file('gshadow'), _file('shadow')])
      ..downloadErrors['/home/demo/gshadow'] = denied();
    await open(tester, sftp);
    await tester.longPress(find.byType(ListTile).first);
    await tester.pump();
    await tester.tap(find.byTooltip(en.sftpSelectAllFiles));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(en.sftpDownloadSelected));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle(tester);
    expect(find.text("Not allowed: you don't have permission for ${en.sftpItemCount(2)}."), findsOneWidget);
    await retryWith(tester, 'hunter2', io: true);
    expect(host.commands.map((c) => c.substring(c.indexOf(' -- ') + 4)).toSet(), {
      "cat -- '/home/demo/gshadow'",
      "cat -- '/home/demo/shadow'",
    });
    final files = downloads.listSync().whereType<File>().toList();
    expect(files, hasLength(2));
    for (final f in files) {
      expect(f.readAsStringSync(), 'root:x:0:0\n');
    }
    await finish(tester);
  });
}

SftpEntry _file(String name) => SftpEntry(name: name, path: '/home/demo/$name', isDirectory: false, size: 5);
SftpEntry _folder(String name) => SftpEntry(name: name, path: '/home/demo/$name', isDirectory: true, size: 0);

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.downloads, this.temporary);
  final String downloads;
  final String temporary;

  @override
  Future<String?> getDownloadsPath() async => downloads;

  @override
  Future<String?> getTemporaryPath() async => temporary;
}

class _Picker extends FilePicker {
  _Picker(this.files);
  final List<PlatformFile> files;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult(files);
}

/// A host with one folder, whose actions fail as told, and whose sudo is
/// [host]'s.
class _Sftp implements SftpService {
  _Sftp(this.host);

  final FakeSudoHost host;
  final List<SftpEntry> entries = [];
  final Map<String, Object> renameErrors = {};
  final Map<String, Object> mkdirErrors = {};
  final Map<String, Object> deleteErrors = {};
  final Map<String, Object> uploadErrors = {};
  final Map<String, Object> downloadErrors = {};
  final List<String> deleted = [];

  @override
  SudoFileOps sudoFileOps() => host.ops();

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async => [
    for (final e in entries)
      if (!deleted.contains(e.path)) e,
  ];

  @override
  Future<SftpFileAttrs?> statOrNull(String path) async => null;

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

  @override
  Future<void> deleteDirectoryRecursive(
    String remotePath, {
    int depth = 0,
    void Function(String deletedPath)? onDeleted,
    bool Function()? isCancelled,
  }) async {
    final e = deleteErrors[remotePath];
    if (e != null) throw e;
    deleted.add(remotePath);
  }

  @override
  Future<void> uploadFileFromPath(
    String localPath,
    String remotePath, {
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    bool preserveTimestamp = true,
    bool preservePermissions = true,
    bool useTransferChannel = false,
  }) async {
    final e = uploadErrors[remotePath];
    if (e != null) throw e;
  }

  @override
  Future<void> downloadFileToPath(
    String remotePath,
    String localPath, {
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    bool allowResume = true,
    bool preserveTimestamp = true,
    int? maxBytes,
    bool useTransferChannel = false,
  }) async {
    final e = downloadErrors[remotePath];
    if (e != null) throw e;
    await File(localPath).writeAsBytes(Uint8List(0));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
