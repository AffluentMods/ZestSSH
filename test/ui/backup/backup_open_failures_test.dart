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
import 'package:zestssh/ui/widgets/top_snackbar.dart' show splitToastMessage;

/// A backup that does not open says what stopped it (found in a review of 3.4.2). Every
/// failure was "wrong password or corrupted backup", with nothing to copy: a
/// file cut short by a copy that did not finish, one over the size ZestSSH
/// opens, one whose header holds settings ZestSSH refuses. The person tried
/// password after password, and took the backup, or their memory, for lost.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  // The cheapest key derivation the app accepts.
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  final records = {
    'connections': [
      {'id': 'c1', 'label': 'web-01', 'host': 'web-01.northwind.example', 'port': 22}
    ],
  };

  late Directory dir;
  late List<int> whole;
  /// A backup as the app writes one (version 3), of [data], under [params].
  Future<List<int>> backupOf(Map<String, dynamic> data, {Map<String, dynamic> params = fast}) async {
    final salt = SyncService.generateSalt();
    final mek = await SyncService.deriveKey('right password', salt, params: fast);
    final sealed = await SyncService.encrypt(data, mek, salt);
    final header = utf8.encode(jsonEncode(params));
    return [...utf8.encode('ZEST'), 3, (header.length >> 8) & 0xff, header.length & 0xff, ...header, ...sealed];
  }

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('zestssh_open_');
    whole = await backupOf(records);
  });
  tearDownAll(() => dir.delete(recursive: true));

  var n = 0;
  Future<File> fileOf(List<int> bytes) async =>
      File('${dir.path}${Platform.pathSeparator}b${n++}.zest')..writeAsBytesSync(bytes);
  Future<BackupResult> open(List<int> bytes, [String password = 'right password']) async =>
      BackupService(_Data()).importBackup((await fileOf(bytes)).path, password);

  group('each is said as what it is, with what was found to copy', () {
    test('a wrong password: wrong, or the file damaged; asked again', () async {
      final result = await open(whole, 'wrong password');
      expect(result.error, en.backupOpenWrongOrDamaged);
      expect(result.passwordWrong, isTrue);
      expect(result.detail, contains('encryption check failed'));
      expect(result.detail, contains('Argon2id memory 65536 KiB'), reason: 'the settings it was opened with');
      expect(result.detail, isNot(contains('wrong password ')), reason: 'never the password typed');
    });

    test('a file cut short: incomplete, and no password asked again', () async {
      // (Its header is the settings as JSON: a whole one is that, the 7
      // bytes before it and at least 60 sealed after it.)
      final least = 7 + utf8.encode(jsonEncode(fast)).length + BackupService.leastSealed;
      for (final cut in [0, 3, 5, 6, 12, least - 1]) {
        final result = await open(whole.sublist(0, cut));
        expect(result.error, en.backupOpenCutShort, reason: 'cut at $cut');
        expect(result.passwordWrong, isFalse, reason: 'cut at $cut');
        expect(result.detail, contains('$cut bytes'), reason: 'cut at $cut');
      }
      final v1 = await open([...utf8.encode('ZEST'), 1, ...List.filled(30, 1)]);
      expect(v1.error, en.backupOpenCutShort);
    });

    test('a file that is no backup, and one a newer version wrote', () async {
      final text = await open(utf8.encode('just some notes, not a backup'));
      expect(text.error, en.backupOpenNotABackup);
      expect(text.passwordWrong, isFalse);
      final odd = await open([...utf8.encode('ZEST'), 0x20, ...List.filled(80, 1)]);
      expect(odd.error, en.backupOpenNotABackup, reason: 'ZEST and then text: no backup version');
      final newer = await open([...utf8.encode('ZEST'), 4, ...List.filled(80, 1)]);
      expect(newer.error, en.backupOpenNewer);
      expect(newer.detail, contains('version 4'));
      expect(newer.passwordWrong, isFalse);
    });

    test('a damaged header: too long, no settings in it, or settings ZestSSH refuses', () async {
      final long = await open([...utf8.encode('ZEST'), 3, 0x08, 0x00, ...List.filled(3000, 0x20)]);
      expect(long.error, en.backupOpenBadHeader);
      expect(long.detail, contains('2048'));
      final notJson = await open([...utf8.encode('ZEST'), 3, 0, 4, ...utf8.encode('{{{{'), ...List.filled(80, 1)]);
      expect(notJson.error, en.backupOpenBadHeader);
      final weak = await open(await backupOf(records, params: {'memory': 1024, 'iterations': 1, 'parallelism': 1}));
      expect(weak.error, en.backupOpenBadHeader, reason: 'weaker than any backup is made with');
      expect(weak.detail, contains('refused'));
      expect(weak.passwordWrong, isFalse, reason: 'no password opens it');
    });

    test('one that opens and holds more than ZestSSH opens: too large, the password was right', () async {
      final big = await backupOf({'notes': 'a' * (65 * 1024 * 1024)});
      final result = await open(big);
      expect(result.error, en.backupOpenTooLarge);
      expect(result.passwordWrong, isFalse);
      expect(result.detail, contains('exceeds the safe maximum'));
    });

    test('a whole one with the right password still opens', () async {
      final result = await open(whole);
      expect(result.success, isTrue);
    });
  });

  testWidgets('a file cut short is said before any password is asked, with its details', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cut = await tester.runAsync(() => fileOf(whole.sublist(0, 40)));
    FilePicker.platform = _Picker(cut!.path);
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
            builder: (context, ref, _) =>
                TextButton(onPressed: () => runBackupImport(context, ref), child: const Text('import')),
          ),
        ),
      ),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.text('import'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    final notice = container.read(notificationCenterProvider).history.first;
    expect(notice.title, splitToastMessage(en.settingsImportFailed(en.backupOpenCutShort)).$1);
    expect(notice.details, contains('40 bytes'));
    expect(find.byType(TextField), findsNothing, reason: 'no password asked');
    expect(backups.asked, isFalse);
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('a wrong password asks again, and its notice has details to copy', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final file = await tester.runAsync(() => fileOf(whole));
    FilePicker.platform = _Picker(file!.path);
    final backups = _Backups(answer: BackupResult(
        success: false, error: en.backupOpenWrongOrDamaged, passwordWrong: true, detail: 'the encryption check failed'));
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
            builder: (context, ref, _) =>
                TextButton(onPressed: () => runBackupImport(context, ref), child: const Text('import')),
          ),
        ),
      ),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.text('import'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'wrong password');
    await tester.tap(find.text(en.accountImportAction).last);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    final notice = container.read(notificationCenterProvider).history.first;
    expect(notice.title, splitToastMessage(en.settingsImportFailed(en.backupOpenWrongOrDamaged)).$1);
    expect(notice.details, contains('the encryption check failed'));
    expect(find.text(en.accountBackupPassword), findsWidgets, reason: 'asked again');
    await tester.pump(const Duration(seconds: 12));
  });

  test('every language says each its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final t = lookupAppLocalizations(locale);
      for (final (theirs, ours) in [
        (t.backupOpenWrongOrDamaged, en.backupOpenWrongOrDamaged),
        (t.backupOpenCutShort, en.backupOpenCutShort),
        (t.backupOpenTooLarge, en.backupOpenTooLarge),
        (t.backupOpenNotABackup, en.backupOpenNotABackup),
        (t.backupOpenBadHeader, en.backupOpenBadHeader),
        (t.backupOpenNewer, en.backupOpenNewer),
      ]) {
        expect(theirs, isNot(ours), reason: '$locale');
      }
    }
  });
}

/// The app's records, as a restore takes them.
class _Data implements SyncDataService {
  @override
  Future<RestorePreview> previewRestore(Map<String, dynamic> data) async =>
      const RestorePreview(hosts: 1, keys: 0, snippets: 0, other: 0, replaces: 0, acting: []);

  @override
  List<String> settingsThatWeaken(Map<dynamic, dynamic> settings) => const [];

  @override
  Future<SyncRestoreResult> restoreAll(Map<String, dynamic> data, {SyncMergeBase? merge, bool asBackup = false}) async =>
      const SyncRestoreResult(success: true, recordsRestored: 1);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

/// A backup service whose import answers as told; whether one was asked.
class _Backups implements BackupService {
  _Backups({this.answer});

  final BackupResult? answer;
  bool asked = false;

  @override
  Future<BackupResult> importBackup(String filePath, String password,
      {bool allowLegacyUnencrypted = false, Future<RestoreChoice?> Function(RestorePreview preview)? confirm}) async {
    asked = true;
    return answer ?? const BackupResult(success: true, recordCount: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

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
      FilePickerResult([PlatformFile(name: path.split(Platform.pathSeparator).last, path: path, size: 0)]);
}
