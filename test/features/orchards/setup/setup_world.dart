import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show canonicalJson;
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_reader.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../fake_crate_server.dart';

// What the setup file's tests share (3.0): accounts with real
// keys, each on a device of its own with the real Orchard service, against
// the stand-in server that checks every entry with the record's rules.

/// When every snapshot of these tests is taken.
final kSetupNow = DateTime.utc(2026, 10, 2, 12);

/// A time to come, and one that has passed, as a file writes them.
const kLater = '2030-06-30T17:00:00Z';
const kPassed = '2026-01-31T17:00:00Z';

int secondsOf(String time) => parseSetupTime(time)!;

/// The file whose fields after the marker are [body]: read as a file is,
/// and nothing wrong with it.
SetupFile setupFile(Map<String, Object?> body) {
  final read = readSetupFile(jsonEncode({kSetupFileMarker: 1, ...body}));
  expect(read.problems.map((p) => '$p').toList(), isEmpty, reason: 'the file itself reads');
  return read.file!;
}

/// [record] after [changes] made by [by], each checked by the record's own
/// rules (the signature aside): what a device and the server would hold
/// once the entries are in. Throws [RecordRejected] where the rules refuse.
Future<OrchardRecord> after(OrchardRecord record, String by, List<RecordChange> changes) async {
  final next = record.copy();
  for (final c in changes) {
    await next.append(
      RecordEntry(
        seq: next.seq + 1,
        prev: next.head,
        type: c.type,
        bodyJson: canonicalJson(c.body),
        by: by,
        byKeyVersion: next.members[by]!.currentKeys.version,
        signature: Uint8List(64),
      ),
      trusted: true,
    );
  }
  return next;
}

/// A record in words: one line for each Crate, role (highest first, with
/// its rank) and member, then the rules and what is recorded. Crates and
/// roles are called what [names] calls their ids.
List<String> describeRecord(OrchardRecord r, Map<String, String> names) {
  String name(String id) => names[id] ?? id;
  String gives(Map<String, Set<String>> byId) {
    final named = {for (final e in byId.entries) name(e.key): e.value};
    return [for (final k in named.keys.toList()..sort()) '$k=${jsonEncode(switchesJson(named[k]!))}'].join(' ');
  }

  final crates = [
    for (final c in r.crates.values)
      [
        'crate ${name(c.id)}:',
        if (c.ownersOnly) 'owners-only',
        'allow=${switchList(c.allow).join('+')}',
        if (c.confirmReveal) 'ask-again',
        if (c.sessionLogs) 'logs',
        if (c.watched) 'watched',
      ].join(' '),
  ]..sort();
  final roles = [
    for (final id in rolesHighestFirst(r))
      'role ${name(id)} (${r.roles[id]!.rank}): can=${switchList(r.roles[id]!.can).join('+')} '
              '${gives(r.roles[id]!.crates)}'
          .trimRight(),
  ];
  String held(Map<String, Set<String>> byId) {
    final named = {for (final e in byId.entries) name(e.key): e.value};
    return [for (final k in named.keys.toList()..sort()) '$k=${jsonEncode(limitJson(named[k]!))}'].join(' ');
  }

  final members = [
    for (final m in r.members.values)
      if (m.status != MemberStatus.removed)
        [
          'member ${m.uid}: ${name(m.role)}',
          if (m.grants.isNotEmpty) 'extra ${gives(m.grants)}',
          if (m.limits.isNotEmpty) 'limited ${held(m.limits)}',
          if (m.endsAt != null) 'until ${setupTime(m.endsAt!)}',
          if (m.status == MemberStatus.suspended) 'suspended',
        ].join(' '),
  ]..sort();
  return [
    ...crates,
    ...roles,
    ...members,
    'rules ${jsonEncode(r.rules.toBody())}',
    'records ${jsonEncode(r.tracking.toBody())}',
  ];
}

/// What [now] calls each Crate and role it can read, by id.
Map<String, String> namesOf(OrchardSnapshot now) => {
      for (final c in now.crates)
        if (c.name != null) c.id: c.name!,
      for (final r in now.roles)
        if (r.name != null) r.id: r.name!,
    };

