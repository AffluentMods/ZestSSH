import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Tickets stay on the device that sent them. The key that makes a ticket
/// readable, what was written, and what waits to be sent are in two
/// device-local tables: none of it enters the synced payload, and so none of
/// it enters a `.zest` backup either (a backup is the same dump).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  test('nothing of a ticket is in the sync payload or a backup', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final key = 'K' * 43;
    await db.into(db.supportTickets).insert(SupportTicketsCompanion.insert(
          nonce: 'nonce-of-the-ticket',
          serverId: const Value('tk_server_id_of_it'),
          number: const Value(10042),
          token: key,
          type: 'support',
          title: 'SUBJECT-ONLY-ON-THIS-DEVICE',
          createdAt: 1,
          conversation: Value(const TicketConversation(body: 'BODY-ONLY-ON-THIS-DEVICE').encode()),
          pending: const Value('{"body":"PENDING-ONLY-ON-THIS-DEVICE"}'),
        ));
    await db.into(db.ticketOutbox).insert(TicketOutboxCompanion.insert(
        nonce: 'nonce-of-the-reply', ticketNonce: 'nonce-of-the-ticket', body: 'REPLY-ONLY-ON-THIS-DEVICE', createdAt: 2));

    final blob = await SyncDataService(
      database: db,
      connectionsDao: db.connectionsDao,
      identitiesDao: db.identitiesDao,
      groupsDao: db.connectionGroupsDao,
      knownHostsDao: db.knownHostsDao,
      snippetsDao: db.snippetsDao,
      snippetCategoriesDao: db.snippetCategoriesDao,
      portForwardRulesDao: db.portForwardRulesDao,
      networksDao: db.networksDao,
      connectionTagsDao: db.connectionTagsDao,
      secureStorage: storage,
      settingsService: settings,
    ).gatherAll();

    final dump = jsonEncode(blob);
    for (final secret in [
      key,
      'nonce-of-the-ticket',
      'nonce-of-the-reply',
      'tk_server_id_of_it',
      'SUBJECT-ONLY-ON-THIS-DEVICE',
      'BODY-ONLY-ON-THIS-DEVICE',
      'PENDING-ONLY-ON-THIS-DEVICE',
      'REPLY-ONLY-ON-THIS-DEVICE',
    ]) {
      expect(dump, isNot(contains(secret)), reason: secret);
    }
    expect(blob.keys, isNot(contains('support_tickets')));
    expect(blob.keys, isNot(contains('ticket_outbox')));
  });
}
