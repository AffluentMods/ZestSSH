import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' as session;
import 'package:zestssh/services/sync_data_service.dart' show StaleReconcileReport;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/profile/master_password_dialog.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/screens/settings/clear_all_data_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/overwrite_conflict_dialog.dart';
import 'package:zestssh/ui/screens/sync/stale_reconcile_dialog.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/paste_question.dart';

import 'shots_util.dart';

/// Pictures of the dialogs, the second set reworked in 3.4 (the app's dialog
/// rules): a dozen of the dialogs this set moved
/// onto the shell, in English, dark and light, a computer's width, and a few
/// as a phone's sheets, with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/dialogs_batch2_shots_test.dart
///
/// Pictures land in build/shots/dialogs-batch2/. Every name, host, key and
/// path on them is made up.
class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

session.HostKeyVerification _hostKey(bool changed) => session.HostKeyVerification(
      host: 'web-01.example.com',
      port: 22,
      hostKey: SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List(51)),
      fingerprint: 'SHA256:Kq3v8Xb0YQm4cJ1sT9fH2nW6pL5rZ7aE0dG3uV8iO1k',
      isChanged: changed,
      expectedFingerprint: changed ? 'SHA256:x9Lm2Qp7Rt4Vw1Ys6Bn3Cd8Fg0Hj5Kl2Mn7Pq4St9U' : null,
      expectedTrustedAt: changed ? DateTime(2026, 9, 14) : null,
      completer: Completer<bool>(),
    );

const _paste = 'sudo systemctl restart nginx\nsudo journalctl -u nginx -n 50 --no-pager\ncurl -sI https://northwind.example.com\n';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<(GlobalKey, BuildContext, WidgetRef)> shown(WidgetTester tester, String themeId, {bool phone = false}) async {
    L10nGlobal.update(l10n);
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = phone ? const Size(390, 844) : const Size(960, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final key = GlobalKey();
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
          databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
          orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
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
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
    await saveShot(tester, key, 'dialogs-batch2/$name', pixelRatio: 2);
  }

  /// Closes whatever is open, from the top: back as a person would.
  Future<void> closeAll(WidgetTester tester, BuildContext context) async {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    await tester.pumpAndSettle();
  }

  Future<void> run(WidgetTester tester, Future<void> Function() body, {bool phone = false}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = phone ? TargetPlatform.android : TargetPlatform.windows;
    try {
      await body();
      await tester.pump(const Duration(seconds: 5));
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('questions ($tag)', (tester) async {
      if (!shotsEnabled) return;
      await run(tester, () async {
        final (key, context, ref) = await shown(tester, themeId);

        await tester.runAsync(() async {
          unawaited(confirmClearAllData(context, ref));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await snap(tester, key, '01-clear-all-data-$tag');
        await closeAll(tester, context);

        unawaited(showPasteQuestion(context, _paste, runs: true));
        await snap(tester, key, '02-paste-question-$tag');
        await closeAll(tester, context);

        unawaited(pauseSyncAsked(context, ref));
        await snap(tester, key, '03-sync-pause-$tag');
        await closeAll(tester, context);

        unawaited(OverwriteConflictDialog.show(context,
            source: OverwriteFileInfo(
                path: '/home/alex/reports/q3-summary.pdf', size: 482113, modified: DateTime(2026, 11, 4, 16, 20)),
            destination: OverwriteFileInfo(
                path: '/srv/share/reports/q3-summary.pdf', size: 471090, modified: DateTime(2026, 10, 30, 9, 5)),
            index: 2,
            total: 7));
        await snap(tester, key, '04-overwrite-conflict-$tag');
        await closeAll(tester, context);

        unawaited(showStaleReconcileDialog(context,
            report: const StaleReconcileReport({
              'connections': ['c1', 'c2', 'c3'],
              'identities': ['k1'],
              'snippets': ['s1', 's2'],
            }),
            lastSync: DateTime.now().subtract(const Duration(days: 64))));
        await snap(tester, key, '05-stale-reconcile-$tag');
        await tester.tap(find.text(l10n.staleReconcileExportBackupFirst));
        await snap(tester, key, '06-stale-reconcile-export-$tag');
        await closeAll(tester, context);
      });
    });

    testWidgets('sign-in and keys ($tag)', (tester) async {
      if (!shotsEnabled) return;
      await run(tester, () async {
        final (key, context, _) = await shown(tester, themeId);

        unawaited(askHostKeyTrust(context, _hostKey(false)));
        await snap(tester, key, '07-host-key-new-$tag');
        await closeAll(tester, context);

        unawaited(askHostKeyTrust(context, _hostKey(true)));
        await snap(tester, key, '08-host-key-changed-$tag');
        await closeAll(tester, context);

        unawaited(showPasswordPrompt(
            context,
            session.PasswordPromptRequest(
                host: 'web-01.example.com',
                username: 'deploy',
                attempt: 2,
                errorHint: 'Wrong password',
                completer: Completer<session.PasswordPromptResult?>())));
        await snap(tester, key, '09-password-prompt-$tag');
        await closeAll(tester, context);

        unawaited(showNewMasterPasswordDialog(context, account: 'alex@northwind.example'));
        await snap(tester, key, '10-master-password-$tag');
        await closeAll(tester, context);

        unawaited(showRecoveryCodes(context,
            codes: [for (var i = 0; i < 10; i++) 'k7m$i-q2x$i-v9p$i'], email: 'alex@northwind.example'));
        await snap(tester, key, '11-recovery-codes-$tag');
        await closeAll(tester, context);

        unawaited(showFileSavedDialog(context,
            title: l10n.sshConfigSavedTitle(12),
            message: l10n.sshConfigSavedBody,
            path: r'C:\Users\alex\Downloads\zestssh_connections.config'));
        await snap(tester, key, '12-ssh-config-saved-$tag');
        await closeAll(tester, context);
      });
    });
  }

  testWidgets("a phone's sheets (dark)", (tester) async {
    if (!shotsEnabled) return;
    await run(tester, phone: true, () async {
      final (key, context, ref) = await shown(tester, 'graphite', phone: true);

      unawaited(showPasteQuestion(context, _paste, runs: true));
      await snap(tester, key, 'phone-01-paste-question');
      await closeAll(tester, context);

      unawaited(pauseSyncAsked(context, ref));
      await snap(tester, key, 'phone-02-sync-pause');
      await closeAll(tester, context);

      await tester.runAsync(() async {
        unawaited(confirmClearAllData(context, ref));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await snap(tester, key, 'phone-03-clear-all-data');
      await closeAll(tester, context);

      unawaited(showPasswordPrompt(
          context,
          session.PasswordPromptRequest(
              host: 'web-01.example.com', username: 'deploy', completer: Completer<session.PasswordPromptResult?>())));
      await snap(tester, key, 'phone-04-password-prompt');
      await closeAll(tester, context);
    });
  });
}
