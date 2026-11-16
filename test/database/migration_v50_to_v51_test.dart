import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// Exercises the REAL schema v50 -> v51 upgrade path.
///
/// Tickets (3.0, S1): two device-local tables. `support_tickets` holds the
/// tickets this device has sent, each with the token that makes it readable;
/// `ticket_outbox` holds follow-ups waiting to be sent. A database made at
/// v50 gains both, empty, with everything else kept as it was; and a
/// database that already has them (a PC that ran a test build) upgrades
/// without a word.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('zest-v51-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* Windows may hold the file a moment */}
  });

  Future<File> makeDatabase(bool orchard) async {
    final file = File('${dir.path}${Platform.pathSeparator}db.sqlite');
    final made = AppDatabase.forTesting(NativeDatabase(file), isOrchard: orchard, skipMigrationBackup: true);
    await made.customStatement(
        "INSERT INTO feedback_queue (nonce, payload, created_at) VALUES ('n1', '{}', 5)");
    await made.customStatement(
        "INSERT INTO local_state (\"key\", value, updated_at) VALUES ('k', 'v', 5)");
    await made.close();
    return file;
  }

  for (final orchard in [false, true]) {
    test('a v50 ${orchard ? 'Orchard' : 'Tree'} database gains both ticket tables, empty; the rest stays', () async {
      final file = await makeDatabase(orchard);
      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          raw.execute('DROP TABLE support_tickets');
          raw.execute('DROP TABLE ticket_outbox');
          raw.execute('PRAGMA user_version = 50');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);

      final names = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('support_tickets', 'ticket_outbox') ORDER BY name")
          .get();
      expect([for (final r in names) r.read<String>('name')], ['support_tickets', 'ticket_outbox']);
      expect(await db.select(db.supportTickets).get(), isEmpty);
      expect(await db.select(db.ticketOutbox).get(), isEmpty);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion, reason: 'on to the newest version');

      // What was there is still there.
      final queued = await db.select(db.feedbackQueue).get();
      expect(queued.single.nonce, 'n1');
      final state = await db.customSelect('SELECT value FROM local_state WHERE "key" = \'k\'').getSingle();
      expect(state.read<String>('value'), 'v');

      // And the new tables take what the app writes: a waiting ticket (no
      // server id yet) and a follow-up, with the defaults the app relies on.
      await db.into(db.supportTickets).insert(SupportTicketsCompanion.insert(
            nonce: 'a1',
            token: 'A' * 43,
            type: 'support',
            title: 'Cannot restore my purchase',
            createdAt: 10,
          ));
      final row = await db.select(db.supportTickets).getSingle();
      expect(row.serverId, isNull);
      expect(row.status, 'open');
      expect(row.tags, '[]');
      expect(row.messageCount, 0);
      expect(row.pending, isNull);
      await db.into(db.ticketOutbox).insert(
          TicketOutboxCompanion.insert(nonce: 'm1', ticketNonce: 'a1', body: 'hello', createdAt: 11));
      expect((await db.select(db.ticketOutbox).getSingle()).error, isNull);
    });

    test('a ${orchard ? 'Orchard' : 'Tree'} database that already has the tables upgrades and keeps their rows', () async {
      final file = await makeDatabase(orchard);
      var done = false;
      final db = AppDatabase.forTesting(
        NativeDatabase(file, setup: (raw) {
          if (done) return;
          done = true;
          raw.execute(
              "INSERT INTO support_tickets (nonce, token, type, title, created_at) VALUES ('kept', '${'B' * 43}', 'bug', 'Tabs overlap', 7)");
          raw.execute('PRAGMA user_version = 50');
        }),
        isOrchard: orchard,
        skipMigrationBackup: true,
      );
      addTearDown(db.close);
      final rows = await db.select(db.supportTickets).get();
      expect(rows.single.nonce, 'kept');
      expect(rows.single.title, 'Tabs overlap');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    });
  }

  test('a token that is not 43 characters is refused by the table itself', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await expectLater(
      db.into(db.supportTickets).insert(SupportTicketsCompanion.insert(
            nonce: 'x',
            token: 'short',
            type: 'support',
            title: 't',
            createdAt: 1,
          )),
      throwsA(anything),
    );
  });
}
