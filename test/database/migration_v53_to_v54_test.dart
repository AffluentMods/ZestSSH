import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

import '../helpers/orchard_db_fixture.dart';

/// Exercises the REAL schema v53 -> v54 upgrade path.
///
/// A key's own password, tried after the key (3.0, accounts per host): the
/// column identities.password_after_key is added, off for every identity
/// there is, so a password left from before an identity became a key is
/// never sent. In an Orchard it is one of the columns of the key's record:
/// a change of it alone is a change of the key, refused where its Crate does
/// not allow one, and sent where it does.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v54-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  for (final orchard in [false, true]) {
    test('a v53 ${orchard ? 'Orchard' : 'Tree'} database gains the column, off for every identity', () async {
      final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
      final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await made.customStatement(
          'INSERT INTO identities (id, label, username, auth_method, created_at, updated_at) VALUES '
          "('i1', 'deploy key', 'deploy', 'publicKey', 0, 0), ('i2', 'root password', 'root', 'password', 0, 0)");
      if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      await made.close();

      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          // As at v53: no column, and nothing that names it.
          final triggers = raw.select("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
          for (final t in triggers) {
            if (((t['sql'] as String?) ?? '').contains('password_after_key')) raw.execute('DROP TRIGGER "${t['name']}"');
          }
          raw.execute('ALTER TABLE identities DROP COLUMN password_after_key');
          raw.execute('PRAGMA user_version = 53');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);

      final rows = await db.customSelect('SELECT id, password_after_key FROM identities ORDER BY id').get();
      expect([for (final r in rows) r.read<String>('id')], ['i1', 'i2']);
      expect([for (final r in rows) r.read<bool>('password_after_key')], [false, false]);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');
      expect(db.schemaVersion, greaterThanOrEqualTo(54));

      Future<void> turnOn() => (db.update(db.identities)..where((i) => i.id.equals('i1')))
          .write(const IdentitiesCompanion(passwordAfterKey: Value(true)));
      if (orchard) {
        expect(db.orchardRecordColumns('identities'), contains('password_after_key'),
            reason: "it travels in the key's record");
        await expectLater(turnOn(), throwsA(predicate((e) => '$e'.contains('orchard-access'))),
            reason: 'no Crate here allows a change yet');
        await seedOrchardAsOwner(db);
        await db.customStatement('DELETE FROM crate_outbox');
      }
      // The column takes the switch; in an Orchard, a change of it alone is
      // a change of the key to send.
      await turnOn();
      expect((await db.identitiesDao.getById('i1'))!.passwordAfterKey, isTrue);
      if (orchard) {
        final queued = await db.customSelect('SELECT kind, item_key FROM crate_outbox').get();
        expect([for (final r in queued) (r.read<String>('kind'), r.read<String>('item_key'))], [('key', 'i1')]);
      }
    });
  }
}
