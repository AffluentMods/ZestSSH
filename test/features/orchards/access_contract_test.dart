import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show kMaxAccessNoteLength;
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';

import 'fake_stream_server.dart' show eventually;

/// Access on request (3.0) against the REAL server routes on a real
/// Postgres: a member asks in words the server cannot read, whoever manages
/// the Crate gives it for a set time, the member's device holds it while it
/// runs and loses it the second the server's own clock passes its end, and
/// what the server does every five minutes after that (the key marked for
/// replacement) follows through. Also what the server refuses (a time its
/// clock does not take, an old sign-in, a sixth request, an answer from
/// someone with no say), and that a certificate the app signs for access
/// with an end is one the server takes. Start the server:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. A Firebase ID token there is
/// `fb:<uid>:<authTime>:<iat>`.

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
  _Device(this.me, this.storage, this.service, this.coordinator);

  final CrateAuthor me;
  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<List<String>> rows(String orchardId, String sql) async => [
        for (final r in await (await db(orchardId)).customSelect(sql).get()) r.data.values.join(':'),
      ];

  /// The Crates this device holds, with the level it has in each.
  Future<List<String>> crates(String orchardId) =>
      rows(orchardId, 'SELECT name, level FROM orchard_crates ORDER BY name');

  Future<List<String>> hosts(String orchardId) => rows(orchardId, 'SELECT id FROM connections ORDER BY id');

  /// How many generations of [crateId]'s key this device holds.
  Future<int> crateKeys(String orchardId, String crateId) async => (await (await db(orchardId)).customSelect(
        "SELECT COUNT(*) AS n FROM space_keys WHERE scope = 'crate' AND scope_id = ?",
        variables: [Variable(crateId)],
      ).getSingle())
          .read<int>('n');

  Future<void> addHost(String orchardId, String id, {required String crateId}) async {
    final d = await db(orchardId);
    await CratePlacement(d).setDefaultCrate(crateId);
    final at = DateTime(2026, 10, 1);
    await d.into(d.connections).insert(
        ConnectionsCompanion.insert(id: id, label: id, host: '192.0.2.10', createdAt: at, updatedAt: at));
  }
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1/?$'), '');
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];
  final lines = <OrchardStream>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Signed in [ago] before now.
  String token(String uid, {Duration ago = Duration.zero}) => 'fb:$uid:${now() - ago.inSeconds}:${now()}';

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
    OrchardService.debugNow = DateTime.now;
    for (final line in lines) {
      await line.dispose();
    }
    lines.clear();
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  String skip() => 'app contract server not running at $base';

  var accounts = 0;

  Future<CrateAuthor> account(String name) async {
    final uid = 'access-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  /// A device of [me]'s; [signedIn] ago, for a sign-in that is no longer
  /// recent.
  _Device device(CrateAuthor me, {Duration signedIn = Duration.zero}) {
    final storage = _MemoryStorage();
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server =
        OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid, ago: signedIn));
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    final d = _Device(
        me, storage, service, OrchardSyncCoordinator(service: service, server: server, databases: databases));
    devices.add(d);
    return d;
  }

  /// [uid]'s live line, what it hears in [heard].
  Future<void> line(String uid, List<OrchardStreamEvent> heard) async {
    final l = OrchardStream(
      url: OrchardStream.urlFor(base),
      connect: (url) => WebSocket.connect(url.toString()),
      token: ({bool fresh = false}) async => token(uid),
      session: () => null,
      retryDelay: (_, _) => const Duration(seconds: 1),
    );
    l.events.listen(heard.add);
    lines.add(l);
    l.start();
    await eventually(() => heard.whereType<StreamConnected>().isNotEmpty);
  }

  /// An Orchard of [owner]'s with Production (which the first role, Member,
  /// uses) and Staging (which only the owner opens), and [members] in it.
  Future<({String id, String production, String staging, String member})> orchard(
      _Device owner, List<_Device> members) async {
    final id = await owner.service.createOrchard('Access', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = (await owner.service.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final staging = await owner.service.createCrate(id, 'Staging');
    final member = (await owner.service.roles(id)).single.id;
    for (final m in members) {
      await owner.service.invite(id, email: '${m.me.uid}@example.com', role: member);
      await m.service.acceptInvite((await m.service.myInvites()).single.id);
      await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
      expect(await m.service.refresh(), contains(id));
    }
    return (id: id, production: production, staging: staging, member: member);
  }

  Matcher answered(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));

  /// The Crates the server lists for [d]'s account in [orchardId], by id,
  /// with whether each waits for a new key.
  Future<Map<String, bool>> listed(_Device d, String orchardId) async => {
        for (final c in (await d.service.server.orchards()).firstWhere((x) => x.id == orchardId).crates)
          c.id: c.rotationDue,
      };

  test('asked in words the server cannot read, given, used, and over the second its time comes', () async {
    if (!serverUp) return markTestSkipped(skip());
    final o = device(await account('owner'));
    final a = device(await account('alice'));
    final t = await orchard(o, [a]);
    await o.addHost(t.id, 'staging-db', crateId: t.staging);
    expect((await o.coordinator.syncAll())[t.id]!.sent, 1);
    await a.coordinator.syncAll();
    expect(await a.crates(t.id), ['Production:use']);

    final ownerHeard = <OrchardStreamEvent>[];
    final aliceHeard = <OrchardStreamEvent>[];
    await line(o.me.uid, ownerHeard);
    await line(a.me.uid, aliceHeard);

    // She asks for a Crate she cannot name: whoever can answer hears at once.
    await a.service.requestAccess(t.id,
        level: CrateLevel.use, duration: const Duration(hours: 2), note: '  Staging, for the release  ');
    await eventually(() => ownerHeard.whereType<AccessRequestsChanged>().isNotEmpty);
    await eventually(() => aliceHeard.whereType<AccessRequestsChanged>().isNotEmpty);
    final raw = (await o.service.server.accessRequests(t.id)).waiting.single;
    expect(raw.uid, a.me.uid);
    expect(utf8.decode(raw.noteEnc!, allowMalformed: true), isNot(contains('Staging')),
        reason: 'the server holds the note, and cannot read it');
    final waiting = (await o.service.accessRequests(t.id)).waiting.single;
    expect((waiting.uid, waiting.note, waiting.noteUnread, waiting.crateId, waiting.level, waiting.duration),
        (a.me.uid, 'Staging, for the release', false, null, CrateLevel.use, const Duration(hours: 2)));
    expect(waiting.expiresAt, closeTo(now() + 7 * 86400, 10));
    var hers = await a.service.accessRequests(t.id);
    expect(hers.waiting, isEmpty);
    expect((hers.mine.single.id, hers.mine.single.uid, hers.mine.single.note),
        (waiting.id, null, 'Staging, for the release'));

    // Asking again for the same changes the request there is.
    await a.service.requestAccess(t.id,
        level: CrateLevel.edit, duration: const Duration(minutes: 30), note: 'Staging, to fix the release');
    final again = (await o.service.accessRequests(t.id)).waiting.single;
    expect((again.id, again.level, again.duration, again.note),
        (waiting.id, CrateLevel.edit, const Duration(minutes: 30), 'Staging, to fix the release'));

    // The owner picks the Crate she means and gives it, naming the request:
    // it goes with the answer, and her devices hear of both.
    ownerHeard.clear();
    aliceHeard.clear();
    await o.service.giveAccess(t.id,
        uid: a.me.uid, crateId: t.staging, level: again.level, duration: again.duration, requestId: again.id);
    await eventually(() =>
        aliceHeard.whereType<OrchardsChanged>().isNotEmpty && aliceHeard.whereType<AccessRequestsChanged>().isNotEmpty);
    expect((await o.service.accessRequests(t.id)).waiting, isEmpty);
    // Her device has not synced since: word of the request is all it had.
    // It reads the record before it would call the request declined.
    hers = await a.service.accessRequests(t.id);
    expect(hers.mine, isEmpty);
    expect(await a.service.takeAccessNotices(t.id, requests: hers), isEmpty,
        reason: 'answered with access: the record says so, and nothing is told of the request itself');

    // On her device: the Crate at the level given, with its key and its host.
    await a.coordinator.syncAll();
    expect(await a.crates(t.id), ['Production:use', 'Staging:edit']);
    expect(await a.crateKeys(t.id, t.staging), 1);
    expect(await a.hosts(t.id), ['staging-db']);
    for (final d in [o, a]) {
      final held = (await d.service.timedAccess(t.id)).single;
      expect((held.uid, held.crateId, held.level, held.wholeCrate, held.canEnd),
          (a.me.uid, t.staging, CrateLevel.edit, true, true));
      expect(held.until, closeTo(now() + 1800, 10));
    }
    expect(await a.service.nextAccessEnd(), closeTo(now() + 1800, 10));
    expect(await listed(a, t.id), {t.production: false, t.staging: false});
    // (As the app does after each sync: nothing to tell, and the name of
    // what she holds until a set time is kept for the day it leaves.)
    expect(await a.service.takeAccessNotices(t.id), isEmpty);

    // What she writes there the server takes, and the owner's device too.
    await a.addHost(t.id, 'staging-web', crateId: t.staging);
    final sent = await a.coordinator.syncOne(t.id);
    expect((sent.sent, sent.rejected), (1, 0));
    final got = await o.coordinator.syncOne(t.id);
    expect((got.received, got.rejected), (1, 0));
    expect(await o.hosts(t.id), ['staging-db', 'staging-web']);

    // Given anew with an end a few seconds away (the app gives five minutes
    // at least; the record and the server take any moment still to come).
    final until = now() + 6;
    await o.service.change(t.id, RecordTypes.accessGrant, {
      'uid': a.me.uid,
      'crate': t.staging,
      'switches': switchList(levelSwitches(CrateLevel.edit)),
      'until': until,
    });
    await a.coordinator.syncAll();
    expect((await a.service.timedAccess(t.id)).single.until, until);
    expect(await a.crates(t.id), ['Production:use', 'Staging:edit']);

    // Its time comes, by the server's own clock: it stops listing the Crate
    // for her and gives her nothing of it, before any job has run.
    await Future<void>.delayed(Duration(seconds: until - now() + 2));
    expect(await listed(a, t.id), {t.production: false});
    await expectLater(a.service.server.changes(t.staging, since: 0), answered('not-found'));
    await a.coordinator.syncAll();
    expect(await a.crates(t.id), ['Production:use']);
    expect(await a.crateKeys(t.id, t.staging), 0);
    expect(await a.hosts(t.id), isEmpty);
    expect(await a.service.timedAccess(t.id), isEmpty);
    expect(await a.service.nextAccessEnd(), isNull);
    final notices = await a.service.takeAccessNotices(t.id);
    expect([for (final n in notices) (n.kind, n.crateId, n.crateName)], [(AccessNoticeKind.over, t.staging, 'Staging')]);
    expect(await a.service.takeAccessNotices(t.id), isEmpty, reason: 'told once');

    // What the server does every five minutes: the Crate's key waits to be
    // replaced, the members hear of it, and the owner's device makes the new
    // key, which goes to the owner alone.
    expect(await listed(o, t.id), {t.production: false, t.staging: false});
    ownerHeard.clear();
    aliceHeard.clear();
    final job = await client.post(Uri.parse('$root/test/access/ended'));
    // (Both of them, and whoever an earlier run on this server left behind.)
    expect((jsonDecode(job.body) as Map)['told'], greaterThanOrEqualTo(2));
    await eventually(() => ownerHeard.whereType<OrchardsChanged>().isNotEmpty);
    await eventually(() => aliceHeard.whereType<OrchardsChanged>().isNotEmpty);
    expect(await listed(o, t.id), {t.production: false, t.staging: true});
    await o.service.refresh();
    expect(await o.service.rotateDue(t.id), isEmpty);
    expect(await listed(o, t.id), {t.production: false, t.staging: false});
    expect((await o.service.server.orchards()).firstWhere((x) => x.id == t.id).crates
        .firstWhere((c) => c.id == t.staging).keyGeneration, 2);
    // Run again, there is nothing left to do.
    final idle = await client.post(Uri.parse('$root/test/access/ended'));
    expect(jsonDecode(idle.body), {'ok': true, 'told': 0});
    await a.coordinator.syncAll();
    expect(await a.crates(t.id), ['Production:use']);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('ended early by whoever manages the Crate or by the member; the server holds times to its own clock, '
      'and giving to a recent sign-in', () async {
    if (!serverUp) return markTestSkipped(skip());
    final owner = await account('owner');
    final o = device(owner);
    final a = device(await account('alice'));
    final b = device(await account('bob'));
    final t = await orchard(o, [a, b]);
    Future<void> give(Duration duration, {_Device? by, CrateLevel level = CrateLevel.use}) => (by ?? o)
        .service
        .giveAccess(t.id, uid: a.me.uid, crateId: t.staging, level: level, duration: duration);

    // A device far behind or far ahead is told so; a few minutes are taken.
    OrchardService.debugNow = () => DateTime.now().subtract(const Duration(hours: 3));
    await expectLater(give(const Duration(hours: 2)), answered('access-until-passed'));
    OrchardService.debugNow = () => DateTime.now().add(const Duration(days: 2));
    await expectLater(give(const Duration(days: 30)), answered('access-too-long'));
    OrchardService.debugNow = () => DateTime.now().add(const Duration(minutes: 4));
    await give(const Duration(days: 30));
    OrchardService.debugNow = DateTime.now;
    await a.service.refresh();
    expect(await a.crates(t.id), ['Production:use', 'Staging:use']);

    // Giving needs a sign-in from the last few minutes; ending does not.
    final stale = device(owner, signedIn: const Duration(hours: 3));
    await stale.service.refresh();
    await expectLater(give(const Duration(hours: 1), by: stale, level: CrateLevel.edit),
        throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'recent sign-in', isTrue)));
    expect((await o.service.timedAccess(t.id)).single.level, CrateLevel.use, reason: 'nothing changed');

    // Bob, a member like her, ends nothing of hers: his own device refuses,
    // and so does the server when asked past it.
    await b.service.refresh();
    await expectLater(b.service.endAccess(t.id, uid: a.me.uid, crateId: t.staging),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'ending access to a Crate needs manage on it')));

    // The owner ends it early, from the device whose sign-in is old.
    await stale.service.endAccess(t.id, uid: a.me.uid, crateId: t.staging);
    await a.service.refresh();
    expect(await a.crates(t.id), ['Production:use']);
    expect(await a.crateKeys(t.id, t.staging), 0);
    expect(await listed(o, t.id), {t.production: false, t.staging: true}, reason: 'a new key is due at once');
    expect(await a.service.takeAccessNotices(t.id), isEmpty, reason: 'ended on purpose is not "your time is over"');

    // Given again, she gives it up herself.
    expect(await o.service.rotateDue(t.id), isEmpty);
    await give(const Duration(hours: 1));
    await a.service.refresh();
    expect(await a.crates(t.id), ['Production:use', 'Staging:use']);
    expect(await a.crateKeys(t.id, t.staging), 2, reason: 'every generation of the key');
    await a.service.endAccess(t.id, uid: a.me.uid, crateId: t.staging);
    expect(await a.crates(t.id), ['Production:use']);
    await expectLater(a.service.server.changes(t.staging, since: 0), answered('not-found'));

    // More in a Crate she opens: the level rises, and the key was hers already.
    await o.service.giveAccess(t.id,
        uid: a.me.uid, crateId: t.production, level: CrateLevel.edit, duration: const Duration(minutes: 30));
    await a.service.refresh();
    expect(await a.crates(t.id), ['Production:edit']);
    final more = (await o.service.timedAccess(t.id)).single;
    expect(more.wholeCrate, isFalse);
    expect(more.adds, {CrateSwitches.add, CrateSwitches.edit, CrateSwitches.delete});
    await a.addHost(t.id, 'web-2', crateId: t.production);
    final sent = await a.coordinator.syncOne(t.id);
    expect((sent.sent, sent.rejected), (1, 0));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('who may ask, how much may wait, and who may answer', () async {
    if (!serverUp) return markTestSkipped(skip());
    final o = device(await account('owner'));
    final a = device(await account('alice'));
    final b = device(await account('bob'));
    final l = device(await account('lead'));
    final t = await orchard(o, [a, b]);
    // A lead manages Staging and ranks above Member.
    final leads = await o.service
        .saveRole(t.id, name: 'Lead', can: const {}, crates: {t.staging: levelSwitches(CrateLevel.manage)});
    await o.service.moveRole(t.id, leads, up: true);
    await o.service.invite(t.id, email: '${l.me.uid}@example.com', role: leads);
    await l.service.acceptInvite((await l.service.myInvites()).single.id);
    await o.service.confirmInvite(t.id, (await o.service.invites(t.id)).single);
    await l.service.refresh();
    for (final d in [a, b]) {
      await d.service.refresh();
    }

    // An owner opens every Crate one could be given.
    await expectLater(
        o.service.requestAccess(t.id, crateId: t.staging, level: CrateLevel.use, duration: const Duration(hours: 1)),
        answered('access-not-needed'));

    // The longest note, in a script that takes four bytes a character.
    final orange = String.fromCharCode(0x1F34A) * kMaxAccessNoteLength;
    await a.service.requestAccess(t.id, level: CrateLevel.use, duration: const Duration(hours: 1), note: orange);
    await a.service.requestAccess(t.id,
        crateId: t.production, level: CrateLevel.edit, duration: const Duration(hours: 1));
    expect([for (final r in (await a.service.accessRequests(t.id)).mine) (r.crateId, r.note)],
        unorderedEquals([(null, orange), (t.production, null)]));

    // The lead is asked about the one that names no Crate (they manage one),
    // not about Production; bob, who manages nothing, about neither.
    expect([for (final r in (await l.service.accessRequests(t.id)).waiting) (r.uid, r.crateId, r.note)],
        [(a.me.uid, null, orange)]);
    final his = await b.service.accessRequests(t.id);
    expect(his.mine, isEmpty);
    expect(his.waiting, isEmpty);
    expect((await b.service.server.accessRequests(t.id)).waiting, isEmpty, reason: 'the server lists none for him');
    expect([for (final r in (await o.service.accessRequests(t.id)).waiting) r.crateId],
        unorderedEquals([null, t.production]));

    // Someone with no say declines nothing: to the server it is not there.
    final forProduction =
        (await o.service.accessRequests(t.id)).waiting.firstWhere((r) => r.crateId == t.production).id;
    final unnamed = (await o.service.accessRequests(t.id)).waiting.firstWhere((r) => r.crateId == null).id;
    await expectLater(b.service.declineAccessRequest(t.id, unnamed), answered('not-found'));
    await expectLater(l.service.declineAccessRequest(t.id, forProduction), answered('not-found'));
    expect((await o.service.accessRequests(t.id)).waiting, hasLength(2));

    // The lead declines the one that is theirs to answer: she is told, once.
    Future<List<AccessNoticeKind>> told(_Device d) async => [
          for (final n in await d.service.takeAccessNotices(t.id, requests: await d.service.accessRequests(t.id)))
            n.kind,
        ];
    expect(await told(a), isEmpty, reason: 'they wait');
    await l.service.declineAccessRequest(t.id, unnamed);
    expect(await told(a), [AccessNoticeKind.declined]);
    expect(await told(a), isEmpty);
    // She withdraws the other herself: nothing to be told.
    await a.service.withdrawAccessRequest(t.id, forProduction);
    expect((await o.service.accessRequests(t.id)).waiting, isEmpty);
    expect(await told(a), isEmpty);
    await expectLater(a.service.withdrawAccessRequest(t.id, forProduction), answered('not-found'));

    // The lead gives Staging, and not Production, which is not theirs to give.
    await l.service.giveAccess(t.id,
        uid: a.me.uid, crateId: t.staging, level: CrateLevel.use, duration: const Duration(hours: 1));
    await expectLater(
        l.service.giveAccess(t.id,
            uid: a.me.uid, crateId: t.production, level: CrateLevel.edit, duration: const Duration(hours: 1)),
        throwsA(isA<OrchardRecordRefused>()));
    await a.service.refresh();
    expect(await a.crates(t.id), ['Production:use', 'Staging:use']);

    // Five wait at most.
    final extra = [for (var i = 0; i < 5; i++) await o.service.createCrate(t.id, 'Extra $i')];
    await b.service.refresh();
    Future<void> ask(String crateId) =>
        b.service.requestAccess(t.id, crateId: crateId, level: CrateLevel.use, duration: const Duration(hours: 1));
    for (final crateId in extra) {
      await ask(crateId);
    }
    await expectLater(ask(t.staging), answered('request-limit'));
    // One of the five again is still one of the five.
    await ask(extra.first);
    expect((await b.service.accessRequests(t.id)).mine, hasLength(5));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a certificate ends with the access it rests on, and the server takes it', () async {
    if (!serverUp) return markTestSkipped(skip());
    final o = device(await account('owner'));
    final a = device(await account('alice'));
    final t = await orchard(o, [a]);
    final vault = await o.service.createCrate(t.id, 'Owner keys', ownersOnly: true);
    // Staging signs certificates that would last a day.
    await o.service.setAuthorityKey(t.id, t.staging,
        keyCrate: vault,
        ttlMinutes: 1440,
        principals: {
          t.member: ['deploy'],
          FixedRoles.owner: ['root'],
        },
        keyLabel: 'Staging authority');
    expect((await o.coordinator.syncAll())[t.id]!.sent, greaterThanOrEqualTo(1));

    // She is given Staging for an hour: her certificate lasts exactly as long.
    await o.service.giveAccess(t.id,
        uid: a.me.uid, crateId: t.staging, level: CrateLevel.connect, duration: const Duration(hours: 1));
    await a.coordinator.syncAll();
    final until = (await a.service.timedAccess(t.id)).single.until;
    await a.service.askForCertificate(t.id, t.staging);
    expect(await o.service.signWaitingCertificates(t.id), 1, reason: 'the server took what the owner signed');
    final pair = await a.service.teamCertificateKey(t.id, t.staging, userName: 'deploy', wait: Duration.zero)
        as SshCertificateKeyPair;
    expect(pair.certificate.validBefore, until);
    expect(pair.certificate.principals, ['deploy']);

    // Ended early: the certificate is no longer one she may use, and the
    // server takes no new request from her.
    await o.service.endAccess(t.id, uid: a.me.uid, crateId: t.staging);
    await a.service.refresh();
    await expectLater(
      a.service.teamCertificateKey(t.id, t.staging, userName: 'deploy', wait: Duration.zero),
      throwsA(isA<TeamCertificateUnavailable>()),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
