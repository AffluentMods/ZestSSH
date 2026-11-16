import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show newRecordKindsOn;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

// Reading an Orchard for a setup file (3.0): the snapshot a file is
// compared with, from the Orchard's record and this device's database, and
// from ZestSSH Cloud the invitations that wait. Nothing here changes the
// Orchard; it is brought up to date first, as any screen does.

/// The Orchard is not one this account can read now: held back by its
/// rules, suspended, ended, waiting for recovery, or its record stopped.
class SetupNotOpen implements Exception, HasTypeName {
  const SetupNotOpen(this.status);

  /// The Orchard's standing on this device ('rules', 'suspended', 'ended',
  /// a record problem), or 'unknown' when it has none here.
  final String status;

  @override
  String toString() => 'Orchards: the Orchard is not open to this account ($status)';

  @override
  String get typeName => 'SetupNotOpen';
}

/// The Orchard [orchardId] as a setup file is compared with.
///
/// It is refreshed from ZestSSH Cloud first, and [sync] (when given) brings
/// its items up to date; when the server cannot be reached, the snapshot is
/// the Orchard as this device last saw it, and says so. [lock] is this
/// device's app lock where the caller can read it.
Future<OrchardSnapshot> readSetupSnapshot(
  OrchardService service,
  String orchardId, {
  Future<void> Function()? sync,
  ({bool on, int minutes})? lock,
  DateTime Function() clock = DateTime.now,
  Future<List<String>> Function()? provenDomains,
}) async {
  final me = await service.currentAuthor();
  if (me == null) throw const AccountKeysNotReady();
  var reached = true;
  try {
    await service.refresh();
  } on AccountKeysNotReady {
    rethrow;
  } catch (e) {
    AppLogger.info('Setup file: ZestSSH Cloud was not reached (${errorKind(e)})');
    reached = false;
  }
  // Only an Orchard this device holds: opening another (as a sync would)
  // makes an empty database for it.
  if (!(await service.databases.onDevice()).contains(orchardId)) throw const SetupNotOpen('unknown');
  if (reached && sync != null) {
    try {
      await sync();
    } catch (e) {
      // The hosts are then as this device has them.
      AppLogger.info('Setup file: the Orchard did not sync first (${errorKind(e)})');
    }
  }
  final db = await service.databases.open(orchardId);
  final info = await db
      .customSelect('SELECT name, status, record_problem FROM orchard_info WHERE id = 1')
      .getSingleOrNull();
  final name = info?.read<String?>('name');
  final status = info?.read<String?>('status');
  if (info == null || name == null || status != 'active' || info.read<String?>('record_problem') != null) {
    throw SetupNotOpen(info?.read<String?>('record_problem') != null ? 'record' : (status ?? 'unknown'));
  }

  final people = await service.people(orchardId);
  final record = people.record;
  final open = {
    for (final r in await db.customSelect('SELECT crate_id, name FROM orchard_crates').get())
      r.read<String>('crate_id'): r.read<String?>('name'),
  };

  final members = <SnapshotMember>[];
  for (final p in people.members) {
    final current = record.members[p.uid]?.currentKeys;
    final trust = p.trust;
    final pinned = trust?.fingerprint;
    // The keys this device holds for them are the ones the record has now,
    // with no change of them waiting to be looked at.
    final holds = current != null &&
        trust != null &&
        !trust.hardStop &&
        trust.keyVersion == current.version &&
        pinned != null &&
        _sameBytes(pinned, current.fingerprint);
    members.add(SnapshotMember(
      uid: p.uid,
      email: p.email?.trim().toLowerCase(),
      compared: holds && trust.verifiedByMe,
      keysTrusted: p.isMe || holds,
    ));
  }

  List<SnapshotInvite>? invites;
  if (reached && record.can(me.uid, RoleCan.invite)) {
    try {
      invites = [
        for (final i in await service.invites(orchardId))
          SnapshotInvite(
            email: i.email.trim().toLowerCase(),
            role: i.role,
            grants: {for (final g in i.grants.entries) g.key: {...g.value}},
            endsAt: i.endsAt,
            expired: i.expired,
            accepted: i.accepted,
          ),
      ];
    } catch (e) {
      AppLogger.info('Setup file: the invitations could not be read (${errorKind(e)})');
    }
  }

  // The items this device holds, each in its Crate: where it was placed,
  // else where new items go.
  final placement = CratePlacement(db);
  final home = await placement.defaultCrate();
  final placed = <String, String>{
    for (final r in await db
        .customSelect("SELECT kind, item_key, crate_id FROM crate_items_meta WHERE kind IN ('host', 'key', 'group')")
        .get())
      '${r.read<String>('kind')} ${r.read<String>('item_key')}': r.read<String>('crate_id'),
  };
  String? crateOf(String kind, String id) => placed['$kind $id'] ?? home;

  final tags = await db.connectionTagsDao.getAllAssignments();
  final accounts = await db.hostAccountsDao.getAllAssignments();
  final hosts = <SnapshotHost>[];
  for (final c in await db.connectionsDao.getAll()) {
    final crateId = crateOf('host', c.id);
    if (crateId == null) continue;
    hosts.add(SnapshotHost(
      id: c.id,
      crateId: crateId,
      name: c.label,
      address: c.host,
      port: c.port,
      protocol: c.protocol,
      keyId: c.identityId,
      accountIds: [...?accounts[c.id]],
      groupId: c.groupId,
      tags: {...?tags[c.id]},
    ));
  }
  final keys = <SnapshotNamed>[];
  for (final k in await db.select(db.identities).get()) {
    final crateId = crateOf('key', k.id);
    if (crateId != null) keys.add(SnapshotNamed(id: k.id, crateId: crateId, name: k.label));
  }
  final groups = <SnapshotNamed>[];
  for (final g in await db.connectionGroupsDao.getAll()) {
    final crateId = crateOf('group', g.id);
    if (crateId != null) groups.add(SnapshotNamed(id: g.id, crateId: crateId, name: g.name));
  }

  return OrchardSnapshot(
    orchardId: orchardId,
    name: name,
    me: me.uid,
    myEmail: people.members.where((p) => p.isMe).firstOrNull?.email?.trim().toLowerCase(),
    record: record,
    now: clock().millisecondsSinceEpoch ~/ 1000,
    crates: [for (final id in record.crates.keys) SnapshotCrate(id: id, name: open[id])],
    roles: [for (final r in people.roles) SnapshotRole(id: r.id, name: r.name)],
    members: members,
    invites: invites,
    hosts: hosts,
    keys: keys,
    groups: groups,
    lockOn: lock?.on,
    lockMinutes: lock?.minutes,
    reached: reached,
    // As the list of Orchards just read said (the last one, when ZestSSH
    // Cloud was not reached).
    newKindsOn: newRecordKindsOn.value,
    provenDomains: {...?await provenDomains?.call()},
  );
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