/// A snapshot with some of it replaced: what a test changes by hand to look
/// at one thing a plan depends on.
extension SnapshotChanged on OrchardSnapshot {
  OrchardSnapshot change({
    String? name,
    OrchardRecord? record,
    String? myEmail,
    List<SnapshotCrate>? crates,
    List<SnapshotRole>? roles,
    List<SnapshotMember>? members,
    List<SnapshotInvite>? invites,
    bool noInvites = false,
    List<SnapshotHost>? hosts,
    List<SnapshotNamed>? keys,
    List<SnapshotNamed>? groups,
    bool? lockOn,
    int? lockMinutes,
    bool? reached,
    bool? newKindsOn,
    Set<String>? provenDomains,
  }) =>
      OrchardSnapshot(
        orchardId: orchardId,
        name: name ?? this.name,
        me: me,
        myEmail: myEmail ?? this.myEmail,
        record: record ?? this.record,
        now: now,
        crates: crates ?? this.crates,
        roles: roles ?? this.roles,
        members: members ?? this.members,
        invites: noInvites ? null : (invites ?? this.invites),
        hosts: hosts ?? this.hosts,
        keys: keys ?? this.keys,
        groups: groups ?? this.groups,
        lockOn: lockOn ?? this.lockOn,
        lockMinutes: lockMinutes ?? this.lockMinutes,
        reached: reached ?? this.reached,
        newKindsOn: newKindsOn ?? this.newKindsOn,
        provenDomains: provenDomains ?? this.provenDomains,
      );
}

/// Each of [things] as it writes itself.
List<String> texts(Iterable<Object> things) => [for (final t in things) '$t'];

class SetupMemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async {
    dbs.remove(orchardId);
  }

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

/// One account's device.
class SetupDevice {
  SetupDevice(this.world, this.uid, this._keys, {SetupMemoryStorage? storage})
      : server = world.server.as(uid),
        _storage = storage ?? SetupMemoryStorage() {
    final keys = _keys;
    // A device that is in contact with ZestSSH Cloud, as one that applies a
    // setup file is: a Crate's own offline limit is measured from now.
    int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()),
        storage: _storage,
        contact: DeviceContact(read: () => OrchardContact(lastContact: now(), latest: now()), now: now));
    service = OrchardService(
      server: server,
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: databases);
  }

  final SetupWorld world;
  final String uid;
  final AccountKeys _keys;
  final CrateServer server;
  final SetupMemoryStorage _storage;

  /// The same device with a service of its own, as after the app was
  /// started again. A screen under test gets this one: what a screen does
  /// runs in the test's own time, what the test does directly in real
  /// time, and one service must not wait in one for what it began in the
  /// other.
  SetupDevice again() => SetupDevice(world, uid, _keys, storage: _storage);
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  /// What the actions of the last [apply] were asked to sync.
  var syncs = 0;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<void> sync(String orchardId) async {
    syncs++;
    await coordinator.syncOne(orchardId);
  }

  Future<OrchardSnapshot> snapshot(String orchardId, {({bool on, int minutes})? lock}) =>
      readSetupSnapshot(service, orchardId, sync: () => sync(orchardId), lock: lock, clock: () => kSetupNow);

  Future<SetupPlan> plan(String orchardId, Map<String, Object?> body) async =>
      planSetup(setupFile(body), await snapshot(orchardId));

  SetupActions actions(String orchardId) => OrchardSetupActions(service, orchardId,
      sync: () => sync(orchardId), clock: () => kSetupNow, newId: world.newId);

  /// Plans [body] and applies it. The plan must have nothing in its way.
  Future<SetupOutcome> apply(String orchardId, Map<String, Object?> body) async {
    final now = await snapshot(orchardId);
    final plan = await planSetup(setupFile(body), now);
    expect(plan.problems.map((p) => '$p').toList(), isEmpty, reason: 'nothing stands in the way');
    return applySetup(plan, now, actions(orchardId));
  }

  /// A key (a saved login) called [name] in [crateId].
  Future<String> addKey(String orchardId, String name, {required String crateId, String? id}) async {
    final d = await db(orchardId);
    final keyId = id ?? world.newId();
    await d.transaction(() async {
      await CratePlacement(d).place('key', keyId, crateId);
      await d.into(d.identities).insert(IdentitiesCompanion.insert(
          id: keyId,
          label: name,
          username: 'deploy',
          authMethod: 'password',
          createdAt: kSetupNow,
          updatedAt: Value(kSetupNow)));
    });
    return keyId;
  }

  /// A host called [name] in [crateId], as someone would have added it.
  Future<String> addHost(String orchardId, String name,
      {required String crateId,
      String address = '192.0.2.10',
      int port = 22,
      String protocol = 'ssh',
      String? keyId,
      String? groupId,
      Set<String> tags = const {}}) async {
    final d = await db(orchardId);
    final id = world.newId();
    await d.transaction(() async {
      await CratePlacement(d).place('host', id, crateId);
      await d.into(d.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: name,
          host: address,
          port: Value(port),
          protocol: Value(protocol),
          identityId: Value(keyId),
          groupId: Value(groupId),
          createdAt: kSetupNow,
          updatedAt: kSetupNow));
      if (tags.isNotEmpty) await d.connectionTagsDao.setTagsForConnection(id, tags);
    });
    return id;
  }

  /// A group called [name] in [crateId].
  Future<String> addGroup(String orchardId, String name, {required String crateId}) async {
    final d = await db(orchardId);
    final id = world.newId();
    await d.transaction(() async {
      await CratePlacement(d).place('group', id, crateId);
      await d.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion(
          id: Value(id), name: Value(name), isExpanded: const Value(true), createdAt: Value(kSetupNow)));
    });
    return id;
  }

  /// Each host here as "crate/name address:port protocol key group tags".
  Future<List<String>> hosts(String orchardId) async {
    final now = await snapshot(orchardId);
    String? name(List<SnapshotNamed> all, String? id) => all.where((x) => x.id == id).firstOrNull?.name;
    return [
      for (final h in now.hosts)
        [
          '${now.crate(h.crateId)?.name}/${h.name}',
          '${h.address}:${h.port}',
          h.protocol,
          'key=${name(now.keys, h.keyId)}',
          'group=${name(now.groups, h.groupId)}',
          'tags=${(h.tags.toList()..sort()).join('+')}',
        ].join(' '),
    ]..sort();
  }

  Future<void> close() async {
    for (final db in _storage.dbs.values) {
      try {
        await db.close();
      } catch (_) {
        // (Closed already, through the same device started again.)
      }
    }
  }
}

