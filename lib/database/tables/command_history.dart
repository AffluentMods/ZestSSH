import 'package:drift/drift.dart';

/// Synced command history (v38): the commands the user actually ran, captured
/// client-side (echo-confirmed, passwords skipped) so they can be searched and
/// re-run across devices. A Squeezed (Pro) feature; the sync transport itself
/// stays free like all sync.
///
/// Synced + tombstoned, newest-wins with the universal updatedAt trigger. The
/// local table is capped (see [CommandHistoryDao.maxEntries]) so a
/// high-volume, append-only stream never bloats the config sync blob.
@DataClassName('CommandHistoryEntry')
class CommandHistory extends Table {
  TextColumn get id => text()();

  /// The exact command line the user ran.
  TextColumn get command => text().withLength(min: 1, max: 4096)();

  /// The host it ran on, or NULL when unknown. Plain id (no FK): a deleted host
  /// simply loses its back-reference, which is harmless.
  TextColumn get connectionId => text().nullable()();

  /// Denormalised host label, so history stays readable after the host record
  /// is gone.
  TextColumn get hostLabel => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Nullable + auto-bumped by the universal newest-wins trigger; drives sync.
  DateTimeColumn get updatedAt => dateTime().nullable()();

  // ── Record extension (v39, Phase 2b) ──────────────────────────────────────
  // Captured from OSC 133 / OSC 7 shell integration when the remote shell emits
  // it (many do not by default, so these stay NULL and the UI shows "Not
  // recorded"). LOCAL-ONLY: stripped from the sync dump so the blob shape does
  // not change (schema_version stays 16) and old devices never refuse a blob.

  /// The command's exit status, or NULL when the shell did not report one.
  IntColumn get exitCode => integer().nullable()();

  /// How long the command ran, in milliseconds, or NULL when not measured.
  IntColumn get durationMs => integer().nullable()();

  /// The working directory the command ran in (from OSC 7), or NULL.
  TextColumn get cwd => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
