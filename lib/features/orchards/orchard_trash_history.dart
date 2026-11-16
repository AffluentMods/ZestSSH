part of 'orchard_service.dart';

// The trash and version history of a Crate (3.0). The server keeps
// every version an item had for 30 days, sealed: it hands the trash (what
// was deleted, with the version each deletion replaced) to anyone who may
// add in the Crate, and earlier versions only while an owner has version
// history on, to owners and those who manage the Crate. Every version is
// opened and checked here as the sync engine checks what it takes: it must
// open under the Crate's key, carry its author's signature, and stand
// against this device's copy of the record ([checkVersionAnchor]); anything
// else is left out. Bringing an item back, or putting an earlier version
// back, is an ordinary change on this device (its write guard, then the
// outbox), signed by whoever does it.

/// An item in a Crate's trash, opened and checked on this device.
class TrashEntry {
  const TrashEntry({
    required this.crateId,
    required this.itemId,
    required this.kind,
    required this.key,
    required this.version,
    required this.deletionRevision,
    required this.deletedBy,
    required this.deletedAt,
    required this.keptUntil,
  });

  final String crateId;
  final String itemId;
  final String kind;
  final String key;

  /// The version the deletion replaced: what bringing it back writes.
  final ItemRecord version;

  /// The deletion's revision in the Crate, which bringing it back replaces.
  final int deletionRevision;

  /// Who deleted it, and when by their device's clock (shown while version
  /// history is on).
  final String deletedBy;
  final DateTime deletedAt;

  /// When the server lets it go.
  final DateTime keptUntil;

  String get name => itemDisplayName(kind, version.data);
}

/// One version of an item, opened and checked on this device.
class ItemVersion {
  const ItemVersion({required this.record, required this.revision, required this.replacedAt, this.historyId});

  /// Who wrote it and when (by their clock), and what it was.
  final ItemRecord record;
  final int? revision;

  /// When the server replaced it; null for the version the item has now.
  final DateTime? replacedAt;

  /// Its place in the Crate's history, for reading further back; null for
  /// the version the item has now.
  final int? historyId;

  bool get isCurrent => replacedAt == null;

  String get name => itemDisplayName(record.kind, record.data);
}

/// One change to a Crate's items: [version] replaced [previous].
class CrateChange {
  const CrateChange({required this.version, required this.previous});

  final ItemVersion version;
  final ItemVersion previous;

  String get kind => version.record.kind;
  String get key => version.record.key;

  /// Who made the change, and when by their device's clock.
  String get by => version.record.author;
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(version.record.editedAt);

  bool get deleted => version.record.deleted;

  /// Brought back from the trash.
  bool get restored => previous.record.deleted && !version.record.deleted;

  String get name => version.record.deleted ? previous.name : version.name;
}

/// A page of a Crate's changes, newest first.
class CrateChangesPage {
  const CrateChangesPage({required this.changes, required this.since, required this.more, this.before});

  final List<CrateChange> changes;

  /// Version history counts from here: nothing earlier is kept for it.
  final DateTime since;
  final bool more;

  /// Pass to read the next page.
  final int? before;
}

