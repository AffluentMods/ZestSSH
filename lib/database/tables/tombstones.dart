import 'package:drift/drift.dart';

/// A "death certificate" for a deleted synced record, so the deletion
/// PROPAGATES across devices.
///
/// The sync merge only ever inserts/updates rows by id ([SyncDataService.
/// restoreAll]) - it never deletes a row that's merely absent from the blob.
/// A deletion is an *absence*, and absence doesn't survive a union merge, so
/// without this a host deleted on one device is silently re-added from another
/// device's blob (the "resurrection" bug). A tombstone turns the deletion into
/// a PRESENT record - "(entityType, entityId) was deleted at deletedAt" - that
/// rides the encrypted sync blob, telling every other device to remove that
/// record and not re-add it.
///
/// Conflict rule is "newest wins": a tombstone deletes the local record only
/// when the record was NOT modified after [deletedAt] (compared against the
/// record's `updatedAt`). Entities without an `updatedAt` fall back to
/// delete-wins. Tombstones are pruned by age (retention GC) to bound blob size.
@DataClassName('Tombstone')
class Tombstones extends Table {
  /// Which synced table the dead id belonged to - one of the fixed set the
  /// merge knows how to delete from (e.g. 'connections', 'identities',
  /// 'snippets', 'connection_groups', 'networks', 'port_forward_rules',
  /// 'snippet_categories', 'host_network_overrides',
  /// 'port_forward_network_overrides').
  TextColumn get entityType => text().withLength(min: 1, max: 64)();

  /// The deleted record's primary-key value: the UUID `id` for most tables, or
  /// the `name` PK for snippet_categories. Capped generously.
  TextColumn get entityId => text().withLength(min: 1, max: 256)();

  /// When the delete happened (device wall clock). The arbitration timestamp
  /// for "newest wins" and the key used by retention GC.
  DateTimeColumn get deletedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {entityType, entityId};
}
