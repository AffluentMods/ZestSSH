import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show itemEditedAfter;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';

/// Which Crate an Orchard's items belong in (3.0): bookkeeping on
/// this device only, with no keys and no server, so screens can use it
/// offline. The next sync sends what it records.
class CratePlacement {
  CratePlacement(this.db, {int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase db;
  final int Function() _nowMs;

  /// The Crates this account can add items to (their switches, from the
  /// Orchard's record, include add), in a stable order.
  Future<List<String>> writableCrates() async {
    final rows = await db.customSelect('SELECT crate_id, switches FROM orchard_crates ORDER BY crate_id').get();
    return [
      for (final r in rows)
        if (_switches(r.read<String>('switches')).contains(CrateSwitches.add)) r.read<String>('crate_id'),
    ];
  }

  /// What this account may do in [crateId], from the Orchard's record.
  Future<Set<String>> switchesOf(String crateId) async {
    final row = await db.customSelect('SELECT switches FROM orchard_crates WHERE crate_id = ?',
        variables: [Variable(crateId)]).getSingleOrNull();
    return row == null ? const {} : _switches(row.read<String>('switches'));
  }

  static Set<String> _switches(String json) {
    try {
      return {
        for (final s in jsonDecode(json) as List)
          if (s is String) s,
      };
    } catch (_) {
      return const {};
    }
  }

  /// The Crate new items go into: the one picked on this device, else the
  /// first this account can write to. Null when it can write to none.
  Future<String?> defaultCrate() async {
    final writable = await writableCrates();
    final row = await db
        .customSelect('SELECT default_crate_id FROM orchard_info WHERE id = 1')
        .getSingleOrNull();
    final picked = row?.read<String?>('default_crate_id');
    if (picked != null && writable.contains(picked)) return picked;
    return writable.isEmpty ? null : writable.first;
  }

  /// Makes [crateId] the Crate new items go into on this device. Items made
  /// here that have not been placed yet stay in the Crate they were made in:
  /// picking another Crate never moves what already exists.
  Future<void> setDefaultCrate(String crateId) async {
    if (!(await writableCrates()).contains(crateId)) return;
    await db.transaction(() async {
      final previous = await defaultCrate();
      if (previous != null && previous != crateId) {
        for (final entry in OrchardItemStore.tablesOfKind.entries) {
          final kind = entry.key;
          final main = entry.value.first;
          final keyColumn = AppDatabase.orchardItemTables[main]!.$2;
          await db.customStatement(
            'INSERT INTO crate_items_meta (kind, item_key, crate_id) '
            'SELECT ?, "$keyColumn", ? FROM $main WHERE "$keyColumn" NOT IN '
            '(SELECT item_key FROM crate_items_meta WHERE kind = ?)',
            [kind, previous, kind],
          );
        }
      }
      await db.customStatement(
          'UPDATE orchard_info SET default_crate_id = ? WHERE id = 1', [crateId]);
    });
    db.notifyOrchardItemsChanged();
  }

  /// The Crate an item is in on this device.
  Future<String?> crateOf(String kind, String key) async =>
      (await _metaCrate(kind, key)) ?? await defaultCrate();

  /// Puts [copyKey], a copy of the item [sourceKey] of [kind] (Duplicate),
  /// into the source's Crate where this account can add there, so a copy
  /// stays beside what it was made from (it went to the Crate new items go
  /// to, wherever its source was). Where it cannot add there, the copy stays
  /// where new items go, as before. Called before the copy's rows are
  /// inserted, the write is checked against that Crate; after, before the
  /// copy reaches the server, it is moved there.
  Future<void> placeCopy(String kind, String sourceKey, String copyKey) async {
    final crate = await crateOf(kind, sourceKey);
    if (crate == null || !(await writableCrates()).contains(crate)) return;
    await place(kind, copyKey, crate);
  }

  /// Puts an item that has not reached the server yet into [crateId]; one
  /// that has is moved there.
  Future<void> place(String kind, String key, String crateId) async {
    final meta = await db.customSelect(
      'SELECT crate_id, server_revision, edited_at FROM crate_items_meta WHERE kind = ? AND item_key = ?',
      variables: [Variable(kind), Variable(key)],
    ).getSingleOrNull();
    if (meta?.read<int?>('server_revision') != null) {
      return moveItem(kind, key, crateId);
    }
    // Nothing is put into a Crate that its own offline limit has closed on
    // this device, and an item that was put into one stays there.
    await _requireOpen([crateId, meta?.read<String>('crate_id')]);
    await _setMeta(kind, key,
        crateId: crateId, serverRevision: null, editedAt: meta?.read<int?>('edited_at'));
    db.notifyOrchardItemsChanged();
  }

  /// Moves an item to another Crate: it is written there on the next sync,
  /// and its copy in the old Crate is replaced by a deletion that names the
  /// new one, so other devices follow it. Arriving is adding (add in the
  /// new Crate); an item the old Crate already holds leaves it by a
  /// deletion (delete there).
  Future<void> moveItem(String kind, String key, String toCrateId) async {
    if (!OrchardItemStore.isKind(kind)) throw ArgumentError.value(kind, 'kind');
    // Nothing leaves a Crate that its own offline limit has closed on this
    // device, and nothing arrives in one: moved to a Crate that is open, an
    // item would be open with it.
    await _requireOpen([toCrateId, await crateOf(kind, key)]);
    await db.transaction(() async {
      if (!(await writableCrates()).contains(toCrateId)) {
        throw StateError('Items cannot be moved into that Crate');
      }
      final meta = await db.customSelect(
        'SELECT crate_id, server_revision, edited_at FROM crate_items_meta '
        'WHERE kind = ? AND item_key = ?',
        variables: [Variable(kind), Variable(key)],
      ).getSingleOrNull();
      final from = meta?.read<String>('crate_id') ?? await defaultCrate();
      if (from == toCrateId) return;
      // Later than the version it moves, as every change is (the outbox's
      // triggers, AppDatabase.createOrchardTriggers), and never past what a
      // record may say ([itemEditedAfter]).
      final now = itemEditedAfter(meta?.read<int?>('edited_at') ?? 0, _nowMs());
      final serverRevision = meta?.read<int?>('server_revision');
      if (from != null && serverRevision != null && !(await switchesOf(from)).contains(CrateSwitches.delete)) {
        throw StateError('Items cannot be moved out of that Crate');
      }
      if (from != null && serverRevision != null) {
        await db.customStatement(
          'INSERT OR REPLACE INTO crate_leftovers (kind, item_key, crate_id, revision, edited_at) '
          'VALUES (?, ?, ?, ?, ?)',
          [kind, key, from, serverRevision, now],
        );
      }
      // Back into a Crate it only just left: that copy is its copy again.
      final back = await db.customSelect(
        'SELECT revision FROM crate_leftovers WHERE kind = ? AND item_key = ? AND crate_id = ?',
        variables: [Variable(kind), Variable(key), Variable(toCrateId)],
      ).getSingleOrNull();
      if (back != null) {
        await db.customStatement(
          'DELETE FROM crate_leftovers WHERE kind = ? AND item_key = ? AND crate_id = ?',
          [kind, key, toCrateId],
        );
      }
      await _setMeta(kind, key,
          crateId: toCrateId,
          serverRevision: back?.read<int>('revision'),
          editedAt: meta?.read<int?>('edited_at'));
      // A move changes no row of the item: queue it by hand.
      await db.customStatement(
          'UPDATE orchard_sync_control SET change_seq = change_seq + 1 WHERE id = 1');
      await db.customStatement(
        'DELETE FROM crate_outbox WHERE kind = ? AND item_key = ?',
        [kind, key],
      );
      await db.customStatement(
        'INSERT INTO crate_outbox (kind, item_key, change_seq, edited_at) '
        'VALUES (?, ?, (SELECT change_seq FROM orchard_sync_control WHERE id = 1), ?)',
        [kind, key, now],
      );
    });
    db.notifyOrchardItemsChanged();
  }

  /// Throws [CrateClosedOffline] when one of [crates] is closed on this
  /// device by its own offline limit (rules/crate_offline.dart).
  Future<void> _requireOpen(List<String?> crates) async {
    final closed = await closedCratesIn(db);
    if (closed.isEmpty) return;
    for (final crateId in crates) {
      final refusal = await crateClosedIn(db, crateId, closed: closed);
      if (refusal != null) throw refusal;
    }
  }

  /// Every host's Crate on this device, by connection id; hosts that have
  /// not been placed yet are in the Crate new items go to.
  Stream<Map<String, String>> watchHostCrates() => watchCrates('host');

  /// Every item of [kind]'s Crate on this device, by item key; items that
  /// have not been placed yet are in the Crate new items go to.
  Stream<Map<String, String>> watchCrates(String kind) => db
      .customSelect(
        'SELECT item_key, crate_id FROM crate_items_meta WHERE kind = ?',
        variables: [Variable(kind)],
        readsFrom: {db.crateItemsMeta},
      )
      .watch()
      .map((rows) => {
            for (final r in rows) r.read<String>('item_key'): r.read<String>('crate_id'),
          });

  Future<String?> _metaCrate(String kind, String key) async => (await db.customSelect(
        'SELECT crate_id FROM crate_items_meta WHERE kind = ? AND item_key = ?',
        variables: [Variable(kind), Variable(key)],
      ).getSingleOrNull())
          ?.read<String>('crate_id');

  Future<void> _setMeta(
    String kind,
    String key, {
    required String crateId,
    required int? serverRevision,
    required int? editedAt,
  }) =>
      // A copy placed or moved into a Crate is never one of its deletions.
      db.customStatement(
        'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, edited_at) '
        'VALUES (?, ?, ?, ?, ?) ON CONFLICT(kind, item_key) DO UPDATE SET '
        'crate_id = excluded.crate_id, server_revision = excluded.server_revision, '
        'server_deleted = 0, edited_at = excluded.edited_at',
        [kind, key, crateId, serverRevision, editedAt],
      );
}
