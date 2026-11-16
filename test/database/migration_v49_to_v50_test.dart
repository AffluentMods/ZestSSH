import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v49 -> v50 upgrade path.
///
/// Cloud import (3.0): connections gain `cloud_source`, where a host was
/// imported from. A database made at v49 gains it, empty, with every host
/// kept as it was; in a Tree and in an Orchard, where the column also
/// travels in the Crate record.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v50-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  for (final orchard in [false, true]) {
    test('a v49 ${orchard ? 'Orchard' : 'Tree'} database gains the column, empty; hosts stay as they were', () async {
      final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
      final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await made.customStatement(
          'INSERT INTO connections (id, label, host, port, protocol, created_at, updated_at) VALUES '
          "('c1', 'web', '10.0.0.5', 22, 'ssh', 0, 0), ('c2', 'db', 'db.lan', 2222, 'ssh', 0, 0)");
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      await made.close();

      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          // Anything naming the new column goes first, as at v49.
          final triggers = raw.select("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
          for (final t in triggers) {
            if (((t['sql'] as String?) ?? '').contains('cloud_source')) raw.execute('DROP TRIGGER "${t['name']}"');
          }
          raw.execute('ALTER TABLE connections DROP COLUMN cloud_source');
          raw.execute('PRAGMA user_version = 49');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);

      final rows = await db.customSelect('SELECT id, host, port, cloud_source FROM connections ORDER BY id').get();
      expect([for (final r in rows) (r.read<String>('id'), r.read<String>('host'), r.read<int>('port'))],
          [('c1', '10.0.0.5', 22), ('c2', 'db.lan', 2222)]);
      expect(rows.every((r) => r.read<String?>('cloud_source') == null), isTrue);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');

      if (orchard) {
        expect(db.orchardRecordColumns('connections'), contains('cloud_source'), reason: 'it travels in the Crate record');
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      }
      const link = '{"v":1,"p":"aws","id":"i-1","l":"AWS main","a":"10.0.0.5","n":"web"}';
      await (db.update(db.connections)..where((c) => c.id.equals('c1'))).write(const ConnectionsCompanion(cloudSource: Value(link)));
      final c1 = await (db.select(db.connections)..where((c) => c.id.equals('c1'))).getSingle();
      expect(c1.cloudSource, link);
    });
  }
}
