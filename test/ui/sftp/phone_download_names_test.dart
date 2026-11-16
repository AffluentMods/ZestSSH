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
import 'package:zestssh/services/sftp_transfer_safety.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';

/// Where a phone keeps a download and a file to share: folders of the test's.
class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.downloads, this.temporary);
  final String downloads;
  final String temporary;

  @override
  Future<String?> getDownloadsPath() async => downloads;

  @override
  Future<String?> getTemporaryPath() async => temporary;
}

/// A host that lists [entries] and records where each download was written.
class _Sftp implements SftpService {
  final List<SftpEntry> entries = [];
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

/// A phone's download and share make a file here of the name a server chose
/// as a computer's transfers do (found in a security review):
/// one name ([safeChildName]), with no control character, no
/// direction override (U+202E shows `invoice`, U+202E, `fdp.exe` as
/// "invoiceexe.pdf") and no more than 200 characters. The phone's screen had
/// its own, which took off folders and NUL and kept the rest.
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
    downloads = Directory.systemTemp.createTempSync('zest_phone_downloads_');
    temporary = Directory.systemTemp.createTempSync('zest_phone_temp_');
    before = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(downloads.path, temporary.path);
  });
  tearDown(() {
    PathProviderPlatform.instance = before;
    // (Best effort: under load the system may still hold a file a moment.)
    for (final d in [downloads, temporary]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } on FileSystemException {
        // Left in the system's temporary folder.
      }
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

  /// Picks [action] for the one file listed, and lets what it does on the
  /// disk happen.
  Future<String> act(WidgetTester tester, _Sftp sftp, String action) async {
    await tester.tap(find.textContaining('invoice').first);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(action));
      for (var i = 0; i < 200 && sftp.writtenTo.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));
    expect(sftp.writtenTo, hasLength(1), reason: 'downloaded once');
    return sftp.writtenTo.single;
  }

  final names = {
    'a direction override': 'invoice\u202Efdp.exe',
    'control characters': 'invoice\x1b[31m\r\n.pdf',
    'a name of 300 characters': 'invoice${'x' * 300}.pdf',
    'a folder in its name': '../../invoice.pdf',
  };

  for (final MapEntry(key: what, value: name) in names.entries) {
    testWidgets('a download of a file with $what', (tester) async {
      final sftp = _Sftp()..entries.add(SftpEntry(name: name, path: '/home/demo/x', isDirectory: false, size: 3));
      await open(tester, sftp);
      final local = await act(tester, sftp, en.sftpDownload);
      expect(p.dirname(local), downloads.path);
      expect(p.basename(local), safeChildName(name));
      expect(p.basename(local), isNot(contains('\u202E')));
      expect(p.basename(local).length, lessThanOrEqualTo(maxComponentLength));
    });
  }

  testWidgets('a file downloaded to share it, with a direction override in its name', (tester) async {
    const name = 'invoice\u202Efdp.exe';
    final sftp = _Sftp()..entries.add(const SftpEntry(name: name, path: '/home/demo/x', isDirectory: false, size: 3));
    await open(tester, sftp);
    final local = await act(tester, sftp, en.sftpDownloadAndShare);
    expect(p.basename(local), safeChildName(name));
    expect(p.isWithin(temporary.path, local), isTrue);
  });
}
