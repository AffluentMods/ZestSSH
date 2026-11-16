import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/attachment_refusal.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/ui/screens/help/public_text_preview.dart';

import 'fake_ticket_server.dart';

/// The server's limits on what a ticket carries (from a security review of 3.4,
/// backend b390931) answer with a code: the app reads it, so the person
/// is told the screenshot or the diagnostics were the trouble, not the
/// words, which can go without them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const ctx = FeedbackContext(
    appVersion: '3.4.0',
    build: 400,
    platform: 'windows',
    osVersion: 'Windows 11',
    locale: 'en-US',
    tier: 'free',
  );
  final shot = Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);

  test('the codes, by status', () {
    expect(AttachmentRefusal.of(413, {'code': 'attachments_full'}), AttachmentRefusal.full);
    expect(AttachmentRefusal.of(429, {'code': 'attachments_hourly'}), AttachmentRefusal.hourly);
    expect(AttachmentRefusal.of(429, {'code': 'attachments_paused'}), AttachmentRefusal.paused);
    expect(AttachmentRefusal.of(429, {'error': 'Too many'}), isNull);
    expect(AttachmentRefusal.of(413, {'code': 'attachments_hourly'}), isNull);
    expect(AttachmentRefusal.of(400, null), isNull);
  });

  group('tickets', () {
    late AppDatabase db;
    late FakeTicketServer server;
    late TicketService service;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      server = FakeTicketServer();
      service = TicketService(db, client: MockClient(server.handle), baseUrl: 'https://api.test/v1');
    });
    tearDown(() => db.close());

    test('a reply refused for what it carries says why, and nothing waits to go', () async {
      final made = await service.createPrivate(type: TicketType.bug, title: 'Upload stalls', body: 'At 60 percent.', context: ctx);
      expect(made.delivered, isTrue);
      for (final (status, code, why, outcome) in [
        (413, 'attachments_full', AttachmentRefusal.full, TicketSendOutcome.rejected),
        (429, 'attachments_hourly', AttachmentRefusal.hourly, TicketSendOutcome.rateLimited),
        (429, 'attachments_paused', AttachmentRefusal.paused, TicketSendOutcome.rateLimited),
      ]) {
        server.refuseAttachments = (status: status, code: code, retryAfter: 3600);
        final r = await service.reply(made.nonce!, 'Same again.', screenshot: shot);
        expect(r.attachments, why, reason: code);
        expect(r.outcome, outcome, reason: code);
        expect(r.retryMinutes, 60, reason: code);
        expect(await db.select(db.ticketOutbox).get(), isEmpty, reason: 'not kept to go later');
      }
      // The words alone go.
      final words = await service.reply(made.nonce!, 'Same again.');
      expect(words.delivered, isTrue);
      expect(words.attachments, isNull);
    });

    test('a new ticket refused for what it carries says why', () async {
      server.refuseAttachments = (status: 429, code: 'attachments_paused', retryAfter: 7200);
      final r = await service.createPrivate(
          type: TicketType.bug, title: 'Upload stalls', body: 'At 60 percent.', context: ctx, screenshot: shot);
      expect(r.attachments, AttachmentRefusal.paused);
      expect(r.retryMinutes, 120);
      expect(await db.select(db.supportTickets).get(), isEmpty);
    });
  });

  test('a report refused for what it carries says why', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final svc = FeedbackService(db, prefs,
        client: MockClient((_) async => http.Response(
            jsonEncode({'error': 'Too many screenshots and diagnostics today.', 'code': 'attachments_paused'}), 429,
            headers: {'retry-after': '600'})));
    final res = await svc.send(FeedbackReport(
        type: FeedbackType.bug, title: 'Keys stop working', body: 'After an upload.', context: ctx, screenshotPng: shot));
    expect(res.outcome, FeedbackOutcome.rateLimited);
    expect(res.attachments, AttachmentRefusal.paused);
    expect(res.retryMinutes, 10);
  });

  group('a public text, marked', () {
    test('what was put in place of something is marked, the rest is not', () {
      final parts = markReplacements('Connecting to acme-billing.com failed', 'Connecting to <domain> failed');
      expect(parts.map((p) => p.text).join(), 'Connecting to <domain> failed');
      expect([for (final p in parts) if (p.replaced) p.text], ['<domain>']);
    });

    test('nothing changed, nothing marked; all changed, all marked', () {
      expect(markReplacements('a b', 'a b').where((p) => p.replaced), isEmpty);
      expect([for (final p in markReplacements('x', '<host>')) if (p.replaced) p.text], ['<host>']);
      expect(markReplacements('', ''), isEmpty);
    });
  });
}
