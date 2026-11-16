import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v52 -> v53 upgrade path.
///
/// A host's other accounts (3.0, accounts per host): the table host_accounts
/// is made, empty. A database made at v52 gains it; hosts keep their identity,
/// which stays their default account. In an Orchard the table's rows travel
/// in the host's record, and its triggers are there once the database opens.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v53-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  for (final orchard in [false, true]) {
    test('a v52 ${orchard ? 'Orchard' : 'Tree'} database gains the table, empty; hosts keep their identity', () async {
      final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
      final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await made.customStatement(
          'INSERT INTO identities (id, label, username, auth_method, created_at, updated_at) VALUES '
          "('i1', 'deploy key', 'deploy', 'publicKey', 0, 0), ('i2', 'root password', 'root', 'password', 0, 0)");
      await made.customStatement(
          'INSERT INTO connections (id, label, host, port, protocol, identity_id, created_at, updated_at) VALUES '
          "('c1', 'web-01', '192.168.10.21', 22, 'ssh', 'i1', 0, 0), "
          "('c2', 'db-primary', 'db.example', 2222, 'ssh', NULL, 0, 0)");
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      await made.close();

      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          // As at v52: no table, and nothing that names it.
          final triggers = raw.select("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
          for (final t in triggers) {
            if (((t['sql'] as String?) ?? '').contains('host_accounts')) raw.execute('DROP TRIGGER "${t['name']}"');
          }
          raw.execute('DROP TABLE host_accounts');
          raw.execute('PRAGMA user_version = 52');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);

      final hosts = await db.customSelect('SELECT id, identity_id FROM connections ORDER BY id').get();
      expect([for (final r in hosts) (r.read<String>('id'), r.read<String?>('identity_id'))],
          [('c1', 'i1'), ('c2', null)]);
      expect(await db.select(db.hostAccounts).get(), isEmpty);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');
      expect(db.schemaVersion, greaterThanOrEqualTo(53));

      if (orchard) {
        expect(db.orchardRecordColumns('host_accounts'), unorderedEquals(['connection_id', 'identity_id', 'position']),
            reason: 'its rows travel in the host\'s record');
        final made = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%host_accounts%'")
            .get();
        expect([for (final r in made) r.read<String>('name')],
            containsAll(['trg_ob_host_accounts_ins', 'trg_ob_host_accounts_del', 'trg_gd_host_accounts_ins']));
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      }
      // The table takes a host's other account.
      await db.hostAccountsDao.setOtherAccounts('c1', ['i2']);
      expect(await db.hostAccountsDao.otherAccountsOf('c1'), ['i2']);
    });
  }
}
