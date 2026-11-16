import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';

/// A backup that could not be written, read or restored says why in the
/// app's language, with what was thrown to copy, and a wrong password asks
/// again in every language (3.0). The import looked for
/// the English word "password" in a message that is in the app's language,
/// so in German a wrong password ended the import; an exception was the
/// whole message, raw; and what the restore said came through in English.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  final de = lookupAppLocalizations(const Locale('de'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  // The cheapest key derivation the app accepts (a test of its own keeps
  // it from going lower).
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  final records = {
    'connections': [
      {'id': 'c1', 'label': 'web-01', 'host': 'web-01.northwind.example', 'port': 22}
    ],
  };

  late Directory dir;
  late File file;
  late File plain;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('zestssh_backup_');
    // A v3 backup, as the app writes one: magic, version, header, sealed data.
    final salt = SyncService.generateSalt();
    final mek = await SyncService.deriveKey('right password', salt, params: fast);
    final sealed = await SyncService.encrypt(records, mek, salt);
    final header = utf8.encode(jsonEncode(fast));
    file = File('${dir.path}${Platform.pathSeparator}northwind.zest')
      ..writeAsBytesSync([
        ...utf8.encode('ZEST'),
        3,
        (header.length >> 8) & 0xff,
        header.length & 0xff,
        ...header,
        ...sealed,
      ]);
    // An unprotected one (v2), which needs no key: what happens after a
    // backup is read is the same.
    plain = File('${dir.path}${Platform.pathSeparator}plain.zest')
      ..writeAsBytesSync([...utf8.encode('ZEST'), 2, ...utf8.encode(jsonEncode(records))]);
  });
  tearDownAll(() => dir.delete(recursive: true));

  group('the backup service', () {
    test('a wrong password is known as one, in German too', () async {
      L10nGlobal.update(de);
      final data = _Data();
      final result = await BackupService(data).importBackup(file.path, 'wrong password');
      expect(result.success, isFalse);
      expect(result.passwordWrong, isTrue);
      expect(result.error, de.backupOpenWrongOrDamaged);
      expect(result.error!.toLowerCase(), isNot(contains('password')));
      expect(data.restored, isEmpty);
    });

    test('an encrypted backup given no password asks for one', () async {
      final result = await BackupService(_Data()).importBackup(file.path, '');
      expect(result.passwordWrong, isTrue);
      expect(result.error, en.backupSvcPasswordProtected);
    });

    test('the right password restores it', () async {
      final data = _Data();
      final result = await BackupService(data).importBackup(file.path, 'right password');
      expect(result.success, isTrue);
      expect(result.recordCount, 1);
      expect(data.restored.single['connections'], records['connections']);
    });

    test('records that could not be saved say so, with what the restore said', () async {
      final data = _Data(restoreError: 'UNIQUE constraint failed: connections.id');
      final result = await BackupService(data).importBackup(plain.path, '', allowLegacyUnencrypted: true);
      expect(result.success, isFalse);
      expect(result.passwordWrong, isFalse);
      expect(result.error, en.backupSvcCouldNotRestore);
      expect(result.detail, 'UNIQUE constraint failed: connections.id');
    });

    test('a backup that could not be read says so, with what was thrown', () async {
      final data = _Data(restoreThrows: StateError('disk I/O error'));
      final result = await BackupService(data).importBackup(plain.path, '', allowLegacyUnencrypted: true);
      expect(result.error, en.backupSvcCouldNotRead);
      expect(result.detail, contains('disk I/O error'));
      expect(result.passwordWrong, isFalse);
    });

    test('a file that is not there is not a wrong password', () async {
      final result = await BackupService(_Data()).importBackup('${dir.path}${Platform.pathSeparator}gone.zest', 'x');
      expect(result.error, en.backupSvcFileNotFound);
      expect(result.passwordWrong, isFalse);
      expect(result.detail, isNull);
    });

    test('an export that fails says so in the app\'s language, with what was thrown', () async {
      final result = await BackupService(_Data(gatherThrows: StateError('database is locked')))
          .exportBackup('a long enough password');
      expect(result.success, isFalse);
      expect(result.error, en.backupSvcCouldNotWrite);
      expect(result.detail, contains('database is locked'));
    });
  });

  group('importing', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      FilePicker.platform = _Picker(file.path);
    });

    Future<(ProviderContainer, _Backups)> open(WidgetTester tester, List<BackupResult> results,
        {RestorePreview? preview}) async {
      final backups = _Backups(results, preview: preview);
      addTearDown(() => FilePicker.platform = _Picker(file.path));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          backupServiceProvider.overrideWithValue(backups),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('de'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(children: [
                TextButton(onPressed: () => runBackupImport(context, ref), child: const Text('import')),
                TextButton(onPressed: () => runBackupExport(context, ref), child: const Text('export')),
              ]),
            ),
          ),
        ),
      ));
      return (ProviderScope.containerOf(tester.element(find.byType(Scaffold))), backups);
    }

    Future<void> start(WidgetTester tester) async {
      // (The file's first bytes are read for real.)
      await tester.runAsync(() async {
        await tester.tap(find.text('import'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
    }

    /// What was tapped goes on where the import began (the file was read for
    /// real).
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    Future<void> answer(WidgetTester tester, String password) async {
      await tester.enterText(find.byType(TextField).last, password);
      await tester.tap(find.text(de.accountImportAction).last);
      await tester.pump();
      // (The import began where the file was read for real: it goes on
      // there.)
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    testWidgets('a backup with no password: its warning in amber, and Import in the footer, off until '
        'I understand is ticked (the dialog rules of 3.4: it was a button in the body, under a yellow tile)',
        (tester) async {
      FilePicker.platform = _Picker(plain.path);
      final (_, backups) = await open(tester, [const BackupResult(success: true, recordCount: 1)]);
      await start(tester);
      expect(find.text(de.backupUnprotectedImportTitle), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('zest-callout')), matching: find.text(de.backupUnprotectedImportBody)),
          findsOneWidget);
      final go = find.byKey(const ValueKey('backup-unprotected-go'));
      // In the footer, beside Cancel.
      final cancel = tester.getRect(find.byKey(const ValueKey('zest-dialog-secondary')));
      expect(tester.getRect(go).center.dy, moreOrLessEquals(cancel.center.dy, epsilon: 1));
      expect(tester.getRect(go).left, greaterThan(cancel.right));
      await tester.tap(go);
      await settle(tester);
      expect(backups.passwords, isEmpty, reason: 'off until ticked');
      await tester.tap(find.byKey(const ValueKey('backup-unprotected-understand')));
      await tester.pumpAndSettle();
      await tester.tap(go);
      await settle(tester);
      expect(backups.passwords, ['']);
      expect(backups.restored, isTrue);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a wrong password asks again, in German', (tester) async {
      L10nGlobal.update(de);
      final (container, backups) = await open(tester, [
        BackupResult(success: false, error: de.backupOpenWrongOrDamaged, passwordWrong: true),
        const BackupResult(success: true, recordCount: 3),
      ]);
      await start(tester);
      await answer(tester, 'wrong password');
      // Asked again, not ended.
      expect(find.text(de.accountBackupPassword), findsWidgets);
      await answer(tester, 'right password');
      expect(backups.passwords, ['wrong password', 'right password']);
      expect(container.read(notificationCenterProvider).history.first.title, de.settingsBackupRestored(3));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a restore says what it would do before anything is written: Cancel restores nothing, and says nothing',
        (tester) async {
      L10nGlobal.update(de);
      final (container, backups) = await open(tester, [const BackupResult(success: true, recordCount: 3)],
          preview: const RestorePreview(hosts: 2, keys: 0, snippets: 0, other: 0, replaces: 1, acting: [
            ('agent-2', {HostActsAlone.forwardsAgent}),
          ]));
      await start(tester);
      await answer(tester, 'right password');
      expect(find.text(de.backupRestoreTitle), findsOneWidget);
      expect(find.text(de.backupRestoreReplaces(1)), findsOneWidget);
      expect(find.text(de.backupRestoreForwardsAgent), findsOneWidget);

      await tester.tap(find.text(de.cancel));
      await settle(tester);
      expect(backups.answered, isFalse);
      expect(backups.restored, isFalse);
      expect(container.read(notificationCenterProvider).history, isEmpty, reason: 'nothing is said of a restore not made');
    });

    testWidgets('and Restore restores it, said as before', (tester) async {
      L10nGlobal.update(de);
      final (container, backups) = await open(tester, [const BackupResult(success: true, recordCount: 3)],
          preview: const RestorePreview(hosts: 3, keys: 0, snippets: 0, other: 0, replaces: 0, acting: []));
      await start(tester);
      await answer(tester, 'right password');
      await tester.tap(find.byKey(const ValueKey('restore-preview-go')));
      await settle(tester);
      expect(backups.answered, isTrue);
      expect(backups.restored, isTrue);
      expect(container.read(notificationCenterProvider).history.first.title, de.settingsBackupRestored(3));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a backup that could not be restored says why, with what the restore said', (tester) async {
      L10nGlobal.update(de);
      final (container, backups) = await open(tester, [
        BackupResult(success: false, error: de.backupSvcCouldNotRestore, detail: 'UNIQUE constraint failed: connections.id'),
      ]);
      await start(tester);
      await answer(tester, 'right password');
      expect(backups.passwords, ['right password']);
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, de.settingsImportFailed(de.backupSvcCouldNotRestore));
      expect(notice.details, contains('UNIQUE constraint failed'));
      await tester.pump(const Duration(seconds: 12));
    });
  });

  group('exporting and reading', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Future<ProviderContainer> open(WidgetTester tester, _Backups backups) async {
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
                TextButton(onPressed: () => runBackupImport(context, ref), child: const Text('import')),
                TextButton(onPressed: () => runBackupExport(context, ref), child: const Text('export')),
              ]),
            ),
          ),
        ),
      ));
      return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    }

    testWidgets('an export that fails says why, with what was thrown', (tester) async {
      final container = await open(
          tester, _Backups(const [], exportResult: BackupResult(success: false, error: en.backupSvcCouldNotWrite, detail: 'database is locked')));
      await tester.tap(find.text('export'));
      await tester.pumpAndSettle();
      // (The new password is typed twice.)
      await tester.enterText(find.byKey(const ValueKey('export-backup-password')), 'a long enough password');
      await tester.enterText(find.byKey(const ValueKey('export-backup-password-again')), 'a long enough password');
      // ("Export": it says what it does, with no "..." where no picker opens.)
      await tester.tap(find.byKey(const ValueKey('export-backup-password-set')));
      await tester.pumpAndSettle();
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.settingsExportFailed(en.backupSvcCouldNotWrite));
      expect(notice.details, contains('database is locked'));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a picked file that cannot be read says why, with what was thrown', (tester) async {
      FilePicker.platform = _Picker('${dir.path}${Platform.pathSeparator}gone.zest');
      addTearDown(() => FilePicker.platform = _Picker(file.path));
      final container = await open(tester, _Backups(const []));
      await tester.runAsync(() async {
        await tester.tap(find.text('import'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.settingsImportFailed('This device no longer has "gone.zest".'));
      expect(notice.details, contains('PathNotFoundException'));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a picked file larger than any backup is refused before it is read: no password is asked '
        '(found in a check)', (tester) async {
      final huge = File('${dir.path}${Platform.pathSeparator}huge.zest');
      await tester.runAsync(() async {
        // An encrypted backup's first bytes, then more than a backup can be.
        final raf = await huge.open(mode: FileMode.write);
        await raf.writeFrom([0x5a, 0x45, 0x53, 0x54, 3]);
        await raf.truncate(BackupService.maxBackupBytes + 1);
        await raf.close();
      });
      addTearDown(() => huge.deleteSync());
      FilePicker.platform = _Picker(huge.path);
      addTearDown(() => FilePicker.platform = _Picker(file.path));
      final container = await open(tester, _Backups(const []));
      await tester.runAsync(() async {
        await tester.tap(find.text('import'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      final notice = container.read(notificationCenterProvider).history.first;
      expect(notice.title, en.settingsImportFailed(en.backupSvcFileTooLarge));
      expect(notice.details, contains('${BackupService.maxBackupBytes + 1} bytes'), reason: 'its size, to copy (3.4.2)');
      expect(find.byType(TextField), findsNothing, reason: 'no password asked');
      await tester.pump(const Duration(seconds: 12));
    });
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      expect(t.backupSvcCouldNotWrite, isNot(en.backupSvcCouldNotWrite), reason: '$locale');
      expect(t.backupSvcCouldNotRead, isNot(en.backupSvcCouldNotRead), reason: '$locale');
      expect(t.backupSvcCouldNotRestore, isNot(en.backupSvcCouldNotRestore), reason: '$locale');
    }
  });
}

/// The app's records, as a backup gathers and restores them, failing as told.
class _Data implements SyncDataService {
  _Data({this.restoreError, this.restoreThrows, this.gatherThrows});

  final String? restoreError;
  final Object? restoreThrows;
  final Object? gatherThrows;
  final List<Map<String, dynamic>> restored = [];

  @override
  Future<Map<String, dynamic>> gatherAll() async {
    if (gatherThrows != null) throw gatherThrows!;
    return const {};
  }

  @override
  Future<SyncRestoreResult> restoreAll(Map<String, dynamic> data, {SyncMergeBase? merge, bool asBackup = false}) async {
    if (restoreThrows != null) throw restoreThrows!;
    if (restoreError != null) return SyncRestoreResult(success: false, recordsRestored: 0, error: restoreError);
    restored.add(data);
    return const SyncRestoreResult(success: true, recordsRestored: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

/// A backup service whose imports answer as told, one after the other.
class _Backups implements BackupService {
  _Backups(this.results, {this.exportResult, this.preview});

  final List<BackupResult> results;
  final BackupResult? exportResult;
  final List<String> passwords = [];

  /// What the backup would do, asked about as the real service asks
  /// (importBackup's confirm) before anything is written; none, nothing asked.
  final RestorePreview? preview;

  /// What the question about [preview] answered, once asked.
  bool? answered;

  /// Whether a restore went through.
  bool restored = false;

  @override
  Future<BackupResult> exportBackup(String password, {String filenamePrefix = 'zestssh_backup_', bool allowUnencrypted = false}) async =>
      exportResult!;

  @override
  Future<BackupResult> importBackup(String filePath, String password,
      {bool allowLegacyUnencrypted = false, Future<RestoreChoice?> Function(RestorePreview preview)? confirm}) async {
    passwords.add(password);
    final asked = preview;
    if (asked != null && confirm != null) {
      answered = await confirm(asked) != null;
      if (!answered!) return const BackupResult(success: false, cancelled: true);
    }
    restored = true;
    return results.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

/// A file picker that picks [path].
class _Picker extends FilePicker {
  _Picker(this.path);

  final String path;

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
      FilePickerResult([PlatformFile(path: path, name: path.split(Platform.pathSeparator).last, size: 0)]);
}

