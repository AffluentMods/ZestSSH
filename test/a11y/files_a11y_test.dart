import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

/// The files panel to a screen reader, a keyboard and a finger (4.0
/// accessibility pass). Names here are made up.
void main() {
  Future<void> pumpPane(WidgetTester tester, {double width = 760}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fs = _Fs('/srv/demo');
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SftpPane(
                key: ObjectKey(fs),
                source: fs,
                sourceDescriptor: const LocalPaneSource(),
                paneSide: 1,
                onInterPaneDrop: (_, _) {},
                onTransferSelection: (_) {},
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets("a computer's file pane: every control named, its text readable", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    debugTouchLayout = false;
    final semantics = tester.ensureSemantics();
    try {
      await pumpPane(tester);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
      debugTouchLayout = null;
    }
  });

  testWidgets("a tablet's file pane: targets a finger takes", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugTouchLayout = true;
    final semantics = tester.ensureSemantics();
    try {
      await pumpPane(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
      debugTouchLayout = null;
    }
  });
  testWidgets("a phone's file browser: targets a finger takes, every control named, text readable", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugTouchLayout = true;
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    final semantics = tester.ensureSemantics();
    try {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sftp = _PhoneSftp()
        ..entries.addAll([
          const SftpEntry(name: 'logs', path: '/home/demo/logs', isDirectory: true, size: 0),
          const SftpEntry(name: 'notes.txt', path: '/home/demo/notes.txt', isDirectory: false, size: 912),
        ]);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: SftpBrowserScreen(sftp: sftp, connectionLabel: 'web-01'),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
      debugTouchLayout = null;
    }
  });
}

class _PhoneSftp implements SftpService {
  final List<SftpEntry> entries = [];

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async => path == '/home/demo' ? entries : const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

class _Fs extends PaneFileSource {
  _Fs(this.home);
  final String home;

  @override
  String get sourceId => 'toolbar-fs:$home';
  @override
  bool get isPosix => true;
  @override
  Future<String> homeDirectory() async => home;
  @override
  Future<List<PaneFileEntry>> list(String path, {bool includeHidden = true}) async => [
        if (path == home) ...[
          PaneFileEntry(name: 'releases', path: '$home/releases', isDirectory: true, size: 0),
          PaneFileEntry(name: '.cache', path: '$home/.cache', isDirectory: true, size: 0),
          PaneFileEntry(name: 'deploy.log', path: '$home/deploy.log', isDirectory: false, size: 48213),
          PaneFileEntry(name: 'notes.txt', path: '$home/notes.txt', isDirectory: false, size: 912),
        ],
      ];
  @override
  Future<PaneFreeSpace?> freeSpace(String path) async =>
      const PaneFreeSpace(freeBytes: 412 * 1024 * 1024 * 1024, totalBytes: 1000 * 1024 * 1024 * 1024);
  @override
  Future<PaneFileEntry?> stat(String path) async => null;
  @override
  Future<void> rename(String oldPath, String newPath) async {}
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
  Future<void> writeBytes(String path, Uint8List bytes) async {}
  @override
  Future<void> downloadFile(String remotePath, String localPath,
      {PaneTransferProgress? onProgress, TransferCancelToken? cancelToken, int? maxBytes, bool bulk = false}) async {}
  @override
  Future<void> uploadFile(String localPath, String remotePath,
      {PaneTransferProgress? onProgress, TransferCancelToken? cancelToken, bool bulk = false}) async {}
}
