import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';

import '../../helpers/contract_run.dart';

/// Seats and Business Services against the REAL server routes (ZestSSH-
/// Backend routes/orchards.js and lib/orchard_billing.js) on a real
/// Postgres (3.0): members read an Orchard's seats; an invitation
/// needs a free seat; with more people than seats the sync keeps new items
/// waiting on the device while changes still go, and sends them once there
/// are seats; directory sync needs Business Services. The contract server's
/// Orchards start with 100 seats and Business Services; PUT
/// /test/billing/(Orchard id) changes them. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Account {
  _Account(this.uid, this.service, this.coordinator, this.billing, this.directory);

  final String uid;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;
  final OrchardBillingApi billing;
  final OrchardDirectoryApi directory;

  String get email => '$uid@example.com';
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1$'), '');
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/orchards')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in opened) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    opened.clear();
  });

  var made = 0;

  Future<_Account> account(String name) async {
    final uid = 'billing-$name-$contractRun-${made++}';
    Future<String> token() async => 'fb:$uid:${now()}:${now()}';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: token),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final storage = _MemoryStorage();
    opened.add(storage);
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: token);
    final service = OrchardService(
      server: server,
      databases: databases,
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    return _Account(
      uid,
      service,
      OrchardSyncCoordinator(service: service, server: server, databases: databases),
      OrchardBillingApi(client: client, baseUrl: base, bearer: token),
      OrchardDirectoryApi(client: client, baseUrl: base, bearer: token),
    );
  }

  /// Sets [orchardId]'s seats or Business Services on the contract server.
  Future<void> billingIs(String orchardId, Map<String, Object?> body) async {
    final r = await client.put(Uri.parse('$root/test/billing/$orchardId'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    expect(r.statusCode, 200, reason: r.body);
  }

  Future<void> addHost(AppDatabase db, String id) async {
    final at = DateTime(2026, 9, 25);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: '10.0.0.1', port: const Value(22), createdAt: at, updatedAt: at));
  }

  Matcher refused(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));

  test('seats as members see them, an invitation needs one, and new items wait while there are too few', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchard = await owner.service.createOrchard('Seats', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = (await owner.service.roles(orchard)).single.id;
    await billingIs(orchard, {'seats': 2});

    var seen = await owner.billing.get(orchard);
    expect((seen.seats.bought, seen.seats.included, seen.seats.total, seen.seats.used, seen.seats.free, seen.seats.over),
        (2, 0, 2, 1, 1, false));
    expect(seen.services.state, BusinessServicesState.active);
    expect(seen.services.yearly, isTrue);
    expect(seen.services.paidThrough!.isAfter(DateTime.now()), isTrue);
    expect(seen.services.worksUntil!.difference(seen.services.paidThrough!), const Duration(days: 14));
    expect(seen.seatPriceCents, 10000, reason: 'a seat is \$100 once (pricing of 22 October 2026)');

    // The second seat goes to Alice's invitation; there is none for Bob's.
    await owner.service.invite(orchard, email: alice.email, role: role);
    await expectLater(owner.service.invite(orchard, email: 'bob-${now()}@example.com', role: role), refused('seats-full'));
    try {
      await owner.service.invite(orchard, email: 'bob-${now()}@example.com', role: role);
    } on OrchardServerException catch (e) {
      expect((e.status, e.seats, e.seatsUsed, e.seatsNeeded), (409, 2, 2, 1));
    }
    await alice.service.acceptInvite((await alice.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchard, (await owner.service.invites(orchard)).single);
    seen = await alice.billing.get(orchard);
    expect((seen.seats.total, seen.seats.used, seen.seats.free), (2, 2, 0), reason: 'members see the seats too');

    // A host added while there were seats.
    final db = await owner.coordinator.databases.open(orchard);
    await addHost(db, 'h-1');
    var reports = await owner.coordinator.syncAll();
    expect(reports[orchard]!.sent, 1);

    // A refund leaves more people than seats: the change goes, the new host
    // waits on this device.
    await billingIs(orchard, {'seats': 1});
    expect((await owner.billing.get(orchard)).seats.over, isTrue);
    await (db.update(db.connections)..where((c) => c.id.equals('h-1'))).write(const ConnectionsCompanion(label: Value('edited')));
    await addHost(db, 'h-2');
    reports = await owner.coordinator.syncAll();
    expect(reports[orchard]!.seatsNeeded, isTrue);
    expect(reports[orchard]!.sent, 1);
    expect(reports[orchard]!.unsent, 1);
    final waiting = await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle();
    expect(waiting.read<int>('n'), 1);

    // Seats bought: it goes, and Alice gets both.
    await billingIs(orchard, {'seats': 5});
    reports = await owner.coordinator.syncAll();
    expect(reports[orchard]!.seatsNeeded, isFalse);
    expect(reports[orchard]!.sent, 1);
    final got = await alice.coordinator.syncAll();
    expect(got[orchard]!.received, 2);
  });

  test('directory sync needs Business Services paid up', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final orchard = await owner.service.createOrchard('Services', firstCrateName: 'Production', memberRoleName: 'Member');
    await billingIs(orchard, {'services': null});
    expect((await owner.billing.get(orchard)).services.state, BusinessServicesState.off);
    await expectLater(owner.directory.enable(orchard), refused('business-services-required'));

    await billingIs(orchard, {'services': 'past_due', 'endsInDays': -3});
    final grace = (await owner.billing.get(orchard)).services;
    expect(grace.state, BusinessServicesState.grace);
    await expectLater(owner.directory.enable(orchard), refused('business-services-required'),
        reason: 'turning it on needs it paid up, not in grace');

    await billingIs(orchard, {'services': 'active'});
    // On to the next check: a proven domain.
    await expectLater(owner.directory.enable(orchard), refused('domain-required'));
  });
  test('buying from the seats sheet: what the server refuses comes back with what it says, as the sheet words it', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final orchard = await owner.service.createOrchard('Buying', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = (await owner.service.roles(orchard)).single.id;
    await billingIs(orchard, {'seats': 0, 'services': null});

    // What the sheet counts with is what the server sends.
    var seen = await owner.billing.get(orchard);
    expect((seen.seatPriceCents, seen.teamMinSeats, seen.teamMaxSeats, seen.maxPerPurchase, seen.maxSeats),
        (10000, 2, 25, 250, 1000));
    expect((seen.seatsMinimum, seen.seatsMaximum), (2, 25));

    // Fewer than a team starts at, and past what it holds without Business.
    await expectLater(owner.billing.buySeats(orchard, 1),
        throwsA(isA<SeatPurchaseRefused>().having((e) => e.code, 'code', 'seats-minimum').having((e) => e.minimum, 'minimum', 2)));
    await expectLater(owner.billing.buySeats(orchard, 26),
        throwsA(isA<SeatPurchaseRefused>().having((e) => e.code, 'code', 'business-needed-for-seats').having((e) => e.maximum, 'maximum', 25)));
    // Within them it asks Stripe, which this server has not: said as that.
    await expectLater(owner.billing.buySeats(orchard, 2), refused('billing-unavailable'));
    await expectLater(owner.billing.sendSeatInvoice(orchard, 2), refused('billing-unavailable'));
    await expectLater(owner.billing.sendSeatInvoice(orchard, 2, email: 'someone@elsewhere.example'), refused('invoice-address'));
    await expectLater(owner.billing.sendSeatInvoice(orchard, 2, po: 'PO%1'), refused('invalid-request'));
    await expectLater(owner.billing.billingPortal(orchard), refused('billing-unavailable'));

    // A team without its first seats: Business says buy seats first.
    await expectLater(owner.billing.subscribeBusiness(orchard, yearly: true), refused('seats-first'));
    await billingIs(orchard, {'seats': 3});
    await expectLater(owner.billing.subscribeBusiness(orchard, yearly: false), refused('billing-unavailable'));
    await billingIs(orchard, {'services': 'active'});
    await expectLater(owner.billing.subscribeBusiness(orchard, yearly: true), refused('business-services-exists'));

    // With Business: past 25 is the server's to allow.
    seen = await owner.billing.get(orchard);
    expect(seen.services.notOver, isTrue);
    expect(seen.seatsMaximum, 250);

    // Only owners.
    await owner.service.invite(orchard, email: alice.email, role: role);
    await alice.service.acceptInvite((await alice.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchard, (await owner.service.invites(orchard)).single);
    await expectLater(alice.billing.buySeats(orchard, 2), refused('owners-only'));
    await expectLater(alice.billing.billingPortal(orchard), refused('owners-only'));
  });

  test('an owner redeems a code that gives the Orchard seats: once for an Orchard, for owners only, and a code for a person is told apart', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');

    /// A code as whoever runs the service makes one, on the contract server.
    Future<String> code(String grant, {int max = 1}) async {
      final name = 'CONTRACT-${contractRun.toUpperCase()}-${made++}';
      final r = await client.put(Uri.parse('$root/test/redemption-code'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'code': name, 'grant': grant, 'max': max}));
      expect(r.statusCode, 200, reason: r.body);
      return name;
    }

    final owner = await account('owner');
    final alice = await account('alice');
    final other = await account('other');
    final orchard = await owner.service.createOrchard('Codes', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = (await owner.service.roles(orchard)).single.id;
    await billingIs(orchard, {'seats': 0, 'services': null});
    await expectLater(owner.service.invite(orchard, email: alice.email, role: role), refused('seats-full'));

    final seats = await code('seats:4');
    // As a person types it.
    final done = await owner.billing.redeem(orchard, ' ${seats.toLowerCase()} ');
    expect(done.added, 4);
    expect((done.billing.seats.bought, done.billing.seats.total, done.billing.seats.used, done.billing.seats.over),
        (4, 4, 1, false));
    // The seats are seats: Alice is invited and joins.
    await owner.service.invite(orchard, email: alice.email, role: role);
    await alice.service.acceptInvite((await alice.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchard, (await owner.service.invites(orchard)).single);

    // Again changes nothing. A member who is no owner is refused. Another
    // Orchard finds the code used up, as it finds one that never was.
    final again = await owner.billing.redeem(orchard, seats);
    expect((again.added, again.billing.seats.bought, again.billing.seats.used), (0, 4, 2));
    final more = await code('seats:2');
    await expectLater(alice.billing.redeem(orchard, more), refused('owners-only'));
    final theirs = await other.service.createOrchard('Other', firstCrateName: 'Production', memberRoleName: 'Member');
    await expectLater(other.billing.redeem(theirs, seats), refused('code-invalid'));
    await expectLater(other.billing.redeem(theirs, 'NOPE-0000-0000'), refused('code-invalid'));

    // A code for a person says so, however often, and gives no seats.
    final personal = await code('pro');
    await expectLater(owner.billing.redeem(orchard, personal), refused('personal-code'));
    await expectLater(owner.billing.redeem(orchard, personal), refused('personal-code'));
    expect((await owner.billing.get(orchard)).seats.bought, 4);
    // The code the member could not use is still there for an owner.
    expect((await owner.billing.redeem(orchard, more)).added, 2);
    expect((await owner.billing.get(orchard)).seats.bought, 6);
  });
}
