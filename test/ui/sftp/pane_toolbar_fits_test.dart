import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';

import '../../visual/shots_util.dart';

/// The file pane fits at every width a pane can be dragged to (the docked
/// file panel's panes are narrow already: 1440 wide with the dock on the
/// right, or a window 900 wide; a pane can be dragged to 15 % of the panel),
/// with the app's theme and real fonts, in English and in German, on a
/// computer and a tablet: the toolbar's actions lose their labels, then move
/// into the overflow menu, then Refresh and Up, then Back and Forward, while
/// the menu and the close control stay; the path's folders above the current
/// one go behind a "…", the current folder stays; the path bar's bookmark and
/// search buttons give way; the footer leaves out the free space, the hidden
/// items' toggle and the selection, the item count last. The toolbar
/// overflowed by up to 170 px under about 350 px, the path under about 160,
/// the footer under about 100 and the path bar's buttons under 60.
void main() {
  late SharedPreferences prefs;
  setUpAll(() async => loadShotFonts());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpPane(WidgetTester tester, double width,
      {Locale locale = const Locale('en'), String home = '/srv/demo'}) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fs = _Fs(home);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: BuiltInThemes.getById('graphite').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
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

  Finder key(String k) => find.byKey(ValueKey(k));

  /// What ran over while [body] ran, or went wrong otherwise.
  Future<List<String>> overflows(Future<void> Function() body) async {
    final found = <String>[];
    final reported = FlutterError.onError;
    FlutterError.onError = (d) => found.add(d.toString().split(String.fromCharCode(10)).take(8).join(' '));
    try {
      await body();
    } finally {
      FlutterError.onError = reported;
    }
    return found;
  }

  const paths = ['/srv/demo', '/home/deploy-automation/releases/2026-10-23/web-frontend'];

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final locale in const [Locale('en'), Locale('de')]) {
      testWidgets('every width from 30 to 700 fits, ${platform.name}, ${locale.languageCode}', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          for (var w = 30.0; w <= 700; w += 10) {
            for (final home in paths) {
              final problems = await overflows(() => pumpPane(tester, w, locale: locale, home: home));
              expect(problems, isEmpty, reason: '$w wide, $home');
              // The overflow menu, the current folder and the item count
              // stay, inside the pane.
              final menu = key('sftp-toolbar-menu');
              expect(menu, findsOneWidget, reason: '$w wide');
              if (w >= 100) {
                expect(tester.getRect(menu).right, lessThanOrEqualTo(w + 0.01), reason: '$w wide');
              }
              expect(find.text(home.split('/').last), findsOneWidget, reason: '$w wide, $home');
              expect(key('sftp-footer-count'), findsOneWidget, reason: '$w wide');
              // Something selected: its line in the footer where it fits.
              if (w % 50 == 0) {
                await tester.tap(find.text('deploy.log'), kind: PointerDeviceKind.mouse, warnIfMissed: false);
                await tester.pump(const Duration(milliseconds: 400));
                expect(await overflows(() => tester.pump()), isEmpty, reason: '$w wide, a file selected');
                if (w == 700) expect(key('sftp-footer-selection'), findsOneWidget, reason: 'the selection, said');
              }
            }
          }
          // (The taps' double-tap timers run out.)
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  testWidgets('wide: every button on the bar, labelled; narrower: the actions, then the rest, in the menu',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final l10n = lookupAppLocalizations(const Locale('en'));
      await pumpPane(tester, 700);
      expect(find.text(l10n.sftpNewFolderAction), findsOneWidget);
      expect(find.text(l10n.sftpDownload), findsOneWidget);
      expect(find.byTooltip(l10n.sftpBack), findsOneWidget);
      expect(find.byTooltip(l10n.refresh), findsOneWidget);
      expect(find.byTooltip(l10n.sftpViewOptions), findsOneWidget);

      await pumpPane(tester, 250);
      expect(find.text(l10n.sftpNewFolderAction), findsNothing);
      expect(key('sftp-toolbar-new-folder'), findsNothing);
      expect(find.byTooltip(l10n.sftpBack), findsOneWidget);
      expect(find.byTooltip(l10n.zestCommonMoreActions), findsOneWidget, reason: 'the menu holds buttons now');
      await tester.tap(key('sftp-toolbar-menu'));
      await tester.pumpAndSettle();
      expect(key('sftp-menu-new-folder'), findsOneWidget);
      expect(key('sftp-menu-transfer'), findsOneWidget);
      expect(tester.widget<PopupMenuItem<void Function()>>(key('sftp-menu-transfer')).enabled, isFalse,
          reason: 'nothing selected');
      expect(key('sftp-menu-back'), findsNothing, reason: 'Back is still on the bar');
      await tester.tapAt(const Offset(1100, 650));
      await tester.pumpAndSettle();

      await pumpPane(tester, 140);
      expect(find.byTooltip(l10n.sftpBack), findsNothing);
      await tester.tap(key('sftp-toolbar-menu'));
      await tester.pumpAndSettle();
      for (final id in ['back', 'forward', 'up', 'refresh', 'new-folder', 'transfer']) {
        expect(key('sftp-menu-$id'), findsOneWidget, reason: id);
      }
      // Up, from the menu, goes up.
      await tester.tap(key('sftp-menu-up'));
      await tester.pumpAndSettle();
      expect(find.text('srv'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// A server's folder at [home], with a few files, one of them hidden, on a
/// disk with room.
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
