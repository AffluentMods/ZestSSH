import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';

import 'fake_ticket_server.dart';

/// Tickets in the app: the ticket a report becomes is
/// kept with the token that makes it readable; a private support ticket is
/// opened, read and answered; an answer from support is noticed once;
/// nothing typed is lost when the server cannot be reached; and a device
/// that holds no ticket never asks the server anything.
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
  late FakeTicketServer server;
  var clock = DateTime.utc(2026, 10, 1, 8);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = FakeTicketServer();
    clock = DateTime.utc(2026, 10, 1, 8);
  });
  tearDown(() => db.close());

  TicketService service({Future<String?> Function()? bearer}) => TicketService(
        db,
        client: MockClient(server.handle),
        bearer: bearer,
        now: () => clock,
        baseUrl: 'https://api.test/v1',
      );

  Future<SupportTicketRow> onlyRow() => db.select(db.supportTickets).getSingle();

  Future<String> support(TicketService svc,
      {String title = 'Cannot restore my purchase',
      String body = 'I paid on my phone and the PC still says Free.',
      bool includeAccount = false,
      TicketContact? contact}) async {
    final res = await svc.createSupport(
        title: title,
        body: body,
        context: ctx,
        contact: contact,
        includeAccount: includeAccount);
    expect(res.outcome, TicketSendOutcome.sent, reason: 'the ticket was taken');
    // "Sent" is said with the server's number for it.
    expect(res.number, server.tickets.values.last.number);
    return res.nonce!;
  }

  group('the ticket token', () {
    test('is 32 random bytes as 43 base64url characters, new every time', () {
      final a = TicketToken.generate(), b = TicketToken.generate();
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(base64Url.decode('$a='), hasLength(32));
      expect(a, isNot(b));
      expect(TicketToken.isValid(a), isTrue);
      for (final bad in [null, '', 'short', '${a}x', a.replaceRange(0, 1, '+'), '$a=']) {
        expect(TicketToken.isValid(bad), isFalse, reason: '$bad');
      }
    });
    test('uses every byte the random source gives', () {
      // A source that always answers 255 must give all ones, not a
      // truncated or masked value.
      final t = TicketToken.generate(_Fixed(255));
      expect(base64Url.decode('$t='), everyElement(255));
      expect(base64Url.decode('${TicketToken.generate(_Fixed(0))}='), everyElement(0));
    });
  });

  group('a report becomes a ticket', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    FeedbackReport report({String title = 'Tab strip overlaps'}) => FeedbackReport(
          type: FeedbackType.bug,
          title: title,
          body: 'The third tab is drawn under the pill bar.',
          expected: 'Tabs stay inside the strip.',
          context: ctx,
          createdAt: DateTime.utc(2026, 10, 1, 7, 30),
        );

    FeedbackService feedback(
            Future<http.Response> Function(http.Request) handler, TicketService tickets) =>
        FeedbackService(db, prefs,
            client: MockClient(handler),
            onTicket: (r, {required id, number}) => tickets.keepReport(r, id: id, number: number));

    test('the answer names the ticket: it is kept with the token the report was sent with', () async {
      final tickets = service();
      Map<String, dynamic>? sent;
      Map<String, String>? headers;
      final r = report();
      final res = await feedback((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        headers = req.headers;
        return http.Response('{"ok":true,"ticket":{"id":"tk_00aa","number":10042}}', 200);
      }, tickets)
          .send(r);
      expect(res.outcome, FeedbackOutcome.sent);
      expect(res.ticketId, 'tk_00aa');
      expect(res.ticketNumber, 10042);
      expect(headers!['X-ZestSSH-Tickets'], '1', reason: 'this build keeps tickets');
      expect(sent!['ticket_token'], r.ticketToken);

      final row = await onlyRow();
      expect(row.nonce, r.nonce);
      expect(row.serverId, 'tk_00aa');
      expect(row.number, 10042);
      expect(row.token, r.ticketToken);
      expect(row.type, 'bug');
      expect(row.title, 'Tab strip overlaps');
      expect(row.status, 'open');
      expect(row.awaiting, 'staff');
      expect(row.createdAt, DateTime.utc(2026, 10, 1, 7, 30).millisecondsSinceEpoch);
      expect(row.pending, isNull);
      expect(row.isSent, isTrue);
      expect(row.hasUnreadReply, isFalse);
      final c = row.cachedConversation!;
      expect(c.body, 'The third tab is drawn under the pill bar.');
      expect(c.expected, 'Tabs stay inside the strip.');
      expect(c.messages, isEmpty);
    });

    test('an answer without a ticket keeps nothing (a duplicate, or a server from before tickets)', () async {
      final tickets = service();
      for (final body in ['{"ok":true}', '{"ok":true,"deduplicated":true}', 'not json', '{"ok":true,"ticket":7}']) {
        SharedPreferences.setMockInitialValues({});
        prefs = await SharedPreferences.getInstance();
        final res = await feedback((_) async => http.Response(body, 200), tickets).send(report());
        expect(res.outcome, FeedbackOutcome.sent, reason: body);
        expect(res.ticketId, isNull, reason: body);
      }
      expect(await db.select(db.supportTickets).get(), isEmpty);
    });

    test('an id the app would never send back is not kept', () async {
      final tickets = service();
      final res = await feedback(
              (_) async => http.Response('{"ok":true,"ticket":{"id":"../../x","number":1}}', 200), tickets)
          .send(report());
      expect(res.outcome, FeedbackOutcome.sent);
      expect(await db.select(db.supportTickets).get(), isEmpty);
    });

    test('a report that waited in the queue is kept when it is delivered, with the token it had first', () async {
      final tickets = service();
      final r = report();
      final offline = feedback((_) async => throw const SocketException('offline'), tickets);
      expect((await offline.send(r)).outcome, FeedbackOutcome.queued);
      expect(await db.select(db.supportTickets).get(), isEmpty, reason: 'nothing to keep yet');
      expect((await offline.watchQueued().first).single.ticketToken, r.ticketToken);

      String? tokenOnRetry;
      final online = feedback((req) async {
        tokenOnRetry = (jsonDecode(req.body) as Map)['ticket_token'] as String?;
        return http.Response('{"ok":true,"ticket":{"id":"tk_late","number":10050}}', 200);
      }, tickets);
      expect(await online.retryQueued(), 1);
      expect(tokenOnRetry, r.ticketToken, reason: 'the same key, or the retry would be a stranger');
      final row = await onlyRow();
      expect(row.serverId, 'tk_late');
      expect(row.token, r.ticketToken);
      expect(row.nonce, r.nonce);
      expect(await online.watchQueued().first, isEmpty);
    });

    test('the same ticket answered twice is kept once, and what was read stays read', () async {
      final tickets = service();
      final r = report();
      await tickets.keepReport(r, id: 'tk_once', number: 10001);
      await (db.update(db.supportTickets)).write(const SupportTicketsCompanion(
          lastSeenMessageId: Value('m_9'), status: Value('closed')));
      await tickets.keepReport(r, id: 'tk_other', number: 10002);
      final row = await onlyRow();
      expect(row.serverId, 'tk_once');
      expect(row.number, 10001);
      expect(row.lastSeenMessageId, 'm_9');
      expect(row.status, 'closed');
    });

    test('a failure to keep the ticket never fails the report', () async {
      final svc = FeedbackService(db, prefs,
          client: MockClient((_) async =>
              http.Response('{"ok":true,"ticket":{"id":"tk_1","number":1}}', 200)),
          onTicket: (r, {required id, number}) async => throw StateError('disk full'));
      final res = await svc.send(report());
      expect(res.outcome, FeedbackOutcome.sent);
      expect(await svc.queued(), isEmpty);
    });

    test('the preview names the key and never shows it; the clipboard text has no key', () {
      final r = report();
      final preview = r.toPreviewJson();
      expect(preview, contains('"ticket_token": "${TicketToken.preview}"'));
      expect(preview, isNot(contains(r.ticketToken)));
      expect(r.toClipboardText(), isNot(contains(r.ticketToken)));
      expect(r.toJson()['ticket_token'], r.ticketToken);
    });

    test('a report restored from the queue keeps its key; one queued by an older build gets one', () {
      final r = report();
      final back = FeedbackReport.fromJson(r.toJson(includeScreenshot: false));
      expect(back.ticketToken, r.ticketToken);
      final old = Map<String, dynamic>.from(r.toJson())..remove('ticket_token');
      expect(TicketToken.isValid(FeedbackReport.fromJson(old).ticketToken), isTrue);
      final bad = Map<String, dynamic>.from(r.toJson())..['ticket_token'] = 'nope';
      final fixed = FeedbackReport.fromJson(bad).ticketToken;
      expect(TicketToken.isValid(fixed), isTrue);
      expect(fixed, isNot('nope'));
    });
  });

  group('a support ticket', () {
    test('reached: kept with the id and number, nothing waiting, and only what the form showed is sent', () async {
      final svc = service();
      final nonce = await support(svc, contact: const TicketContact.email('kit@example.com'));
      final row = await onlyRow();
      expect(row.nonce, nonce);
      expect(row.serverId, startsWith('tk_'));
      expect(row.number, 10001);
      expect(row.type, 'support');
      expect(row.isPrivate, isTrue);
      expect(row.title, 'Cannot restore my purchase');
      expect(row.pending, isNull);
      expect(row.sendError, isNull);
      expect(row.createdAt, clock.millisecondsSinceEpoch);
      expect(row.cachedConversation!.body, 'I paid on my phone and the PC still says Free.');
      expect(TicketToken.isValid(row.token), isTrue);

      final req = server.calls('/tickets').single;
      expect(req.method, 'POST');
      expect(req.headers.containsKey('Authorization'), isFalse, reason: 'signed out: no account at all');
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent.keys.toSet(),
          {'title', 'body', 'context', 'contact', 'include_account', 'nonce', 'ticket_token'});
      expect(sent['include_account'], isFalse);
      expect(sent['contact'], {'kind': 'email', 'value': 'kit@example.com'});
      expect(sent['nonce'], nonce);
      expect(sent['ticket_token'], row.token);
      expect((sent['context'] as Map).keys.toSet(),
          {'app_version', 'build', 'platform', 'os_version', 'locale', 'tier'});
      // The server holds the token it was sent, and nothing else of this
      // device.
      expect(server.tickets.values.single.token, row.token);
      expect(server.tickets.values.single.account, isNull);
    });

    test('signed in: the bearer rides along; the account is stored only when the box is ticked', () async {
      server.bearers['tok-1'] = 'uid-1';
      final svc = service(bearer: () async => 'tok-1');
      await support(svc);
      expect(server.calls('/tickets').last.headers['Authorization'], 'Bearer tok-1');
      expect(server.tickets.values.last.account, isNull, reason: 'the box was not ticked');
      await support(svc, title: 'Second', includeAccount: true);
      expect(server.tickets.values.last.account, 'uid-1');
    });

    test('"include my account" without a signed-in account is refused and nothing is kept', () async {
      final res = await service().createSupport(
          title: 'Licence', body: 'Where is my licence?', context: ctx, includeAccount: true);
      expect(res.outcome, TicketSendOutcome.needsSignIn);
      expect(await db.select(db.supportTickets).get(), isEmpty);
      expect(server.tickets, isEmpty);
    });

    test('the limits and refusals of the server keep nothing here', () async {
      for (final (code, outcome) in [
        (429, TicketSendOutcome.rateLimited),
        (403, TicketSendOutcome.blocked),
        (400, TicketSendOutcome.rejected),
        (413, TicketSendOutcome.rejected),
        (409, TicketSendOutcome.rejected),
      ]) {
        server.failWith = code;
        final res = await service().createSupport(title: 't', body: 'b', context: ctx);
        expect(res.outcome, outcome, reason: 'HTTP $code');
        if (code == 429) expect(res.retryMinutes, 2);
        expect(await db.select(db.supportTickets).get(), isEmpty, reason: 'HTTP $code');
      }
    });

    test('not reached: it waits here and is delivered later as the same ticket', () async {
      final svc = service();
      for (final down in [() => server.offline = true, () => server.failWith = 503]) {
        down();
        final res = await svc.createSupport(title: 'Offline', body: 'Written on a train.', context: ctx);
        expect(res.outcome, TicketSendOutcome.queued);
        server
          ..offline = false
          ..failWith = null;
      }
      var rows = await db.select(db.supportTickets).get();
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.isWaiting && r.serverId == null && r.pending != null), isTrue);
      expect(await svc.hasWaiting(), isTrue);
      expect(server.tickets, isEmpty);

      expect(await svc.retryPending(), 2);
      rows = await db.select(db.supportTickets).get();
      expect(rows.every((r) => r.isSent && r.pending == null), isTrue);
      expect(server.tickets, hasLength(2));
      for (final r in rows) {
        final onServer = server.tickets[r.serverId]!;
        expect(onServer.token, r.token, reason: 'the key made when it was written');
        expect(onServer.nonce, r.nonce);
        expect(onServer.body, 'Written on a train.');
      }
      expect(await svc.hasWaiting(), isFalse);
      expect(await svc.retryPending(), 0, reason: 'nothing left to send');
    });

    test('the answer was lost: the retry is the same ticket, not a second one', () async {
      final svc = service();
      server.loseNextAnswer = true;
      final res = await svc.createSupport(title: 'Lost', body: 'Did this arrive?', context: ctx);
      expect(res.outcome, TicketSendOutcome.queued);
      expect(res.number, isNull, reason: 'no number without an answer from the server: it is not said to be sent');
      expect(server.tickets, hasLength(1), reason: 'the server did take it');
      expect((await onlyRow()).isWaiting, isTrue);

      expect(await svc.retryPending(), 1);
      expect(server.tickets, hasLength(1));
      final row = await onlyRow();
      expect(row.serverId, server.tickets.keys.single);
      expect(row.number, server.tickets.values.single.number);
    });

    test('at most five wait; a sixth is not kept (the form still holds the text)', () async {
      final svc = service();
      server.offline = true;
      for (var i = 0; i < TicketLimits.maxWaiting; i++) {
        expect((await svc.createSupport(title: 't$i', body: 'b', context: ctx)).outcome,
            TicketSendOutcome.queued);
      }
      final res = await svc.createSupport(title: 'one too many', body: 'b', context: ctx);
      expect(res.outcome, TicketSendOutcome.tooManyWaiting);
      expect(await db.select(db.supportTickets).get(), hasLength(TicketLimits.maxWaiting));
    });

    test('a waiting ticket the server refuses for good is marked, kept readable and not tried again', () async {
      final svc = service();
      server.offline = true;
      await svc.createSupport(title: 'Blocked later', body: 'text to keep', context: ctx);
      server
        ..offline = false
        ..failWith = 403;
      expect(await svc.retryPending(), 0);
      var row = await onlyRow();
      expect(row.sendError, 'blocked');
      expect(row.isRefused, isTrue);
      expect(row.isWaiting, isFalse);
      expect(row.cachedConversation!.body, 'text to keep');
      final callsBefore = server.requests.length;
      server.failWith = null;
      expect(await svc.retryPending(), 0);
      expect(server.requests.length, callsBefore, reason: 'not tried again');
      row = await onlyRow();
      expect(row.serverId, isNull);
      expect(await svc.hasWaiting(), isFalse);
    });

    test('a waiting ticket that asked for the account and lost the sign-in can go without it', () async {
      server.bearers['tok-1'] = 'uid-1';
      var signedIn = true;
      final svc = service(bearer: () async => signedIn ? 'tok-1' : null);
      server.offline = true;
      final res = await svc.createSupport(
          title: 'Billing', body: 'Charged twice.', context: ctx, includeAccount: true);
      expect(res.outcome, TicketSendOutcome.queued);
      server.offline = false;
      signedIn = false;
      expect(await svc.retryPending(), 0);
      expect((await onlyRow()).sendError, 'account');

      expect(await svc.retryWithoutAccount(res.nonce!), isTrue);
      final row = await onlyRow();
      expect(row.sendError, isNull);
      expect((jsonDecode(row.pending!) as Map)['include_account'], isFalse);
      expect(await svc.retryPending(), 1);
      expect(server.tickets.values.single.account, isNull);
      expect((await onlyRow()).isSent, isTrue);
      expect(await svc.retryWithoutAccount(res.nonce!), isFalse, reason: 'already sent');
    });

    test('a 5xx on retry keeps it waiting; a row that no longer parses is marked, not looped on', () async {
      final svc = service();
      server.offline = true;
      await svc.createSupport(title: 'Keep', body: 'b', context: ctx);
      server
        ..offline = false
        ..failWith = 502;
      expect(await svc.retryPending(), 0);
      expect((await onlyRow()).isWaiting, isTrue);
      await db.update(db.supportTickets).write(const SupportTicketsCompanion(pending: Value('{not json')));
      server.failWith = null;
      expect(await svc.retryPending(), 0);
      expect((await onlyRow()).sendError, 'rejected');
    });

    test('the preview shows the request and names the key instead of showing it', () {
      final request = TicketService.supportRequest(
        title: ' Subject ',
        body: ' Text ',
        context: ctx,
        contact: null,
        includeAccount: true,
        nonce: 'n-1',
        token: 'T' * 43,
      );
      expect(request['title'], 'Subject');
      expect(request['body'], 'Text');
      expect(request['include_account'], isTrue);
      final preview = TicketService.previewOf(request);
      expect(preview, contains('"ticket_token": "${TicketToken.preview}"'));
      expect(preview, isNot(contains('T' * 43)));
      expect(preview, contains('"include_account": true'));
      expect(preview, contains('"nonce": "n-1"'));
    });
  });

  // The server's number for a ticket is shown, never trusted to be one: a
  // double such as 1e400 (Infinity once parsed) made toInt() throw after the
  // ticket was made, so it was not kept here and the person sent it again (found
  // in a security review).
  group("the server's ticket number", () {
    Future<(TicketSendResult, SupportTicketRow)> sentWith(String number) async {
      final svc = TicketService(
        db,
        client: MockClient((_) async =>
            http.Response('{"ok":true,"ticket":{"id":"tk_n","number":$number}}', 201)),
        now: () => clock,
        baseUrl: 'https://api.test/v1',
      );
      final res = await svc.createSupport(title: 'Number', body: 'What it says', context: ctx);
      return (res, await onlyRow());
    }

    for (final odd in ['1e400', '-1e400', '-5', '0', '1.5', '"7"', '2147483648', 'null']) {
      test('$odd is no number: the ticket is sent and kept, said without one', () async {
        final (res, row) = await sentWith(odd);
        expect(res.outcome, TicketSendOutcome.sent);
        expect(res.number, isNull);
        expect(row.serverId, 'tk_n', reason: 'kept as the ticket it is, so it is not sent again');
        expect(row.number, isNull);
      });
    }

    test('a whole number from 1 up is the number', () async {
      final (res, row) = await sentWith('10042');
      expect(res.number, 10042);
      expect(row.number, 10042);
    });
  });

  group('refresh', () {
    test('a device with no ticket asks the server nothing', () async {
      final svc = service();
      final res = await svc.refresh();
      expect(res.reached, isTrue);
      expect(res.replies, isEmpty);
      expect(server.requests, isEmpty);
      expect(await svc.hasOpenTickets(), isFalse);
    });

    test('a ticket still waiting to be sent is not asked about', () async {
      final svc = service();
      server.offline = true;
      await svc.createSupport(title: 't', body: 'b', context: ctx);
      server.offline = false;
      server.requests.clear();
      await svc.refresh();
      expect(server.requests, isEmpty);
    });

    test('carries ids and keys only: no account, no install, nothing else', () async {
      server.bearers['tok-1'] = 'uid-1';
      final svc = service(bearer: () async => 'tok-1');
      await support(svc);
      await svc.refresh();
      final req = server.calls('/tickets/lookup').single;
      expect(req.headers.containsKey('Authorization'), isFalse,
          reason: 'reading is proved by the key alone');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body.keys, ['tickets']);
      final row = await onlyRow();
      expect(body['tickets'], [
        {'id': row.serverId, 'token': row.token},
      ]);
    });

    test('an answer from support is unread and announced once', () async {
      final svc = service();
      final nonce = await support(svc);
      var row = await onlyRow();
      expect((await svc.refresh()).replies, isEmpty);
      expect((await onlyRow()).hasUnreadReply, isFalse);
      expect(await svc.hasOpenTickets(), isTrue);

      server.now = DateTime.utc(2026, 10, 1, 9);
      final m = server.staffReply(row.serverId!, 'Which store did you buy it from?');
      final res = await svc.refresh();
      expect(res.reached, isTrue);
      expect(res.replies.map((t) => t.nonce), [nonce]);
      row = await onlyRow();
      expect(row.hasUnreadReply, isTrue);
      expect(row.awaiting, 'user');
      expect(row.messageCount, 1);
      expect(row.lastMessageId, m.id);
      expect(row.lastMessageFrom, 'staff');
      expect(row.lastMessageAt, DateTime.utc(2026, 10, 1, 9).millisecondsSinceEpoch);
      expect(row.notifiedMessageId, m.id);

      final again = await svc.refresh();
      expect(again.replies, isEmpty, reason: 'one answer, one announcement');
      expect((await onlyRow()).hasUnreadReply, isTrue, reason: 'still unread until it is opened');

      final m2 = server.staffReply(row.serverId!, 'Never mind, found it.');
      expect((await svc.refresh()).replies.single.lastMessageId, m2.id,
          reason: 'a second answer is announced');
    });

    test('an answer on the ticket that is on screen is not announced', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      svc.viewing = nonce;
      final m = server.staffReply(id, 'Hello');
      expect((await svc.refresh()).replies, isEmpty);
      expect((await onlyRow()).notifiedMessageId, m.id);
      svc.viewing = null;
      expect((await svc.refresh()).replies, isEmpty, reason: 'it was not saved up for later');
    });

    test('the person writing last is not an unread answer', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      server.staffReply(id, 'One question.');
      await svc.refresh();
      expect((await svc.reply(nonce, 'Here is the answer.')).outcome, TicketSendOutcome.sent);
      expect((await onlyRow()).hasUnreadReply, isFalse);
      await svc.refresh();
      expect((await onlyRow()).hasUnreadReply, isFalse);
    });

    test('status, tags, number and the forum link follow the server', () async {
      final svc = service();
      final report = FeedbackReport(type: FeedbackType.bug, body: 'x', title: 'Old title', context: ctx);
      final t = server.addReport(token: report.ticketToken, title: 'Tabs overlap');
      await svc.keepReport(report, id: t.id, number: null);
      server.staffTags(t.id, ['Confirmed', 'Desktop App', 'Confirmed', '', 'x' * 80]);
      await svc.refresh();
      var row = await onlyRow();
      expect(row.number, t.number);
      expect(row.title, 'Tabs overlap');
      expect(row.tagNames, ['Confirmed', 'Desktop App', 'x' * 50]);
      expect(row.discordUrl, 'https://discord.com/channels/1/2');
      expect(row.status, 'open');

      server.staffClose(t.id);
      await svc.refresh();
      row = await onlyRow();
      expect(row.status, 'closed');
      expect(row.isClosed, isTrue);
      expect(row.awaiting, isNull);
      expect(await svc.hasOpenTickets(), isFalse);

      server.staffReopen(t.id);
      await svc.refresh();
      expect((await onlyRow()).status, 'open');
    });

    test('at most twenty tags are kept, the first twenty', () async {
      final svc = service();
      final report = FeedbackReport(type: FeedbackType.bug, body: 'x', title: 'Tabs', context: ctx);
      final t = server.addReport(token: report.ticketToken, title: 'Tabs overlap');
      await svc.keepReport(report, id: t.id, number: null);
      server.staffTags(t.id, [for (var i = 1; i <= 25; i++) 'Tag $i']);
      await svc.refresh();
      expect((await onlyRow()).tagNames, [for (var i = 1; i <= 20; i++) 'Tag $i']);
    });

    test('only a real Discord link is ever kept, and never on a support ticket', () async {
      expect(TicketService.discordLinkOf('https://discord.com/channels/1/2'),
          'https://discord.com/channels/1/2');
      expect(TicketService.discordLinkOf('https://ptb.discord.com/channels/1/2'), isNotNull);
      for (final bad in [
        null,
        7,
        '',
        'http://discord.com/channels/1/2',
        'https://discord.com.evil.example/channels/1/2',
        'https://evil.example/discord.com',
        'https://notdiscord.com/x',
        'https://user@discord.com/x',
        'javascript:alert(1)',
        'file:///C:/x',
        'https://discord.com/${'a' * 300}',
      ]) {
        expect(TicketService.discordLinkOf(bad), isNull, reason: '$bad');
      }

      final svc = service();
      await support(svc);
      final onServer = server.tickets.values.single;
      // A server gone wrong names a link on a private ticket: not taken.
      server.nextRawAnswer = jsonEncode({
        'tickets': [
          {...onServer.forUser(), 'discord_url': 'https://discord.com/channels/9/9'},
        ],
      });
      await svc.refresh();
      expect((await onlyRow()).discordUrl, isNull);
    });

    test('a ticket the server no longer has is marked gone and kept; it comes back if the server has it again', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      await svc.open(nonce);
      final kept = server.tickets[id]!;
      server.delete(id);
      final res = await svc.refresh();
      expect(res.reached, isTrue);
      var row = await onlyRow();
      expect(row.status, 'gone');
      expect(row.isGone, isTrue);
      expect(row.hasUnreadReply, isFalse);
      expect(row.cachedConversation!.body, isNotEmpty, reason: 'what was read stays readable');
      expect(row.token, kept.token, reason: 'the key is not thrown away');

      server.tickets[id] = kept;
      await svc.refresh();
      row = await onlyRow();
      expect(row.status, 'open');
    });

    test('an answer that is not the list keeps everything as it was', () async {
      final svc = service();
      await support(svc);
      for (final raw in ['<html>Sign in to the hotel Wi-Fi</html>', '{"ok":true}', '{"tickets":"none"}', '[]']) {
        server.nextRawAnswer = raw;
        final res = await svc.refresh();
        expect(res.reached, isFalse, reason: raw);
        expect((await onlyRow()).status, 'open', reason: raw);
        // What stopped it is kept for the screens: an answer, with its status.
        expect(svc.readStopped, 'HTTP 200', reason: raw);
      }
      for (final code in [429, 500, 503]) {
        server.failWith = code;
        expect((await svc.refresh()).reached, isFalse);
        expect((await onlyRow()).status, 'open');
        expect(svc.readStopped, 'HTTP $code');
      }
      server
        ..failWith = null
        ..offline = true;
      expect((await svc.refresh()).reached, isFalse);
      expect((await onlyRow()).status, 'open');
      // Nothing answered: what was caught itself, since which kind of
      // failure it is is told by what it is.
      expect(svc.readStopped, isA<SocketException>());
      // And nothing once a read got through.
      server.offline = false;
      expect((await svc.refresh()).reached, isTrue);
      expect(svc.readStopped, isNull);
    });

    test('more than fifty tickets are asked about fifty at a time, every one of them', () async {
      final svc = service();
      for (var i = 0; i < 60; i++) {
        final r = FeedbackReport(
            type: FeedbackType.suggestion,
            body: 'idea $i',
            context: ctx,
            createdAt: DateTime.utc(2026, 9, 1, 0, i));
        final t = server.addReport(token: r.ticketToken, type: 'suggestion', title: 'idea $i');
        await svc.keepReport(r, id: t.id, number: t.number);
      }
      for (final t in server.tickets.values) {
        server.staffTags(t.id, ['Planned']);
      }
      server.requests.clear();
      final res = await svc.refresh();
      expect(res.reached, isTrue);
      final sizes = [
        for (final r in server.calls('/tickets/lookup'))
          ((jsonDecode(r.body) as Map)['tickets'] as List).length,
      ];
      expect(sizes, [50, 10]);
      final rows = await db.select(db.supportTickets).get();
      expect(rows.every((r) => r.tagNames.single == 'Planned'), isTrue);
    });
  });

  group('reading a ticket', () {
    test('the conversation is kept for reading offline, and reading it marks it read', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      server.now = DateTime.utc(2026, 10, 1, 9, 15);
      server.staffReply(id, 'Which store did you buy it from?', name: 'Robin');
      await svc.refresh();
      expect((await onlyRow()).hasUnreadReply, isTrue);

      expect(await svc.open(nonce), isTrue);
      final req = server.requests.last;
      expect(req.method, 'GET');
      expect(req.url.path, endsWith('/tickets/$id'));
      expect(req.headers['X-Ticket-Token'], (await onlyRow()).token);
      expect(req.headers.containsKey('Authorization'), isFalse);

      var row = await onlyRow();
      expect(row.hasUnreadReply, isFalse);
      final c = row.cachedConversation!;
      expect(c.body, 'I paid on my phone and the PC still says Free.');
      expect(c.messages, hasLength(1));
      expect(c.messages.single.fromStaff, isTrue);
      expect(c.messages.single.staffName, 'Robin');
      expect(c.messages.single.body, 'Which store did you buy it from?');
      expect(c.messages.single.at, DateTime.utc(2026, 10, 1, 9, 15));

      expect(svc.readStopped, isNull, reason: 'the read got through');
      server.offline = true;
      expect(await svc.open(nonce), isFalse);
      expect(svc.readStopped, isA<SocketException>(), reason: 'what stopped it, for the page to say');
      row = await onlyRow();
      expect(row.cachedConversation!.messages.single.body, 'Which store did you buy it from?',
          reason: 'offline: what was read last is still there');
      expect(row.status, 'open');
      // A fault of the service's own is kept with its status; and nothing
      // is kept of an earlier failure once a read gets through.
      server
        ..offline = false
        ..failWith = 503;
      expect(await svc.open(nonce), isFalse);
      expect(svc.readStopped, 'HTTP 503');
      server.failWith = null;
      expect(await svc.open(nonce), isTrue);
      expect(svc.readStopped, isNull);
    });

    test('reading without marking it read leaves the answer unread', () async {
      final svc = service();
      final nonce = await support(svc);
      server.staffReply((await onlyRow()).serverId!, 'Hello');
      await svc.refresh();
      expect(await svc.open(nonce, seen: false), isTrue);
      final row = await onlyRow();
      expect(row.cachedConversation!.messages, hasLength(1));
      expect(row.hasUnreadReply, isTrue);
      await svc.markSeen(nonce);
      expect((await onlyRow()).hasUnreadReply, isFalse);
    });

    test('a ticket the server no longer has reads as gone, with what was kept', () async {
      final svc = service();
      final nonce = await support(svc);
      await svc.open(nonce);
      server.delete((await onlyRow()).serverId!);
      expect(await svc.open(nonce), isTrue);
      final row = await onlyRow();
      expect(row.status, 'gone');
      expect(row.cachedConversation!.body, isNotEmpty);
    });

    test('an answer that is not a ticket changes nothing; a ticket not sent yet asks nothing', () async {
      final svc = service();
      final nonce = await support(svc);
      await svc.open(nonce);
      final before = await onlyRow();
      for (final raw in ['{}', '{"ticket":{},"messages":"x"}', 'nope']) {
        server.nextRawAnswer = raw;
        expect(await svc.open(nonce), isFalse, reason: raw);
      }
      expect((await onlyRow()).conversation, before.conversation);
      expect(svc.readStopped, 'HTTP 200', reason: 'an answer, and not one to read');
      expect(await svc.open('no-such-ticket'), isFalse);
      expect(svc.readStopped, isNull, reason: 'nothing was asked: nothing stopped it');

      server.offline = true;
      final waiting = await svc.createSupport(title: 'w', body: 'b', context: ctx);
      server.offline = false;
      final calls = server.requests.length;
      expect(await svc.open(waiting.nonce!), isFalse);
      expect(server.requests.length, calls);
      expect(svc.readStopped, isNull);
    });

    test('a staff name with control characters is cleaned; a message that is not one is skipped', () async {
      final svc = service();
      final nonce = await support(svc);
      final t = server.tickets.values.single;
      server.nextRawAnswer = jsonEncode({
        'ticket': {...t.forUser(), 'body': t.body, 'expected': null},
        'messages': [
          {
            'id': 'm_1',
            'author': {'kind': 'staff', 'name': 'Ro\nbin\u0007'},
            'body': 'Hi',
            'created_at': '2026-10-01T09:00:00.000Z',
          },
          {'id': 'm_2', 'author': {'kind': 'staff', 'name': 'X'}, 'body': 7, 'created_at': 'x'},
          'not a message',
          {
            'id': 'm_3',
            'author': {'kind': 'user', 'name': 'Staff'},
            'body': 'mine',
            'created_at': '2026-10-01T09:05:00.000Z',
          },
        ],
      });
      expect(await svc.open(nonce), isTrue);
      final messages = (await onlyRow()).cachedConversation!.messages;
      expect(messages.map((m) => m.id), ['m_1', 'm_3']);
      expect(messages.first.staffName, 'Ro bin');
      expect(messages.last.fromStaff, isFalse);
      expect(messages.last.staffName, isNull, reason: 'a name only ever belongs to staff');
    });
  });

  group('writing back', () {
    test('a follow-up is sent with its own nonce and joins the conversation', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      server.staffReply(id, 'Which store?');
      await svc.open(nonce);
      server.now = DateTime.utc(2026, 10, 1, 10);
      final res = await svc.reply(nonce, '  Google Play.  ');
      expect(res.outcome, TicketSendOutcome.sent);

      final req = server.requests.last;
      expect(req.url.path, endsWith('/tickets/$id/messages'));
      expect(req.headers['X-Ticket-Token'], (await onlyRow()).token);
      expect(req.headers.containsKey('Authorization'), isFalse);
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent.keys.toSet(), {'body', 'nonce'});
      expect(sent['body'], 'Google Play.');
      expect(sent['nonce'], matches(RegExp(r'^[0-9a-f-]{36}$')));

      final row = await onlyRow();
      final messages = row.cachedConversation!.messages;
      expect(messages.map((m) => m.body), ['Which store?', 'Google Play.']);
      expect(messages.last.fromStaff, isFalse);
      expect(row.awaiting, 'staff');
      expect(row.lastMessageFrom, 'user');
      expect(row.messageCount, 2);
      expect(row.lastMessageAt, DateTime.utc(2026, 10, 1, 10).millisecondsSinceEpoch);
      expect(row.hasUnreadReply, isFalse);
      expect(await db.select(db.ticketOutbox).get(), isEmpty);
      expect(server.tickets[id]!.messages.last.body, 'Google Play.');
    });

    test('not reached: it waits, and the retry is the same message on the server', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      server.offline = true;
      clock = DateTime.utc(2026, 10, 1, 11);
      expect((await svc.reply(nonce, 'First while offline')).outcome, TicketSendOutcome.queued);
      clock = DateTime.utc(2026, 10, 1, 11, 1);
      expect((await svc.reply(nonce, 'Second while offline')).outcome, TicketSendOutcome.queued);
      var waiting = await svc.watchOutbox(nonce).first;
      expect(waiting.map((w) => w.body), ['First while offline', 'Second while offline']);
      expect(waiting.every((w) => w.error == null), isTrue);
      expect(waiting.first.createdAt, DateTime.utc(2026, 10, 1, 11).millisecondsSinceEpoch);
      expect(await svc.hasWaiting(), isTrue);
      expect(server.tickets[id]!.messages, isEmpty);

      // The server takes the first and its answer is lost: the next try
      // must not make a second copy.
      server
        ..offline = false
        ..loseNextAnswer = true;
      expect(await svc.retryPending(), 1, reason: 'the second went through');
      expect(server.tickets[id]!.messages.map((m) => m.body),
          ['First while offline', 'Second while offline']);
      expect(await svc.retryPending(), 1);
      expect(server.tickets[id]!.messages, hasLength(2), reason: 'the same message, not a third');
      expect(await svc.watchOutbox(nonce).first, isEmpty);
      waiting = await db.select(db.ticketOutbox).get();
      expect(waiting, isEmpty);
      final bodies = (await onlyRow()).cachedConversation!.messages.map((m) => m.body).toSet();
      expect(bodies, {'First while offline', 'Second while offline'});
    });

    test('a closed ticket takes no follow-up: nothing waits, and the ticket reads as closed', () async {
      final svc = service();
      final nonce = await support(svc);
      server.staffClose((await onlyRow()).serverId!);
      final res = await svc.reply(nonce, 'One more thing');
      expect(res.outcome, TicketSendOutcome.closed);
      expect(await db.select(db.ticketOutbox).get(), isEmpty);
      final row = await onlyRow();
      expect(row.status, 'closed');
      expect(row.awaiting, isNull);
    });

    test('a follow-up that waited while the ticket was closed is marked and its text kept', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      server.offline = true;
      await svc.reply(nonce, 'Text worth keeping');
      server.offline = false;
      server.staffClose(id);
      expect(await svc.retryPending(), 0);
      var item = (await db.select(db.ticketOutbox).get()).single;
      expect(item.error, 'closed');
      expect(item.body, 'Text worth keeping');
      final calls = server.requests.length;
      expect(await svc.retryPending(), 0);
      expect(server.requests.length, calls, reason: 'not tried again');
      expect(await svc.hasWaiting(), isFalse);

      await svc.discardFollowUp(item.nonce);
      expect(await db.select(db.ticketOutbox).get(), isEmpty);

      // The same for a ticket that is gone, and for one refused outright.
      server.staffReopen(id);
      server.offline = true;
      await svc.reply(nonce, 'again');
      server.offline = false;
      server.delete(id);
      await svc.retryPending();
      item = (await db.select(db.ticketOutbox).get()).single;
      expect(item.error, 'gone');
      expect((await onlyRow()).status, 'gone');
    });

    test('a limit or a server error on retry keeps a follow-up waiting', () async {
      final svc = service();
      final nonce = await support(svc);
      server.offline = true;
      await svc.reply(nonce, 'later');
      server.offline = false;
      for (final code in [429, 500]) {
        server.failWith = code;
        expect(await svc.retryPending(), 0);
        expect((await db.select(db.ticketOutbox).get()).single.error, isNull, reason: 'HTTP $code');
      }
      server.failWith = 400;
      await svc.retryPending();
      expect((await db.select(db.ticketOutbox).get()).single.error, 'rejected');
    });

    test('the limits of the server keep nothing waiting; the reply box still holds the text', () async {
      final svc = service();
      final nonce = await support(svc);
      server.failWith = 429;
      final limited = await svc.reply(nonce, 'too fast');
      expect(limited.outcome, TicketSendOutcome.rateLimited);
      expect(limited.retryMinutes, 2);
      server.failWith = 400;
      expect((await svc.reply(nonce, 'bad')).outcome, TicketSendOutcome.rejected);
      expect(await db.select(db.ticketOutbox).get(), isEmpty);
    });

    test('nothing empty, too long, or on a ticket that is not there is sent', () async {
      final svc = service();
      final nonce = await support(svc);
      server.requests.clear();
      expect((await svc.reply(nonce, '   ')).outcome, TicketSendOutcome.rejected);
      expect((await svc.reply(nonce, 'x' * (TicketLimits.bodyMax + 1))).outcome, TicketSendOutcome.rejected);
      expect((await svc.reply('no-such-ticket', 'hello')).outcome, TicketSendOutcome.rejected);
      expect(server.requests, isEmpty);
      // Exactly the cap goes, counted in characters, not UTF-16 units.
      final atCap = '\u{1F34A}' * TicketLimits.bodyMax;
      expect((await svc.reply(nonce, atCap)).outcome, TicketSendOutcome.sent);

      server.offline = true;
      final waiting = await svc.createSupport(title: 'w', body: 'b', context: ctx);
      server.offline = false;
      server.requests.clear();
      expect((await svc.reply(waiting.nonce!, 'hello')).outcome, TicketSendOutcome.rejected,
          reason: 'the ticket itself has not been sent yet');
      expect(server.requests, isEmpty);
    });

    test('at most ten follow-ups wait on one ticket', () async {
      final svc = service();
      final nonce = await support(svc);
      server.offline = true;
      for (var i = 0; i < TicketLimits.maxWaitingReplies; i++) {
        expect((await svc.reply(nonce, 'm$i')).outcome, TicketSendOutcome.queued);
      }
      expect((await svc.reply(nonce, 'one too many')).outcome, TicketSendOutcome.tooManyWaiting);
      expect(await db.select(db.ticketOutbox).get(), hasLength(TicketLimits.maxWaitingReplies));
    });

    test('a follow-up whose ticket was removed from the device is dropped', () async {
      final svc = service();
      final nonce = await support(svc);
      server.offline = true;
      await svc.reply(nonce, 'orphan');
      await db.delete(db.supportTickets).go();
      server.offline = false;
      expect(await svc.retryPending(), 0);
      expect(await db.select(db.ticketOutbox).get(), isEmpty);
    });

    test('closing takes the key; a ticket that is gone reads as gone', () async {
      final svc = service();
      final nonce = await support(svc);
      final id = (await onlyRow()).serverId!;
      expect(await svc.close(nonce), isTrue);
      final req = server.requests.last;
      expect(req.url.path, endsWith('/tickets/$id/close'));
      expect(req.headers['X-Ticket-Token'], (await onlyRow()).token);
      expect((await onlyRow()).status, 'closed');
      expect(server.tickets[id]!.status, 'closed');

      server.offline = true;
      expect(await svc.close(nonce), isFalse);
      server.offline = false;
      server.delete(id);
      expect(await svc.close(nonce), isTrue);
      expect((await onlyRow()).status, 'gone');
      expect(await svc.close('no-such-ticket'), isFalse);
    });

    test('removing a ticket from the device takes its key and what was waiting, and asks the server nothing', () async {
      final svc = service();
      final keep = await support(svc, title: 'Keep me');
      final drop = await support(svc, title: 'Drop me');
      server.offline = true;
      await svc.reply(drop, 'waiting on the dropped one');
      await svc.reply(keep, 'waiting on the kept one');
      server.requests.clear();
      await svc.forget(drop);
      expect(server.requests, isEmpty);
      final rows = await db.select(db.supportTickets).get();
      expect(rows.single.nonce, keep);
      expect((await db.select(db.ticketOutbox).get()).single.ticketNonce, keep);
      expect(server.tickets, hasLength(2), reason: 'the server keeps its copy');
    });
  });

  group('what the app shows', () {
    test('tickets are listed by their latest activity, newest first', () async {
      final svc = service();
      clock = DateTime.utc(2026, 10, 1, 8);
      final first = await support(svc, title: 'First');
      clock = DateTime.utc(2026, 10, 1, 9);
      final second = await support(svc, title: 'Second');
      expect((await svc.watchTickets().first).map((t) => t.nonce), [second, first]);
      server.now = DateTime.utc(2026, 10, 1, 12);
      server.staffReply((await svc.ticket(first))!.serverId!, 'Answer on the older one');
      await svc.refresh();
      expect((await svc.watchTickets().first).map((t) => t.nonce), [first, second]);
      expect((await svc.watchTicket(first).first)!.title, 'First');
      expect(await svc.watchTicket('nope').first, isNull);
    });

    test('unread means support wrote last, on a ticket the server still has, and it was not on screen', () async {
      final svc = service();
      await support(svc);
      final id = (await onlyRow()).serverId!;
      server.staffReply(id, 'Hello');
      await svc.refresh();
      expect((await onlyRow()).hasUnreadReply, isTrue);

      // The person's own message is never an answer to read, seen or not.
      await db.update(db.supportTickets).write(const SupportTicketsCompanion(lastMessageFrom: Value('user')));
      expect((await onlyRow()).hasUnreadReply, isFalse);
      await db.update(db.supportTickets).write(const SupportTicketsCompanion(lastMessageFrom: Value('staff')));
      expect((await onlyRow()).hasUnreadReply, isTrue);

      // A ticket the server no longer has is not counted: there is nothing
      // left to open and read.
      await db.update(db.supportTickets).write(const SupportTicketsCompanion(status: Value(TicketStatus.gone)));
      expect((await onlyRow()).hasUnreadReply, isFalse);
    });

    test('a cached conversation that no longer parses reads as none, not as a crash', () {
      expect(TicketConversation.decode(null), isNull);
      expect(TicketConversation.decode(''), isNull);
      expect(TicketConversation.decode('{broken'), isNull);
      expect(TicketConversation.decode('[]'), isNull);
      final c = TicketConversation.decode('{"body":"b","messages":[{"id":"m","body":"x","at":"nope"},7]}')!;
      expect(c.body, 'b');
      expect(c.messages, isEmpty);
      const full = TicketConversation(body: 'b', expected: 'e', messages: []);
      final m = TicketMessage(id: 'm1', fromStaff: true, staffName: 'Robin', body: 'hi', at: DateTime.utc(2026));
      final round = TicketConversation.decode(full.withMessage(m).withMessage(m).encode())!;
      expect(round.expected, 'e');
      expect(round.messages, hasLength(1), reason: 'the same message twice is one');
      expect(round.messages.single.staffName, 'Robin');
      expect(round.messages.single.at, DateTime.utc(2026));
    });

    test('tags that are not a list of names read as none', () async {
      final svc = service();
      await support(svc);
      await db.update(db.supportTickets).write(const SupportTicketsCompanion(tags: Value('{"a":1}')));
      expect((await onlyRow()).tagNames, isEmpty);
      await db.update(db.supportTickets).write(const SupportTicketsCompanion(tags: Value('broken')));
      expect((await onlyRow()).tagNames, isEmpty);
      await db.update(db.supportTickets).write(const SupportTicketsCompanion(tags: Value('["Fixed",3,""]')));
      expect((await onlyRow()).tagNames, ['Fixed']);
    });
  });
}

class _Fixed implements Random {
  _Fixed(this.value);
  final int value;

  @override
  int nextInt(int max) => value % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
