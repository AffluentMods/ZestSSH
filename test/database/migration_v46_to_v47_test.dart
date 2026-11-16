import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v46 -> v47 upgrade path.
///
/// Team-pinned host keys (3.0) are an Orchard item kind with a
/// table of their own. An Orchard database made at v46 gains the table (and
/// its write guard and outbox triggers when it opens), and keeps what it had.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v47-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  /// An Orchard database with a Crate this account edits and a member, closed.
  Future<File> orchardDatabase() async {
    final file = File('${dir.path}${Platform.pathSeparator}orchard.db');
    final db = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
        "VALUES (1, '44444444-4444-4444-8444-444444444444', 'Acme', 'owner', 1, "
        "'11111111-1111-4111-8111-111111111111')");
    await db.customStatement(
        'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
        '''('11111111-1111-4111-8111-111111111111', 'Open', 'edit', '["add","connect","edit"]', 1)''');
    await db.customStatement(
        'INSERT INTO member_keys (uid, email, role, key_version, verified_by_me, verified_by) '
        "VALUES ('alice', 'alice@example.com', 'admin', 2, 1, '[]')");
    await db.close();
    return file;
  }

  /// Reopens [file] after [change] ran on it, as the app would.
  Future<AppDatabase> reopen(File file, void Function(dynamic raw) change) {
    var done = false;
    final db = AppDatabase.forTesting(
      NativeDatabase(file, setup: (raw) {
        if (done) return;
        done = true;
        change(raw);
      }),
      isOrchard: true,
    );
    return db.customSelect('SELECT 1').get().then((_) => db);
  }

  test('a v46 database gains the pinned host keys, guarded and queued like any item, and keeps its rows', () async {
    final file = await orchardDatabase();
    final db = await reopen(file, (raw) {
      raw.execute('DROP TABLE team_host_keys');
      raw.execute('PRAGMA user_version = 46');
    });
    addTearDown(db.close);

    expect((await db.customSelect('SELECT email FROM member_keys').getSingle()).read<String>('email'),
        'alice@example.com');
    await db.customStatement(
        "INSERT INTO team_host_keys (id, host, port, host_keys) VALUES ('web1|22|', 'web1', 22, '[]')");
    final pin = await db.customSelect('SELECT id, via_scope FROM team_host_keys').getSingle();
    expect(pin.data, {'id': 'web1|22|', 'via_scope': ''});
    expect(
        [for (final r in await db.customSelect('SELECT kind, item_key FROM crate_outbox').get()) r.data.values.join(':')],
        ['hostkey:web1|22|'],
        reason: 'the outbox trigger came with it');
    // Without edit in the Crate new items go to, the guard refuses a pin.
    await db.customStatement('''UPDATE orchard_crates SET switches = '["add","connect"]' ''');
    await expectLater(
        db.customStatement(
            "INSERT INTO team_host_keys (id, host, port, host_keys) VALUES ('web2|22|', 'web2', 22, '[]')"),
        throwsA(predicate((e) => '$e'.contains('orchard-access'))));
  });
}