/// The accounts, the server and the devices of one test.
class SetupWorld {
  static const owner = 'owner-1';
  static const second = 'owner-2';
  static const ada = 'ada';
  static const lin = 'lin';
  static const sam = 'sam';
  static const accounts = [owner, second, ada, lin, sam];

  static final _keys = <String, AccountKeys>{};

  /// Each account's keys, made once for the whole run.
  static Future<void> makeKeys() async {
    for (final uid in accounts) {
      _keys[uid] ??= await AccountKeys.generate();
    }
  }

  static String emailOf(String uid) => '$uid@northwind.example';

  late final FakeCrateServer server;
  final _devices = <SetupDevice>[];
  var _ids = 0;

  /// Ids in the order they are asked for: of the form a real one has.
  String newId() => '00000000-0000-4000-8000-${(++_ids).toString().padLeft(12, '0')}';

  Future<void> start() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: owner);
    for (final uid in accounts) {
      await server.publish(uid, _keys[uid]!, email: emailOf(uid));
    }
  }

  Future<void> stop() async {
    for (final d in _devices) {
      await d.close();
    }
    _devices.clear();
  }

  /// A device of [uid]; with [keys], one that holds those and not the ones
  /// the account started with.
  SetupDevice device(String uid, {AccountKeys? keys}) {
    final d = SetupDevice(this, uid, keys ?? _keys[uid]!);
    _devices.add(d);
    return d;
  }

  /// An Orchard of the owner's, Northwind Ops (or [name]): the Crates
  /// Production (the first role, Members, has use of it) and Staging.
  Future<({String id, String production, String staging, String members})> orchard(SetupDevice owner,
      {String name = 'Northwind Ops'}) async {
    final id = await owner.service
        .createOrchard(name, firstCrateName: 'Production', memberRoleName: 'Members');
    final staging = await owner.service.createCrate(id, 'Staging');
    final role = server.recordOf(id).roles.values.single;
    return (id: id, production: role.crates.keys.single, staging: staging, members: role.id);
  }

  /// [person] joins [orchardId] as [role], added by [by] after comparing
  /// their keys.
  Future<void> join(SetupDevice by, SetupDevice person, String orchardId, String role,
      {Map<String, Set<String>> grants = const {}, int? endsAt}) async {
    await by.service.invite(orchardId, email: emailOf(person.uid), role: role, grants: grants, endsAt: endsAt);
    final invite = (await by.service.invites(orchardId)).singleWhere((i) => i.email == emailOf(person.uid));
    server.acceptAs(orchardId, invite.id, person.uid);
    await by.service.confirmInvite(
        orchardId, (await by.service.invites(orchardId)).singleWhere((i) => i.email == emailOf(person.uid)));
    expect(await person.service.refresh(), contains(orchardId));
  }

  /// The Orchard's record on the server in words ([describeRecord]), its
  /// Crates and roles by the names [device] reads them under.
  Future<List<String>> record(SetupDevice device, String orchardId) async =>
      describeRecord(server.recordOf(orchardId), namesOf(await device.snapshot(orchardId)));
}
