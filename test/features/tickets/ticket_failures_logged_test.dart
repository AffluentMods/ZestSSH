import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/ticket_poller.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/utils/logger.dart';

import 'fake_ticket_server.dart';

/// What the app notes of a ticket or a report that did not go names the
/// kind of what stopped it (3.0; the SSH core's audit, the app's half of
/// what it found of names).
///
/// Those lines carry the kind of the error and not its words, which can
/// hold an address. They asked the program for the name of the error's
/// type (`runtimeType`), which is another name in a build made for release:
/// "Ticket check failed: aB". The lines are kept for an error's details,
/// which is all anybody ever sees of them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const ctx = FeedbackContext(
    appVersion: '3.0.0',
    build: 300,
    platform: 'windows',
    osVersion: 'Windows 11',
    locale: 'en-US',
    tier: 'free',
  );

  late AppDatabase db;
  late List<String> noted;
  var clock = DateTime.utc(2026, 10, 1, 8);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    clock = DateTime.utc(2026, 10, 1, 8);
    noted = [];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final listening = Logger.root.onRecord.listen((record) => noted.add('${record.level.name}: ${record.message}'));
    AppLogger.forget();
    addTearDown(() {
      Logger.root.level = level;
      return listening.cancel();
    });
  });
  tearDown(() => db.close());

  TicketService tickets(Future<http.Response> Function(http.Request) handler) =>
      TicketService(db, client: MockClient(handler), now: () => clock, baseUrl: 'https://api.test/v1');

  test('a round of checking that fails: the kind of what failed, and nothing of its words', () async {
    final server = FakeTicketServer();
    final poller = TicketPoller(tickets(server.handle),
        now: () => clock, retryReports: () async => throw StateError('the queue at 192.0.2.10 is broken'));
    await poller.check(force: true);
    expect(noted, ['WARNING: Ticket check failed: StateError']);

    // A cast that fails is a TypeError. (What the program calls that kind starts with an underscore in a test.)
    noted.clear();
    final Object list = <int>[];
    final other = TicketPoller(tickets(server.handle),
        now: () => clock, retryReports: () async => (list as Map<String, Object?>).clear());
    await other.check(force: true);
    expect(noted, ['WARNING: Ticket check failed: TypeError']);
  });

  test('a call that does not reach ZestSSH Cloud: the kind of what stopped it', () async {
    for (final (thrown, kind) in <(Object, String)>[
      (const SocketException('Failed host lookup: api.test'), 'SocketException'),
      (http.ClientException('Connection closed before full header was received'), 'ClientException'),
      (const HandshakeException('CERTIFICATE_VERIFY_FAILED'), 'HandshakeException'),
    ]) {
      noted.clear();
      final service = tickets((_) async => throw thrown);
      final res = await service.createSupport(title: 'Help', body: 'Please.', context: ctx);
      expect(res.outcome, isNot(TicketSendOutcome.sent));
      expect(noted, contains('WARNING: Ticket call not delivered: $kind'), reason: '$thrown');
      expect(noted.join('\n'), isNot(contains('api.test')));
    }
  });

  test('a report that does not go for another reason than no network: the kind of what stopped it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final feedback = FeedbackService(db, prefs,
        client: MockClient((_) async => throw http.ClientException('Connection reset by 192.0.2.10')));
    final res = await feedback.send(FeedbackReport(
      type: FeedbackType.bug,
      title: 'Tab strip overlaps',
      body: 'The third tab is drawn under the pill bar.',
      expected: 'Tabs stay inside the strip.',
      context: ctx,
      createdAt: DateTime.utc(2026, 10, 1, 7, 30),
    ));
    expect(res.outcome, FeedbackOutcome.queued);
    expect(noted, contains('WARNING: Feedback send error: ClientException'));
    expect(noted.join('\n'), isNot(contains('192.0.2.10')));
  });

  test('a ticket that cannot be kept once its report was taken: the kind of what stopped it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final feedback = FeedbackService(db, prefs,
        client: MockClient((_) async => http.Response('{"ok":true,"ticket":{"id":"tk_1","number":10001}}', 200)),
        onTicket: (r, {required id, number}) async => throw const FormatException('not a ticket: tk_1'));
    final res = await feedback.send(FeedbackReport(
      type: FeedbackType.bug,
      title: 'Tab strip overlaps',
      body: 'The third tab is drawn under the pill bar.',
      expected: 'Tabs stay inside the strip.',
      context: ctx,
      createdAt: DateTime.utc(2026, 10, 1, 7, 30),
    ));
    expect(res.outcome, FeedbackOutcome.sent, reason: 'the report went all the same');
    expect(noted, contains('WARNING: Could not keep the ticket: FormatException'));
  });
}
