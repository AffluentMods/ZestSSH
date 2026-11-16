import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';

/// What a device reports of a session that went on with nobody watching
/// (3.0; orchard_unwatched.dart): sealed and kept on the
/// device before anything is sent, with nothing of it readable there; put
/// into the Orchard's record once the server can be reached, by the sync
/// every device runs; never twice; and read by whoever holds the Crate's
/// key, on their own device, and by nobody else.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';

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

class _Device {
  _Device(FakeCrateServer shared, this.uid, AccountKeys keys) : server = shared.as(uid) {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    service = OrchardService(
      server: server,
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    sync = OrchardSyncCoordinator(service: service, server: server, databases: databases);
  }

  final String uid;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;
  late final OrchardSyncCoordinator sync;

  Future<AppDatabase> db(String orchardId) => databases.open(orchardId);

  /// What this device keeps to send, as it is written there.
  Future<Map<String, String>> kept(String orchardId) async {
    final store = LocalStateStore(await db(orchardId));
    return {
      for (final key in await store.keysWithPrefix(kUnwatchedState)) key: (await store.read(key))!,
    };
  }

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  /// Every device's clock, in seconds: tests move it.
  late int clock;

  setUpAll(() async {
    for (final uid in [_owner, _alice, _bob]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    clock = 1791504000;
    OrchardService.debugNow = () => DateTime.fromMillisecondsSinceEpoch(clock * 1000);
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _alice, _bob]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    OrchardService.debugNow = DateTime.now;
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid) {
    final d = _Device(server, uid, keys[uid]!);
    devices.add(d);
    return d;
  }

  Future<void> join(_Device by, _Device person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    server.acceptAs(orchardId, (await by.service.invites(orchardId)).single.id, person.uid);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    expect(await person.service.refresh(), contains(orchardId));
  }

  /// Acme: Production's sessions are watched. alice is a Member (use of
  /// Production); bob's role opens no Crate at all.
  Future<({String id, String production, _Device owner, _Device alice, _Device bob})> team() async {
    final owner = device(_owner);
    final alice = device(_alice);
    final bob = device(_bob);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single;
    final production = member.crates.keys.single;
    final nothing = await owner.service.saveRole(id, name: 'Guests', can: const {}, crates: const {});
    await join(owner, alice, id, member.id);
    await join(owner, bob, id, nothing);
    await owner.service.setCrateWatched(id, production, true);
    for (final d in [owner, alice, bob]) {
      await d.service.refresh();
    }
    return (id: id, production: production, owner: owner, alice: alice, bob: bob);
  }

  /// The reports in the record as the server has it.
  List<RecordEntry> reported(String orchardId) => [
        for (final e in server.entriesOf(orchardId))
          if (e.type == RecordTypes.sessionUnwatched) e,
      ];

  /// [d] keeps what it reports of a session that runs with nobody watching.
  Future<void> keep(_Device d, String orchardId, String crateId,
      {String host = 'db-primary', String reason = 'restoring the database', String reach = 'down'}) async {
    d.service.unwatchedRan(
        await d.service.keepUnwatchedReport(orchardId, crateId: crateId, hostLabel: host, reason: reason, reach: reach));
  }

  test('kept sealed on the device before anything is sent, put into the record by the next sync that reaches the '
      'server, and read by whoever holds the key of the Crate', () async {
    final t = await team();
    final before = server.recordOf(t.id).seq;
    // ZestSSH Cloud cannot be reached: nothing is asked of it to keep a report.
    server.down = true;
    final asked = server.asked;
    await keep(t.alice, t.id, t.production, host: '  db-primary\n(Production) ', reason: ' restoring   the database ');
    expect(server.asked, asked);
    expect(await t.alice.service.unwatchedWaiting(t.id), 1);
    // As it is kept: the Crate, the time, which key, and the sealed part.
    // Nothing of the host or the reason is readable there.
    final kept = (await t.alice.kept(t.id)).values.single;
    final body = jsonDecode(kept) as Map<String, Object?>;
    expect(body.keys.toSet(), {'crate', 'at', 'gen', 'sealed'});
    expect((body['crate'], body['at'], body['gen']), (t.production, clock, 1));
    expect(kept, isNot(contains('db-primary')));
    expect(kept, isNot(contains('restoring')));
    expect(utf8.decode(base64Decode(body['sealed'] as String), allowMalformed: true), isNot(contains('restoring')));

    // The server is still away: the round sends nothing and keeps it, and
    // so does a sync, which fails as a sync does then.
    await expectLater(t.alice.service.unwatchedRound(t.id), throwsA(isA<SocketException>()));
    await expectLater(t.alice.sync.syncAll(), throwsA(isA<SocketException>()));
    expect(await t.alice.service.unwatchedWaiting(t.id), 1);
    expect(reported(t.id), isEmpty);

    // Back: the sync every device runs puts it into the record, signed by
    // alice, as it was kept.
    server.down = false;
    clock += 3600;
    await t.alice.sync.syncAll();
    expect(await t.alice.service.unwatchedWaiting(t.id), 0);
    expect(await t.alice.kept(t.id), isEmpty);
    final entry = reported(t.id).single;
    expect((entry.seq, entry.by), (before + 1, _alice));
    expect(entry.body, body);
    expect(server.appends.last, [RecordTypes.sessionUnwatched]);
    // A sync after that has nothing more to send.
    final sent = server.appends.length;
    await t.alice.sync.syncAll();
    expect(server.appends.length, sent);

    // The owner's device reads it with its next sync: who, which Crate,
    // when (by alice's clock then, an hour before it was sent), and what
    // only holders of the Crate's key read.
    await t.owner.service.refresh();
    final mine = (await LocalRecord.load(await t.owner.db(t.id), t.id)).entries.last;
    expect(mine.type, RecordTypes.sessionUnwatched);
    final read = (await t.owner.service.unwatchedSessionOf(t.id, mine))!;
    expect((read.seq, read.by, read.crateId, read.at), (before + 1, _alice, t.production, clock - 3600));
    expect(read.report,
        const UnwatchedReport(host: 'db-primary (Production)', reason: 'restoring the database', reach: 'down'));
    // alice's own device reads it as well.
    expect((await t.alice.service.unwatchedSessionOf(t.id, entry))!.report, read.report);
    // bob is in the Orchard and opens nothing in it: who, where and when
    // are the record's, and the rest stays shut.
    await t.bob.service.refresh();
    final bobs = (await t.bob.service.unwatchedSessionOf(t.id, entry))!;
    expect((bobs.by, bobs.crateId, bobs.at, bobs.report), (_alice, t.production, clock - 3600, null));
    // An entry of another kind is no report.
    final other = (await LocalRecord.load(await t.owner.db(t.id), t.id)).entries.first;
    expect(await t.owner.service.unwatchedSessionOf(t.id, other), isNull);

    // Something in the record that says it is a report and does not open
    // (sealed with nothing this device knows): who, where and when, and
    // nothing made up for the rest.
    await t.alice.service.change(t.id, RecordTypes.sessionUnwatched,
        {'crate': t.production, 'at': clock, 'gen': 1, 'sealed': base64Encode(List<int>.filled(60, 9))});
    final shut = (await t.owner.service.unwatchedSessionOf(t.id, reported(t.id).last))!;
    expect((shut.by, shut.crateId, shut.at, shut.report), (_alice, t.production, clock, null));

    // The key of the Crate is replaced: a report kept after that is sealed
    // with the new one and says so, and the one from before still opens.
    await t.owner.service.rotateAll();
    expect(server.recordOf(t.id).crates[t.production]!.generation, 2);
    await t.alice.service.refresh();
    await keep(t.alice, t.id, t.production, reason: 'after the new key');
    await t.alice.sync.syncAll();
    final latest = reported(t.id).last;
    expect(latest.body['gen'], 2);
    await t.owner.service.refresh();
    expect((await t.owner.service.unwatchedSessionOf(t.id, latest))!.report!.reason, 'after the new key');
    expect((await t.owner.service.unwatchedSessionOf(t.id, entry))!.report!.reason, 'restoring the database');
  });

  test('a report that cannot be kept is not kept in part, and says why', () async {
    final t = await team();
    Matcher notKept(String why) => throwsA(isA<UnwatchedNotKept>().having((e) => e.why, 'why', why));
    // No reason given.
    await expectLater(keep(t.alice, t.id, t.production, reason: '  \n '), notKept('no reason'));
    // A Crate the Orchard does not have, and one whose key is not on the
    // device (bob opens nothing).
    await expectLater(keep(t.alice, t.id, 'no-such-crate'), notKept('no such Crate'));
    await expectLater(keep(t.bob, t.id, t.production), notKept("the Crate's key is not on this device"));
    for (final d in [t.alice, t.bob]) {
      expect(await d.service.unwatchedWaiting(t.id), 0);
      expect(await d.kept(t.id), isEmpty);
    }
    expect('${const UnwatchedNotKept('no reason')}', contains('no reason'));
  });

  test('a reason too long to seal loses its end, and the host stays whole', () async {
    final t = await team();
    // Three hundred characters of four bytes each, and a host of a hundred
    // and twenty of them: more than an entry takes.
    final faces = String.fromCharCodes(List.filled(kUnwatchedReasonMax, 0x1F600));
    final host = String.fromCharCodes(List.filled(kUnwatchedHostMax, 0x1F5A5));
    await keep(t.alice, t.id, t.production, host: host, reason: faces);
    final body = jsonDecode((await t.alice.kept(t.id)).values.single) as Map<String, Object?>;
    final sealed = base64Decode(body['sealed'] as String);
    expect(sealed.length, lessThanOrEqualTo(kMaxUnwatchedSealed));
    await t.alice.sync.syncAll();
    final report = (await t.alice.service.unwatchedSessionOf(t.id, reported(t.id).single))!.report!;
    expect(report.host, host);
    expect(report.reason.runes.length, 225, reason: 'a quarter of it gone, once');
    expect(faces, startsWith(report.reason), reason: 'its beginning, cut between characters');
    // One that fits is kept whole.
    await keep(t.alice, t.id, t.production, reason: 'r' * kUnwatchedReasonMax);
    await t.alice.sync.syncAll();
    expect((await t.alice.service.unwatchedSessionOf(t.id, reported(t.id).last))!.report!.reason,
        'r' * kUnwatchedReasonMax);
  });

  test('sent oldest first; what cannot be sent waits, and is not sent twice when the answer never arrived', () async {
    final t = await team();
    // How much of the server one report asks.
    await keep(t.alice, t.id, t.production, reason: 'the first');
    final start = server.asked;
    expect(await t.alice.service.unwatchedRound(t.id), 1);
    final each = server.asked - start;
    expect(each, greaterThan(1));

    // Three more, kept in another order than they happened.
    clock += 300;
    await keep(t.alice, t.id, t.production, reason: 'the third');
    clock -= 200;
    await keep(t.alice, t.id, t.production, reason: 'the second');
    clock += 500;
    await keep(t.alice, t.id, t.production, reason: 'the fourth');
    // The server goes away after the first of them went in.
    server.downAfter = each;
    await expectLater(t.alice.service.unwatchedRound(t.id), throwsA(isA<SocketException>()));
    expect(await t.alice.service.unwatchedWaiting(t.id), 2);
    Future<List<String>> reasons() async => [
          for (final e in reported(t.id)) (await t.alice.service.unwatchedSessionOf(t.id, e))!.report!.reason,
        ];
    expect(await reasons(), ['the first', 'the second']);

    // Back: the rest, in the order they happened.
    server.down = false;
    expect(await t.alice.service.unwatchedRound(t.id), 2);
    expect(await reasons(), ['the first', 'the second', 'the third', 'the fourth']);
    expect(await t.alice.service.unwatchedWaiting(t.id), 0);
    expect(await t.alice.service.unwatchedRound(t.id), 0, reason: 'nothing waits');

    // The record took one, and the device never heard: it is still kept.
    // The next round finds it in the record and sends nothing.
    await keep(t.alice, t.id, t.production, reason: 'the fifth');
    final body = jsonDecode((await t.alice.kept(t.id)).values.single) as Map<String, Object?>;
    final stored = Map.of(await t.alice.kept(t.id));
    await t.alice.service.change(t.id, RecordTypes.sessionUnwatched, body);
    final store = LocalStateStore(await t.alice.db(t.id));
    for (final e in stored.entries) {
      await store.write(e.key, e.value);
    }
    expect(await t.alice.service.unwatchedWaiting(t.id), 1);
    final appended = server.appends.length;
    expect(await t.alice.service.unwatchedRound(t.id), 0);
    expect(server.appends.length, appended, reason: 'not sent again');
    expect(await t.alice.service.unwatchedWaiting(t.id), 0);
    expect((await reasons()).where((r) => r == 'the fifth'), hasLength(1));

    // Someone else's entry that carries the same sealed part is not hers
    // (it does not open as theirs either): hers still goes.
    await keep(t.alice, t.id, t.production, reason: 'the sixth');
    final copied = jsonDecode((await t.alice.kept(t.id)).values.single) as Map<String, Object?>;
    await t.bob.service.refresh();
    await t.bob.service.change(t.id, RecordTypes.sessionUnwatched, copied);
    expect(await t.alice.service.unwatchedRound(t.id), 1);
    final same = [
      for (final e in reported(t.id))
        if (e.body['sealed'] == copied['sealed']) e,
    ];
    expect([for (final e in same) e.by], [_bob, _alice]);
    expect((await t.alice.service.unwatchedSessionOf(t.id, same.first))!.report, isNull);
    expect((await t.alice.service.unwatchedSessionOf(t.id, same.last))!.report!.reason, 'the sixth');
  });

  test('a report the record will never take is dropped, the others go, and what is kept there and is no report is '
      'left alone', () async {
    final t = await team();
    final store = LocalStateStore(await t.alice.db(t.id));
    await keep(t.alice, t.id, t.production, reason: 'a real one');
    // As if kept for a Crate that is gone, and before the real one.
    await store.write(
        '${kUnwatchedState}gone',
        jsonEncode({'crate': 'no-such-crate', 'at': clock - 60, 'gen': 1, 'sealed': base64Encode(List.filled(40, 9))}));
    // Things that are no report.
    await store.write('${kUnwatchedState}text', 'not a report');
    await store.write('${kUnwatchedState}list', '[1,2]');
    await store.write('${kUnwatchedState}half', jsonEncode({'crate': t.production, 'gen': 1}));
    await store.write('${kUnwatchedState}unsealed', jsonEncode({'crate': t.production, 'at': clock, 'gen': 1}));
    await store.write(
        '${kUnwatchedState}untimed', jsonEncode({'crate': t.production, 'gen': 1, 'sealed': base64Encode([1, 2, 3])}));
    expect(await t.alice.service.unwatchedWaiting(t.id), 2);

    expect(await t.alice.service.unwatchedRound(t.id), 1);
    expect(await t.alice.service.unwatchedWaiting(t.id), 0);
    expect(reported(t.id), hasLength(1));
    final noReports = {
      for (final name in ['text', 'list', 'half', 'unsealed', 'untimed']) '$kUnwatchedState$name',
    };
    expect((await t.alice.kept(t.id)).keys.toSet(), noReports);
    // A fault of the server's own is no refusal: the report waits.
    await keep(t.alice, t.id, t.production, reason: 'another');
    server.fault = 503;
    await expectLater(t.alice.service.unwatchedRound(t.id), throwsA(isA<OrchardServerException>()));
    expect(await t.alice.service.unwatchedWaiting(t.id), 1);
    server.fault = null;
    // Nor is the server refusing the request for another reason.
    server.failNextAppend = const OrchardServerException(403, 'rules-unmet');
    await expectLater(t.alice.service.unwatchedRound(t.id), throwsA(isA<OrchardServerException>()));
    expect(await t.alice.service.unwatchedWaiting(t.id), 1);
    expect(await t.alice.service.unwatchedRound(t.id), 1);
    expect(reported(t.id), hasLength(2));
    // The server's own rules refuse one this device would have let through:
    // dropped as well, and the one after it still goes.
    await keep(t.alice, t.id, t.production, reason: 'refused there');
    clock += 60;
    await keep(t.alice, t.id, t.production, reason: 'taken');
    server.failNextAppend = const OrchardServerException(403, 'record-refused', reason: 'malformed session');
    expect(await t.alice.service.unwatchedRound(t.id), 1);
    expect(await t.alice.service.unwatchedWaiting(t.id), 0);
    expect(reported(t.id), hasLength(3));
    expect((await t.alice.service.unwatchedSessionOf(t.id, reported(t.id).last))!.report!.reason, 'taken');

    // Nothing waits: a round asks nothing, not even who is signed in (a
    // device whose account keys are not ready yet syncs without a word).
    final asked = server.asked;
    final noKeys = OrchardService(server: t.alice.server, databases: t.alice.databases, author: () async => null);
    expect(await noKeys.unwatchedRound(t.id), 0);
    expect(server.asked, asked);
  });

  test('a report is not sent before its session is said to run, and is taken back where it never does', () async {
    final t = await team();
    final store = LocalStateStore(await t.alice.db(t.id));
    Future<String> keepNotYet(String reason) => t.alice.service
        .keepUnwatchedReport(t.id, crateId: t.production, hostLabel: 'db-primary', reason: reason, reach: 'down');
    Future<List<String>> reasons() async => [
          for (final e in reported(t.id)) (await t.alice.service.unwatchedSessionOf(t.id, e))!.report!.reason,
        ];

    // Kept, under a name of its own, and left where it is: by a round, and
    // by the sync every device runs.
    final first = await keepNotYet('still connecting');
    expect(first, startsWith(kUnwatchedState));
    expect((await t.alice.kept(t.id)).keys, [first]);
    expect(await t.alice.service.unwatchedWaiting(t.id), 1);
    final asked = server.asked;
    expect(await t.alice.service.unwatchedRound(t.id), 0);
    expect(server.asked, asked, reason: 'nothing to send: nothing is asked');
    await t.alice.sync.syncAll();
    expect(reported(t.id), isEmpty);
    // One whose session runs goes, and the other stays.
    final ran = await keepNotYet('a session that ran');
    expect(ran, isNot(first));
    t.alice.service.unwatchedRan(ran);
    expect(await t.alice.service.unwatchedRound(t.id), 1);
    expect((await t.alice.kept(t.id)).keys, [first]);
    // Its session runs: it goes with the next round.
    t.alice.service.unwatchedRan(first);
    expect(await t.alice.service.unwatchedRound(t.id), 1);
    expect(await reasons(), ['a session that ran', 'still connecting']);
    expect(await t.alice.kept(t.id), isEmpty);

    // Its session never ran: taken back, and nothing of it is ever sent.
    // Whatever else the database keeps is left alone.
    final second = await keepNotYet('never connected');
    await store.write('something.else', 'kept');
    await t.alice.service.forgetUnwatchedReport(t.id, 'something.else');
    expect(await store.read('something.else'), 'kept');
    await t.alice.service.forgetUnwatchedReport(t.id, second);
    expect(await t.alice.kept(t.id), isEmpty);
    t.alice.service.unwatchedRan(second);
    expect(await t.alice.service.unwatchedRound(t.id), 0);
    // Taken back twice, or after it went: nothing happens.
    await t.alice.service.forgetUnwatchedReport(t.id, second);
    await t.alice.service.forgetUnwatchedReport(t.id, first);
    expect(await reasons(), ['a session that ran', 'still connecting']);

    // The app ended without saying what became of a session. Started
    // again, it finds the report and sends it: better one report too many
    // than a session nobody hears of.
    await keepNotYet('the app was closed');
    expect(await t.alice.service.unwatchedRound(t.id), 0);
    debugUnwatchedNewRun();
    expect(await t.alice.service.unwatchedRound(t.id), 1);
    expect(await reasons(), ['a session that ran', 'still connecting', 'the app was closed']);
  });

  test('a sync does not fail for a report that cannot be sent just then: the report waits for the next one', () async {
    final t = await team();
    // How much of the server a sync asks when nothing waits (the second of
    // two: the first brings what the device did not have yet).
    await t.alice.sync.syncAll();
    final start = server.asked;
    await t.alice.sync.syncAll();
    final each = server.asked - start;

    // A report waits, and the server goes away right after the sync's own
    // questions: the sync itself is done, and says so.
    await keep(t.alice, t.id, t.production);
    server.downAfter = each;
    final reports = await t.alice.sync.syncAll();
    expect(reports.keys, [t.id]);
    expect(server.down, isTrue, reason: 'the round did ask, and got no answer');
    expect(await t.alice.service.unwatchedWaiting(t.id), 1);
    expect(reported(t.id), isEmpty);
    // The next sync that reaches the server sends it.
    server.down = false;
    await t.alice.sync.syncAll();
    expect(await t.alice.service.unwatchedWaiting(t.id), 0);
    expect(reported(t.id), hasLength(1));
  });
}
