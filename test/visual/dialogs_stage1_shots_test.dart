import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/screens/identity/key_users.dart';

import 'shots_util.dart';

/// Pictures of the dialogs, the first set reworked in 3.4 (the app's dialog
/// rules): the shell in its kinds (a plain
/// question, a destructive one, one with a warning in amber, a done one, an
/// input) and Export a backup in its three states, in English, dark and
/// light, a computer's width, with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/dialogs_stage1_shots_test.dart
///
/// Pictures land in build/shots/dialogs-stage1/. Every name and path on them
/// is made up.
///
/// The path a backup reports on Windows, which mixed `\` and `/` (rule 6:
/// the dialog shows it in the system's style).
const _mixedPath = r'C:\Users\alex\Documents/ZestSSH/backups/zestssh_backup_2026-11-05T13-01-22.zest';

class _Backups implements BackupService {
  @override
  Future<BackupResult> exportBackup(String password,
      {String filenamePrefix = 'zestssh_backup_', bool allowUnencrypted = false}) async {
    return const BackupResult(success: true, filePath: _mixedPath, recordCount: 77);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this picture');
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<(GlobalKey, BuildContext, WidgetRef)> shown(WidgetTester tester, String themeId) async {
    L10nGlobal.update(l10n);
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final key = GlobalKey();
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          backupServiceProvider.overrideWithValue(_Backups()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Consumer(builder: (ctx, r, _) {
            context = ctx;
            ref = r;
            return const Scaffold();
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (key, context, ref);
  }

  Future<void> snap(WidgetTester tester, GlobalKey key, String name) async {
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'dialogs-stage1/$name', pixelRatio: 2);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('the shell in its kinds ($tag)', (tester) async {
      if (!shotsEnabled) return;
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (key, context, _) = await shown(tester, themeId);

        unawaited(ZestConfirmDialog.show(context,
            tone: ZestDialogTone.warning,
            title: l10n.wfStopRunTitle,
            body: l10n.wfStopRunBody,
            confirmLabel: l10n.wfStopRunAction));
        await snap(tester, key, 'question-$tag');
        await close(tester);

        unawaited(ZestConfirmDialog.show(context,
            tone: ZestDialogTone.destructive,
            title: l10n.identityListDeleteConfirmTitle('deploy-key'),
            body: l10n.identityListDeleteUsageMessage(3),
            // The hosts by name, as the app lists them (4.0).
            bullets: keyUsersLinesOf(l10n, const ['db-primary', 'web-01', 'web-02']),
            confirmLabel: l10n.delete));
        await snap(tester, key, 'destructive-$tag');
        await close(tester);

        // A warning: a backup with no password, about to be restored.
        final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}zest-shots-plain.zest');
        await tester.runAsync(() => file.writeAsBytes([0x5a, 0x45, 0x53, 0x54, 2, ...'{}'.codeUnits]));
        // (The file's first bytes are read for real.)
        await tester.runAsync(() async {
          unawaited(restoreBackupFile(context, file.path));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await snap(tester, key, 'warning-$tag');
        await close(tester);
        await tester.runAsync(file.delete);

        unawaited(showFileSavedDialog(context,
            title: l10n.setupSavedTitle,
            message: l10n.setupSavedBody,
            path: r'C:\Users\alex\Documents\zestssh-setup-northwind.json'));
        await snap(tester, key, 'done-$tag');
        await tester.tap(find.byKey(const ValueKey('file-saved-done')));
        await tester.pumpAndSettle();

        unawaited(showZestInputDialog(
            context: context,
            title: l10n.tmuxRenameWindow,
            icon: LucideIcons.pencil,
            fieldLabel: l10n.tmuxRenameWindowHint,
            initialValue: 'build',
            confirmLabel: l10n.save));
        await snap(tester, key, 'input-$tag');
        await close(tester);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    });

    testWidgets('the Export flow ($tag)', (tester) async {
      if (!shotsEnabled) return;
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (key, context, ref) = await shown(tester, themeId);
        const pw = 'correct horse battery staple';

        // With a password.
        unawaited(runBackupExport(context, ref));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('export-backup-password')), pw);
        await snap(tester, key, 'export-1-password-$tag');
        await tester.enterText(find.byKey(const ValueKey('export-backup-password-again')), pw);
        await tester.tap(find.byKey(const ValueKey('export-backup-password-set')));
        await snap(tester, key, 'export-2-done-encrypted-$tag');
        await tester.tap(find.byKey(const ValueKey('file-saved-done')));
        await tester.pumpAndSettle();

        // Without one: the same dialog, changed in place.
        unawaited(runBackupExport(context, ref));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('export-backup-no-password')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('backup-unprotected-understand')));
        await snap(tester, key, 'export-3-no-password-$tag');
        await tester.tap(find.byKey(const ValueKey('backup-unprotected-go')));
        await snap(tester, key, 'export-4-done-unencrypted-$tag');
        await tester.tap(find.byKey(const ValueKey('file-saved-done')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    });
  }
}
