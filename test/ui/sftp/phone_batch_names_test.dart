// Since 32d373f0 a phone's
// download of several files names each with safeChildName, which trims the
// name, drops control and direction characters and cuts it at 200
// characters. Two files of one folder could come to the same local name;
// the batch resolved conflicts up front, against what is on the disk only,
// so both went to one path and the second silently replaced the first. The
// same held for a phone's upload of two picked files of one name.
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
import 'package:zest_ssh_core/dartssh2.dart' show SftpFileAttrs;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.downloads, this.temporary);
  final String downloads;
  final String temporary;

  @override
  Future<String?> getDownloadsPath() async => downloads;

  @override
  Future<String?> getTemporaryPath() async => temporary;
}

/// A file picker that hands back [files].
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
  }) async =>
      FilePickerResult(files);
}

class _Sftp implements SftpService {
  final List<SftpEntry> entries = [];
  final List<String> writtenTo = [];
  final List<String> uploadedTo = [];

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async => entries;

  @override
  Future<SftpFileAttrs?> statOrNull(String path) async => null;

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
    writtenTo.add(localPath);
    await File(localPath).writeAsBytes(Uint8List.fromList(remotePath.codeUnits));
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
    uploadedTo.add(remotePath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  late SharedPreferences prefs;
  late Directory downloads;
  late Directory temporary;
  late PathProviderPlatform before;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    downloads = Directory.systemTemp.createTempSync('zest_poc_batch_dl_');
    temporary = Directory.systemTemp.createTempSync('zest_poc_batch_tmp_');
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
  }

  // Each pair: two different files of one folder, as a server lists them.
  final pairs = {
    'a name with a space at its start': (' notes.txt', 'notes.txt'),
    'two long names that differ past 200 characters':
        ('build-${'x' * 200}-part1.log', 'build-${'x' * 200}-part2.log'),
    // A phone's Download folder takes the two for one file (so does the
    // folder of a test run on Windows or a Mac).
    'two names that differ only in case': ('Notes.txt', 'notes.txt'),
  };

  for (final MapEntry(key: what, value: (first, second)) in pairs.entries) {
    testWidgets('a download of two files, $what, keeps both', (tester) async {
      final sftp = _Sftp()
        ..entries.addAll([
          SftpEntry(name: first, path: '/home/demo/one', isDirectory: false, size: 3),
          SftpEntry(name: second, path: '/home/demo/two', isDirectory: false, size: 3),
        ]);
      await open(tester, sftp);

      // Select both files (long press, then select all files) and download.
      await tester.longPress(find.byType(ListTile).first);
      await tester.pump();
      await tester.tap(find.byTooltip(en.sftpSelectAllFiles));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip(en.sftpDownloadSelected));
        for (var i = 0; i < 300 && sftp.writtenTo.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 6));

      expect(sftp.writtenTo, hasLength(2), reason: 'both were downloaded');
      expect(sftp.writtenTo.toSet(), hasLength(2),
          reason: 'two files of the server went to one local path: ${sftp.writtenTo}');
      expect(sftp.writtenTo.map((p) => p.toLowerCase()).toSet(), hasLength(2),
          reason: 'two files of the server went to one local file: ${sftp.writtenTo}');
      expect(downloads.listSync().whereType<File>(), hasLength(2), reason: 'both are on the disk');
    });
  }

  testWidgets('an upload of two picked files of one name, from two folders, keeps both',
      (tester) async {
    final one = Directory('${temporary.path}/one')..createSync();
    final two = Directory('${temporary.path}/two')..createSync();
    File('${one.path}/IMG_0001.jpg').writeAsStringSync('one');
    File('${two.path}/IMG_0001.jpg').writeAsStringSync('two');
    FilePicker.platform = _Picker([
      PlatformFile(name: 'IMG_0001.jpg', path: '${one.path}/IMG_0001.jpg', size: 3),
      PlatformFile(name: 'IMG_0001.jpg', path: '${two.path}/IMG_0001.jpg', size: 3),
    ]);
    final sftp = _Sftp();
    await open(tester, sftp);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(en.sftpUploadFile));
      for (var i = 0; i < 300 && sftp.uploadedTo.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));

    expect(sftp.uploadedTo, ['/home/demo/IMG_0001.jpg', '/home/demo/IMG_0001 (1).jpg'],
        reason: 'the second must not replace the first on the server');
  });
}
