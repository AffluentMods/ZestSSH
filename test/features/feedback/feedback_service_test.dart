import 'dart:convert';
import 'dart:io';
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

/// The in-app report pipeline:
/// the payload carries exactly the six context facts and nothing else,
/// identity is a typed handle or nothing, the account bearer rides along only
/// when the app has one, a failed send is queued IN THE ENCRYPTED DATABASE
/// and retried, and a refusal (rate limit, block, bad request) is never
/// retried.
///
/// Since tickets, a report also carries the key of the ticket it becomes:
/// random for that one report, so it identifies nothing but the report
/// (`test/features/tickets/ticket_service_test.dart` covers what it is for).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Every test opens its own in-memory database; drift's warning is about
  // sharing one executor, which never happens here.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const ctx = FeedbackContext(
    appVersion: '1.9.7',
    build: 210,
    platform: 'windows',
    osVersion: 'Windows 11',
    locale: 'en-US',
    tier: 'squeezed',
  );

  FeedbackReport report(
          {String? contact, List<int>? png, String? title, String? ticketToken}) =>
      FeedbackReport(
        ticketToken: ticketToken,
        type: FeedbackType.bug,
        title: title ?? 'Tab strip overlaps',
        body: 'The third tab is drawn under the pill bar.\nSecond line.',
        expected: 'Tabs stay inside the strip.',
        context: ctx,
        contact: contact == null ? null : FeedbackContact.discord(contact),
        screenshotPng: png == null ? null : Uint8List.fromList(png),
      );

  late SharedPreferences prefs;
  late AppDatabase db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  FeedbackService service(
          {required Future<http.Response> Function(http.Request) handler,
          Future<String?> Function()? bearer}) =>
      FeedbackService(db, prefs, client: MockClient(handler), bearer: bearer);

  Future<int> rowsInDb() async =>
      (await db.select(db.feedbackQueue).get()).length;

  group('payload', () {
    test('carries exactly the documented keys and snake_case context facts',
        () {
      // A fixed key, so the check for forbidden words below never trips on
      // a random one that happens to spell "uid".
      final key = 'K' * 43;
      final j = report(ticketToken: key).toJson();
      expect(j.keys.toSet(), {
        'type', 'title', 'body', 'expected', 'context', 'contact',
        'screenshot', 'nonce', 'ticket_token',
      });
      expect(j['ticket_token'], key);
      expect((j['context'] as Map).keys.toSet(), {
        'app_version', 'build', 'platform', 'os_version', 'locale', 'tier',
      });
      expect((j['context'] as Map)['build'], 210);
      expect(j['contact'], isNull);
      expect(j['screenshot'], isNull);
      // No install id, no account, no logs, no host list.
      final flat = jsonEncode(j);
      for (final forbidden in [
        'installId', 'install_id', 'deviceId', 'email', 'uid', 'hosts',
      ]) {
        expect(flat, isNot(contains(forbidden)));
      }
    });
    test('the contact is a typed Discord handle or null, never anything else',
        () {
      expect(report().isAnonymous, isTrue);
      expect(report(contact: '@me').toJson()['contact'],
          {'kind': 'discord', 'handle': '@me'});
      expect(report(contact: '@me').isAnonymous, isFalse);
      expect(FeedbackContact.fromJson({'kind': 'email', 'handle': 'x'}),
          isNull);
      expect(FeedbackContact.fromJson({'kind': 'discord', 'handle': '  '}),
          isNull);
    });
    test('a suggestion category is sent as a value, only for suggestions',
        () {
      final s = FeedbackReport(
          type: FeedbackType.suggestion,
          body: 'tabs could remember their width',
          category: FeedbackCategory.qualityOfLife,
          context: ctx);
      expect(s.toJson()['category'], 'quality_of_life');
      expect(s.toClipboardText(), contains('Category: Quality of life'));
      final roundTrip = FeedbackReport.fromJson(s.toJson());
      expect(roundTrip.category, FeedbackCategory.qualityOfLife);
      final b = FeedbackReport(
          type: FeedbackType.bug,
          body: 'x',
          category: FeedbackCategory.uiUx,
          context: ctx);
      expect(b.toJson().containsKey('category'), isFalse);
      expect(FeedbackCategory.fromWire('1482019756902187081'), isNull);
    });
    test('the ticket key is random per report: two reports share nothing', () {
      final a = report(), b = report();
      expect(a.ticketToken, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(a.ticketToken, isNot(b.ticketToken));
      expect(report(ticketToken: 'not a key').ticketToken,
          matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
          reason: 'a malformed key is replaced, never sent');
    });
    test('the nonce is a uuid and fresh per report', () {
      final a = report().nonce, b = report().nonce;
      expect(
          a,
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(a, isNot(b));
    });
    test('the thread title is the title, else the first body line, capped',
        () {
      expect(report().toJson()['title'], 'Tab strip overlaps');
      expect(report(title: '').toJson()['title'],
          'The third tab is drawn under the pill bar.');
      final long = FeedbackReport(
          type: FeedbackType.suggestion,
          body: 'x' * 300,
          context: ctx);
      expect(long.threadTitle.length, FeedbackLimits.titleMax);
      expect(long.threadTitle, endsWith('…'));
    });
    test('the preview names the screenshot by size, never inlines it', () {
      final r = report(png: List.filled(4096, 0));
      final preview = r.toPreviewJson();
      expect(preview, contains('4 KB'));
      expect(preview, isNot(contains(base64Encode(r.screenshotPng!))));
      final j = r.toJson();
      expect(j['screenshot'], base64Encode(r.screenshotPng!));
      expect(j['screenshot_redacted'], isTrue);
    });
    test('the clipboard text holds everything a human needs', () {
      final t = report(contact: '@me', png: [1, 2, 3]).toClipboardText();
      expect(t, contains('Tab strip overlaps'));
      expect(t, contains('The third tab'));
      expect(t, contains('Expected: Tabs stay'));
      expect(t, contains('1.9.7 (210) on windows Windows 11, en-US, squeezed'));
      expect(t, contains('Discord: @me'));
      expect(t, contains('redacted screenshot was attached'));
    });
    test('limits are what the form and the server enforce', () {
      expect(FeedbackLimits.bodyMax, 4000);
      expect(FeedbackLimits.titleMax, 100);
      expect(FeedbackLimits.contactMax, 64);
    });
  });

  group('send', () {
    test('2xx is sent and starts the cooldown; no bearer means no auth header',
        () async {
      Map<String, dynamic>? posted;
      Map<String, String>? headers;
      final svc = service(handler: (req) async {
        posted = jsonDecode(req.body) as Map<String, dynamic>;
        headers = req.headers;
        expect(req.url.path, endsWith('/feedback'));
        return http.Response('{"ok":true}', 200);
      });
      final res = await svc.send(report());
      expect(res.outcome, FeedbackOutcome.sent);
      expect(posted!['type'], 'bug');
      expect(headers!['Content-Type'], startsWith('application/json'));
      expect(headers!.containsKey('Authorization'), isFalse);
      expect(headers!['X-ZestSSH-Tickets'], '1');
      // The only headers a signed-out report carries.
      expect(headers!.keys.map((k) => k.toLowerCase()).toSet(),
          {'content-type', 'x-zestssh-tickets'});
      expect(prefs.getInt(FeedbackService.lastSentKey), isNotNull);
      expect(svc.cooldownMinutesLeft(), greaterThan(0));
      expect(await svc.queued(), isEmpty);
    });
    test('the account bearer is attached when the app has one', () async {
      String? auth;
      final svc = service(handler: (req) async {
        auth = req.headers['Authorization'];
        return http.Response('{"ok":true}', 200);
      }, bearer: () async => 'tok-123');
      await svc.send(report());
      expect(auth, 'Bearer tok-123');
    });
    test('a 202 (queued on the server) counts as sent', () async {
      final svc = service(
          handler: (_) async =>
              http.Response('{"ok":true,"queued":true}', 202));
      final res = await svc.send(report());
      expect(res.outcome, FeedbackOutcome.sent);
      expect(await svc.queued(), isEmpty);
    });
    test('the client cooldown blocks a second send with minutes left',
        () async {
      var calls = 0;
      final svc = service(handler: (_) async {
        calls++;
        return http.Response('{"ok":true}', 200);
      });
      await svc.send(report());
      final second = await svc.send(report());
      expect(second.outcome, FeedbackOutcome.rateLimited);
      expect(second.retryMinutes, inInclusiveRange(1, 3));
      expect(calls, 1, reason: 'the second report never reached the network');
    });
    test(
        'a network failure queues the report in the database, text only, '
        'and nothing lands in preferences', () async {
      final svc = service(handler: (_) async {
        throw const SocketException('offline');
      });
      final res = await svc.send(report(png: List.filled(64, 7)));
      expect(res.outcome, FeedbackOutcome.queued);
      final q = await svc.queued();
      expect(q, hasLength(1));
      expect(q.single.body, contains('third tab'));
      expect(q.single.screenshotPng, isNull);
      expect(q.single.nonce, isNotEmpty);
      expect(await rowsInDb(), 1);
      // The vault is the only place report text may rest.
      expect(prefs.getKeys().where((k) => k != FeedbackService.lastSentKey),
          isEmpty);
    });
    test(
        'a 5xx queues; a 4xx is rejected; a 403 is a block; a 429 is a rate '
        'limit; none of the refusals are queued', () async {
      for (final (code, outcome) in [
        (503, FeedbackOutcome.queued),
        (400, FeedbackOutcome.rejected),
        (413, FeedbackOutcome.rejected),
        (403, FeedbackOutcome.blocked),
        (429, FeedbackOutcome.rateLimited),
      ]) {
        SharedPreferences.setMockInitialValues({});
        final p = await SharedPreferences.getInstance();
        final d = AppDatabase.forTesting(NativeDatabase.memory());
        final svc = FeedbackService(d, p, client: MockClient((_) async =>
            http.Response('{}', code, headers: {'retry-after': '120'})));
        final res = await svc.send(report());
        expect(res.outcome, outcome, reason: 'HTTP $code');
        expect((await svc.queued()).length, code == 503 ? 1 : 0,
            reason: 'HTTP $code');
        if (code == 429) expect(res.retryMinutes, 2);
        await d.close();
      }
    });
    test('the queue is capped, oldest first', () async {
      final svc = service(handler: (_) async {
        throw const SocketException('offline');
      });
      for (var i = 0; i < FeedbackService.maxQueued + 3; i++) {
        await svc.send(FeedbackReport(
            type: FeedbackType.suggestion,
            title: '$i',
            body: 'q $i',
            context: ctx,
            createdAt: DateTime(2026, 1, 1, 0, i)));
      }
      final titles = (await svc.queued()).map((r) => r.title).toList();
      expect(titles, hasLength(FeedbackService.maxQueued));
      expect(titles.first, '3');
    });
  });

  group('retryQueued', () {
    test('delivers what it can, drops what the server refuses, keeps the rest',
        () async {
      // Queue four reports while offline.
      final offline = service(handler: (_) async {
        throw const SocketException('offline');
      });
      var minute = 0;
      for (final t in ['ok', 'bad', 'blocked', 'later']) {
        await offline.send(FeedbackReport(
            type: FeedbackType.suggestion,
            title: t,
            body: t,
            context: ctx,
            createdAt: DateTime(2026, 1, 1, 0, minute++)));
      }
      expect(await offline.queued(), hasLength(4));

      // Back online: the server accepts one, rejects one, refuses one, is
      // down for one.
      final online = service(handler: (req) async {
        final title = (jsonDecode(req.body) as Map)['title'];
        return switch (title) {
          'ok' => http.Response('{"ok":true}', 200),
          'bad' => http.Response('{"error":"no"}', 400),
          'blocked' => http.Response('{"error":"blocked"}', 403),
          _ => http.Response('down', 502),
        };
      });
      final delivered = await online.retryQueued();
      expect(delivered, 1);
      expect((await online.queued()).map((r) => r.title), ['later']);
      expect(await rowsInDb(), 1);
    });
    test('a retried report keeps its nonce so the server can deduplicate',
        () async {
      final offline = service(handler: (_) async {
        throw const SocketException('offline');
      });
      final r = report(contact: '@me');
      await offline.send(r);
      Map<String, dynamic>? seen;
      final online = service(handler: (req) async {
        seen = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"ok":true}', 200);
      });
      await online.retryQueued();
      expect(seen!['nonce'], r.nonce);
      expect(seen!['contact'], {'kind': 'discord', 'handle': '@me'});
      expect((seen!['context'] as Map)['build'], 210);
    });
    test(
        'a queue left in preferences by an older build is moved into the '
        'database once and the plaintext copy deleted', () async {
      final legacy = report(title: 'from prefs');
      SharedPreferences.setMockInitialValues({
        FeedbackService.legacyQueueKey: [jsonEncode(legacy.toJson())],
      });
      prefs = await SharedPreferences.getInstance();
      final svc = service(handler: (_) async {
        throw const SocketException('offline');
      });
      await svc.retryQueued();
      expect(prefs.getStringList(FeedbackService.legacyQueueKey), isNull);
      final q = await svc.queued();
      expect(q.map((r) => r.title), ['from prefs']);
      expect(q.single.nonce, legacy.nonce);
      // A second launch finds nothing to import and changes nothing.
      await svc.retryQueued();
      expect(await rowsInDb(), 1);
    });
  });
}