/// A name to show for an item of [kind] from its rows ([data], table by
/// table): a host's label, a key's, a group's name; a pinned host key's host
/// and port. Empty when it has none.
String itemDisplayName(String kind, Map<String, Object?>? data) {
  final tables = OrchardItemStore.tablesOfKind[kind];
  if (data == null || tables == null) return '';
  final rows = data[tables.first];
  if (rows is! List || rows.isEmpty || rows.first is! Map) return '';
  final row = rows.first as Map;
  if (kind == kHostKeyKind) return '${row['host'] ?? ''}:${row['port'] ?? ''}';
  for (final column in const ['label', 'name', 'host', 'remote_host']) {
    final value = row[column];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

extension OrchardTrashAndHistory on OrchardService {
  /// What was deleted in [crateId] of [orchardId] in the last 30 days and
  /// can be brought back, newest first. Items moved to another Crate, and
  /// ones already back on this device, are left out. Needs add there.
  Future<List<TrashEntry>> trashOf(String orchardId, String crateId) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final record = await LocalRecord.load(db, orchardId);
    final store = OrchardItemStore(db);
    final out = <TrashEntry>[];
    for (final t in await server.trash(crateId)) {
      final deletion = t.deletion.item == null ? null : await _openVersion(db, orchardId, crateId, t.deletion.item!, record, me);
      final last = t.last.item == null ? null : await _openVersion(db, orchardId, crateId, t.last.item!, record, me);
      if (deletion == null || last == null) continue;
      // Moved, not deleted; or not the same item; or not a live version.
      if (!deletion.deleted || deletion.movedTo != null || last.deleted) continue;
      if (deletion.kind != last.kind || deletion.key != last.key || !OrchardItemStore.isKind(last.kind)) continue;
      if (await store.read(last.kind, last.key) != null) continue;
      out.add(TrashEntry(
        crateId: crateId,
        itemId: t.itemId,
        kind: last.kind,
        key: last.key,
        version: last,
        deletionRevision: t.deletion.revision,
        deletedBy: deletion.author,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(deletion.editedAt),
        keptUntil: t.keptUntil,
      ));
    }
    return out;
  }

  /// Brings [entry] back into its Crate: its last version written again on
  /// this device, as a change of this account's that the next sync sends.
  /// Needs add in the Crate (this device's write guard refuses it
  /// otherwise, with 'orchard-access').
  Future<void> restoreFromTrash(String orchardId, TrashEntry entry) async {
    final db = await databases.open(orchardId);
    await db.transaction(() async {
      // Based on the deletion in its Crate, unless this device already knows
      // a later version there.
      final meta = await db.customSelect(
        'SELECT crate_id, server_revision FROM crate_items_meta WHERE kind = ? AND item_key = ?',
        variables: [Variable(entry.kind), Variable(entry.key)],
      ).getSingleOrNull();
      final known = meta?.read<int?>('server_revision');
      if (meta == null || meta.read<String>('crate_id') != entry.crateId || known == null ||
          known <= entry.deletionRevision) {
        await db.customStatement(
          'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, server_deleted) '
          'VALUES (?, ?, ?, ?, 1) ON CONFLICT(kind, item_key) DO UPDATE SET '
          'crate_id = excluded.crate_id, server_revision = excluded.server_revision, server_deleted = 1',
          [entry.kind, entry.key, entry.crateId, entry.deletionRevision],
        );
      }
      await _writeVersion(db, entry.version);
    });
    db.notifyOrchardItemsChanged();
  }

  /// The versions of one item in [crateId] (its kind and key), the one it
  /// has now first, then each earlier one version history kept (newest
  /// first). Owners and those who manage the Crate, while version history
  /// is on; the server answers 409 'history-off' otherwise.
  Future<List<ItemVersion>> itemVersions(String orchardId, String crateId,
      {required String kind, required String key}) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final record = await LocalRecord.load(db, orchardId);
    final first = await OrchardService._secret(db, orchardId, crateId, 1);
    if (first == null) return const [];
    final itemId = crateItemId(await crateItemIdKey(first, orchardId: orchardId, crateId: crateId), kind: kind, key: key);
    final out = <ItemVersion>[];
    var current = false;
    int? before;
    // At most five pages (500 versions): 30 days of an item's changes.
    for (var page = 0; page < 5; page++) {
      final p = await server.itemHistory(crateId, itemId: itemId, before: before);
      if (!current) {
        current = true;
        final now = p.current[itemId];
        final opened = now?.item == null ? null : await _openVersion(db, orchardId, crateId, now!.item!, record, me);
        if (opened != null && opened.kind == kind && opened.key == key) {
          out.add(ItemVersion(record: opened, revision: now!.revision, replacedAt: null));
        }
      }
      for (final v in p.versions) {
        final opened = await _openVersion(db, orchardId, crateId, v.item, record, me);
        if (opened == null || opened.kind != kind || opened.key != key) continue;
        out.add(ItemVersion(record: opened, revision: v.revision, replacedAt: v.replacedAt, historyId: v.id));
      }
      if (!p.more || p.versions.isEmpty) break;
      before = p.versions.last.id;
    }
    return out;
  }

  /// The changes to [crateId]'s items version history kept, newest first:
  /// each version that replaced another, with the one it replaced. Read
  /// further back with [before] (the last page's [CrateChangesPage.before]).
  Future<CrateChangesPage> crateChanges(String orchardId, String crateId, {int? before}) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final record = await LocalRecord.load(db, orchardId);
    final p = await server.itemHistory(crateId, before: before);
    // The version that replaced each: the next newer one of the same item,
    // on this page or the item as it is now.
    final newer = <String, ItemVersion?>{};
    Future<ItemVersion?> currentOf(String itemId) async {
      final now = p.current[itemId];
      final opened = now?.item == null ? null : await _openVersion(db, orchardId, crateId, now!.item!, record, me);
      return opened == null ? null : ItemVersion(record: opened, revision: now!.revision, replacedAt: null);
    }

    final changes = <CrateChange>[];
    for (final v in p.versions) {
      final after = newer.containsKey(v.itemId) ? newer[v.itemId] : await currentOf(v.itemId);
      final opened = await _openVersion(db, orchardId, crateId, v.item, record, me);
      final previous =
          opened == null ? null : ItemVersion(record: opened, revision: v.revision, replacedAt: v.replacedAt, historyId: v.id);
      newer[v.itemId] = previous;
      if (after == null || previous == null) continue;
      if (after.record.kind != previous.record.kind || after.record.key != previous.record.key) continue;
      changes.add(CrateChange(version: after, previous: previous));
    }
    return CrateChangesPage(
      changes: changes,
      since: p.since,
      more: p.more,
      before: p.more && p.versions.isNotEmpty ? p.versions.last.id : null,
    );
  }

  /// Puts [version] back as the item's version, a change of this account's
  /// that the next sync sends (edit; add when the item is in the trash).
  Future<void> putVersionBack(String orchardId, ItemVersion version) async {
    if (version.record.deleted) throw ArgumentError('A deletion is put back from the trash');
    final db = await databases.open(orchardId);
    await db.transaction(() => _writeVersion(db, version.record));
    db.notifyOrchardItemsChanged();
  }

  /// Writes [rec]'s rows on this device as a change of this account's (the
  /// write guard checks it, the outbox queues it), with what a newer app
  /// put in it kept along.
  Future<void> _writeVersion(AppDatabase db, ItemRecord rec) async {
    final store = OrchardItemStore(db);
    await store.write(rec.kind, rec.key, data: rec.data, editedAt: DateTime.now().millisecondsSinceEpoch);
    await db.customStatement(
      'UPDATE crate_items_meta SET extra = ? WHERE kind = ? AND item_key = ?',
      [store.extrasOf(rec.kind, rec.data!, record: rec.extra).encode(), rec.kind, rec.key],
    );
  }

  /// Opens and checks [item], read from [crateId]: null when it does not
  /// open under the Crate's key of its generation, its signature does not
  /// verify, or it does not stand against [record].
  Future<ItemRecord?> _openVersion(
    AppDatabase db,
    String orchardId,
    String crateId,
    SealedItem item,
    LocalRecord record,
    CrateAuthor me,
  ) async {
    final crateKey = await OrchardService._secret(db, orchardId, crateId, item.keyGeneration);
    final first = await OrchardService._secret(db, orchardId, crateId, 1);
    if (crateKey == null || first == null) return null;
    final members = MemberDirectory(db);
    try {
      final rec = await openItem(
        item,
        orchardId: orchardId,
        crateId: crateId,
        crateKey: crateKey,
        idKey: await crateItemIdKey(first, orchardId: orchardId, crateId: crateId),
        signers: (uid, version) async => uid == me.uid && version == me.keys.version
            ? me.keys.signingPublicKey
            : members.signingKey(uid, version),
      );
      return await checkVersionAnchor(record, rec, crateId) == VersionStanding.allowed ? rec : null;
    } on ItemRejected {
      return null;
    }
  }
}
