import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';

import '../helpers/orchard_db_fixture.dart';

/// Exercises the REAL schema v55 -> v56 upgrade path.
///
/// A team host's shared SFTP bookmarks (4.0): the column
/// connections.shared_pins is added, null for every host there is. In an
/// Orchard it is one of the columns of the host's record: a change of it
/// alone is a change of the host, refused where its Crate does not let this
/// account edit (a member who may only view), and sent where it does. A
/// member's own pins stay a column of the device, which changes nothing in
/// the team.

const _shared = '[{"label":"Service","path":"/opt/x/service"}]';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v56-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// A database made at v55: two hosts, then the column and whatever names
  /// it taken away, and the version set back.
  Future<AppDatabase> openAt55({required bool orchard}) async {
    final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
    final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
    if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await made.customStatement(
        'INSERT INTO connections (id, label, host, port, protocol, pins, created_at, updated_at) VALUES '
        "('h1', 'web', '192.0.2.10', 22, 'ssh', '[{\"label\":\"Mine\",\"path\":\"/home/deploy\"}]', 0, 0), "
        "('h2', 'files', 'files.example.com', 21, 'ftps', NULL, 0, 0)");
    if (orchard) await made.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    await made.close();

    var done = false;
    final db = AppDatabase.forTesting(
      NativeDatabase(file, setup: (raw) {
        if (done) return;
        done = true;
        // As at v55: no column, and nothing that names it.
        final triggers = raw.select("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
        for (final t in triggers) {
          if (((t['sql'] as String?) ?? '').contains('shared_pins')) raw.execute('DROP TRIGGER "${t['name']}"');
        }
        raw.execute('ALTER TABLE connections DROP COLUMN shared_pins');
        raw.execute('PRAGMA user_version = 55');
      }),
      isOrchard: orchard,
      skipMigrationBackup: true,
    );
    addTearDown(db.close);
    return db;
  }

  Future<void> setShared(AppDatabase db) => db.connectionsDao.setSharedPins('h1', _shared);

  for (final orchard in [false, true]) {
    test('a v55 ${orchard ? 'Orchard' : 'Tree'} database gains the column, null for every host, '
        'and every host keeps its own pins', () async {
      final db = await openAt55(orchard: orchard);

      final rows = await db.customSelect('SELECT id, pins, shared_pins FROM connections ORDER BY id').get();
      expect([for (final r in rows) r.read<String>('id')], ['h1', 'h2']);
      expect([for (final r in rows) r.read<String?>('shared_pins')], [null, null]);
      expect(rows.first.read<String?>('pins'), contains('/home/deploy'), reason: 'your own pins stay as they were');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');
      expect(db.schemaVersion, greaterThanOrEqualTo(56));
      expect(db.orchardRecordColumns('connections'), contains('shared_pins'),
          reason: "it travels in a team host's record (when set)");
      expect(db.orchardRecordColumns('connections'), isNot(contains('pins')), reason: 'your own pins never do');

      if (orchard) {
        await expectLater(setShared(db), throwsA(predicate((e) => '$e'.contains('orchard-access'))),
            reason: 'no Crate here allows a change yet');
        await seedOrchardAsOwner(db);
        await db.customStatement('DELETE FROM crate_outbox');
      }
      await setShared(db);
      expect((await db.connectionsDao.getById('h1'))!.sharedPins, _shared);
      if (orchard) {
        final queued = await db.customSelect('SELECT kind, item_key FROM crate_outbox').get();
        expect([for (final r in queued) (r.read<String>('kind'), r.read<String>('item_key'))], [('host', 'h1')],
            reason: 'a change of the shared bookmarks is a change of the host, sent to the team');
      }
    });
  }

  test('in a team, a member who may only view the host cannot change its shared bookmarks; '
      'their own pins they can', () async {
    final db = await openAt55(orchard: true);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
      "VALUES (1, ?, 'Fixture', 'member', 1, ?, '[]')",
      [kFixtureOrchardId, kFixtureCrateId],
    );
    await db.customStatement(
      'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) '
      "VALUES (?, 'Fixture', 'use', ?, 1)",
      [kFixtureCrateId, jsonEncode([CrateSwitches.connect, CrateSwitches.sftp])],
    );
    // The host is on the server, in that Crate.
    await db.customStatement(
      'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, edited_at) '
      "VALUES ('host', 'h1', ?, 3, 1)",
      [kFixtureCrateId],
    );

    await expectLater(setShared(db), throwsA(predicate((e) => '$e'.contains('orchard-access'))));
    expect((await db.connectionsDao.getById('h1'))!.sharedPins, isNull);

    await db.connectionsDao.setPins('h1', '[{"label":"Logs","path":"/var/log"}]');
    expect((await db.connectionsDao.getById('h1'))!.pins, contains('/var/log'));
    final queued = await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle();
    expect(queued.read<int>('n'), 0, reason: 'your own pins are not the team\'s');
  });
}
