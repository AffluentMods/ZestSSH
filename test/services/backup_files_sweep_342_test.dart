import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/auto_backup_service.dart';
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/services/backup/backup_destination_manager.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Backup files the 3.4.2 sweep found wanting (L6, L7, L8): the copy of the
/// database before an upgrade left its write-ahead file behind; a backup was
/// written in place and named to the second; the backup places it was
/// copied to kept every one, without end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('zest_backup_files_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // (Left in the system's temporary folder.)
    }
  });
  String at(String name) => '${dir.path}${Platform.pathSeparator}$name';

  group('the copy of the database before an upgrade', () {
    test('takes its write-ahead file with it, under the name SQLite opens it by', () async {
      File(at('zestssh.db')).writeAsStringSync('the database');
      File(at('zestssh.db-wal')).writeAsStringSync('the newest changes');
      final copy = (await AppDatabase.backupDatabase(dir))!;
      expect(copy.readAsStringSync(), 'the database');
      expect(File('${copy.path}-wal').readAsStringSync(), 'the newest changes');
    });

    test('with no write-ahead file, the copy is the database alone', () async {
      File(at('zestssh.db')).writeAsStringSync('the database');
      final copy = (await AppDatabase.backupDatabase(dir))!;
      expect(File('${copy.path}-wal').existsSync(), isFalse);
    });

    test('a copy let go takes its write-ahead file with it', () async {
      for (final ts in [1000, 2000, 3000]) {
        File(at('zestssh_backup_$ts.db')).writeAsStringSync('copy $ts');
        File(at('zestssh_backup_$ts.db-wal')).writeAsStringSync('wal $ts');
      }
      await AppDatabase.pruneDatabaseBackups(keep: 2, folder: dir);
      expect(File(at('zestssh_backup_1000.db')).existsSync(), isFalse);
      expect(File(at('zestssh_backup_1000.db-wal')).existsSync(), isFalse);
      expect(File(at('zestssh_backup_3000.db-wal')).existsSync(), isTrue);
    });
  });

  group('a backup is written whole, then named', () {
    late PathProviderPlatform before;
    setUp(() {
      before = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(dir.path);
    });
    tearDown(() => PathProviderPlatform.instance = before);

    Directory backups() => Directory('${dir.path}/ZestSSH/backups');

    test('two in the same second are two files, named to the millisecond, and nothing half written is left',
        () async {
      final service = BackupService(_Data());
      final first = await service.exportBackup('', allowUnencrypted: true);
      final second = await service.exportBackup('', allowUnencrypted: true);
      expect(first.success && second.success, isTrue);
      expect(first.filePath, isNot(second.filePath));
      final names = backups().listSync().map((f) => f.uri.pathSegments.last).toList();
      expect(names, hasLength(2));
      for (final name in names) {
        expect(name, matches(RegExp(r'^zestssh_backup_\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}(-\d+)?\.zest$')));
      }
    });

    test('one left half written by a stop in the middle is cleared after an hour, not before', () async {
      backups().createSync(recursive: true);
      final old = File('${backups().path}/zestssh_auto_2026-11-07T01-00-00-000.zest${BackupService.unfinishedSuffix}')
        ..writeAsStringSync('cut');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
      final fresh = File('${backups().path}/zestssh_backup_2026-11-07T09-00-00-000.zest${BackupService.unfinishedSuffix}')
        ..writeAsStringSync('being written');
      await BackupService(_Data()).exportBackup('', allowUnencrypted: true);
      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(AutoBackupKind.of(old.uri.pathSegments.last), isNull, reason: 'never counted as a backup kept');
    });
  });

  group('the places backups are copied to keep what this device keeps', () {
    test('the oldest of the kind just copied go; the other kind and backups the person made stay', () async {
      SharedPreferences.setMockInitialValues({});
      final place = _Place('nextcloud', [
        for (var d = 1; d <= 9; d++) 'zestssh_auto_2026-11-0${d}T09-00-00.zest',
        for (var h = 1; h <= 3; h++) 'zestssh_auto_change_2026-11-09T0$h-00-00-000.zest',
        'zestssh_backup_2026-10-01T09-00-00.zest',
        'notes.txt',
      ]);
      final manager = BackupDestinationManager(prefs: await SharedPreferences.getInstance(), initial: [place]);
      final deleted =
          await manager.pruneAutoBackups(['nextcloud'], justCopied: 'zestssh_auto_2026-11-09T09-00-00.zest');
      expect(deleted['nextcloud'], ['zestssh_auto_2026-11-02T09-00-00.zest', 'zestssh_auto_2026-11-01T09-00-00.zest']);
      expect(place.files.where((n) => AutoBackupKind.of(n) == AutoBackupKind.scheduled), hasLength(7));
      expect(place.files.where((n) => AutoBackupKind.of(n) == AutoBackupKind.onChange), hasLength(3));
      expect(place.files, contains('zestssh_backup_2026-10-01T09-00-00.zest'));
      expect(place.files, contains('notes.txt'));
    });

    test('where the one just copied is not listed there, nothing is deleted', () async {
      SharedPreferences.setMockInitialValues({});
      final place = _Place('drive', [for (var d = 1; d <= 9; d++) 'zestssh_auto_2026-11-0${d}T09-00-00.zest']);
      final manager = BackupDestinationManager(prefs: await SharedPreferences.getInstance(), initial: [place]);
      final deleted = await manager.pruneAutoBackups(['drive'], justCopied: 'zestssh_auto_2026-11-10T09-00-00.zest');
      expect(deleted, isEmpty);
      expect(place.files, hasLength(9));
    });

    test('the app clears them after each copy', () {
      final app = File('lib/app.dart').readAsStringSync();
      final start = app.indexOf('Future<Map<String, String>> _copyAutoBackup(');
      final body = app.substring(start, app.indexOf('} catch (e) {', start));
      expect(body, contains('manager.pruneAutoBackups('));
    });
  });
}

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// The app's records, as a backup gathers them: none.
class _Data implements SyncDataService {
  @override
  Future<Map<String, dynamic>> gatherAll() async => {'connections': <Object>[]};

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

/// A backup place holding [files] by name.
class _Place implements BackupDestination {
  _Place(this.id, List<String> names) : files = [...names];

  @override
  final String id;
  final List<String> files;

  @override
  String get displayName => id;

  @override
  Future<List<BackupFileInfo>> listBackups() async => [
        for (final n in files)
          if (n.endsWith('.zest')) BackupFileInfo(filename: n, createdAt: DateTime(2026, 11, 9), sizeBytes: 100, destinationId: id),
      ];

  @override
  Future<void> deleteBackup(String filename) async => files.remove(filename);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
