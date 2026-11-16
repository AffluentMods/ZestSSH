import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';
import 'package:zestssh/ui/screens/sync/stale_reconcile_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A backup service that writes nothing and says what it was asked.
class _Backups implements BackupService {
  final exported = <(String, bool)>[];

  @override
  Future<BackupResult> exportBackup(String password,
      {String filenamePrefix = 'zestssh_backup_', bool allowUnencrypted = false}) async {
    exported.add((password, allowUnencrypted));
    return const BackupResult(success: true, filePath: 'C:/backups/zestssh_backup.zest', recordCount: 3);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

/// A new password or passphrase that locks something away is typed twice
/// (one field for it and a second to confirm it, so that
/// a slip of a key cannot make a backup nobody can
/// open). Before, the backup export and the
/// backup offered before a sync is reconciled each took the password once: a
/// slip in it made a file nobody could open, found out when it was needed.
/// Two that differ now do nothing but say so under the second field. (A
/// generated key's passphrase was asked twice too, and locked nothing: it is
/// gone, test/ui/keys_kept_test.dart.)
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const good = 'a long enough password';
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<_Backups> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backups = _Backups();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        backupServiceProvider.overrideWithValue(backups),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(children: [
              TextButton(onPressed: () => runBackupExport(context, ref), child: const Text('export')),
              TextButton(
                onPressed: () => showStaleReconcileDialog(context,
                    report: const StaleReconcileReport({
                      'connections': ['c1']
                    })),
                child: const Text('reconcile'),
              ),
            ]),
          ),
        ),
      ),
    ));
    return backups;
  }

  Future<void> twice(WidgetTester tester, String keys, String first, String second) async {
    await tester.enterText(find.byKey(ValueKey(keys)), first);
    await tester.enterText(find.byKey(ValueKey('$keys-again')), second);
    await tester.tap(find.byKey(ValueKey('$keys-set')));
    await tester.pumpAndSettle();
  }

  testWidgets('Export backup asks for its new password twice: two that differ export nothing', (tester) async {
    final backups = await open(tester);
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-backup-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('export-backup-password-again')), findsOneWidget);

    await twice(tester, 'export-backup-password', good, 'a long enough passwort');
    expect(find.text(en.backupPasswordMismatch), findsOneWidget);
    expect(backups.exported, isEmpty);

    await twice(tester, 'export-backup-password', good, good);
    expect(backups.exported, [(good, false)]);
    expect(find.text(en.accountBackupExported), findsOneWidget);
    expect(find.text(en.backupExportedEncrypted(3)), findsOneWidget);
  });

  testWidgets('a password too short, or none, is said under the first field: the unprotected export is never '
      'the easy way, but a quiet link (the dialog rules of 3.4)', (tester) async {
    final backups = await open(tester);
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
    await twice(tester, 'export-backup-password', 'short', 'short');
    expect(find.text(en.accountBackupPasswordTooShort(BackupService.minBackupPasswordLength)), findsOneWidget);
    expect(backups.exported, isEmpty);

    // Empty in both is no longer an export without a password (it was, a
    // second dialog away): it is too short, as any other.
    await twice(tester, 'export-backup-password', '', '');
    expect(find.text(en.accountBackupPasswordTooShort(BackupService.minBackupPasswordLength)), findsOneWidget);
    expect(find.byKey(const ValueKey('zest-callout')), findsNothing);
    expect(backups.exported, isEmpty);
    await tester.tap(find.text(en.cancel).last);
    await tester.pumpAndSettle();
    expect(backups.exported, isEmpty);
  });

  testWidgets('Export is one dialog, changed in place: No password, its warning in amber, a red Export unencrypted '
      'once I understand is ticked, Use a password back, then where the file went', (tester) async {
    final backups = await open(tester);
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.byType(ZestDialogShell)));
    ModalRoute<Object?>? now() => ModalRoute.of(tester.element(find.byType(ZestDialogShell)));

    await tester.tap(find.byKey(const ValueKey('export-backup-no-password')));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(now(), same(route), reason: 'the same dialog, not a second one over it or after it');
    expect(find.descendant(of: find.byKey(const ValueKey('zest-callout')), matching: find.text(en.backupNoPasswordBody)),
        findsOneWidget);
    expect(find.text(en.backupExportUnencryptedAction), findsOneWidget);
    expect(find.byKey(const ValueKey('export-backup-password')), findsNothing);
    // Off until the box is ticked.
    await tester.tap(find.byKey(const ValueKey('backup-unprotected-go')));
    await tester.pumpAndSettle();
    expect(backups.exported, isEmpty);

    // Use a password: back to the fields, in the same dialog.
    await tester.tap(find.byKey(const ValueKey('export-backup-use-password')));
    await tester.pumpAndSettle();
    expect(now(), same(route));
    expect(find.byKey(const ValueKey('export-backup-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('zest-callout')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('export-backup-no-password')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-unprotected-understand')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-unprotected-go')));
    await tester.pumpAndSettle();
    expect(backups.exported, [('', true)]);
    // Where it went, still the same dialog: a green tick, not encrypted, Done.
    expect(now(), same(route));
    expect(find.text(en.accountBackupExported), findsOneWidget);
    expect(find.text(en.backupExportedNotEncrypted(3)), findsOneWidget);
    expect(find.text('zestssh_backup.zest'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-saved-done')));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsNothing);
  });

  testWidgets('the backup offered before a sync is reconciled asks twice too', (tester) async {
    final backups = await open(tester);
    await tester.tap(find.text('reconcile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.staleReconcileExportBackupFirst));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reconcile-backup-password-again')), findsOneWidget);

    await twice(tester, 'reconcile-backup-password', good, 'a long enough passwort');
    expect(find.text(en.backupPasswordMismatch), findsOneWidget);
    expect(backups.exported, isEmpty);

    // Here a backup always has a password: none is said to be too short.
    await twice(tester, 'reconcile-backup-password', '', '');
    expect(find.text(en.staleReconcileMinPasswordChars(BackupService.minBackupPasswordLength)), findsOneWidget);
    expect(backups.exported, isEmpty);

    await twice(tester, 'reconcile-backup-password', good, good);
    expect(backups.exported, [(good, false)]);
  });

  testWidgets('the stale-sync question is one dialog, changed in place: its backup password is asked in it, Cancel '
      'goes back, and the saved file comes back with Show in folder in the footer, no button in the body', (tester) async {
    final backups = await open(tester);
    await tester.tap(find.text('reconcile'));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);

    // Export backup first: the same dialog asks for the password (it opened a
    // second dialog over this one).
    await tester.tap(find.text(en.staleReconcileExportBackupFirst));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.byKey(const ValueKey('reconcile-backup-password')), findsOneWidget);
    expect(find.text(en.staleReconcileKeepMyItems), findsNothing);

    // Cancel goes back to the question.
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.text(en.staleReconcileKeepMyItems), findsOneWidget);
    expect(backups.exported, isEmpty);

    await tester.tap(find.text(en.staleReconcileExportBackupFirst));
    await tester.pumpAndSettle();
    await twice(tester, 'reconcile-backup-password', good, good);
    expect(backups.exported, [(good, false)]);
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.text(en.staleReconcileKeepMyItems), findsOneWidget, reason: 'back to the question');
    expect(find.byKey(const ValueKey('file-saved-name')), findsOneWidget);
    // No button in the body: the file's copy icon only; Show in folder is the
    // footer's side link, where Export backup first was.
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.byType(TextButton)), findsNothing);
    expect(find.byKey(const ValueKey('file-saved-show')), findsOneWidget);
    expect(find.text(en.staleReconcileExportBackupFirst), findsNothing);
  });
}
