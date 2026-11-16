import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcript_viewer_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcripts_screen.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The transcripts saved on a device are listed, read and deleted in the app
/// (3.0). A recording a phone saved, or one a computer saved
/// encrypted (.zesttx), could be opened nowhere: nothing listed them, and
/// nothing in the app read one. One made on another device says it does not
/// open here, and why, with the details to copy.
void main() {
  final de = lookupAppLocalizations(const Locale('de'));

  late Directory folder;
  late List<String> copied;

  setUp(() {
    debugTopSnackBarOnPhone = true;
    FlutterSecureStorage.setMockInitialValues({});
    folder = Directory.systemTemp.createTempSync('zest_transcripts_');
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  tearDown(() {
    debugTopSnackBarOnPhone = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  late GoRouter router;

  Future<ProviderContainer> pump(WidgetTester tester, {Widget? home}) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      transcriptsFolderProvider.overrideWith((ref) async => folder),
    ]);
    addTearDown(container.dispose);
    router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => home ?? const TranscriptsScreen()),
      GoRoute(path: Routes.transcripts, builder: (context, state) => const TranscriptsScreen()),
      GoRoute(
          path: Routes.transcriptView,
          builder: (context, state) => TranscriptViewerScreen(path: state.extra! as String)),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
      ),
    ));
    return container;
  }

  /// Real work (files, the key in the system's storage) between frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('listed newest first, read with this device key, one from another device said, deleted after asking',
      (tester) async {
    final mine = '${folder.path}${Platform.pathSeparator}web-01_2026-10-17T01-00-00.zesttx';
    final plain = '${folder.path}${Platform.pathSeparator}db-01_2026-10-16T09-00-00.txt';
    final foreign = '${folder.path}${Platform.pathSeparator}from-another-device.zesttx';
    await tester.runAsync(() async {
      expect(await SessionTranscriptService.saveTextToPath('ZestSSH Session Transcript\nline one\nline two', mine,
          encrypt: true), mine);
      expect(await SessionTranscriptService.saveTextToPath('plain words', plain, encrypt: false), plain);
      final random = Random(7);
      File(foreign).writeAsBytesSync([1, for (var i = 0; i < 80; i++) random.nextInt(256)]);
      File('${folder.path}${Platform.pathSeparator}notes.md').writeAsStringSync('not a transcript');
      File(mine).setLastModifiedSync(DateTime(2026, 10, 17, 1));
      File(plain).setLastModifiedSync(DateTime(2026, 10, 16, 9));
      File(foreign).setLastModifiedSync(DateTime(2026, 10, 15, 8));
    });
    await pump(tester);
    await settle(tester);

    // Newest first; the file that is not a transcript left out.
    final names = [
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
        ((tile.title! as Text).data!),
    ];
    expect(names, ['web-01_2026-10-17T01-00-00.zesttx', 'db-01_2026-10-16T09-00-00.txt', 'from-another-device.zesttx']);
    expect(find.textContaining(de.transcriptsEncrypted), findsNWidgets(2));
    expect(find.textContaining(de.transcriptsPlainText), findsOneWidget);

    // Read, with this device's key, and copied whole.
    await tester.tap(find.text('web-01_2026-10-17T01-00-00.zesttx'));
    await settle(tester);
    expect(find.byType(TranscriptViewerScreen), findsOneWidget);
    expect(find.text('line one'), findsOneWidget);
    expect(find.text('line two'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transcript-copy-all')));
    await settle(tester);
    expect(copied, ['ZestSSH Session Transcript\nline one\nline two']);
    router.pop();
    await settle(tester);

    // One made with another key: said, with the details to copy.
    await tester.tap(find.text('from-another-device.zesttx'));
    await settle(tester);
    expect(find.text(de.transcriptNotOpened), findsOneWidget);
    expect(find.text(de.transcriptNotOpenedHint), findsOneWidget);
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    expect(find.byKey(const ValueKey('transcript-copy-all')), findsNothing);
    router.pop();
    await settle(tester);

    // Deleted after asking: No keeps it, Yes deletes it.
    await tester.tap(find.byKey(const ValueKey('transcript-delete-db-01_2026-10-16T09-00-00.txt')));
    await settle(tester);
    expect(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(de.transcriptsDeleteTitle)),
        findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(de.cancel)));
    await settle(tester);
    expect(File(plain).existsSync(), isTrue);
    await tester.tap(find.byKey(const ValueKey('transcript-delete-db-01_2026-10-16T09-00-00.txt')));
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(de.delete)));
    await settle(tester);
    expect(File(plain).existsSync(), isFalse);
    expect(find.text('db-01_2026-10-16T09-00-00.txt'), findsNothing);
    expect(find.text('web-01_2026-10-17T01-00-00.zesttx'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('an empty folder says where transcripts come from', (tester) async {
    await pump(tester);
    await settle(tester);
    expect(find.text(de.transcriptsEmpty), findsOneWidget);
  });

  testWidgets("a phone's terminal settings open the saved transcripts", (tester) async {
    await pump(tester, home: const TerminalSettingsScreen());
    await settle(tester);
    final row = find.byKey(const ValueKey('settings-saved-transcripts'));
    await tester.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await settle(tester);
    expect(find.byType(TranscriptsScreen), findsOneWidget);
    expect(find.text(de.transcriptsEmpty), findsOneWidget);
  });
}
