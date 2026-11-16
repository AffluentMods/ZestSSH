import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/android_save_folder.dart';

/// The app's folders as path_provider gives them: none of them made yet.
class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths({required this.downloads, required this.documents, required this.temporary});
  final String downloads;
  final String documents;
  final String temporary;

  @override
  Future<String?> getDownloadsPath() async => downloads;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getTemporaryPath() async => temporary;
}

/// A host with one file, which writes a download where it is told to, as a
/// file and nothing else: a folder that is not there makes it fail.
class _Sftp implements SftpService {
  final List<SftpEntry> entries = [
    const SftpEntry(name: 'report.pdf', path: '/home/demo/report.pdf', isDirectory: false, size: 3),
  ];
  final List<String> writtenTo = [];

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
    await File(localPath).writeAsBytes(Uint8List(3));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

/// Where a phone's or a small tablet's SFTP list saves a download (the 4.0
/// platform comparison): on an iPhone or an iPad in the app's Documents, which
/// the Files app shows as the ZestSSH folder, and the message says so. It was
/// the app's own Downloads folder there, which iOS never makes and the Files
/// app does not show, so the first download failed and any later one could
/// not be found. A computer keeps its Downloads. The folder is made where it
/// is not there yet, before anything is written.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  late SharedPreferences prefs;
  late Directory root;
  late String downloads;
  late String documents;
  late PathProviderPlatform before;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    root = Directory.systemTemp.createTempSync('zest_download_folder_');
    downloads = p.join(root.path, 'Downloads');
    documents = p.join(root.path, 'Documents');
    // The phone's message: a card at the top of the screen.
    debugTopSnackBarOnPhone = true;
    before = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(
      downloads: downloads,
      documents: documents,
      temporary: Directory(p.join(root.path, 'tmp')).path,
    );
  });
  tearDown(() {
    PathProviderPlatform.instance = before;
    debugDownloadSaveSystem = null;
    debugTopSnackBarOnPhone = null;
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on FileSystemException {
      // Left in the system's temporary folder.
    }
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

  /// Downloads the one file, and gives where it was written.
  Future<String> download(WidgetTester tester, _Sftp sftp) async {
    await tester.tap(find.text('report.pdf').first);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(en.sftpDownload));
      for (var i = 0; i < 200 && sftp.writtenTo.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // The write itself, then the message.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(sftp.writtenTo, hasLength(1), reason: 'downloaded once');
    return sftp.writtenTo.single;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('on an iPhone or an iPad: into the app\'s Documents, made first, and the message names the Files app',
      (tester) async {
    debugDownloadSaveSystem = 'ios';
    final sftp = _Sftp();
    await open(tester, sftp);
    final local = await download(tester, sftp);
    expect(p.dirname(local), documents, reason: 'Documents, which the Files app shows');
    expect(File(local).existsSync(), isTrue, reason: 'the folder was made before the file was written');
    expect(Directory(downloads).existsSync(), isFalse, reason: 'the app\'s Downloads, which Files never shows');
    expect(find.text(en.sftpDownloadedTo('report.pdf', en.sftpPlaceIosFiles)), findsOneWidget);
    expect(find.textContaining(documents), findsNothing, reason: 'no path an iPhone never shows');
    await finish(tester);
  });

  for (final system in ['macos', 'windows', 'linux']) {
    testWidgets('on a computer ($system): into its Downloads, made where it is not there, the message with its path',
        (tester) async {
      debugDownloadSaveSystem = system;
      final sftp = _Sftp();
      await open(tester, sftp);
      final local = await download(tester, sftp);
      expect(p.dirname(local), downloads);
      expect(File(local).existsSync(), isTrue);
      expect(find.text(en.sftpDownloadedTo('report.pdf', downloads)), findsOneWidget);
      await finish(tester);
    });
  }

  test('the place named on an iPhone is the ZestSSH folder in every language (the Files app by the name iOS gives '
      'it there)', () {
    expect(en.sftpPlaceIosFiles, contains('Files'));
    for (final locale in AppLocalizations.supportedLocales) {
      expect(lookupAppLocalizations(locale).sftpPlaceIosFiles, contains('ZestSSH'), reason: '$locale');
    }
  });
}
