import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v48 -> v49 upgrade path.
///
/// Password managers (3.0): identities gain whose agent holds an
/// agent-backed key (`agent_source`) and where a password in a password
/// manager lives (`password_ref`). A database made at v48 gains both, empty,
/// with every identity kept as it was; in a Tree and in an Orchard.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v49-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  for (final orchard in [false, true]) {
    test('a v48 ${orchard ? 'Orchard' : 'Tree'} database gains both columns, empty; identities stay as they were',
        () async {
      final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
      final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await made.customStatement(
          "INSERT INTO identities (id, label, username, auth_method, uses_agent, created_at) VALUES "
          "('k1', 'Deploy', 'deploy', 'password', 0, 0), ('k2', 'Token', 'git', 'hardwareToken', 1, 0)");
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      await made.close();

      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          // Anything naming the new columns goes first, as at v48.
          final triggers = raw.select("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
          for (final t in triggers) {
            final sql = (t['sql'] as String?) ?? '';
            if (sql.contains('agent_source') || sql.contains('password_ref')) {
              raw.execute('DROP TRIGGER "${t['name']}"');
            }
          }
          raw.execute('ALTER TABLE identities DROP COLUMN agent_source');
          raw.execute('ALTER TABLE identities DROP COLUMN password_ref');
          raw.execute('PRAGMA user_version = 48');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);

      final rows = await db.customSelect('SELECT id, auth_method, uses_agent, agent_source, password_ref FROM identities ORDER BY id').get();
      expect([for (final r in rows) (r.read<String>('id'), r.read<String>('auth_method'), r.read<bool>('uses_agent'))],
          [('k1', 'password', false), ('k2', 'hardwareToken', true)]);
      expect(rows.every((r) => r.read<String?>('agent_source') == null && r.read<String?>('password_ref') == null), isTrue);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');

      // And they are written and read like any column.
      if (orchard) await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await (db.update(db.identities)..where((i) => i.id.equals('k2')))
          .write(const IdentitiesCompanion(agentSource: Value('1password')));
      final k2 = await (db.select(db.identities)..where((i) => i.id.equals('k2'))).getSingle();
      expect(k2.agentSource, '1password');
    });
  }
}
