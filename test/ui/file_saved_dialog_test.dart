import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A saved file says where it went, helpfully (3.0): readable
/// and selectable, copied in one tap, and on a computer shown in its folder.
/// As the dialog rules of 3.4 have it: a green tick for done, the file's
/// name first and its folder under it, in the system's own style (a
/// backup's path mixed `\` and `/`), and Done, not Close.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<String?> open(WidgetTester tester, String path) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showFileSavedDialog(context,
                  title: l10n.accountBackupExported, message: l10n.backupExportedEncrypted(73), path: path),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-saved-copy')));
    await tester.pump();
    return copied;
  }

  testWidgets('the name first and its folder under it, selectable; Copy path copies it; Show in folder and Done '
      'in the footer, under a green tick', (tester) async {
    const path = r'C:\Users\me\Documents\zestssh_backup_2026-09-25T14-48-20.zest';
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final copied = await open(tester, path);
      expect(find.text(l10n.accountBackupExported), findsOneWidget);
      expect(find.text(l10n.backupExportedEncrypted(73)), findsOneWidget);
      expect(find.widgetWithText(SelectableText, 'zestssh_backup_2026-09-25T14-48-20.zest'), findsOneWidget);
      expect(find.widgetWithText(SelectableText, r'C:\Users\me\Documents'), findsOneWidget);
      // The name above the folder.
      expect(tester.getRect(find.byKey(const ValueKey('file-saved-name'))).top,
          lessThan(tester.getRect(find.byKey(const ValueKey('file-saved-folder'))).top));
      expect(copied, path);
      // Done: a green tick.
      expect(tester.widget<ZestDialogShell>(find.byType(ZestDialogShell)).tone, ZestDialogTone.success);
      expect(AppColors.v3Success, ZestDialogTone.success.meaning);
      // Tests run on a computer: the file can be shown in its folder, from
      // the footer, beside Done.
      final show = tester.getRect(find.byKey(const ValueKey('file-saved-show')));
      final done = tester.getRect(find.byKey(const ValueKey('file-saved-done')));
      expect(show.right, lessThan(done.left));
      expect(show.center.dy, moreOrLessEquals(done.center.dy, epsilon: 1));
      expect(find.text(l10n.done), findsOneWidget);
      expect(find.text(l10n.close), findsNothing);
      await tester.tap(find.byKey(const ValueKey('file-saved-done')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.accountBackupExported), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a path that mixes \\ and / on Windows is shown and copied in its one style', (tester) async {
    // What a backup reported: its folder joined with a slash.
    const mixed = r'C:\Users\me\Documents/ZestSSH/backups/zestssh_backup_2026-09-25T14-48-20.zest';
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final copied = await open(tester, mixed);
      expect(find.widgetWithText(SelectableText, r'C:\Users\me\Documents\ZestSSH\backups'), findsOneWidget);
      expect(find.textContaining('/'), findsNothing);
      expect(copied, r'C:\Users\me\Documents\ZestSSH\backups\zestssh_backup_2026-09-25T14-48-20.zest');
      await tester.tap(find.byKey(const ValueKey('file-saved-done')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
