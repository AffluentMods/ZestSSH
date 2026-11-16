import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/database.dart';

// Bulk edit of hosts (3.4, "Edit 42
// hosts"). Every field starts as it is on the hosts selected; only the fields
// the person changes are written, to every host they may change, in one
// transaction: one change for sync to carry, all of it or none of it. In a
// team's space each host is written by the rules a single edit goes by (its
// vault's switches): the screen leaves out a host its person may not change,
// and the database's own write guard refuses the whole edit if one slips
// through, as it refuses a single edit.

/// A field of a bulk edit given a value. Null is a value here: no key, no
/// jump host, no group, no colour label.
@immutable
class BulkSet<T> {
  const BulkSet(this.value);
  final T value;

  @override
  bool operator ==(Object other) => other is BulkSet<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Compatibility mode in a bulk edit: as each host has it, off on all, on
/// for the hosts refused for an old key exchange, or on for all.
enum BulkCompat { keep, off, onNeeding, onAll }

/// What a bulk edit does to tags: adds them, takes them away, or makes them
/// every host's tags.
enum BulkTagsMode { add, remove, replace }

/// The tags of a bulk edit, in their canonical form.
@immutable
class BulkTags {
  const BulkTags(this.mode, this.tags);
  final BulkTagsMode mode;
  final List<String> tags;
}

/// A field of the bulk edit: what Tags and Move to group open the editor on.
enum BulkField { port, key, jumpHost, compat, group, tags, color }

/// What a bulk edit changes. A field left null (or [BulkCompat.keep]) is
/// not written at all.
@immutable
class HostBulkEdit {
  const HostBulkEdit({
    this.port,
    this.identity,
    this.jumpHost,
    this.compat = BulkCompat.keep,
    this.group,
    this.tags,
    this.color,
  });

  final int? port;

  /// The key (identity) each host signs in with.
  final BulkSet<String?>? identity;

  /// The host each is reached through (null value: directly).
  final BulkSet<String?>? jumpHost;
  final BulkCompat compat;
  final BulkSet<String?>? group;
  final BulkTags? tags;

  /// The colour label as ARGB; a null value is none (the group's colour).
  final BulkSet<int?>? color;

  /// How many fields it changes.
  int get changeCount => [
        port != null,
        identity != null,
        jumpHost != null,
        compat != BulkCompat.keep,
        group != null,
        tags != null,
        color != null,
      ].where((changed) => changed).length;

  bool get isEmpty => changeCount == 0;
}

// Which hosts a field is written to: the protocols whose editor has it.

/// A host with an address and a port (not a shell on this device).
bool bulkTakesPort(String protocol) => protocol != 'localShell' && protocol != 'demo';

/// A host that signs in with a key: as the host editor shows its Key field.
bool bulkTakesKey(String protocol) => const {'ssh', 'sftp', 'mosh', 'et', 'serial'}.contains(protocol);

/// A host that can be reached through another: SSH, and SFTP only.
bool bulkTakesJumpHost(String protocol) => protocol == 'ssh' || protocol == 'sftp';

/// A host whose connection Compatibility mode changes: SSH, SFTP only, and
/// a serial line (reached over SSH), as the host editor offers it.
bool bulkTakesCompat(String protocol) => const {'ssh', 'sftp', 'serial'}.contains(protocol);

/// The values the hosts had before a bulk edit, of the fields it changed:
/// what Undo writes back.
@immutable
class HostBulkUndo {
  const HostBulkUndo({required this.rows, required this.tags, required this.accounts});

  /// Each host's columns as they were.
  final Map<String, ConnectionsCompanion> rows;

  /// Each host's tags as they were, where the edit changed tags.
  final Map<String, List<String>> tags;

  /// Each host's other accounts as they were, where the edit changed its
  /// key.
  final Map<String, List<String>> accounts;

