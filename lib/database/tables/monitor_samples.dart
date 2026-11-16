import 'package:drift/drift.dart';

/// Device-local time-series of Server Monitor checks (host detail pane §4).
///
/// One row per host per completed check - successful checks carry the plotted
/// metrics, failed checks carry a null metric set with [ok] = false so the
/// history chart can draw truthful gaps. This table is **never synced** (it is
/// device-specific observation, not configuration); it is deliberately NOT
/// registered in `SyncDataService`.
///
/// Retention (see `MonitorHistoryService`): full-resolution rows
/// ([resolutionSeconds] = 0) are kept for 48h, then collapsed into 15-minute
/// averages ([resolutionSeconds] = 900) out to 30 days, then discarded. A
/// per-host row cap is the backstop, pruning oldest first.
///
/// The metric set is the six series the history chart plots (CPU, RAM, Swap,
/// Disk, Load, Temp) plus Ping. Per-mount filesystem usage and the "System"
/// facts are point-in-time (rendered from the live [ServerStats] sample), not
/// historized here - keeping rows compact for 48h full-resolution retention.
@DataClassName('MonitorSample')
@TableIndex(name: 'idx_monitor_samples_conn_time', columns: {#connectionId, #capturedAt})
@TableIndex(name: 'idx_monitor_samples_time', columns: {#capturedAt})
class MonitorSamples extends Table {
  /// Surrogate rowid key - this is a high-volume append table.
  IntColumn get id => integer().autoIncrement()();

  /// NON-FK reference to `connections.id`. A dangling row (host deleted) is
  /// simply pruned by retention; no cascade.
  TextColumn get connectionId => text()();

  /// When this check completed.
  DateTimeColumn get capturedAt => dateTime()();

  /// True for a successful check, false for a failed one (metrics all null).
  BoolColumn get ok => boolean().withDefault(const Constant(true))();

  /// Resolution of this row: 0 = raw full-resolution, 900 = 15-minute
  /// downsampled average. Lets retention avoid re-aggregating aggregate rows.
  IntColumn get resolutionSeconds => integer().withDefault(const Constant(0))();

  // ── Plotted metrics (all nullable; null = not reportable / failure) ──
  RealColumn get cpuPercent => real().nullable()();
  RealColumn get ramPercent => real().nullable()();
  RealColumn get swapPercent => real().nullable()();
  RealColumn get diskPercent => real().nullable()();
  RealColumn get load1 => real().nullable()();
  RealColumn get load5 => real().nullable()();
  RealColumn get load15 => real().nullable()();
  RealColumn get tempC => real().nullable()();
  IntColumn get pingMs => integer().nullable()();
}
