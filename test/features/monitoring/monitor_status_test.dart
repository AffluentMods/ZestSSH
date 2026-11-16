import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// A host's state on the phone's Server Monitor, from what is known of it:
/// the figures of its last reading, a check of whether it can be reached
/// (where its person has those on), and whether a session is connected.
///
/// What changed with the checks: they are off until turned
/// on and run at an interval their person chose, so a check's result is not
/// old before the next two were due, however little time a reading is
/// allowed; and latency is the round trip of the reading itself where it has
/// one, so that it is known, and held to its limits, with no check at all.

final now = DateTime.utc(2026, 10, 9, 12);
const allowed = Duration(seconds: 90);

ServerStats reading({double cpu = 5, int? pingMs, Duration ago = const Duration(seconds: 12)}) => ServerStats(
      cpuPercent: cpu,
      ramUsedMB: 420,
      ramTotalMB: 1000,
      diskPercent: 52,
      pingMs: pingMs,
      collectedAt: now.subtract(ago),
      source: MetricSource.ssh,
    );

HealthCheckResult check(
  ConnectionHealth status, {
  int? latencyMs,
  Duration ago = const Duration(seconds: 10),
  Duration goodFor = Duration.zero,
}) =>
    HealthCheckResult(status: status, latencyMs: latencyMs, checkedAt: now.subtract(ago), goodFor: goodFor);

HostStatus at({HealthCheckResult? health, ServerStats? stats, bool session = false}) =>
    evaluateHost(health: health, stats: stats, hasActiveSession: session, threshold: allowed, now: now);

void main() {
  const online = ConnectionHealth.online;
  const offline = ConnectionHealth.offline;

  test('nothing known of a host is said as that, and a session alone says it is there', () {
    expect(at().severity, HostSeverity.unknown);
    expect(at(health: check(ConnectionHealth.unknown)).severity, HostSeverity.unknown);
    expect(at(session: true).severity, HostSeverity.healthy);
    expect(at(health: check(online)).severity, HostSeverity.healthy);
    expect(at(stats: reading()).severity, HostSeverity.healthy);
  });

  test('a host a fresh check could not reach is away, unless a session is connected to it', () {
    expect(at(health: check(offline)).severity, HostSeverity.offline);
    expect(at(health: check(offline), stats: reading(cpu: 99)).severity, HostSeverity.offline,
        reason: 'away comes before what its last figures were');
    expect(at(health: check(offline), session: true).severity, HostSeverity.healthy);
  });

  test('a check is not old before the next two were due: its own interval counts where that is longer than what a '
      'reading is allowed', () {
    // Checked every five minutes, eight minutes ago; a reading is allowed
    // a minute and a half.
    final everyFive = check(offline, ago: const Duration(minutes: 8), goodFor: const Duration(minutes: 10));
    expect(at(health: everyFive).severity, HostSeverity.offline);
    expect(at(health: everyFive).healthStale, isFalse);
    // The same age with nothing said of an interval: old.
    final plain = check(offline, ago: const Duration(minutes: 8));
    expect(at(health: plain).severity, HostSeverity.stale);
    expect((at(health: plain).healthStale, at(health: plain).isStale), (true, true));
    // And past its own two intervals: old as well.
    final long = check(offline, ago: const Duration(minutes: 11), goodFor: const Duration(minutes: 10));
    expect(at(health: long).severity, HostSeverity.stale);
  });

  test('a host is stale when everything known of it is old and no session is connected; one fresh thing is enough',
      () {
    final oldCheck = check(online, ago: const Duration(minutes: 5));
    final oldReading = reading(ago: const Duration(minutes: 5));
    expect(at(health: oldCheck, stats: oldReading).severity, HostSeverity.stale);
    expect(at(stats: oldReading).severity, HostSeverity.stale);
    expect(at(health: oldCheck).severity, HostSeverity.stale);
    expect(at(health: oldCheck, stats: oldReading, session: true).severity, HostSeverity.healthy);

    final one = at(health: oldCheck, stats: reading());
    expect((one.severity, one.statsStale, one.healthStale, one.isStale), (HostSeverity.healthy, false, true, false));
    final other = at(health: check(online), stats: oldReading);
    expect((other.severity, other.statsStale, other.healthStale, other.isStale),
        (HostSeverity.healthy, true, false, false));
  });

  test('latency is the round trip of the reading itself where it has one, so its limits hold with no check of '
      'whether the host can be reached', () {
    expect(at(stats: reading(pingMs: 300)).severity, HostSeverity.critical);
    expect(at(stats: reading(pingMs: 150)).severity, HostSeverity.warning);
    expect(at(stats: reading(pingMs: 20)).severity, HostSeverity.healthy);
    // Exactly at a limit is within it.
    expect(at(stats: reading(pingMs: kLatencyCriticalMs)).severity, HostSeverity.warning);
    expect(at(stats: reading(pingMs: kLatencyWarnMs)).severity, HostSeverity.healthy);

    // Both known: the reading's own, timed on the connection it came over.
    expect(at(stats: reading(pingMs: 20), health: check(online, latencyMs: 900)).severity, HostSeverity.healthy);
    expect(at(stats: reading(pingMs: 300), health: check(online, latencyMs: 20)).severity, HostSeverity.critical);
    // A reading with none: a check's, where there is one.
    expect(at(stats: reading(), health: check(online, latencyMs: 300)).severity, HostSeverity.critical);
    expect(at(stats: reading(), health: check(online, latencyMs: 150)).severity, HostSeverity.warning);
    expect(at(health: check(online, latencyMs: 300)).severity, HostSeverity.critical);
  });

  test('an old figure counts for nothing, whichever it is', () {
    final oldReading = reading(pingMs: 900, ago: const Duration(minutes: 5));
    final oldCheck = check(online, latencyMs: 900, ago: const Duration(minutes: 5));
    expect(at(stats: oldReading, health: check(online, latencyMs: 20)).severity, HostSeverity.healthy);
    expect(at(stats: reading(pingMs: 20), health: oldCheck).severity, HostSeverity.healthy);
    expect(at(stats: reading(), health: oldCheck).severity, HostSeverity.healthy);
    // An old reading's figure gives way to a fresh check's.
    expect(at(stats: oldReading, health: check(online, latencyMs: 300)).severity, HostSeverity.critical);
    // A check of every five minutes is not old at eight.
    final everyFive =
        check(online, latencyMs: 300, ago: const Duration(minutes: 8), goodFor: const Duration(minutes: 10));
    expect(at(stats: reading(), health: everyFive).severity, HostSeverity.critical);
  });

  test('figures over their limits, where nothing else decides', () {
    expect(at(stats: reading(cpu: 95)).severity, HostSeverity.critical);
    expect(at(stats: reading(cpu: 75)).severity, HostSeverity.warning);
    expect(at(stats: reading(cpu: 95, ago: const Duration(minutes: 5)), health: check(online)).severity,
        HostSeverity.healthy,
        reason: 'old figures are no status');
  });
}
