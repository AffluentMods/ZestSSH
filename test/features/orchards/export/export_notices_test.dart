import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/local_state_store.dart';

import '../fake_crate_server.dart';

/// Event export (3.0) as members hear of it: every member's device
/// tells its person when the team's events start to be sent on to a system
/// of its own, and when that ends, whatever ended it (turned off, activity
/// no longer recorded, the owner who set it up no longer one). Nobody is
/// told of their own change, a key that is replaced tells nobody, and a
/// device new to the Orchard says once where things stand. With it: the
/// record's words for the entry, and what a refusal reads as.

const _owner = 'owner-1';
const _owner2 = 'owner-2';
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

final _key = base64Encode(List.filled(32, 0x61));
final _key2 = base64Encode(List.filled(32, 0xfb));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    for (final uid in [_owner, _owner2, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _owner2, _alice]) {
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

  Future<void> join(_Device by, _Device person, String id, String role) async {
    await by.service.invite(id, email: '${person.uid}@example.com', role: role);
    server.acceptAs(id, (await by.service.invites(id)).single.id, person.uid);
    await by.service.confirmInvite(id, (await by.service.invites(id)).single);
    await person.coordinator.syncAll();
  }

  Future<void> export(_Device by, String id, {String? key}) =>
      by.service.change(id, RecordTypes.exportSet, key == null ? {'on': false} : {'on': true, 'key': key});

  test('every member is told when the events start to be sent on and when that ends, whatever ended it; '
      'never the one who did it', () async {
    final owner = device(_owner);
    final owner2 = device(_owner2);
    final alice = device(_alice);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, id, server.recordOf(id).roles.values.single.id);
    await join(owner, owner2, id, FixedRoles.owner);
    await owner.coordinator.syncAll();
    for (final d in [owner, owner2, alice]) {
      expect(await takeTeamNotices(await d.db(id), id), isEmpty, reason: 'the first look only notes where things stand');
    }

    Future<List<(String, String, String?)>> told(_Device d) async {
      await d.coordinator.syncAll();
      final notes = await takeTeamNotifications({id: await d.db(id)},
          me: d.uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
      return [for (final n in notes) (n.id, n.title, n.body)];
    }

    String seq() => '${server.entriesOf(id).last.seq}';
    final on = l10n.noticeExportOnTitle('The Acme Orchard');
    final off = l10n.noticeExportOffTitle('The Acme Orchard');

    await owner.service.setTracking(id, const RecordTracking(activity: true));
    expect((await told(alice)).single.$2, l10n.noticeTrackingMoreTitle('The Acme Orchard'));
    await told(owner2);

    // On: everyone but its author hears who turned it on, and what goes.
    await export(owner, id, key: _key);
    expect(await told(alice), [
      ('orchard-notice-$id-${seq()}-export', on, l10n.noticeExportOnBody('owner-1@example.com')),
    ]);
    expect(await told(owner2), [
      ('orchard-notice-$id-${seq()}-export', on, l10n.noticeExportOnBody('owner-1@example.com')),
    ]);
    expect(await told(owner), isEmpty, reason: 'its own change');
    expect(await told(alice), isEmpty, reason: 'told once');

    // Another key, another owner's device: it is still on, and nobody is
    // told anything.
    await export(owner, id, key: _key2);
    await export(owner2, id, key: _key);
    expect(await told(alice), isEmpty);
    expect(await told(owner), isEmpty);

    // Turned off: told that nothing leaves any more.
    await export(owner, id);
    expect(await told(alice), [('orchard-notice-$id-${seq()}-export', off, l10n.noticeExportOffBody)]);
    expect(await told(owner2), [('orchard-notice-$id-${seq()}-export', off, l10n.noticeExportOffBody)]);
    expect(await told(owner), isEmpty);
    // Off while it is off tells nobody.
    await export(owner2, id);
    expect(await told(alice), isEmpty);

    // Activity is no longer recorded: one entry, two things to tell, each
    // a notice of its own.
    await export(owner2, id, key: _key);
    expect((await told(alice)).single.$2, on);
    expect((await told(owner)).single.$3, l10n.noticeExportOnBody('owner-2@example.com'));
    await owner.service.setTracking(id, const RecordTracking(history: true));
    final entry = seq();
    expect(await told(alice), [
      ('orchard-notice-$id-$entry', l10n.noticeTrackingMoreTitle('The Acme Orchard'),
          l10n.noticeTrackingOnBody('owner-1@example.com', 'version history')),
      ('orchard-notice-$id-$entry-export', off, l10n.noticeExportOffBody),
    ]);
    expect(await told(owner2), hasLength(2), reason: 'not their change');
    expect(await told(owner), isEmpty);

    // The owner who set it up steps down: over, and said so.
    await owner.service.setTracking(id, const RecordTracking(activity: true, history: true));
    await told(alice);
    await told(owner2);
    await export(owner2, id, key: _key2);
    expect((await told(alice)).single.$3, l10n.noticeExportOnBody('owner-2@example.com'));
    expect((await told(owner)).single.$3, l10n.noticeExportOnBody('owner-2@example.com'));
    await owner2.service.stepDown(id);
    expect(server.recordOf(id).eventExport, isNull);
    expect(await told(alice), [('orchard-notice-$id-${seq()}-export', off, l10n.noticeExportOffBody)]);
    expect(await told(owner), [('orchard-notice-$id-${seq()}-export', off, l10n.noticeExportOffBody)]);
    expect(await told(owner2), isEmpty, reason: 'they did it themselves');
    // Other entries tell nothing about it.
    await owner.service.createCrate(id, 'Vault', ownersOnly: true);
    expect(await told(alice), isEmpty);
  });

  test('a device new to the Orchard says once what is recorded and that events are sent on', () async {
    final owner = device(_owner);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = server.recordOf(id).roles.values.single.id;
    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await export(owner, id, key: _key);
    final exportSeq = server.entriesOf(id).last.seq;
    await owner.service.createCrate(id, 'Vault', ownersOnly: true);

    final alice = device(_alice);
    await join(owner, alice, id, role);
    final notes = await takeTeamNotifications({id: await alice.db(id)},
        me: _alice, l10n: l10n, orchardName: (name) => orchardDisplayName(name, l10n));
    expect([for (final n in notes) (n.id, n.title, n.body)], [
      ('orchard-notice-$id-${exportSeq - 1}', l10n.noticeTrackingNowTitle('Acme'),
          l10n.noticeTrackingNowBody('activity')),
      ('orchard-notice-$id-$exportSeq-export', l10n.noticeExportOnTitle('Acme'),
          l10n.noticeExportOnBody('owner-1@example.com')),
    ]);
    expect(await takeTeamNotices(await alice.db(id), id), isEmpty, reason: 'once');

    // Recorded, and not sent on: only what is recorded is said.
    await export(owner, id);
    final owner2 = device(_owner2);
    await join(owner, owner2, id, FixedRoles.owner);
    final theirs = await takeTeamNotices(await owner2.db(id), id);
    expect([for (final n in theirs) n.kind], [TeamNoticeKind.trackingNow]);

    // A device that looked before it held any of the record (it was held
    // back then) is told of everything since, from the first entry on.
    await export(owner, id, key: _key2);
    await alice.coordinator.syncAll();
    await LocalStateStore(await alice.db(id)).write('orchards.told_seq', '0');
    final all = await takeTeamNotices(await alice.db(id), id);
    expect([for (final n in all) n.kind], [
      TeamNoticeKind.trackingMore,
      TeamNoticeKind.exportOn,
      TeamNoticeKind.exportOff,
      TeamNoticeKind.exportOn,
    ]);
  });

  test('the entry in the record: what it reads as on the Team page, in the key log, and when it is refused',
      () async {
    final owner = device(_owner);
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    await owner.service.setTracking(id, const RecordTracking(activity: true));
    await export(owner, id, key: _key);
    await export(owner, id);
    final local = await LocalRecord.load(await owner.db(id), id);
    final changes = await teamChanges(id, local.entries);
    expect([for (final c in changes.skip(changes.length - 3)) c.kind],
        [TeamChangeKind.tracking, TeamChangeKind.exportOn, TeamChangeKind.exportOff]);
    expect(changes.last.by, _owner);
    String words(TeamChangeKind kind) => teamChangeText(
          TeamChange(seq: 1, kind: kind, by: _owner, byKeyVersion: 1),
          l10n,
          nameOf: (uid) => '$uid',
          crateName: (id) => '$id',
          roleName: (id) => id,
        );
    expect(words(TeamChangeKind.exportOn), 'Turned event export on');
    expect(words(TeamChangeKind.exportOff), 'Turned event export off');
    // An entry that says something this app does not know reads as off: on
    // is said only for what is on.
    RecordEntry entry(Map<String, Object?> body) => RecordEntry(
        seq: 9,
        prev: Uint8List(32),
        type: RecordTypes.exportSet,
        bodyJson: jsonEncode(body),
        by: _owner,
        byKeyVersion: 1,
        signature: Uint8List(64));
    expect(describeRecordEntry(entry({'on': true, 'key': _key}), local.latest).kind, TeamChangeKind.exportOn);
    expect(describeRecordEntry(entry({'on': false}), local.latest).kind, TeamChangeKind.exportOff);
    expect(describeRecordEntry(entry({'on': 'yes'}), local.latest).kind, TeamChangeKind.exportOff);

    // What the record refuses, in words a person can act on.
    await owner.service.setTracking(id, RecordTracking.none);
    Object? refused;
    try {
      await export(owner, id, key: _key);
    } catch (e) {
      refused = e;
    }
    expect(refused, isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'event export needs activity recorded'));
    expect(orchardChangeErrorMessage(refused!, l10n), l10n.exportErrorNeedsActivity);
    expect(orchardChangeErrorMessage(const OrchardServerException(409, 'activity-off'), l10n), l10n.exportErrorNeedsActivity);
    expect(orchardChangeErrorMessage(const OrchardRecordRefused('only owners set event export'), l10n),
        l10n.orchardErrorRefused);
  });
}
