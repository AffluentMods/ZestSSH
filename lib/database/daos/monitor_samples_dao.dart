import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/monitor_samples.dart';

part 'monitor_samples_dao.g.dart';

/// Data access for the device-local Server Monitor history
/// ([MonitorSamples]). Insertion happens on every completed check; the pruning
/// / downsampling orchestration lives in `MonitorHistoryService`, which drives
/// these primitives.
@DriftAccessor(tables: [MonitorSamples])
class MonitorSamplesDao extends DatabaseAccessor<AppDatabase>
    with _$MonitorSamplesDaoMixin {
  MonitorSamplesDao(super.db);

  /// Insert one sample. Returns the new rowid.
  Future<int> insertSample(MonitorSamplesCompanion sample) =>
      into(monitorSamples).insert(sample);

  /// Insert many samples in one batch (used by downsampling).
  Future<void> insertSamples(List<MonitorSamplesCompanion> samples) async {
    if (samples.isEmpty) return;
    await batch((b) => b.insertAll(monitorSamples, samples));
  }

  /// All samples for a host at or after [since], oldest first. Drives the
  /// history chart (a later UI phase).
  Future<List<MonitorSample>> rangeFor(String connectionId, DateTime since) {
    return (select(monitorSamples)
          ..where((t) =>
              t.connectionId.equals(connectionId) &
              t.capturedAt.isBiggerOrEqualValue(since))
          ..orderBy([(t) => OrderingTerm.asc(t.capturedAt)]))
        .get();
  }

  /// The most recent [limit] samples for a host, returned oldest→newest - the
  /// source for the desktop "Last 24 checks" status strip (§1). Includes failed
  /// checks (ok = false) so a gap renders as a neutral block.
  Future<List<MonitorSample>> recentFor(String connectionId,
      {int limit = 24}) async {
    final rows = await (select(monitorSamples)
          ..where((t) => t.connectionId.equals(connectionId))
          ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)])
          ..limit(limit))
        .get();
    return rows.reversed.toList();
  }

  /// Watch samples for a host at or after [since], oldest first.
  Stream<List<MonitorSample>> watchRangeFor(
      String connectionId, DateTime since) {
    return (select(monitorSamples)
          ..where((t) =>
              t.connectionId.equals(connectionId) &
              t.capturedAt.isBiggerOrEqualValue(since))
          ..orderBy([(t) => OrderingTerm.asc(t.capturedAt)]))
        .watch();
  }

  /// Raw (full-resolution) rows older than [cutoff], oldest first - the
  /// candidates for downsampling.
  Future<List<MonitorSample>> rawSamplesOlderThan(DateTime cutoff) {
    return (select(monitorSamples)
          ..where((t) =>
              t.resolutionSeconds.equals(0) &
              t.capturedAt.isSmallerThanValue(cutoff))
          ..orderBy([(t) => OrderingTerm.asc(t.capturedAt)]))
        .get();
  }

  /// Delete raw (full-resolution) rows older than [cutoff]. Called after their
  /// 15-minute aggregates have been written.
  Future<int> deleteRawOlderThan(DateTime cutoff) {
    return (delete(monitorSamples)
          ..where((t) =>
              t.resolutionSeconds.equals(0) &
              t.capturedAt.isSmallerThanValue(cutoff)))
        .go();
  }

  /// Delete every row older than [cutoff] regardless of resolution (final
  /// discard past the retention window).
  Future<int> deleteOlderThan(DateTime cutoff) {
    return (delete(monitorSamples)
          ..where((t) => t.capturedAt.isSmallerThanValue(cutoff)))
        .go();
  }

  /// Delete all history for a host (e.g. when the connection is removed).
  Future<int> deleteForHost(String connectionId) {
    return (delete(monitorSamples)
          ..where((t) => t.connectionId.equals(connectionId)))
        .go();
  }

  /// Distinct connection ids present in the history table.
  Future<List<String>> distinctConnectionIds() async {
    final q = selectOnly(monitorSamples, distinct: true)
      ..addColumns([monitorSamples.connectionId]);
    final rows = await q.get();
    return rows
        .map((r) => r.read(monitorSamples.connectionId))
        .whereType<String>()
        .toList();
  }

  /// Row count for a host.
  Future<int> countForHost(String connectionId) async {
    final count = monitorSamples.id.count();
    final q = selectOnly(monitorSamples)
      ..addColumns([count])
      ..where(monitorSamples.connectionId.equals(connectionId));
    final row = await q.getSingle();
    return row.read(count) ?? 0;
  }

  /// Backstop pruning: keep at most [maxRows] rows for [connectionId],
  /// deleting the oldest beyond that.
  Future<int> enforceHostCap(String connectionId, int maxRows) async {
    final total = await countForHost(connectionId);
    if (total <= maxRows) return 0;
    final excess = total - maxRows;
    final oldest = await (select(monitorSamples)
          ..where((t) => t.connectionId.equals(connectionId))
          ..orderBy([(t) => OrderingTerm.asc(t.capturedAt)])
          ..limit(excess))
        .get();
    if (oldest.isEmpty) return 0;
    final ids = oldest.map((r) => r.id).toList();
    return (delete(monitorSamples)..where((t) => t.id.isIn(ids))).go();
  }
}
