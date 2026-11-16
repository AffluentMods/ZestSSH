import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'fake_crate_server.dart';

/// What the team records (3.0): an owner turns it on
/// or off in the record, and every other member's device tells its person
/// what is on now, whether it records more or less than before. Nobody is
/// told of their own change, the first look on a device only notes where
/// things stand, the same switches set again tell nobody, and only owners
/// may change it.

const _owner = 'owner-1';
const _alice = 'alice';

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
  _Device(FakeCrateServer shared, this.uid, this.keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final AccountKeys keys;
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
  final l10n = lookupAppLocalizations(const Locale('en'));

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    for (final uid in [_owner, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _alice]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
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

  test('each change is told to the others, more or less, with what is on now; never to its author', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await owner.service.invite(id, email: 'alice@example.com', role: server.recordOf(id).roles.values.single.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    await alice.coordinator.syncAll();
    final aliceDb = await alice.db(id);
    final ownerDb = await owner.db(id);
    expect(await takeTeamNotices(aliceDb, id), isEmpty, reason: 'the first look only notes where things stand');
    expect(await takeTeamNotices(ownerDb, id), isEmpty);

    Future<List<(String, String?)>> told(_Device d) async {
      await d.coordinator.syncAll();
      final notes = await takeTeamNotifications({id: await d.db(id)},
          me: d.uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
      return [for (final n in notes) (n.title, n.body)];
    }

    // On: alice hears it records more, and what is on now, in order.
    await owner.service.setTracking(id, const RecordTracking(activity: true, history: true));
    expect(await told(alice), [
      (l10n.noticeTrackingMoreTitle('The Acme Orchard'),
          l10n.noticeTrackingOnBody('owner-1@example.com', 'version history, activity')),
    ]);
    expect(await told(owner), isEmpty, reason: 'its own change');
    expect(await told(alice), isEmpty, reason: 'told once');

    // Some of it off: less.
    await owner.service.setTracking(id, const RecordTracking(history: true));
    expect(await told(alice), [
      (l10n.noticeTrackingLessTitle('The Acme Orchard'), l10n.noticeTrackingOnBody('owner-1@example.com', 'version history')),
    ]);

    // One off and another on at once records something new: more.
    await owner.service.setTracking(id, const RecordTracking(ips: true));
    expect(await told(alice), [
      (l10n.noticeTrackingMoreTitle('The Acme Orchard'),
          l10n.noticeTrackingOnBody('owner-1@example.com', 'sign-in addresses')),
    ]);

    // The same again: nothing changed, nobody told.
    await owner.service.setTracking(id, const RecordTracking(ips: true));
    expect(await told(alice), isEmpty);

    // Everything off.
    await owner.service.setTracking(id, RecordTracking.none);
    expect(await told(alice), [
      (l10n.noticeTrackingLessTitle('The Acme Orchard'), l10n.noticeTrackingNoneBody('owner-1@example.com')),
    ]);
    expect(await told(owner), isEmpty);

    // A member may not change it.
    await expectLater(alice.service.setTracking(id, const RecordTracking(history: true)),
        throwsA(predicate((e) => '$e'.contains('only owners set what the team records'))));
    expect(server.recordOf(id).tracking, RecordTracking.none);
  });

  test('a device that was away hears each change it missed, in order', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await owner.service.invite(id, email: 'alice@example.com', role: server.recordOf(id).roles.values.single.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    await alice.coordinator.syncAll();
    final aliceDb = await alice.db(id);
    expect(await takeTeamNotices(aliceDb, id), isEmpty);

    await owner.service.setTracking(id, const RecordTracking(devices: true));
    await owner.service.setTracking(id, const RecordTracking(devices: true, activity: true));
    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await owner.service.setTracking(id, const RecordTracking(activity: true, history: true));
    await alice.coordinator.syncAll();
    final notices = await takeTeamNotices(aliceDb, id);
    expect(notices.map((n) => (n.kind, n.tracking)), [
      (TeamNoticeKind.trackingMore, const RecordTracking(devices: true)),
      (TeamNoticeKind.trackingMore, const RecordTracking(devices: true, activity: true)),
      (TeamNoticeKind.trackingLess, const RecordTracking(activity: true)),
      (TeamNoticeKind.trackingMore, const RecordTracking(activity: true, history: true)),
    ]);
  });

  test('someone who joins a team that records something is told once what is on; its author is not', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await owner.service.setTracking(id, const RecordTracking(history: true));
    await owner.service.invite(id, email: 'alice@example.com', role: server.recordOf(id).roles.values.single.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    await alice.coordinator.syncAll();

    final told = await takeTeamNotifications({id: await alice.db(id)},
        me: _alice, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
    expect([for (final n in told) (n.title, n.body)], [
      (l10n.noticeTrackingNowTitle('The Acme Orchard'), l10n.noticeTrackingNowBody('version history')),
    ]);
    expect(await takeTeamNotices(await alice.db(id), id), isEmpty, reason: 'once');

    // The owner's new laptop: its own choice, nothing to tell.
    final laptop = device(_owner);
    await laptop.service.refresh();
    await laptop.coordinator.syncAll();
    expect(
        await takeTeamNotifications({id: await laptop.db(id)},
            me: _owner, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard'),
        isEmpty);
  });
}