  bool get isEmpty => rows.isEmpty && tags.isEmpty && accounts.isEmpty;
}

/// What a bulk edit did: the hosts written, and how to undo it.
@immutable
class HostBulkOutcome {
  const HostBulkOutcome({required this.changed, required this.undo});
  final List<String> changed;
  final HostBulkUndo undo;
}

/// Writes [edit] to the hosts [hostIds] of [db] (the ones its person may
/// change), in one transaction: each field only where the edit changes it
/// and the host's kind has it, Compatibility mode's "on for those that need
/// it" only on [needCompat]. A write the database's guard refuses (a team's
/// vault that does not let this account edit) throws, and nothing is
/// written.
Future<HostBulkOutcome> applyHostBulkEdit(
  AppDatabase db,
  List<String> hostIds,
  HostBulkEdit edit, {
  Set<String> needCompat = const {},
  DateTime? now,
}) {
  return db.transaction(() async {
    final at = now ?? DateTime.now();
    final rows = await (db.select(db.connections)..where((c) => c.id.isIn(hostIds))).get();
    final byId = {for (final r in rows) r.id: r};
    final changed = <String>[];
    final undoRows = <String, ConnectionsCompanion>{};
    final undoTags = <String, List<String>>{};
    final undoAccounts = <String, List<String>>{};
    for (final id in hostIds) {
      final host = byId[id];
      if (host == null) continue;
      var next = ConnectionsCompanion(id: Value(id));
      var before = ConnectionsCompanion(id: Value(id));
      var columns = false;
      // The host's other accounts once its key has changed, where they do.
      List<String>? othersAfter;

      if (edit.port case final port? when bulkTakesPort(host.protocol)) {
        next = next.copyWith(port: Value(port));
        before = before.copyWith(port: Value(host.port));
        columns = true;
      }
      if (edit.identity case final identity? when bulkTakesKey(host.protocol)) {
        // As the host editor picks a default account: the key leaves the
        // host's other accounts where it was one; with none chosen, the
        // first other account takes its place.
        final others = await db.hostAccountsDao.otherAccountsOf(id);
        var nextOthers = [for (final o in others) if (o != identity.value) o];
        var key = identity.value;
        if (key == null && nextOthers.isNotEmpty) {
          key = nextOthers.first;
          nextOthers = nextOthers.sublist(1);
        }
        next = next.copyWith(identityId: Value(key));
        before = before.copyWith(identityId: Value(host.identityId));
        columns = true;
        if (!listEquals(others, nextOthers)) {
          undoAccounts[id] = others;
          othersAfter = nextOthers;
        }
      }
      if (edit.jumpHost case final jump? when bulkTakesJumpHost(host.protocol) && jump.value != id) {
        next = next.copyWith(connectViaId: Value(jump.value));
        before = before.copyWith(connectViaId: Value(host.connectViaId));
        columns = true;
      }
      if (bulkTakesCompat(host.protocol)) {
        final on = switch (edit.compat) {
          BulkCompat.keep => null,
          BulkCompat.off => false,
          BulkCompat.onAll => true,
          BulkCompat.onNeeding => needCompat.contains(id) ? true : null,
        };
        if (on != null) {
          next = next.copyWith(compatibilityMode: Value(on));
          before = before.copyWith(compatibilityMode: Value(host.compatibilityMode));
          columns = true;
        }
      }
      if (edit.group case final group?) {
        next = next.copyWith(groupId: Value(group.value));
        before = before.copyWith(groupId: Value(host.groupId));
        columns = true;
      }
      if (edit.color case final color?) {
        // As the colour label is set everywhere: a custom value over the
        // palette's first place, or none, which takes the group's colour.
        next = next.copyWith(colorValue: Value(color.value), colorIndex: const Value(0));
        before = before.copyWith(colorValue: Value(host.colorValue), colorIndex: Value(host.colorIndex));
        columns = true;
      }

      if (columns) {
        await db.connectionsDao.updateConnection(next.copyWith(updatedAt: Value(at)));
        undoRows[id] = before;
      }
      // After the host's own key: the default is never among the others.
      if (othersAfter != null) await db.hostAccountsDao.setOtherAccounts(id, othersAfter);
      if (edit.tags case final tags?) {
        final had = await db.connectionTagsDao.getTagsForConnection(id);
        final want = switch (tags.mode) {
          BulkTagsMode.add => {...had, ...tags.tags},
          BulkTagsMode.remove => {for (final t in had) if (!tags.tags.contains(t)) t},
          BulkTagsMode.replace => {...tags.tags},
        };
        if (!setEquals(had.toSet(), want)) {
          await db.connectionTagsDao.setTagsForConnection(id, want);
          undoTags[id] = had;
        }
      }
      changed.add(id);
    }
    return HostBulkOutcome(
      changed: changed,
      undo: HostBulkUndo(rows: undoRows, tags: undoTags, accounts: undoAccounts),
    );
  });
}

/// Writes back what [undo] kept, in one transaction: Undo of a bulk edit.
/// A host deleted since is left gone.
Future<void> undoHostBulkEdit(AppDatabase db, HostBulkUndo undo, {DateTime? now}) {
  return db.transaction(() async {
    final at = now ?? DateTime.now();
    for (final row in undo.rows.values) {
      await db.connectionsDao.updateConnection(row.copyWith(updatedAt: Value(at)));
    }
    for (final MapEntry(key: id, value: others) in undo.accounts.entries) {
      if (await db.connectionsDao.getById(id) == null) continue;
      await db.hostAccountsDao.setOtherAccounts(id, others);
    }
    for (final MapEntry(key: id, value: tags) in undo.tags.entries) {
      if (await db.connectionsDao.getById(id) == null) continue;
      await db.connectionTagsDao.setTagsForConnection(id, tags);
    }
  });
}

/// The tags [raw] in their canonical form, each once, in order.
List<String> bulkCanonicalTags(Iterable<String> raw) {
  final out = <String>[];
  for (final t in raw) {
    final c = ConnectionTagsDao.normalize(t);
    if (c != null && !out.contains(c)) out.add(c);
  }
  return out;
}

/// How often each value occurs among [values], the most common first (in
/// the order first seen where two are as common): what a field's "now"
/// says ("root on 30, admin on 12").
List<({T value, int count})> bulkValueCounts<T>(Iterable<T> values) {
  final counts = <T, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  final order = counts.keys.toList();
  final entries = [for (var i = 0; i < order.length; i++) (i: i, value: order[i], count: counts[order[i]]!)]
    ..sort((a, b) => a.count != b.count ? b.count.compareTo(a.count) : a.i.compareTo(b.i));
  return [for (final e in entries) (value: e.value, count: e.count)];
}

/// The hosts of a bulk edit: those its person may change, and those left
/// out, by the vault they are in (null: no vault, or one not known).
@immutable
class HostBulkPlan {
  const HostBulkPlan({required this.editable, required this.skipped});
  final List<String> editable;
  final Map<String?, List<String>> skipped;

