import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v51 -> v52 upgrade path.
///
/// What colours a host's icon (3.0): connections gain `icon_color`. A
/// database made at v51 gains it, empty, which is the icon's own colour: the
/// default that was asked for, also for every host there already is (their
/// icons took the colour of the host's label or group until now). Hosts stay
/// as they were, with their icon and their colour label; in a Tree and in an
/// Orchard, where the column also travels in the Crate record.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v52-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  for (final orchard in [false, true]) {
    test('a v51 ${orchard ? 'Orchard' : 'Tree'} database gains the column, empty; hosts stay as they were', () async {
      final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
      final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await made.customStatement(
          'INSERT INTO connections (id, label, host, port, protocol, icon_id, color_value, created_at, updated_at) VALUES '
          "('c1', 'web-01', '192.168.10.21', 22, 'ssh', 'debian', 4282090230, 0, 0), "
          "('c2', 'db-primary', 'db.example', 2222, 'ssh', NULL, NULL, 0, 0)");
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      await made.close();

      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          // Anything naming the new column goes first, as at v51.
          final triggers = raw.select("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
          for (final t in triggers) {
            if (((t['sql'] as String?) ?? '').contains('icon_color')) raw.execute('DROP TRIGGER "${t['name']}"');
          }
          raw.execute('ALTER TABLE connections DROP COLUMN icon_color');
          raw.execute('PRAGMA user_version = 51');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);

      final rows = await db
          .customSelect('SELECT id, host, port, icon_id, color_value, icon_color FROM connections ORDER BY id')
          .get();
      expect([
        for (final r in rows)
          (r.read<String>('id'), r.read<String>('host'), r.read<int>('port'), r.read<String?>('icon_id'), r.read<int?>('color_value'))
      ], [
        ('c1', '192.168.10.21', 22, 'debian', 4282090230),
        ('c2', 'db.example', 2222, null, null),
      ]);
      expect(rows.every((r) => r.read<int?>('icon_color') == null), isTrue, reason: 'the icon\'s own colour');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');
      expect(db.schemaVersion, greaterThanOrEqualTo(52));

      if (orchard) {
        expect(db.orchardRecordColumns('connections'), contains('icon_color'), reason: 'it travels in the Crate record');
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      }
      // The column takes each of the three choices.
      for (final choice in [HostIconColor.followsLabel, 0xFF22C55E, null]) {
        await (db.update(db.connections)..where((c) => c.id.equals('c1')))
            .write(ConnectionsCompanion(iconColor: Value(choice)));
        final c1 = await (db.select(db.connections)..where((c) => c.id.equals('c1'))).getSingle();
        expect(c1.iconColor, choice);
      }
    });
  }
}
