// Who a session can be shared with (session_shares.dart): worked out from
// the Orchard's record and the keys this device has pinned, against an
// Orchard built the way the app builds one (the same in-memory server the
// Orchard tests use). And the registry of the sessions being shared: what
// the session's terminal feeds, and what ends with what.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../orchards/fake_crate_server.dart';
import 'share_fakes.dart';

const _dana = 'uid-dana';
const _sam = 'uid-sam';
const _kit = 'uid-kit';
const _noa = 'uid-noa';
const _eve = 'uid-eve';
const _mal = 'uid-mal';
const _everyone = [_dana, _sam, _kit, _noa, _eve, _mal];

const hostId = 'h-web1';

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
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    service = OrchardService(
      server: server,
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: databases);
  }

  final String uid;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

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
  final closing = <AppDatabase>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    for (final uid in _everyone) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _dana);
    for (final uid in _everyone) {
      await server.publish(uid, keys[uid]!, email: '${uid.substring(4)}@example.com');
    }
    SessionShares.reset();
  });

  tearDown(() async {
    SessionShares.reset();
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
    for (final db in closing) {
      await db.close();
    }
    closing.clear();
  });

  _Device device(String uid) {
    final d = _Device(server, uid, keys[uid]!);
    devices.add(d);
    return d;
  }

  Future<void> join(_Device by, String uid, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${uid.substring(4)}@example.com', role: role);
    final invite = (await by.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, uid);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
  }

  Future<void> addHost(AppDatabase db, String id) async {
    final at = DateTime(2026, 10, 1);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: 'Web 1',
          host: 'web1.example.com',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
  }

  /// dana's Orchard. Production: sam and kit use it, noa connects only, mal
  /// uses it and is suspended. Staging: eve.
  Future<({String id, String production, String staging, _Device dana})> orchard() async {
    final dana = device(_dana);
    final id = await dana.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await dana.service.createCrate(id, 'Staging');
    final member = server.recordOf(id).roles.values.single;
    final production = member.crates.keys.single;
    final watchers = await dana.service
        .saveRole(id, name: 'Watchers', can: {}, crates: {production: levelSwitches(CrateLevel.connect)});
    final ops =
        await dana.service.saveRole(id, name: 'Ops', can: {}, crates: {staging: levelSwitches(CrateLevel.edit)});
    await join(dana, _sam, id, member.id);
    await join(dana, _kit, id, member.id);
    await join(dana, _noa, id, watchers);
    await join(dana, _eve, id, ops);
    await join(dana, _mal, id, member.id);
    await dana.service.suspendMember(id, _mal);
    await dana.service.refresh();
    await addHost(await dana.db(id), hostId);
    return (id: id, production: production, staging: staging, dana: dana);
  }

  group('who a session can be shared with', () {
    test('a host in your Tree, or in an Orchard this device knows nothing of yet, is not one to share', () async {
      final tree = AppDatabase.forTesting(NativeDatabase.memory());
      closing.add(tree);
      await addHost(tree, hostId);
      expect(await shareContextFor(tree, hostId, myUid: _dana, nowSeconds: now()), isNull);
      final empty = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      closing.add(empty);
      expect(await shareContextFor(empty, hostId, myUid: _dana, nowSeconds: now()), isNull);
    });

    test('everyone who can open the host\'s Crate now, by name; those who cannot are named too', () async {
      final o = await orchard();
      final db = await o.dana.db(o.id);
      final c = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: now()))!;
      expect((c.orchardId, c.crateId, c.crateName, c.connectionId, c.myUid), (o.id, o.production, 'Production', hostId, _dana));
      // In the order of their addresses; dana herself and the suspended mal
      // are nowhere.
      expect(c.people.map((p) => (p.uid, p.email, p.level)), [
        (_kit, 'kit@example.com', CrateLevel.use),
        (_noa, 'noa@example.com', CrateLevel.connect),
        (_sam, 'sam@example.com', CrateLevel.use),
      ]);
      expect(c.people.map((p) => p.watchOnly), [false, true, false]);
      expect(c.people.every((p) => !p.keysChanged), isTrue);
      expect(c.withoutAccess, ['eve@example.com']);
      expect(c.sessionLogs, isFalse);
      // The keys are the ones each of them published.
      final sam = c.people.last.party!;
      expect((sam.uid, sam.keyVersion, sam.keysChanged), (_sam, keys[_sam]!.version, false));
      expect(sam.signingKey, keys[_sam]!.signingPublicKey);
      expect(sam.encryptionKey, keys[_sam]!.encryption.publicKey);

      // As sam sees it from his device, once the host has reached it: dana
      // is one of the people.
      await o.dana.coordinator.syncAll();
      final samDevice = device(_sam);
      await samDevice.coordinator.syncAll();
      final samDb = await samDevice.db(o.id);
      final forSam = (await shareContextFor(samDb, hostId, myUid: _sam, nowSeconds: now()))!;
      expect(forSam.people.map((p) => p.uid), [_dana, _kit, _noa]);
      expect(forSam.myUid, _sam);
    });

    test('a host in another Crate is shared with that Crate\'s people', () async {
      final o = await orchard();
      final db = await o.dana.db(o.id);
      await addHost(db, 'h-staging');
      await (await o.dana.coordinator.engineFor(o.id, author: CrateAuthor(uid: _dana, keys: keys[_dana]!)))
          .moveItem('host', 'h-staging', o.staging);
      final c = (await shareContextFor(db, 'h-staging', myUid: _dana, nowSeconds: now()))!;
      expect((c.crateId, c.crateName), (o.staging, 'Staging'));
      expect(c.people.map((p) => (p.uid, p.level)), [(_eve, CrateLevel.edit)]);
      expect(c.withoutAccess, ['kit@example.com', 'noa@example.com', 'sam@example.com']);
      // A Crate the record does not have (a copy of the Orchard that is
      // behind): nothing is shared from it.
      await db.customStatement("UPDATE crate_items_meta SET crate_id = 'no-such-crate' WHERE item_key = 'h-staging'");
      expect(await shareContextFor(db, 'h-staging', myUid: _dana, nowSeconds: now()), isNull);
    });

    test('whether the others have the host yet, and whether the Crate logs sessions', () async {
      final o = await orchard();
      final db = await o.dana.db(o.id);
      expect((await shareContextFor(db, hostId, myUid: _dana, nowSeconds: now()))!.synced, isFalse);
      await o.dana.coordinator.syncAll();
      expect((await shareContextFor(db, hostId, myUid: _dana, nowSeconds: now()))!.synced, isTrue);
      await o.dana.service.setCrateSessionLogs(o.id, o.production, true);
      expect((await shareContextFor(db, hostId, myUid: _dana, nowSeconds: now()))!.sessionLogs, isTrue);
    });

    test('someone whose access has ended cannot be invited, from the moment it ends', () async {
      final o = await orchard();
      final db = await o.dana.db(o.id);
      final ends = now() + 3600;
      await o.dana.service.setMemberEndsAt(o.id, _sam, ends);
      final before = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: ends - 1))!;
      expect(before.people.map((p) => p.uid), [_kit, _noa, _sam]);
      final after = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: ends))!;
      expect(after.people.map((p) => p.uid), [_kit, _noa]);
      expect(after.withoutAccess, ['eve@example.com', 'sam@example.com']);
    });

    test('someone given the Crate until a set time can be invited while it runs, at the level they hold then',
        () async {
      final o = await orchard();
      final db = await o.dana.db(o.id);
      // eve opens Staging only and is given Production for an hour; noa, who
      // only connects there, is given more for two.
      await o.dana.service.giveAccess(o.id,
          uid: _eve, crateId: o.production, level: CrateLevel.use, duration: const Duration(hours: 1));
      await o.dana.service.giveAccess(o.id,
          uid: _noa, crateId: o.production, level: CrateLevel.use, duration: const Duration(hours: 2));
      final record = server.recordOf(o.id);
      final eveEnds = record.members[_eve]!.timed[o.production]!.until;
      final noaEnds = record.members[_noa]!.timed[o.production]!.until;

      final during = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: eveEnds - 1))!;
      expect(during.people.map((p) => (p.uid, p.level, p.watchOnly)), [
        (_eve, CrateLevel.use, false),
        (_kit, CrateLevel.use, false),
        (_noa, CrateLevel.use, false),
        (_sam, CrateLevel.use, false),
      ]);
      expect(during.withoutAccess, isEmpty);

      // eve's time comes: she can no longer be invited. noa still holds more.
      final after = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: eveEnds))!;
      expect(after.people.map((p) => (p.uid, p.level)), [
        (_kit, CrateLevel.use),
        (_noa, CrateLevel.use),
        (_sam, CrateLevel.use),
      ]);
      expect(after.withoutAccess, ['eve@example.com']);

      // noa's time comes: back to watching only.
      final later = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: noaEnds))!;
      expect(later.people.map((p) => (p.uid, p.level, p.watchOnly)), [
        (_kit, CrateLevel.use, false),
        (_noa, CrateLevel.connect, true),
        (_sam, CrateLevel.use, false),
      ]);
    });

    test('nothing is shared with someone whose keys this device cannot vouch for', () async {
      final o = await orchard();
      final db = await o.dana.db(o.id);
      ShareCandidate of(ShareContext c, String uid) => c.people.firstWhere((p) => p.uid == uid);

      // sam replaced his keys since dana compared them, and nobody here has
      // compared the new ones.
      await db.customStatement(
          "UPDATE member_keys SET replaced_since_compared = 1, verified_by_me = 0, verified_by = '[]' WHERE uid = ?",
          [_sam]);
      // kit's new keys wait after a hard stop.
      final fresh = await AccountKeys.generate();
      await db.customStatement('UPDATE member_keys SET pending_keys = ? WHERE uid = ?',
          [jsonEncode((await fresh.publish(_kit)).toJson()), _kit]);
      // This device has no keys for noa at all.
      await db.customStatement('UPDATE member_keys SET key_version = NULL WHERE uid = ?', [_noa]);

      var c = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: now()))!;
      expect(c.people.map((p) => (p.uid, p.keysChanged)), [(_kit, true), (_noa, true), (_sam, true)]);
      expect(of(c, _sam).party!.keysChanged, isTrue);
      expect(of(c, _kit).party!.keysChanged, isTrue);
      expect(of(c, _noa).party, isNull);
      expect((await sharePartyOf(db, _sam, myUid: _dana))!.keysChanged, isTrue);
      expect((await sharePartyOf(db, _kit, myUid: _dana))!.keysChanged, isTrue);
      expect(await sharePartyOf(db, _noa, myUid: _dana), isNull);
      expect(await sharePartyOf(db, 'uid-nobody', myUid: _dana), isNull);

      // dana compares sam's new keys: he can be invited again.
      await db.customStatement('UPDATE member_keys SET verified_by_me = 1 WHERE uid = ?', [_sam]);
      c = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: now()))!;
      expect(of(c, _sam).keysChanged, isFalse);
      final party = (await sharePartyOf(db, _sam, myUid: _dana))!;
      expect((party.uid, party.keyVersion, party.keysChanged), (_sam, keys[_sam]!.version, false));
      expect(party.signingKey, keys[_sam]!.signingPublicKey);
      expect(party.encryptionKey, keys[_sam]!.encryption.publicKey);

      // Someone who left keeps their pinned keys (what they signed still
      // checks out), and is not someone to share with.
      await o.dana.service.removeMember(o.id, _sam);
      c = (await shareContextFor(db, hostId, myUid: _dana, nowSeconds: now()))!;
      expect(c.people.map((p) => p.uid), [_kit, _noa]);
      expect(c.withoutAccess, ['eve@example.com']);
      expect((await sharePartyOf(db, _sam, myUid: _dana))?.keysChanged, isTrue,
          reason: 'not among the members shown: never vouched for');
    });
  });

  group('the sessions being shared', () {
    late AccountKeys dana;
    late AccountKeys sam;
    const orchardId = '22222222-2222-4222-8222-222222222222';
    const crateId = '33333333-3333-4333-8333-333333333333';

    setUp(() {
      dana = keys[_dana]!;
      sam = keys[_sam]!;
    });

    /// A share of dana's with sam, on a relay in memory; [watch] has sam's
    /// device watching it.
    Future<
        ({
          ShareHostController host,
          FakeShareRelay relay,
          FakeShareApi api,
          SharedTerminal terminal,
          ShareViewerController? viewer,
        })> share(String shareId, {bool watch = false}) async {
      final relay = FakeShareRelay();
      final api = FakeShareApi();
      final terminal = SharedTerminal();
      final pinned = {_sam: partyOf(_sam, sam)};
      final record = teamRecord(orchardId, crateId, {_dana: dana, _sam: sam});
      final host = await ShareHostController.start(
        shareId: shareId,
        mode: ShareMode.live,
        orchardId: orchardId,
        crateId: crateId,
        connectionId: hostId,
        people: [pinned[_sam]!],
        myUid: _dana,
        keys: dana,
        api: api,
        link: relay.host(),
        record: () async => record,
        party: (uid) async => pinned[uid],
        terminal: terminal,
        keyboardRequests: true,
      );
      addTearDown(() async {
        if (!host.isEnded) await host.stop();
      });
      ShareViewerController? viewer;
      if (watch) {
        final invitation =
            await SignedShareInvitation.open(api.created.single.invites[_sam]!, sam.encryption, shareId: shareId);
        viewer = ShareViewerController(invitation: invitation, keys: sam, link: relay.viewer(_sam));
        addTearDown(viewer.dispose);
        viewer.start();
        final v = viewer;
        await until(() => v.phase == ShareViewPhase.watching, what: 'sam watching');
      }
      return (host: host, relay: relay, api: api, terminal: terminal, viewer: viewer);
    }

    const one = '11111111-1111-4111-8111-111111111111';
    const two = '11111111-1111-4111-8111-222222222222';

    test('a shared session is listed, named, and fed what its terminal shows', () async {
      final announced = <List<String>>[];
      void listener() => announced.add(SessionShares.active.value.keys.toList());
      SessionShares.active.addListener(listener);
      addTearDown(() => SessionShares.active.removeListener(listener));

      expect(SessionShares.of('s-1'), isNull);
      expect(SessionShares.active.value, isEmpty);
      // Nothing is shared: what a terminal shows goes nowhere, quietly.
      SessionShares.output('s-1', 'nobody');
      SessionShares.resized('s-1', 80, 24);
      SessionShares.sessionClosed('s-1');
      await SessionShares.stop('s-1');
      SessionShares.addNames('s-1', {_sam: 'sam@example.com'});
      expect(SessionShares.nameOf('s-1', _sam), _sam, reason: 'names are kept for shared sessions only');
      expect(announced, isEmpty);

      final s = await share(one, watch: true);
      SessionShares.add('s-1', s.host, names: {_sam: 'sam@example.com'});
      expect(SessionShares.of('s-1'), same(s.host));
      expect(announced, [
        ['s-1']
      ]);
      expect(SessionShares.nameOf('s-1', _sam), 'sam@example.com');
      expect(SessionShares.nameOf('s-1', _kit), _kit, reason: 'the id when no address is known');
      SessionShares.addNames('s-1', {_kit: 'kit@example.com'});
      expect(SessionShares.nameOf('s-1', _kit), 'kit@example.com');
      expect(SessionShares.nameOf('s-2', _sam), _sam);
      expect(() => SessionShares.active.value['s-9'] = s.host, throwsUnsupportedError,
          reason: 'what is published cannot be changed from outside');

      // What the session's terminal shows reaches the person watching;
      // another session's does not.
      s.terminal.terminal.write('uptime\r\n');
      SessionShares.output('s-1', 'uptime\r\n');
      SessionShares.output('s-2', 'from another session\r\n');
      s.terminal.terminal.resize(70, 20);
      SessionShares.resized('s-1', 70, 20);
      SessionShares.resized('s-2', 100, 40);
      await Future<void>.delayed(ShareHostController.gather * 3);
      await settle();
      sameScreen(s.terminal.terminal, s.viewer!.terminal);
      expect((s.viewer!.terminal.viewWidth, s.viewer!.terminal.viewHeight), (70, 20));
    });

    test('stopping one: it ends, is listed no more, and its names are forgotten', () async {
      final a = await share(one, watch: true);
      final b = await share(two);
      SessionShares.add('s-1', a.host, names: {_sam: 'sam@example.com'});
      SessionShares.add('s-2', b.host, names: {_sam: 'sam@example.com'});
      expect(SessionShares.active.value.keys, ['s-1', 's-2']);

      await SessionShares.stop('s-1');
      expect(a.host.isEnded, isTrue);
      expect(a.api.ended, [one]);
      expect(a.viewer!.end, ShareViewEnd.stopped);
      expect(SessionShares.of('s-1'), isNull);
      expect(SessionShares.active.value.keys, ['s-2']);
      expect(SessionShares.nameOf('s-1', _sam), _sam);
      expect(b.host.isEnded, isFalse);
      expect(SessionShares.nameOf('s-2', _sam), 'sam@example.com');
    });

    test('a session that closes ends its share, and those watching are told it closed', () async {
      final a = await share(one, watch: true);
      SessionShares.add('s-1', a.host);
      SessionShares.sessionClosed('s-1');
      expect(SessionShares.of('s-1'), isNull, reason: 'gone at once, not when the server has answered');
      expect(SessionShares.active.value, isEmpty);
      await until(() => a.viewer!.phase == ShareViewPhase.ended, what: 'the end');
      expect(a.viewer!.end, ShareViewEnd.sessionClosed);
      await until(() => a.api.ended.isNotEmpty);
      expect(a.api.ended, [one]);
    });

    test('a share that ends from the other side is listed no more', () async {
      final a = await share(one);
      final b = await share(two);
      SessionShares.add('s-1', a.host, names: {_sam: 'sam@example.com'});
      SessionShares.add('s-2', b.host);
      await settle();
      final announced = <List<String>>[];
      void listener() => announced.add(SessionShares.active.value.keys.toList());
      SessionShares.active.addListener(listener);
      addTearDown(() => SessionShares.active.removeListener(listener));

      // Something that is not the end changes nothing here.
      a.relay.dropHostLine();
      await settle();
      expect(announced, isEmpty);
      expect(SessionShares.of('s-1'), same(a.host));

      // ZestSSH Cloud ended it (its time ran out).
      a.relay.end();
      await until(() => a.host.isEnded);
      expect(a.host.endedBy, ShareLineEnd.ended);
      expect(SessionShares.of('s-1'), isNull);
      expect(announced, [
        ['s-2']
      ]);
      expect(SessionShares.nameOf('s-1', _sam), _sam);
      expect(a.api.ended, isEmpty, reason: 'there is nothing left to end');
    });

    test('sharing a session that is shared already replaces the share it had', () async {
      final a = await share(one, watch: true);
      final b = await share(two, watch: true);
      SessionShares.add('s-1', a.host, names: {_sam: 'sam@example.com'});
      SessionShares.add('s-1', b.host, names: {_kit: 'kit@example.com'});
      expect(SessionShares.of('s-1'), same(b.host));
      expect(SessionShares.active.value.keys, ['s-1']);
      expect(SessionShares.nameOf('s-1', _kit), 'kit@example.com');
      expect(SessionShares.nameOf('s-1', _sam), _sam, reason: 'the first share\'s names went with it');
      await until(() => a.viewer!.phase == ShareViewPhase.ended, what: 'the first share stopped');
      expect(a.viewer!.end, ShareViewEnd.stopped);
      await until(() => a.api.ended.isNotEmpty);
      // The first one ending does not take the second one off the list.
      await settle();
      expect(SessionShares.of('s-1'), same(b.host));
      expect(b.host.isEnded, isFalse);
      // What the terminal shows goes to the second, and nothing to the first.
      final before = a.relay.passed.length;
      b.terminal.terminal.write('for the second\r\n');
      SessionShares.output('s-1', 'for the second\r\n');
      await Future<void>.delayed(ShareHostController.gather * 3);
      await settle();
      sameScreen(b.terminal.terminal, b.viewer!.terminal);
      expect(a.relay.passed.length, before);
    });

    test('the app locks: nobody else types into a session whose owner is not looking, and watching goes on', () async {
      final a = await share(one, watch: true);
      final b = await share(two);
      SessionShares.add('s-1', a.host);
      SessionShares.add('s-2', b.host);
      expect(a.host.giveKeyboard(_sam), isTrue);
      await until(() => a.viewer!.isTyping, what: 'the keyboard');

      SessionShares.appLocked();
      expect(a.host.keyboardHolder, isNull);
      await until(() => !a.viewer!.isTyping, what: 'the keyboard back');
      a.viewer!.terminal.textInput('typed while locked');
      a.terminal.terminal.write('still shown\r\n');
      SessionShares.output('s-1', 'still shown\r\n');
      await Future<void>.delayed(ShareHostController.gather * 3);
      await settle();
      expect(a.terminal.typed, isEmpty);
      sameScreen(a.terminal.terminal, a.viewer!.terminal);
      expect(a.host.isEnded, isFalse);
      expect(SessionShares.active.value.keys, ['s-1', 's-2']);
    });

    test('signing out ends every share', () async {
      final a = await share(one, watch: true);
      final b = await share(two);
      SessionShares.add('s-1', a.host);
      SessionShares.add('s-2', b.host);
      await SessionShares.stopAll();
      expect(SessionShares.active.value, isEmpty);
      expect((a.host.isEnded, b.host.isEnded), (true, true));
      expect(a.api.ended, [one]);
      expect(b.api.ended, [two]);
      expect(a.viewer!.end, ShareViewEnd.stopped);
    });
  });
}