  int get skippedCount => skipped.values.fold(0, (n, l) => n + l.length);
}

/// Splits [hostIds] into those [mayChange] lets this account change and the
/// rest, by [vaultOf]: in your own space every host is yours; in a team's,
/// a host is changed only where its vault lets this account edit, the rule
/// a single edit goes by.
HostBulkPlan planHostBulkEdit(
  List<String> hostIds, {
  required bool Function(String id) mayChange,
  String? Function(String id)? vaultOf,
}) {
  final editable = <String>[];
  final skipped = <String?, List<String>>{};
  for (final id in hostIds) {
    if (mayChange(id)) {
      editable.add(id);
    } else {
      (skipped[vaultOf?.call(id)] ??= []).add(id);
    }
  }
  return HostBulkPlan(editable: editable, skipped: skipped);
}

/// Whether an item of a team's vault [itemVault] may serve every one of the
/// hosts in [hostVaults]: an item of a vault whose sessions are watched
/// signs in only to that vault's own hosts; any other may serve any
/// host. Outside a team's space, [watched] is empty and everything may.
bool bulkItemServesAll(String? itemVault, Set<String?> hostVaults, Set<String> watched) {
  if (itemVault == null || !watched.contains(itemVault)) return true;
  return hostVaults.every((v) => v == itemVault);
}

/// Whether [candidate] can be the jump host of the hosts [selected]: it is
/// none of them, and the hosts it is reached through (by [jumpOf], each
/// host's own jump host) reach none of them, which would make a loop.
bool bulkJumpHostFits(String candidate, Set<String> selected, String? Function(String id) jumpOf) {
  final seen = <String>{};
  String? at = candidate;
  while (at != null && seen.add(at)) {
    if (selected.contains(at)) return false;
    at = jumpOf(at);
  }
  return true;
}
