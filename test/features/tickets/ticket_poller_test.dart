import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_poller.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';

import 'fake_ticket_server.dart';

/// When the app asks for answers (to know about
/// a reply): once as the database opens, when the app comes back to the
/// front, and every few minutes while a ticket is open. Never while the
/// device holds no ticket, and never more often than it should.
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
  late TicketService service;
  var clock = DateTime.utc(2026, 10, 1, 8);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = FakeTicketServer();
    clock = DateTime.utc(2026, 10, 1, 8);
    service = TicketService(db,
        client: MockClient(server.handle), now: () => clock, baseUrl: 'https://api.test/v1');
  });
  tearDown(() => db.close());

  int lookups() => server.calls('/tickets/lookup').length;

  test('a device with no ticket asks nothing, however often it is checked', () async {
    var reportRetries = 0;
    final poller = TicketPoller(service, now: () => clock, retryReports: () async => reportRetries++);
    await poller.check(force: true);
    clock = clock.add(const Duration(hours: 1));
    await poller.check(force: true);
    expect(server.requests, isEmpty);
    expect(reportRetries, 2, reason: 'the report queue is still looked at (it asks nothing when empty)');
  });

  test('an answer from support is handed over once', () async {
    final seen = <List<String>>[];
    final poller = TicketPoller(service, now: () => clock)
      ..onReplies = (replies) => seen.add([for (final r in replies) r.nonce]);
    final res = await service.createSupport(title: 'Help', body: 'Please.', context: ctx);
    await poller.check(force: true);
    expect(seen, isEmpty);

    server.staffReply((await service.ticket(res.nonce!))!.serverId!, 'Hello');
    await poller.check(force: true);
    expect(seen, [
      [res.nonce!],
    ]);
    await poller.check(force: true);
    expect(seen, hasLength(1), reason: 'the same answer is not handed over again');
  });

  test('coming back to the front again and again asks at most once per gap', () async {
    final poller = TicketPoller(service, now: () => clock);
    await service.createSupport(title: 'Help', body: 'Please.', context: ctx);
    await poller.check(force: true);
    expect(lookups(), 1);

    for (var i = 0; i < 5; i++) {
      clock = clock.add(const Duration(seconds: 5));
      await poller.check();
    }
    expect(lookups(), 1, reason: 'inside the gap');

    clock = clock.add(TicketPoller.minGap);
    await poller.check();
    expect(lookups(), 2);
    await poller.check(force: true);
    expect(lookups(), 3, reason: 'the person asked: no gap');
  });

  test('what waits is sent before the tickets are asked about', () async {
    final poller = TicketPoller(service, now: () => clock);
    server.offline = true;
    final res = await service.createSupport(title: 'Offline', body: 'Later.', context: ctx);
    await poller.check(force: true);
    expect((await service.ticket(res.nonce!))!.isWaiting, isTrue);

    server.offline = false;
    server.requests.clear();
    await poller.check(force: true);
    expect((await service.ticket(res.nonce!))!.isSent, isTrue);
    expect(server.requests.map((r) => r.url.path.split('/').last), ['tickets', 'lookup'],
        reason: 'sent first, then asked about');
  });

  test('the report queue is tried at most every quarter of an hour while the app runs', () async {
    var reportRetries = 0;
    final poller = TicketPoller(service, now: () => clock, retryReports: () async => reportRetries++);
    await poller.check(force: true);
    expect(reportRetries, 1);
    clock = clock.add(const Duration(minutes: 5));
    await poller.check(force: true);
    expect(reportRetries, 1);
    clock = clock.add(TicketPoller.reportRetryGap);
    await poller.check(force: true);
    expect(reportRetries, 2);
  });

  test('a failure in a round never escapes, and the next round still runs', () async {
    var calls = 0;
    final poller = TicketPoller(service, now: () => clock, retryReports: () async {
      calls++;
      if (calls == 1) throw StateError('the queue is broken');
    });
    await service.createSupport(title: 'Help', body: 'Please.', context: ctx);
    await poller.check(force: true);
    clock = clock.add(TicketPoller.reportRetryGap);
    await poller.check(force: true);
    expect(calls, 2);
    expect(lookups(), 1, reason: 'the round that failed stopped; the next one finished');
  });

  group('the timer', () {
    // The timer's own behaviour, on the test's clock, with a service that
    // counts instead of a database (a database needs real time to answer).
    testWidgets('asks every few minutes only while a ticket is open and the app is in front', (tester) async {
      final fake = _CountingService(db);
      final poller = TicketPoller(fake, now: tester.binding.clock.now, interval: const Duration(minutes: 3));
      addTearDown(poller.stop);
      poller.start();
      await tester.pump();
      expect(fake.refreshes, 1, reason: 'once as the database opens');
      expect(poller.running, isTrue);

      // No open ticket and nothing waiting: the timer ticks and asks nothing.
      await tester.pump(const Duration(minutes: 10));
      expect(fake.refreshes, 1);

      fake.hasOpen = true;
      await tester.pump(const Duration(minutes: 3));
      expect(fake.refreshes, 2);
      await tester.pump(const Duration(minutes: 3));
      await tester.pump(const Duration(minutes: 3));
      expect(fake.refreshes, 4);

      // The window is hidden: nothing is asked. Back in front: at once.
      poller.onBackground();
      await tester.pump(const Duration(minutes: 30));
      expect(fake.refreshes, 4);
      poller.onForeground();
      await tester.pump();
      expect(fake.refreshes, 5);

      // Something waiting to be sent is reason enough to keep trying.
      fake
        ..hasOpen = false
        ..waiting = true;
      await tester.pump(const Duration(minutes: 3));
      expect(fake.refreshes, 6);
      expect(fake.retries, greaterThan(0));

      // The app locks: the timer stops, and a return to the front asks
      // nothing while it is stopped.
      poller.stop();
      expect(poller.running, isFalse);
      fake.hasOpen = true;
      await tester.pump(const Duration(hours: 1));
      poller.onForeground();
      await tester.pump();
      expect(fake.refreshes, 6);
    });
  });
}

/// The poller's view of the service, counting calls.
class _CountingService extends TicketService {
  _CountingService(super.db);

  bool hasOpen = false;
  bool waiting = false;
  int refreshes = 0;
  int retries = 0;

  @override
  Future<bool> hasOpenTickets() async => hasOpen;

  @override
  Future<bool> hasWaiting() async => waiting;

  @override
  Future<int> retryPending() async {
    retries++;
    return 0;
  }

  @override
  Future<TicketRefresh> refresh() async {
    refreshes++;
    return const TicketRefresh(reached: true);
  }
}
