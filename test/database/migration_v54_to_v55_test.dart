import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';

import '../helpers/orchard_db_fixture.dart';

/// Exercises the REAL schema v54 -> v55 upgrade path.
///
/// A remote screen's options (4.0, VNC hosts): the column
/// connections.screen_options is added, null for every host there is. In an
/// Orchard it is one of the columns of the host's record: a change of it alone
/// is a change of the host, refused where its Crate does not allow one, and
/// sent where it does.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v55-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  for (final orchard in [false, true]) {
    test('a v54 ${orchard ? 'Orchard' : 'Tree'} database gains the column, null for every host', () async {
      final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
      final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await made.customStatement(
          'INSERT INTO connections (id, label, host, port, protocol, created_at, updated_at) VALUES '
          "('h1', 'web', '10.0.0.1', 22, 'ssh', 0, 0), ('h2', 'files', 'files.example.com', 21, 'ftps', 0, 0)");
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      await made.close();

      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          // As at v54: no column, and nothing that names it.
          final triggers = raw.select("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
          for (final t in triggers) {
            if (((t['sql'] as String?) ?? '').contains('screen_options')) raw.execute('DROP TRIGGER "${t['name']}"');
          }
          raw.execute('ALTER TABLE connections DROP COLUMN screen_options');
          raw.execute('PRAGMA user_version = 54');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);

      final rows = await db.customSelect('SELECT id, screen_options FROM connections ORDER BY id').get();
      expect([for (final r in rows) r.read<String>('id')], ['h1', 'h2']);
      expect([for (final r in rows) r.read<String?>('screen_options')], [null, null]);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');
      expect(db.schemaVersion, greaterThanOrEqualTo(55));

      // A host turned into a screen keeps its options (a personal space; a
      // team's host never changes kind, which commit 6's trigger checks).
      final options = ScreenOptions.defaults.copyWith(viewOnly: true).encode();
      Future<void> setOptions() => (db.update(db.connections)..where((c) => c.id.equals('h1')))
          .write(ConnectionsCompanion(screenOptions: Value(options)));
      if (orchard) {
        expect(db.orchardRecordColumns('connections'), contains('screen_options'),
            reason: "it travels in the host's record (when set)");
        await expectLater(setOptions(), throwsA(predicate((e) => '$e'.contains('orchard-access'))),
            reason: 'no Crate here allows a change yet');
        await seedOrchardAsOwner(db);
        await db.customStatement('DELETE FROM crate_outbox');
      }
      await setOptions();
      expect(ScreenOptions.decode((await db.connectionsDao.getById('h1'))!.screenOptions).viewOnly, isTrue);
      if (orchard) {
        final queued = await db.customSelect('SELECT kind, item_key FROM crate_outbox').get();
        expect([for (final r in queued) (r.read<String>('kind'), r.read<String>('item_key'))], [('host', 'h1')]);
      }
    });
  }
}
