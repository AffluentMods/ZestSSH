import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/profiles/profile_boot.dart';

/// Data written by a newer ZestSSH. Drift calls
/// onUpgrade for any version that differs, every step is "from < n", so none
/// ran, the open went ahead without a word and the file was stamped with the
/// older version: the older app then ran on newer data. Now the open stops
/// with DatabaseNewerThanApp, the file keeps its version, and nothing that
/// changes data is offered for it: no copy put back, no Reset, no Set aside.
/// Also: a failure of the moment ("database is locked") is not taken
/// for a failed upgrade either.
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zest_newer_db_');
    file = File('${dir.path}/zestssh.db');
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  int versionOnDisk() {
    final raw = sqlite.sqlite3.open(file.path);
    try {
      return raw.select('PRAGMA user_version').first.values.first as int;
    } finally {
      raw.dispose();
    }
  }

  test('a database from a newer ZestSSH does not open, and keeps its version', () async {
    final first = AppDatabase.forTesting(NativeDatabase(file));
    await first.customSelect('SELECT 1').get();
    await first.close();
    final newer = AppDatabase.currentSchemaVersion + 1;
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('PRAGMA user_version = $newer');
    raw.dispose();

    final again = AppDatabase.forTesting(NativeDatabase(file));
    Object? error;
    try {
      await again.customSelect('SELECT 1').get();
    } catch (e) {
      error = e;
    }
    await again.close();
    expect(error, isA<DatabaseNewerThanApp>());
    final e = error! as DatabaseNewerThanApp;
    expect(e.fileVersion, newer);
    expect(e.appVersion, AppDatabase.currentSchemaVersion);
    expect(versionOnDisk(), newer);
  });

  test('nothing that changes data is offered for it', () {
    const e = DatabaseNewerThanApp(56, 55);
    expect(MigrationBackupService.looksLikeMigrationFailure(e), isFalse);
    expect(dataStaysAsItIs(e), isTrue);
    expect(resetOffered(e, moving: false, computer: false), isFalse);
  });

  test('a failure of the moment is not taken for a failed upgrade; a failed upgrade still is', () {
    expect(MigrationBackupService.looksLikeMigrationFailure(Exception('SqliteException(5): database is locked')),
        isFalse);
    expect(MigrationBackupService.looksLikeMigrationFailure(Exception('SqliteException(13): database or disk is full')),
        isFalse);
    expect(
        MigrationBackupService.looksLikeMigrationFailure(
            const MigrationIntegrityException(message: 'x', fromVersion: 54, toVersion: 55, failures: ['y'])),
        isTrue);
    expect(MigrationBackupService.looksLikeMigrationFailure(Exception('SqliteException(1): no such column: foo')),
        isTrue);
  });
}
