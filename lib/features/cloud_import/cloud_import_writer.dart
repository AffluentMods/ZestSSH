/// Cloud import (3.0): writing what the person chose (or what a kept
/// account's check found) into a space's database: the Tree's, or an
/// Orchard's, where each new host is placed in the chosen Crate before it is
/// written so the Crate's own rules decide. Each host is written on its own:
/// one the rules refuse is reported and the rest still land.
library;

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';

/// Where imported hosts land and how they sign in.
class CloudImportTarget {
  const CloudImportTarget({
    required this.db,
    required this.label,
    this.crateId,
    this.identityId,
    this.groupName,
    this.preferPrivate = false,
    this.compatibilityMode = false,
  });

  /// The destination space's database.
  final AppDatabase db;

  /// The account's name: the links carry it ("from AWS production").
  final String label;

  /// In an Orchard: the Crate new hosts go into.
  final String? crateId;

  /// The key or password new hosts sign in with; null asks when connecting.
  final String? identityId;

  /// The group new hosts go into (found by name, else made); null for none.
  final String? groupName;

  final bool preferPrivate;

  /// Compatibility mode for every new host (off unless ticked).
  final bool compatibilityMode;
}

/// What an import did, for the result line and Copy details.
class CloudImportOutcome {
  int added = 0;
  int linked = 0;
  int updated = 0;
  int gone = 0;
  final failures = <({String name, String error})>[];

  bool get changedAnything => added + linked + updated + gone > 0;
}

/// The hosts in [db], as the plan compares them.
Future<List<CloudExistingHost>> cloudExistingHosts(AppDatabase db) async => [
      for (final c in await db.connectionsDao.getAll())
        CloudExistingHost(id: c.id, label: c.label, host: c.host, port: c.port, link: CloudLink.decode(c.cloudSource)),
    ];

/// Writes [rows]: new and "no SSH" rows are added, "already here" rows are
/// linked, changed rows are updated where the person has not changed the
/// host themselves, and gone rows are marked. Rows of other kinds are
/// skipped. [now] stamps every write.
Future<CloudImportOutcome> applyCloudImport(
  CloudImportTarget target,
  Iterable<CloudRow> rows, {
  DateTime Function() now = DateTime.now,
  String Function() newId = _uuid,
}) async {
  final db = target.db;
  final outcome = CloudImportOutcome();
  final placement = db.isOrchard && target.crateId != null ? CratePlacement(db) : null;
  String? groupId;
  var groupLooked = false;

  Future<String?> group() async {
    if (groupLooked) return groupId;
    groupLooked = true;
    final name = cleanCloudText(target.groupName ?? '', max: 255);
    if (name.isEmpty) return null;
    for (final g in await db.connectionGroupsDao.getAll()) {
      if (g.name.toLowerCase() == name.toLowerCase()) return groupId = g.id;
    }
    final id = newId();
    await db.transaction(() async {
      await placement?.place('group', id, target.crateId!);
      await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion(
        id: Value(id),
        name: Value(name),
        isExpanded: const Value(true),
        createdAt: Value(now()),
      ));
    });
    return groupId = id;
  }

  Future<void> update(String id, {String? host, String? label, required CloudLink link}) async {
    await (db.update(db.connections)..where((c) => c.id.equals(id))).write(ConnectionsCompanion(
      host: host == null ? const Value.absent() : Value(host),
      label: label == null ? const Value.absent() : Value(label),
      cloudSource: Value(link.encode()),
      updatedAt: Value(now()),
    ));
  }

  for (final row in rows) {
    final m = row.machine;
    final name = m?.name ?? row.existing?.label ?? '';
    try {
      switch (row.status) {
        case CloudRowStatus.fresh || CloudRowStatus.noSsh:
          final address = row.address;
          if (m == null || address == null) continue;
          final gid = await group();
          final id = newId();
          final label = m.name.isEmpty ? address : m.name;
          await db.transaction(() async {
            await placement?.place('host', id, target.crateId!);
            await db.connectionsDao.insertConnection(ConnectionsCompanion(
              id: Value(id),
              label: Value(label),
              host: Value(address),
              port: const Value(22),
              identityId: Value(target.identityId),
              groupId: Value(gid),
              protocol: const Value('ssh'),
              compatibilityMode: Value(target.compatibilityMode),
              cloudSource: Value(CloudLink(provider: m.provider, machineId: m.id, label: target.label, address: address, name: m.name).encode()),
              createdAt: Value(now()),
              updatedAt: Value(now()),
            ));
            if (m.tags.isNotEmpty) await db.connectionTagsDao.setTagsForConnection(id, m.tags);
          });
          outcome.added++;
        case CloudRowStatus.here:
          final existing = row.existing;
          if (m == null || existing == null) continue;
          await update(existing.id,
              link: CloudLink(provider: m.provider, machineId: m.id, label: target.label, address: existing.host, name: existing.label));
          outcome.linked++;
        case CloudRowStatus.changed:
          final existing = row.existing;
          if (m == null || existing == null) continue;
          final u = cloudUpdateFor(existing, m, address: row.address, label: target.label);
          await update(existing.id, host: u.host, label: u.label, link: u.link);
          outcome.updated++;
        case CloudRowStatus.gone:
          final existing = row.existing;
          final link = existing?.link;
          if (existing == null || link == null) continue;
          await update(existing.id, link: link.copyWith(gone: true));
          outcome.gone++;
        case CloudRowStatus.imported || CloudRowStatus.noAddress:
          continue;
      }
    } catch (e) {
      outcome.failures.add((name: name, error: '$e'));
    }
  }
  return outcome;
}

String _uuid() => const Uuid().v4();
