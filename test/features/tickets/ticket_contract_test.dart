import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';

/// Tickets against the REAL server routes (ZestSSH Cloud's routes/tickets.js,
/// routes/tickets_admin.js and routes/feedback.js) on a real Postgres: what
/// `ticket_service_test.dart` checks against a fake, checked again against
/// the thing itself, with the test playing the staff through the admin API
/// the Discord bot and the dashboard use. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).
void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1$'), '');
  // The contract server's admin secret (test/helpers/app_contract_server.js).
  const adminSecret = 'app-contract-admin-secret-0123456789abcdef';
  final client = http.Client();
  var serverUp = false;
  final opened = <AppDatabase>[];

  const ctx = FeedbackContext(
    appVersion: '3.0.0',
    build: 300,
    platform: 'windows',
    osVersion: 'Windows 11',
    locale: 'en-US',
    tier: 'free',
  );

  setUpAll(() async {
    try {
      final r = await client
          .get(Uri.parse('$base/tickets/tk_nothere'))
          .timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 404;
    } catch (_) {
      serverUp = false;
    }
  });

  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
  });

  AppDatabase database() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    opened.add(db);
    return db;
  }

  /// One device: its own database and its own ticket service.
  ({AppDatabase db, TicketService tickets}) device({Future<String?> Function()? bearer}) {
    final db = database();
    return (db: db, tickets: TicketService(db, client: client, bearer: bearer, baseUrl: base));
  }

  Future<Map<String, dynamic>> admin(String method, String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$base/admin/tickets$path');
    final headers = {'X-Admin-Secret': adminSecret, 'Content-Type': 'application/json'};
    final http.Response r;
    switch (method) {
      case 'GET':
        r = await client.get(uri, headers: headers);
      case 'PATCH':
        r = await client.patch(uri, headers: headers, body: jsonEncode(body));
      default:
        r = await client.post(uri, headers: headers, body: jsonEncode(body));
    }
    final j = r.body.isEmpty ? const <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    return {'status': r.statusCode, ...j};
  }

  var made = 0;
  String unique(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}-${made++}';

  Future<String> staffReply(String id, String body, {String name = 'Robin'}) async {
    final r = await admin('POST', '/$id/messages', {
      'body': body,
      'author_name': name,
      'origin': 'dashboard',
      'idempotency_key': unique('k').replaceAll(' ', '-'),
    });
    expect(r['status'], 201, reason: '$r');
    return (r['message'] as Map)['id'] as String;
  }

  Future<SupportTicketRow> row(AppDatabase db) => db.select(db.supportTickets).getSingle();

  test('a support ticket: private on the server, answered by staff, read and answered here, closed here', () async {
    if (!serverUp) return markTestSkipped('contract server not running');
    final d = device();
    final subject = unique('Cannot restore my purchase');
    final sent = await d.tickets.createSupport(
      title: subject,
      body: 'I paid on my phone and the PC still says Free.',
      context: ctx,
      contact: const TicketContact.email('kit@example.com'),
    );
    expect(sent.outcome, TicketSendOutcome.sent);
    var t = await row(d.db);
    expect(t.serverId, startsWith('tk_'));
    expect(t.number, greaterThan(10000));

    // What staff see: the whole ticket, private, tied to no account, and an
    // app that can read the answer.
    final seen = await admin('GET', '/${t.serverId}');
    final onServer = seen['ticket'] as Map;
    expect(onServer['visibility'], 'private');
    expect(onServer['type'], 'support');
    expect(onServer['origin'], 'app');
    expect(onServer['title'], subject);
    expect(onServer['body'], 'I paid on my phone and the PC still says Free.');
    expect(onServer['discord'], isNull, reason: 'a support ticket has no place in Discord');
    expect(onServer['reachable'], isTrue);
    expect((onServer['author'] as Map)['contact'], 'kit@example.com');
    expect((onServer['author'] as Map).containsKey('account_email'), isFalse);
    expect((onServer['context'] as Map)['platform'], 'windows');
    expect(jsonEncode(seen), isNot(contains(t.token)), reason: 'the key is never given back');

    // Staff answer: noticed once, unread until it is opened.
    final messageId = await staffReply(t.serverId!, 'Which store did you buy it from?');
    final found = await d.tickets.refresh();
    expect(found.reached, isTrue);
    expect(found.replies.single.nonce, t.nonce);
    t = await row(d.db);
    expect(t.hasUnreadReply, isTrue);
    expect(t.awaiting, 'user');
    expect(t.lastMessageId, messageId);
    expect((await d.tickets.refresh()).replies, isEmpty);

    expect(await d.tickets.open(t.nonce), isTrue);
    t = await row(d.db);
    expect(t.hasUnreadReply, isFalse);
    final first = t.cachedConversation!.messages.single;
    expect(first.fromStaff, isTrue);
    expect(first.staffName, 'Robin');
    expect(first.body, 'Which store did you buy it from?');
    expect(t.cachedConversation!.body, 'I paid on my phone and the PC still says Free.');

    // The person answers: staff see it as the user's, waiting on them.
    expect((await d.tickets.reply(t.nonce, 'Google Play.')).outcome, TicketSendOutcome.sent);
    final after = await admin('GET', '/${t.serverId}');
    final messages = (after['messages'] as List).cast<Map>();
    expect(messages.map((m) => m['body']), ['Which store did you buy it from?', 'Google Play.']);
    expect((messages.last['author'] as Map)['kind'], 'user');
    expect(messages.last['origin'], 'app');
    expect((after['ticket'] as Map)['awaiting'], 'staff');
    t = await row(d.db);
    expect(t.cachedConversation!.messages.map((m) => m.body), ['Which store did you buy it from?', 'Google Play.']);
    expect(t.awaiting, 'staff');

    // Closed from here: closed there, and it takes no more.
    expect(await d.tickets.close(t.nonce), isTrue);
    expect(((await admin('GET', '/${t.serverId}'))['ticket'] as Map)['status'], 'closed');
    expect((await row(d.db)).status, 'closed');
    expect((await d.tickets.reply(t.nonce, 'One more thing')).outcome, TicketSendOutcome.closed);
    final late = await admin('POST', '/${t.serverId}/messages',
        {'body': 'too late', 'author_name': 'Robin', 'origin': 'dashboard', 'idempotency_key': 'late'});
    expect(late['status'], 409);
  });

  test('a report becomes a public ticket with its forum post, and follows its tags and status', () async {
    if (!serverUp) return markTestSkipped('contract server not running');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final d = device();
    final feedback = FeedbackService(d.db, prefs,
        client: client,
        baseUrl: base,
        onTicket: (r, {required id, number}) => d.tickets.keepReport(r, id: id, number: number));
    final report = FeedbackReport(
      type: FeedbackType.bug,
      title: unique('Tab strip overlaps'),
      body: unique('The third tab is drawn under the pill bar.'),
      expected: 'Tabs stay inside the strip.',
      context: ctx,
    );
    final res = await feedback.send(report);
    expect(res.outcome, FeedbackOutcome.sent);
    expect(res.ticketId, startsWith('tk_'));
    var t = await row(d.db);
    expect(t.serverId, res.ticketId);
    expect(t.token, report.ticketToken);
    expect(t.type, 'bug');

    final onServer = (await admin('GET', '/${t.serverId}'))['ticket'] as Map;
    expect(onServer['visibility'], 'public');
    expect(onServer['reachable'], isTrue, reason: 'this build keeps the ticket');
    expect((onServer['discord'] as Map)['url'], startsWith('https://discord.com/channels/'));

    await d.tickets.refresh();
    t = await row(d.db);
    expect(t.discordUrl, (onServer['discord'] as Map)['url']);
    expect(t.number, onServer['number']);

    // Tagged and answered by staff, then closed as fixed.
    expect((await admin('PATCH', '/${t.serverId}', {'tags': ['Confirmed', 'Desktop App'], 'origin': 'discord'}))['status'], 200);
    await staffReply(t.serverId!, 'Thanks, fixed in the next build.', name: 'Morgan');
    final found = await d.tickets.refresh();
    expect(found.replies, hasLength(1));
    t = await row(d.db);
    expect(t.tagNames, ['Confirmed', 'Desktop App']);
    expect(await d.tickets.open(t.nonce), isTrue);
    t = await row(d.db);
    expect(t.cachedConversation!.messages.single.staffName, 'Morgan');
    expect(t.cachedConversation!.expected, 'Tabs stay inside the strip.');

    expect((await admin('PATCH', '/${t.serverId}', {'status': 'closed', 'tags': ['Fixed'], 'origin': 'discord'}))['status'], 200);
    await d.tickets.refresh();
    t = await row(d.db);
    expect(t.status, 'closed');
    expect(t.tagNames, ['Fixed']);

    // The same report sent again (a retry after a lost answer) is the same
    // ticket, and is not kept twice.
    final again = await FeedbackService(d.db, await SharedPreferences.getInstance(),
            client: client,
            baseUrl: base,
            onTicket: (r, {required id, number}) => d.tickets.keepReport(r, id: id, number: number))
        .retryQueued();
    expect(again, 0);
    expect(await d.db.select(d.db.supportTickets).get(), hasLength(1));
  });

  test('only the key reads a ticket: another device with the id and a wrong key learns nothing', () async {
    if (!serverUp) return markTestSkipped('contract server not running');
    final owner = device();
    await owner.tickets.createSupport(title: unique('Mine'), body: 'Only I may read this.', context: ctx);
    final mine = await row(owner.db);
    await staffReply(mine.serverId!, 'A private answer.');

    // Someone who learned the id, with a key of their own making.
    final thief = device();
    await thief.db.into(thief.db.supportTickets).insert(SupportTicketsCompanion.insert(
          nonce: 'stolen',
          serverId: Value(mine.serverId),
          token: TicketToken.generate(),
          type: 'support',
          title: 'not mine',
          createdAt: 1,
        ));
    final looked = await thief.tickets.refresh();
    expect(looked.reached, isTrue);
    expect(looked.replies, isEmpty);
    var stolen = await row(thief.db);
    expect(stolen.status, 'gone', reason: 'left out of the answer, exactly like a ticket that does not exist');
    expect(stolen.title, 'not mine');
    expect(stolen.lastMessageId, isNull);
    expect(await thief.tickets.open('stolen'), isTrue);
    stolen = await row(thief.db);
    expect(stolen.conversation, isNull, reason: 'nothing of the conversation was given');
    expect((await thief.tickets.reply('stolen', 'let me in')).outcome, TicketSendOutcome.gone);
    expect(await thief.tickets.close('stolen'), isTrue);
    expect((await row(thief.db)).status, 'gone');

    // And nothing of it happened to the real ticket.
    final onServer = await admin('GET', '/${mine.serverId}');
    expect((onServer['ticket'] as Map)['status'], 'open');
    expect((onServer['messages'] as List).map((m) => (m as Map)['body']), ['A private answer.']);
    await owner.tickets.refresh();
    expect((await row(owner.db)).status, 'open');
  });

  test('a ticket the server has deleted reads as gone here, with what was read last', () async {
    if (!serverUp) return markTestSkipped('contract server not running');
    final d = device();
    await d.tickets.createSupport(title: unique('Old ticket'), body: 'Long ago.', context: ctx);
    var t = await row(d.db);
    await staffReply(t.serverId!, 'All sorted.');
    await d.tickets.open(t.nonce);
    final gone = await client.delete(Uri.parse('$root/test/tickets/${t.serverId}'));
    expect(gone.statusCode, 200);
    final res = await d.tickets.refresh();
    expect(res.reached, isTrue);
    t = await row(d.db);
    expect(t.status, 'gone');
    expect(t.cachedConversation!.messages.single.body, 'All sorted.');
  });

  test('a retry is the same ticket and the same message, never a second one', () async {
    if (!serverUp) return markTestSkipped('contract server not running');
    final d = device();
    final subject = unique('Sent twice');
    await d.tickets.createSupport(title: subject, body: 'Did this arrive?', context: ctx);
    final t = await row(d.db);

    // The answer to the first send was lost: the ticket is still marked as
    // waiting here, with the request it was sent with.
    final request = TicketService.supportRequest(
        title: subject,
        body: 'Did this arrive?',
        context: ctx,
        includeAccount: false,
        nonce: t.nonce,
        token: t.token);
    await d.db.update(d.db.supportTickets).write(SupportTicketsCompanion(
        serverId: const Value(null), number: const Value(null), pending: Value(jsonEncode(request))));
    expect(await d.tickets.retryPending(), 1);
    final again = await row(d.db);
    expect(again.serverId, t.serverId, reason: 'the same ticket');
    expect(again.number, t.number);

    // A follow-up delivered twice (its first answer lost) is one message.
    final nonce = unique('n').replaceAll(RegExp('[^0-9]'), '').padLeft(32, '0').substring(0, 32);
    final direct = await client.post(Uri.parse('$base/tickets/${t.serverId}/messages'),
        headers: {'Content-Type': 'application/json', 'X-Ticket-Token': t.token},
        body: jsonEncode({'body': 'Sent once, tried twice', 'nonce': nonce}));
    expect(direct.statusCode, 201);
    await d.db.into(d.db.ticketOutbox).insert(TicketOutboxCompanion.insert(
        nonce: nonce, ticketNonce: t.nonce, body: 'Sent once, tried twice', createdAt: 1));
    expect(await d.tickets.retryPending(), 1);
    expect(await d.db.select(d.db.ticketOutbox).get(), isEmpty);
    final messages = (await admin('GET', '/${t.serverId}'))['messages'] as List;
    expect(messages, hasLength(1));

    // Someone else sending the same nonce with another key is refused.
    final stranger = await client.post(Uri.parse('$base/tickets'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({...request, 'ticket_token': TicketToken.generate()}));
    expect(stranger.statusCode, 409);
    expect(stranger.body, isNot(contains(t.serverId!)));
  });

  test('the account is stored with a ticket only when the box is ticked', () async {
    if (!serverUp) return markTestSkipped('contract server not running');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uid = 'ticket-user-$now-${made++}';
    final bearer = 'fb:$uid:$now:$now';
    // The account exists once it has signed in to anything.
    final signIn = await client.get(Uri.parse('$base/sessions'), headers: {'Authorization': 'Bearer $bearer'});
    expect(signIn.statusCode, 200);

    final d = device(bearer: () async => bearer);
    await d.tickets.createSupport(title: unique('No account'), body: 'Signed in, box not ticked.', context: ctx);
    final plain = await row(d.db);
    final seenPlain = (await admin('GET', '/${plain.serverId}'))['ticket'] as Map;
    expect((seenPlain['author'] as Map).containsKey('account_email'), isFalse);
    expect((seenPlain['author'] as Map)['contact'], isNull);
    await d.tickets.forget(plain.nonce);

    final res = await d.tickets.createSupport(
        title: unique('With account'), body: 'Charged twice.', context: ctx, includeAccount: true);
    expect(res.outcome, TicketSendOutcome.sent);
    final linked = await row(d.db);
    final seen = (await admin('GET', '/${linked.serverId}'))['ticket'] as Map;
    expect((seen['author'] as Map)['account_email'], '$uid@example.com');

    // Ticked while signed out: refused, and nothing is kept anywhere.
    final signedOut = device();
    final refused = await signedOut.tickets.createSupport(
        title: unique('No sign-in'), body: 'x', context: ctx, includeAccount: true);
    expect(refused.outcome, TicketSendOutcome.needsSignIn);
    expect(await signedOut.db.select(signedOut.db.supportTickets).get(), isEmpty);
  });

  test('what the server refuses reads as a refusal here', () async {
    if (!serverUp) return markTestSkipped('contract server not running');
    final d = device();
    // A subject of nothing but spaces is not a subject.
    final empty = await client.post(Uri.parse('$base/tickets'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'title': '   ', 'body': 'text', 'ticket_token': TicketToken.generate()}));
    expect(empty.statusCode, 400);
    // More than fifty in one lookup is refused, which is why the app asks
    // fifty at a time.
    final many = await client.post(Uri.parse('$base/tickets/lookup'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'tickets': List.generate(TicketService.lookupChunk + 1, (_) => {'id': 'tk_x', 'token': TicketToken.generate()}),
        }));
    expect(many.statusCode, 400);
    final exactly = await client.post(Uri.parse('$base/tickets/lookup'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'tickets': List.generate(TicketService.lookupChunk, (_) => {'id': 'tk_x', 'token': TicketToken.generate()}),
        }));
    expect(exactly.statusCode, 200);
    // The longest message the app lets through is taken; one longer is not.
    await d.tickets.createSupport(title: unique('Long'), body: 'x', context: ctx);
    final t = await row(d.db);
    expect((await d.tickets.reply(t.nonce, '\u{1F34A}' * TicketLimits.bodyMax)).outcome, TicketSendOutcome.sent);
    final over = await client.post(Uri.parse('$base/tickets/${t.serverId}/messages'),
        headers: {'Content-Type': 'application/json', 'X-Ticket-Token': t.token},
        body: jsonEncode({'body': 'x' * (TicketLimits.bodyMax + 1)}));
    expect(over.statusCode, 400);
    // The longest subject the app allows is kept whole.
    final longTitle = 'T' * TicketLimits.titleMax;
    final other = device();
    await other.tickets.createSupport(title: longTitle, body: unique('long subject'), context: ctx);
    final kept = await row(other.db);
    expect(((await admin('GET', '/${kept.serverId}'))['ticket'] as Map)['title'], longTitle);
  });
}
