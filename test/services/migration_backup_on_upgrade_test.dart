import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';

/// Every start copied the whole database to `migration_backups/pre_v0_to_v0_<time>.db`
/// before opening it, whether an upgrade was to run or not, and only a start with
/// the lock off ever cleared any, keeping every copy from the last 30 days (3.3, seen
/// in the Sandbox: one new copy per start). Now a copy is made only where opening the
/// database will upgrade it, named with the two versions; the three newest are kept,
/// cut wherever a database opens; and a restore after a failed upgrade puts back only
/// the copy made before it, never an older one.
void main() {
  const now = AppDatabase.currentSchemaVersion;
  late Directory base;
  late File db;

  Directory backups([Directory? folder]) =>
      Directory(p.join((folder ?? base).path, 'migration_backups'));
  List<String> copiesIn([Directory? folder]) {
    final dir = backups(folder);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .where((n) => n.endsWith('.db'))
        .toList()
      ..sort();
  }

  setUp(() async {
    base = await Directory.systemTemp.createTemp('zest_backups_');
    ProfilePaths.debugBase = base;
    Profiles.debugReset();
    MigrationBackupService.debugForgetThisRun();
    MigrationBackupService.restoreHeld = null;
    db = File(p.join(base.path, 'zestssh.db'))
      ..writeAsStringSync('the database');
  });

  tearDown(() async {
    ProfilePaths.debugBase = null;
    MigrationBackupService.debugForgetThisRun();
    await base.delete(recursive: true);
  });

  group('a database that keeps failing to open', () {
    test('is not copied again at every start while it is the same: the copies kept stay the older ones', () async {
      final first = await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now);
      expect(first, isNotNull);
      MigrationBackupService.debugForgetThisRun();
      final again = await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now);
      expect(again, first);
      expect(copiesIn(), hasLength(1));
      // Changed since: a new copy.
      db.writeAsStringSync('the database, changed');
      MigrationBackupService.debugForgetThisRun();
      final changed = await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now);
      expect(changed, isNot(first));
      expect(copiesIn(), hasLength(2));
    });

    test('a copy is put back whole and leaves nothing beside the database', () async {
      final copy = await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now);
      db.writeAsStringSync('the broken one');
      await MigrationBackupService.restoreFromBackup(copy!);
      expect(db.readAsStringSync(), 'the database');
      expect(File('${db.path}.restoring').existsSync(), isFalse);
    });
  });

  group('a copy before opening', () {
    test(
      'none where the database last opened at this version: a start that upgrades nothing copies nothing',
      () async {
        await MigrationBackupService.noteOpened(now);
        expect(
          await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now),
          isNull,
        );
        expect(
          await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now),
          isNull,
        );
        expect(copiesIn(), isEmpty);
      },
    );

    test(
      'one where it last opened at an older version, named with the two, holding the database',
      () async {
        await MigrationBackupService.noteOpened(now - 1);
        final copy = await MigrationBackupService.backupBeforeUpgrade(
          schemaVersion: now,
        );
        expect(copy, isNotNull);
        expect(p.basename(copy!), startsWith('pre_v${now - 1}_to_v${now}_'));
        expect(File(copy).readAsStringSync(), 'the database');
      },
    );

    test(
      'one where the version it opened at is not known (from before 3.3, moved into a profile)',
      () async {
        final copy = await MigrationBackupService.backupBeforeUpgrade(
          schemaVersion: now,
        );
        expect(p.basename(copy!), startsWith('pre_v0_to_v${now}_'));
      },
    );

    test('none where there is no database yet', () async {
      db.deleteSync();
      expect(
        await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now),
        isNull,
      );
    });

    test(
      'a profile opened at a sign-in: its own folder, its own version',
      () async {
        final profile = Directory(p.join(base.path, 'profiles', 'a' * 32))
          ..createSync(recursive: true);
        File(
          p.join(profile.path, 'zestssh.db'),
        ).writeAsStringSync('the profile');
        await MigrationBackupService.noteOpened(now, folder: profile);
        expect(
          await MigrationBackupService.backupBeforeUpgrade(
            schemaVersion: now,
            folder: profile,
          ),
          isNull,
        );
        await MigrationBackupService.noteOpened(now - 2, folder: profile);
        final copy = await MigrationBackupService.backupBeforeUpgrade(
          schemaVersion: now,
          folder: profile,
        );
        expect(p.isWithin(backups(profile).path, copy!), isTrue);
        expect(
          copiesIn(),
          isEmpty,
          reason: 'nothing in the folder of the one open',
        );
      },
    );
  });

  group('the copies kept', () {
    test(
      'the three newest, whatever their age, with the write-ahead files of those that go',
      () async {
        final dir = backups()..createSync(recursive: true);
        for (var day = 1; day <= 5; day++) {
          final f = File(p.join(dir.path, 'pre_v0_to_v0_$day.db'))
            ..writeAsStringSync('copy $day');
          File('${f.path}-wal').writeAsStringSync('wal $day');
          // Day 1 the newest, all of them within 30 days.
          f.setLastModifiedSync(DateTime.now().subtract(Duration(days: day)));
        }
        await MigrationBackupService.noteOpened(now);
        expect(copiesIn(), [
          'pre_v0_to_v0_1.db',
          'pre_v0_to_v0_2.db',
          'pre_v0_to_v0_3.db',
        ]);
        expect(
          File(p.join(dir.path, 'pre_v0_to_v0_4.db-wal')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(dir.path, 'pre_v0_to_v0_1.db-wal')).existsSync(),
          isTrue,
        );
        expect(
          await MigrationBackupService.openedSchema(),
          now,
          reason: 'what it notes is not a copy',
        );
      },
    );

    test(
      'a database opening notes its version and cuts its copies, wherever it opens',
      () async {
        final profile = Directory(p.join(base.path, 'profiles', 'b' * 32))
          ..createSync(recursive: true);
        final dir = backups(profile)..createSync(recursive: true);
        for (var i = 0; i < 6; i++) {
          File(
            p.join(dir.path, 'pre_v0_to_v0_$i.db'),
          ).writeAsStringSync('copy $i');
        }
        final opened = AppDatabase(NativeDatabase.memory(), ownFolder: profile);
        await opened.customSelect('SELECT 1').get();
        await opened.close();
        expect(await MigrationBackupService.openedSchema(folder: profile), now);
        expect(copiesIn(profile), hasLength(3));
      },
    );

    test(
      'a test database notes nothing (it would reach the real app data)',
      () async {
        final opened = AppDatabase.forTesting(NativeDatabase.memory());
        await opened.customSelect('SELECT 1').get();
        await opened.close();
        expect(await MigrationBackupService.openedSchema(), isNull);
      },
    );
  });

  group('putting a copy back', () {
    test(
      'a restore forgets the version opened, so the next start copies again',
      () async {
        await MigrationBackupService.noteOpened(now - 1);
        final copy = await MigrationBackupService.backupBeforeUpgrade(
          schemaVersion: now,
        );
        db.writeAsStringSync('half upgraded');
        await MigrationBackupService.restoreFromBackup(copy!);
        expect(db.readAsStringSync(), 'the database');
        expect(await MigrationBackupService.openedSchema(), isNull);
        expect(
          await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now),
          isNotNull,
        );
      },
    );

    test(
      'an unlock that fails with what looks like a failed upgrade puts back the copy made before it',
      () async {
        await MigrationBackupService.noteOpened(now - 1);
        await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now);
        db.writeAsStringSync('half upgraded');
        await DatabaseSessionNotifier.afterFailedOpen(
          Exception('SqliteException: no such column'),
        );
        expect(db.readAsStringSync(), 'the database');
      },
    );

    test(
      'once the database has opened, the copy from before its upgrade is not put back any more',
      () async {
        await MigrationBackupService.noteOpened(now - 1);
        await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now);
        await MigrationBackupService.noteOpened(now); // its upgrade passed
        db.writeAsStringSync('everything since');
        await DatabaseSessionNotifier.afterFailedOpen(
          Exception('SqliteException: database is locked'),
        );
        expect(db.readAsStringSync(), 'everything since');
      },
    );

    test(
      'but never an older copy: with no upgrade this start made none, and the database stays',
      () async {
        // A copy from an upgrade weeks ago, and this start upgraded nothing.
        final old = File(
          p.join(
            (backups()..createSync(recursive: true)).path,
            'pre_v${now - 1}_to_v${now}_1.db',
          ),
        )..writeAsStringSync('as it was weeks ago');
        await MigrationBackupService.noteOpened(now);
        expect(
          await MigrationBackupService.backupBeforeUpgrade(schemaVersion: now),
          isNull,
        );
        db.writeAsStringSync('everything since');
        await DatabaseSessionNotifier.afterFailedOpen(
          Exception('SqliteException: database is locked'),
        );
        expect(db.readAsStringSync(), 'everything since');
        expect(old.existsSync(), isTrue);
      },
    );
  });
}
