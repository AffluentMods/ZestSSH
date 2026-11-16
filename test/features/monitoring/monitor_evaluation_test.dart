import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/utils/redactor.dart';

/// Server Monitor's status for a host, and what its tooltip says.
///
/// Two rules, which the status used to break (it held a status for N checks
/// in both directions, and named whichever metric was "closest" when none
/// was over a limit: a host whose disk had been cleaned up stayed Critical
/// and read "RAM is at 42%, over the 85% critical limit"):
///
///  * The status is never worse than what the latest check found. A level
///    shows once the last N checks in a row all reach it, so a lone spike
///    never raises the status, and a host back within its limits is healthy
///    at that check.
///  * The tooltip says only what the latest check found: a metric within its
///    limits is never named as being over one.

final now = DateTime.utc(2026, 10, 1, 12);
final l10n = lookupAppLocalizations(const Locale('en'));

/// One check's figures. The defaults are a host well within every limit
/// (the limits: CPU and RAM 70/85, disk 80/90, swap 60/85, temp 70/85).
ServerStats reading({
  double? cpu = 5,
  double? ram = 42,
  double? disk = 52,
  double? swap = 0,
  double? temp,
}) =>
    ServerStats(
      cpuPercent: cpu,
      ramUsedMB: ram == null ? null : (ram * 10).round(),
      ramTotalMB: ram == null ? null : 1000,
      diskPercent: disk,
      swapPercent: swap,
      tempC: temp,
      collectedAt: now.subtract(const Duration(seconds: 12)),
      source: MetricSource.ssh,
    );

ServerStats fine() => reading();
ServerStats warning() => reading(disk: 85);
ServerStats critical() => reading(disk: 95);

MonitorHostView resolve(
  List<ServerStats> history, {
  int n = 2,
  int? latencyMs,
  ServerStats? stats,
  Map<MonitorMetric, MetricThreshold> thresholds = kDefaultThresholds,
}) =>
    resolveMonitorHost(
      history: history,
      stats: stats ?? history.last,
      health: latencyMs == null
          ? null
          : HealthCheckResult(status: ConnectionHealth.online, latencyMs: latencyMs, checkedAt: now),
      monitor: MonitorHostStatus(MonitorHostState.ok, updatedAt: now),
      hasActiveSession: false,
      thresholds: thresholds,
      debounceReadings: n,
      staleAfter: const Duration(minutes: 15),
      now: now,
    );

String tip(MonitorHostView view, {AppLocalizations? l}) =>
    monitorPillTooltip(view, l ?? l10n, checkedPhrase: '12s ago');

void main() {
  group('the status', () {
    test('a host whose disk was cleaned up is healthy at that very check, and nothing is named as over a limit', () {
      final full = [for (var i = 0; i < 20; i++) critical()];
      var view = resolve(full);
      expect(view.bucket, MonitorBucket.critical);
      expect(view.breachedMetric, MonitorMetric.disk);
      expect(tip(view), 'Disk is at 95%, over the 90% critical limit.\nOther metrics are within limits. Checked 12s ago.');

      view = resolve([...full, fine()]);
      expect(view.bucket, MonitorBucket.healthy);
      expect(view.breachedMetric, isNull);
      expect(view.pendingReadings, isNull);
      expect(view.overLimit, isEmpty);
      expect(tip(view), 'All metrics within limits. Checked 12s ago.');
      expect(healthChipsFor(view, l10n), isEmpty);
      expect(hostNeedsAttention(view, changedHostKey: false), isFalse);
    });

    test('a lone spike does not raise it, and the tooltip says what was found and when the status would change', () {
      var view = resolve([fine(), fine(), critical()]);
      expect(view.bucket, MonitorBucket.healthy);
      expect(view.pendingReadings, 2);
      expect(
        tip(view),
        'Disk is at 95%, over the 90% critical limit.\n'
        'The status changes when 2 checks in a row find this.\n'
        'Other metrics are within limits. Checked 12s ago.',
      );
      // The Hosts page counts what the status says, not a single reading.
      expect(healthChipsFor(view, l10n), isEmpty);
      expect(hostNeedsAttention(view, changedHostKey: false), isFalse);

      view = resolve([fine(), fine(), critical(), fine()]);
      expect(view.bucket, MonitorBucket.healthy);
      expect(view.pendingReadings, isNull);
      expect(tip(view), 'All metrics within limits. Checked 12s ago.');
    });

    test('as many checks in a row as the person set raise it', () {
      var view = resolve([fine(), critical(), critical()]);
      expect(view.bucket, MonitorBucket.critical);
      expect(view.pendingReadings, isNull);
      expect(tip(view), 'Disk is at 95%, over the 90% critical limit.\nOther metrics are within limits. Checked 12s ago.');
      expect(healthChipsFor(view, l10n).single.label, 'Disk 95%');

      // Three in a row when set to three.
      view = resolve([fine(), critical(), critical()], n: 3);
      expect(view.bucket, MonitorBucket.healthy);
      expect(view.pendingReadings, 3);
      expect(tip(view), contains('The status changes when 3 checks in a row find this.'));
      expect(resolve([fine(), critical(), critical(), critical()], n: 3).bucket, MonitorBucket.critical);
      // An interruption starts the count again.
      expect(resolve([critical(), critical(), fine(), critical(), critical()], n: 3).bucket, MonitorBucket.healthy);
    });

    test('set to one, every check counts at once', () {
      expect(resolve([fine(), critical()], n: 1).bucket, MonitorBucket.critical);
      expect(resolve([fine(), critical()], n: 1).pendingReadings, isNull);
      expect(resolve([critical(), fine()], n: 1).bucket, MonitorBucket.healthy);
      // Nonsense below one is one.
      expect(resolve([fine(), critical()], n: 0).bucket, MonitorBucket.critical);
      expect(resolve([fine(), critical()], n: -3).bucket, MonitorBucket.critical);
    });

    test('a host that got better but not well shows what the latest check found', () {
      final view = resolve([critical(), critical(), critical(), warning()]);
      expect(view.bucket, MonitorBucket.warning);
      expect(view.pendingReadings, isNull);
      expect(tip(view), 'Disk is at 85%, over the 80% warning limit.\nOther metrics are within limits. Checked 12s ago.');
    });

    test('a host getting worse step by step shows the level every one of the last checks reached', () {
      var view = resolve([fine(), warning(), critical()]);
      expect(view.bucket, MonitorBucket.warning);
      expect(view.pendingReadings, 2);
      expect(
        tip(view),
        'Disk is at 95%, over the 90% critical limit.\n'
        'The status changes when 2 checks in a row find this.\n'
        'Other metrics are within limits. Checked 12s ago.',
      );
      view = resolve([fine(), warning(), critical(), critical()]);
      expect(view.bucket, MonitorBucket.critical);
      expect(view.pendingReadings, isNull);
    });

    test('a host that swings between warning and critical is at least warning throughout', () {
      final swings = <ServerStats>[fine()];
      for (var i = 0; i < 8; i++) {
        swings.add(i.isEven ? warning() : critical());
        if (i == 0) continue;
        expect(resolve(swings).bucket, MonitorBucket.warning, reason: 'after ${i + 1} swings');
      }
    });

    test('the first check counts at once', () {
      expect(resolve([critical()]).bucket, MonitorBucket.critical);
      expect(resolve([warning()], n: 5).bucket, MonitorBucket.warning);
      // Stats loaded at start, with no history yet: the sample stands alone.
      expect(resolve(const [], stats: critical()).bucket, MonitorBucket.critical);
      expect(resolve(const [], stats: fine()).bucket, MonitorBucket.healthy);
    });

    test('the latest check is the last reading, also before the history has it', () {
      final history = [critical(), critical()];
      expect(resolve(history, stats: fine()).bucket, MonitorBucket.healthy);
      // And it counts once, not twice, when the history has it.
      final spike = critical();
      expect(resolve([fine(), spike], stats: spike).bucket, MonitorBucket.healthy);
      expect(resolve([fine()], stats: spike).bucket, MonitorBucket.healthy);
    });

    test('for every run of checks: the worst level all of the last N reach, and never worse than the latest', () {
      const levels = [MetricSeverity.healthy, MetricSeverity.warning, MetricSeverity.critical];
      ServerStats at(MetricSeverity s) => switch (s) {
            MetricSeverity.healthy => fine(),
            MetricSeverity.warning => warning(),
            MetricSeverity.critical => critical(),
          };
      MonitorBucket bucketOf(MetricSeverity s) => switch (s) {
            MetricSeverity.healthy => MonitorBucket.healthy,
            MetricSeverity.warning => MonitorBucket.warning,
            MetricSeverity.critical => MonitorBucket.critical,
          };
      var runs = 0;
      void walk(List<MetricSeverity> run) {
        if (run.isNotEmpty) {
          for (var n = 1; n <= 4; n++) {
            final last = run.length > n ? run.sublist(run.length - n) : run;
            final expected = last.reduce((a, b) => a.rank < b.rank ? a : b);
            final view = resolve([for (final s in run) at(s)], n: n);
            final what = '${run.map((s) => s.name[0]).join()} with N=$n';
            expect(view.bucket, bucketOf(expected), reason: what);
            expect(expected.rank, lessThanOrEqualTo(run.last.rank), reason: what);
            expect(view.pendingReadings, run.last.rank > expected.rank ? n : null, reason: what);
            // Whatever the status, the tooltip names disk only when the
            // latest check found it over a limit.
            expect(tip(view).contains('Disk'), run.last != MetricSeverity.healthy, reason: what);
            expect(tip(view).contains('RAM'), isFalse, reason: what);
            runs++;
          }
        }
        if (run.length == 6) return;
        for (final s in levels) {
          walk([...run, s]);
        }
      }

      walk([]);
      expect(runs, (3 + 9 + 27 + 81 + 243 + 729) * 4);
    });

    test('a metric the host does not report neither counts nor is named', () {
      final view = resolve([reading(cpu: null, ram: null, swap: null), reading(cpu: null, ram: null, swap: null)]);
      expect(view.bucket, MonitorBucket.healthy);
      expect(view.metricEval(MonitorMetric.cpu)!.available, isFalse);
      // Only the disk is reported, and it is over: there are no other
      // metrics to call fine.
      final full = resolve([reading(cpu: null, ram: null, swap: null, disk: 95)]);
      expect(tip(full), 'Disk is at 95%, over the 90% critical limit.\nChecked 12s ago.');
    });

    test('the limits are the ones given: changing one changes the status of the same checks', () {
      final history = [reading(disk: 85), reading(disk: 85)];
      expect(resolve(history).bucket, MonitorBucket.warning);
      final strict = {...kDefaultThresholds, MonitorMetric.disk: const MetricThreshold(60, 80)};
      final view = resolve(history, thresholds: strict);
      expect(view.bucket, MonitorBucket.critical);
      expect(tip(view), startsWith('Disk is at 85%, over the 80% critical limit.'));
      final lax = {...kDefaultThresholds, MonitorMetric.disk: const MetricThreshold(90, 95)};
      expect(resolve(history, thresholds: lax).bucket, MonitorBucket.healthy);
    });

    test('a value on a limit is over it', () {
      expect(resolve([reading(disk: 80)]).bucket, MonitorBucket.warning);
      expect(resolve([reading(disk: 79.9)]).bucket, MonitorBucket.healthy);
      expect(resolve([reading(disk: 90)]).bucket, MonitorBucket.critical);
      expect(resolve([reading(disk: 89.9)]).bucket, MonitorBucket.warning);
    });
  });

  group('several metrics over a limit', () {
    test('each has its own line, critical before warning, the furthest over first among equals', () {
      final sample = reading(cpu: 72, ram: 91, disk: 96, swap: 88, temp: 61);
      final view = resolve([sample, sample]);
      expect(view.bucket, MonitorBucket.critical);
      // Over the warning limit by: swap 28, RAM 21, disk 16; CPU is a warning.
      expect([for (final e in view.overLimit) e.metric], [
        MonitorMetric.swap,
        MonitorMetric.ram,
        MonitorMetric.disk,
        MonitorMetric.cpu,
      ]);
      expect(view.breachedMetric, MonitorMetric.swap);
      expect(
        tip(view),
        'Swap is at 88%, over the 85% critical limit.\n'
        'RAM is at 91%, over the 85% critical limit.\n'
        'Disk is at 96%, over the 90% critical limit.\n'
        'CPU is at 72%, over the 70% warning limit.\n'
        'Other metrics are within limits. Checked 12s ago.',
      );
    });

    test('when every reported metric is over, nothing is called fine', () {
      final sample = reading(cpu: 99, ram: 99, disk: 99, swap: 99);
      final view = resolve([sample, sample]);
      expect(tip(view).split('\n'), hasLength(5));
      expect(tip(view), endsWith('\nChecked 12s ago.'));
      expect(tip(view), isNot(contains('Other metrics')));
    });

    test('a temperature reads in degrees', () {
      final sample = reading(temp: 88);
      expect(tip(resolve([sample, sample])), startsWith('Temp is at 88°C, over the 85°C critical limit.'));
    });
  });

  group('latency', () {
    test('counts at once, and is named with its own limit', () {
      final view = resolve([fine()], latencyMs: 500);
      expect(view.bucket, MonitorBucket.critical);
      expect(view.breachedMetric, MonitorMetric.latency);
      expect(tip(view), 'Latency is at 500ms, over the 400ms critical limit.\nOther metrics are within limits. Checked 12s ago.');
      expect(resolve([fine()], latencyMs: 200).bucket, MonitorBucket.warning);
      expect(resolve([fine()], latencyMs: 20).bucket, MonitorBucket.healthy);
    });

    test('only raises the status, and a gauge that would not change it is not said to be about to', () {
      // The disk has been over its warning limit for one check; the status
      // is critical already, for the latency.
      var view = resolve([fine(), warning()], latencyMs: 500);
      expect(view.bucket, MonitorBucket.critical);
      expect(view.pendingReadings, isNull);
      expect(
        tip(view),
        'Latency is at 500ms, over the 400ms critical limit.\n'
        'Disk is at 85%, over the 80% warning limit.\n'
        'Other metrics are within limits. Checked 12s ago.',
      );
      // A critical disk for one check with a latency warning: it would.
      view = resolve([fine(), critical()], latencyMs: 200);
      expect(view.bucket, MonitorBucket.warning);
      expect(view.pendingReadings, 2);
      expect(tip(view).split('\n'), [
        'Disk is at 95%, over the 90% critical limit.',
        'Latency is at 200ms, over the 150ms warning limit.',
        'The status changes when 2 checks in a row find this.',
        'Other metrics are within limits. Checked 12s ago.',
      ]);
      // A slow answer does not hide a critical disk.
      expect(resolve([critical(), critical()], latencyMs: 200).bucket, MonitorBucket.critical);
    });

    test('an old latency figure counts for nothing', () {
      final view = resolveMonitorHost(
        history: [fine()],
        stats: fine(),
        health: HealthCheckResult(
          status: ConnectionHealth.online,
          latencyMs: 900,
          checkedAt: now.subtract(const Duration(hours: 1)),
        ),
        monitor: MonitorHostStatus(MonitorHostState.ok, updatedAt: now),
        hasActiveSession: false,
        thresholds: kDefaultThresholds,
        debounceReadings: 2,
        staleAfter: const Duration(minutes: 15),
        now: now,
      );
      expect(view.bucket, MonitorBucket.healthy);
      expect(tip(view), 'All metrics within limits. Checked 12s ago.');
    });

    // The checks of whether hosts can be reached are off until their person
    // turns them on: Server Monitor's latency is timed on
    // the connection its figures come over, and needs none.
    MonitorHostView timed(
      ServerStats stats, {
      int? checked,
      Duration checkedAgo = Duration.zero,
      Duration goodFor = Duration.zero,
      Duration staleAfter = const Duration(minutes: 15),
    }) =>
        resolveMonitorHost(
          history: [stats],
          stats: stats,
          health: checked == null
              ? null
              : HealthCheckResult(
                  status: ConnectionHealth.online,
                  latencyMs: checked,
                  checkedAt: now.subtract(checkedAgo),
                  goodFor: goodFor,
                ),
          monitor: MonitorHostStatus(MonitorHostState.ok, updatedAt: now),
          hasActiveSession: false,
          thresholds: kDefaultThresholds,
          debounceReadings: 2,
          staleAfter: staleAfter,
          now: now,
        );

    test('is the round trip of the reading itself where it has one, so its limits hold with no check of whether the '
        'host can be reached', () {
      final view = timed(fine().copyWith(pingMs: 500));
      expect(view.bucket, MonitorBucket.critical);
      expect(view.breachedMetric, MonitorMetric.latency);
      expect(tip(view), 'Latency is at 500ms, over the 400ms critical limit.\nOther metrics are within limits. Checked 12s ago.');
      expect(timed(fine().copyWith(pingMs: 200)).bucket, MonitorBucket.warning);
      expect(timed(fine().copyWith(pingMs: 20)).bucket, MonitorBucket.healthy);
      // Both known: the reading's own, timed where its figures came from.
      expect(timed(fine().copyWith(pingMs: 20), checked: 900).bucket, MonitorBucket.healthy);
      expect(timed(fine().copyWith(pingMs: 500), checked: 20).bucket, MonitorBucket.critical);
      // A reading with none goes by a check's.
      expect(timed(fine(), checked: 500).bucket, MonitorBucket.critical);
      expect(timed(fine()).bucket, MonitorBucket.healthy);
      // And a reading too old to trust has no latency to show either.
      double? shown(MonitorHostView v) => v.metrics.firstWhere((m) => m.metric == MonitorMetric.latency).value;
      expect(shown(view), 500);
      final old = fine().copyWith(pingMs: 500, collectedAt: now.subtract(const Duration(hours: 2)));
      expect(shown(timed(old)), isNull);
    });

    test('a check\'s figure is not old before the next two checks were due, however little a reading is allowed', () {
      // Checked every five minutes, eight minutes ago; a reading is allowed
      // a minute and a half.
      const eight = Duration(minutes: 8);
      const allowed = Duration(seconds: 90);
      expect(timed(fine(), checked: 900, checkedAgo: eight, goodFor: const Duration(minutes: 10), staleAfter: allowed).bucket,
          MonitorBucket.critical);
      expect(timed(fine(), checked: 900, checkedAgo: eight, staleAfter: allowed).bucket, MonitorBucket.healthy,
          reason: 'nothing said of an interval: old');
      expect(
          timed(fine(), checked: 900, checkedAgo: const Duration(minutes: 11), goodFor: const Duration(minutes: 10), staleAfter: allowed)
              .bucket,
          MonitorBucket.healthy,
          reason: 'past its own two intervals');
    });
  });

  group('what cannot be checked', () {
    setUp(() => L10nGlobal.update(l10n));

    MonitorHostView at(
      MonitorHostState state, {
      ServerStats? stats,
      Object? failedWith,
      bool signInRefused = false,
      bool notTriedAgain = false,
      bool hostKeyChanged = false,
      ConnectionHealth? ping,
    }) =>
        resolveMonitorHost(
          history: [?stats],
          stats: stats,
          health: ping == null ? null : HealthCheckResult(status: ping, checkedAt: now),
          monitor: MonitorHostStatus(
            state,
            failedWith: failedWith,
            signInRefused: signInRefused,
            notTriedAgain: notTriedAgain,
            hostKeyChanged: hostKeyChanged,
            updatedAt: now,
          ),
          hasActiveSession: false,
          thresholds: kDefaultThresholds,
          debounceReadings: 2,
          staleAfter: const Duration(minutes: 15),
          now: now,
        );

    /// A host whose check failed with [failedWith].
    MonitorHostView failed(
      Object failedWith, {
      bool signInRefused = false,
      bool notTriedAgain = false,
      ConnectionHealth? ping,
    }) =>
        at(MonitorHostState.error,
            failedWith: failedWith, signInRefused: signInRefused, notTriedAgain: notTriedAgain, ping: ping);

    /// A jump host on the way to db-primary that failed with [cause] at [stage].
    JumpHostFailure via(JumpStage stage, Object cause) => JumpHostFailure(
        label: 'vpn-gateway', host: '192.168.10.23', port: 22, stage: stage, cause: cause, onward: 'db-primary');

    final refusedAll = SSHAuthFailError('All authentication methods failed');
    final timedOut = TimeoutException('Connection timed out', const Duration(seconds: 10));
    const notThere = JumpChainBroken(
        'The jump host that db-primary is set to connect through is no longer there. Open db-primary and pick '
        'another under Connect Via, or None.');

    test('says why, whatever the last figures were', () {
      expect(at(MonitorHostState.needsCredentials, stats: critical()).cantCheckReason, CantCheckReason.noCredentials);
      expect(at(MonitorHostState.needsHostKeyReview, stats: critical()).cantCheckReason, CantCheckReason.hostKeyReview);
      expect(at(MonitorHostState.error, stats: critical(), failedWith: timedOut).cantCheckReason,
          CantCheckReason.unreachable);
      expect(at(MonitorHostState.connecting).cantCheckReason, CantCheckReason.connecting);
      expect(at(MonitorHostState.connecting).bucket, MonitorBucket.cantCheck);
    });

    // A phone on cellular, its hosts at home: every try times out, and each
    // was "Connecting to collect stats." for as long as it took, under
    // figures five days old. A try after one that failed says why that one
    // failed, and that it is tried again; "Connecting" is said only where
    // no try before it failed.
    test('a host tried again after a try that failed says why that one failed, not "Connecting"', () {
      String says(MonitorHostView view) => monitorPillTooltip(view, l10n, host: 'web-01', port: 22);
      final old = ServerStats(cpuPercent: 10, collectedAt: now.subtract(const Duration(days: 5)));

      final again = at(MonitorHostState.connecting, stats: old, failedWith: timedOut);
      expect(again.cantCheckReason, CantCheckReason.unreachable);
      expect(again.tryingAgain, isTrue);
      expect(again.statsStale, isTrue, reason: 'the old figures are still said to be old');
      expect(says(again),
          'The host could not be reached.\nCould not reach web-01 within the timeout period.\nTrying again now.');
      expect(says(again), isNot(contains(l10n.zestMonitorTipConnecting)));

      // Once that try has failed too: why, and nothing said of a try.
      final failedAgain = at(MonitorHostState.error, stats: old, failedWith: timedOut);
      expect(says(failedAgain), 'The host could not be reached.\nCould not reach web-01 within the timeout period.');
      expect(failedAgain.tryingAgain, isFalse);

      // A refused sign-in tried again (its person asked) says it was refused.
      final askedAgain = at(MonitorHostState.connecting, failedWith: refusedAll, signInRefused: true);
      expect(askedAgain.cantCheckReason, CantCheckReason.authFailed);
      expect(says(askedAgain), 'The host refused the sign-in.\nTrying again now.');

      // The first try, with no failure before it: connecting, as it is.
      expect(says(at(MonitorHostState.connecting, stats: old)), l10n.zestMonitorTipConnecting);
      expect(at(MonitorHostState.connecting, stats: old).tryingAgain, isFalse);
    });

    test('a check that failed is filed by what it failed with: a sign-in the host refused, a host that could not be '
        'reached, or a check that failed for another reason', () {
      expect(failed(refusedAll, signInRefused: true).cantCheckReason, CantCheckReason.authFailed);
      for (final Object onTheWay in [
        timedOut,
        const SocketException('Connection refused', osError: OSError('Connection refused', 111)),
        const SocketException("Failed host lookup: 'web-01.example.com'"),
        const SocketException('No route to host', osError: OSError('No route to host', 113)),
        SSHNoAnswerError(const Duration(seconds: 30), 3),
      ]) {
        expect(failed(onTheWay).cantCheckReason, CantCheckReason.unreachable, reason: '$onTheWay');
      }
      for (final Object other in [
        SSHAuthAbortError('Connection closed before authentication'),
        SSHHandshakeError('No matching key exchange algorithm'),
        notThere,
        const MonitorNoFigures('The host gave no figures when it was asked.'),
        StateError('anything else'),
      ]) {
        expect(failed(other).cantCheckReason, CantCheckReason.checkFailed, reason: '$other');
      }
      // What it failed with is handed on as it is, for whoever shows the host.
      expect(failed(timedOut).failedWith, same(timedOut));
      expect(at(MonitorHostState.needsCredentials).failedWith, isNull);
    });

    test('and not by words in it, nor by whether the host answers a check of whether it can be reached', () {
      // (Each of these was a failed sign-in, with a link to the host's sign-in details.)
      expect(failed(timedOut, ping: ConnectionHealth.online).cantCheckReason, CantCheckReason.unreachable);
      expect(failed(notThere, ping: ConnectionHealth.online).cantCheckReason, CantCheckReason.checkFailed);
      expect(failed(SSHAuthAbortError('Connection closed before authentication')).cantCheckReason,
          CantCheckReason.checkFailed);
      expect(failed(StateError('the password manager rejected the credential')).cantCheckReason,
          CantCheckReason.checkFailed);
      // A sign-in the host refused is one whatever a check of whether it can be reached says.
      expect(failed(refusedAll, signInRefused: true, ping: ConnectionHealth.offline).cantCheckReason,
          CantCheckReason.authFailed);
    });

    test('a jump host on the way: the host is not reached where the jump host was not, or could not reach the next '
        'one itself; what else a jump host failed with is a check that failed, its own refused sign-in too', () {
      expect(failed(via(JumpStage.reach, const SocketException('Connection refused'))).cantCheckReason,
          CantCheckReason.unreachable);
      expect(failed(via(JumpStage.reach, timedOut)).cantCheckReason, CantCheckReason.unreachable);
      expect(failed(via(JumpStage.onward, SSHChannelOpenError(2, 'connect failed: Connection refused'))).cantCheckReason,
          CantCheckReason.unreachable);
      // It was reached, and what it had with this app did not work.
      expect(failed(via(JumpStage.reach, SSHHandshakeError('No matching key exchange algorithm'))).cantCheckReason,
          CantCheckReason.checkFailed);
      expect(failed(via(JumpStage.onward, SSHChannelOpenError(1, 'open failed'))).cantCheckReason,
          CantCheckReason.checkFailed);
      expect(failed(via(JumpStage.onward, timedOut)).cantCheckReason, CantCheckReason.checkFailed);
      expect(failed(via(JumpStage.details, StateError('no key'))).cantCheckReason, CantCheckReason.checkFailed);
      // The jump host refused its own sign-in: the host is held as for one (nothing is tried by a timer), and it
      // is not the host's sign-in that is to be mended.
      final refusedThere = failed(via(JumpStage.signIn, refusedAll), signInRefused: true);
      expect(refusedThere.cantCheckReason, CantCheckReason.checkFailed);
      expect(monitorCantCheckAction(refusedThere.cantCheckReason!), isNull);
      expect(monitorCantCheckAction(CantCheckReason.authFailed), MonitorCantCheckAction.fixCredential);
    });

    test('the tooltip says what kind of failure it was, and behind it what the check failed with, as a session that '
        'failed the same way is told', () {
      String says(MonitorHostView view) =>
          monitorPillTooltip(view, l10n, rejectedUser: 'deploy', host: 'web-01', port: 2222);

      expect(says(failed(timedOut)),
          'The host could not be reached.\nCould not reach web-01 within the timeout period.');
      expect(says(failed(const SocketException('Connection refused'))),
          'The host could not be reached.\nweb-01 is not accepting connections on port 2222.');
      // A sign-in the host refused: that, and who was refused. (What a session is told of it would be that the
      // server closed the connection before the sign-in was done, which it did not.) Where the host ended the
      // connection saying why, what it said.
      expect(says(failed(refusedAll, signInRefused: true)), 'The host refused the sign-in.\nRejected user deploy.');
      final tooMany = SSHAuthAbortError('Connection closed before authentication',
          SSHDisconnectError(2, 'Too many authentication failures', authentic: true));
      expect(
        says(failed(tooMany, signInRefused: true)),
        'The host refused the sign-in.\nRejected user deploy.\n'
        'The host ended the connection. Its reason: Too many authentication failures',
      );
      expect(monitorPillTooltip(failed(refusedAll, signInRefused: true), l10n), 'The host refused the sign-in.');
      // The app's own words for it, which say what to do.
      expect(says(failed(notThere)), 'The check could not be made.\n${notThere.message}');
      expect(
        says(failed(via(JumpStage.onward, SSHChannelOpenError(1, 'open failed')))),
        'The check could not be made.\nThe jump host vpn-gateway does not pass connections on to db-primary: '
        'forwarding is turned off there, or not allowed for this account or key.',
      );
      expect(
        says(failed(via(JumpStage.reach, const SocketException('Connection refused')))).split('\n'),
        ['The host could not be reached.', startsWith('The jump host vpn-gateway could not be reached. ')],
      );
      // What the host said when it ended the connection.
      final ended = SSHAuthAbortError('Connection closed before authentication',
          SSHDisconnectError(12, 'Too many connections', authentic: true));
      expect(says(failed(ended)),
          'The check could not be made.\nThe host ended the connection. Its reason: Too many connections');
      expect(says(failed(const MonitorNoFigures('The host gave no figures when it was asked.'))),
          'The check could not be made.\nThe host gave no figures when it was asked.');

      // With no check of it at all, a host that does not answer the checks of whether it can be reached: as it was.
      final noAnswer = resolveMonitorHost(
        history: const [],
        stats: null,
        health: HealthCheckResult(status: ConnectionHealth.offline, checkedAt: now),
        monitor: null,
        hasActiveSession: false,
        thresholds: kDefaultThresholds,
        debounceReadings: 2,
        staleAfter: const Duration(minutes: 15),
        now: now,
      );
      expect((noAnswer.cantCheckReason, says(noAnswer)), (CantCheckReason.unreachable, 'No response to ping or SSH.'));
    });

    test('a host whose key this device has not seen is said as that, and not as one whose key changed', () {
      // (Both were "The host key changed": of a host nobody had connected to yet, that is alarming and untrue.)
      expect(
        monitorPillTooltip(at(MonitorHostState.needsHostKeyReview), l10n),
        'This device has not seen this host\'s key before. Open a terminal to it and check the key: monitoring '
        'begins once the key is trusted.',
      );
      expect(monitorPillTooltip(at(MonitorHostState.needsHostKeyReview, hostKeyChanged: true), l10n),
          'The host key changed. Open a terminal to review it before monitoring resumes.');
      // Either way it is a key to look at, and nothing a check found of the host.
      for (final changed in [false, true]) {
        final view = at(MonitorHostState.needsHostKeyReview, hostKeyChanged: changed);
        expect((view.cantCheckReason, view.hostKeyChanged, view.notTriedAgain),
            (CantCheckReason.hostKeyReview, changed, false));
      }
    });

    test('a host that no timer tries again says so, last, with how it is tried again: a sign-in it refused, and a '
        'connection that ended over what no timer changes; a host that is tried again says nothing of it', () {
      String says(MonitorHostView view) =>
          monitorPillTooltip(view, l10n, rejectedUser: 'deploy', host: 'web-01', port: 2222);
      const held = 'It is not tried again by itself: every try would end the same way. Refresh to try again.';
      expect(l10n.zestMonitorTipNotTriedAgain, held);

      expect(says(failed(refusedAll, signInRefused: true, notTriedAgain: true)),
          'The host refused the sign-in.\nRejected user deploy.\n$held');
      // After what the host said when it refused, where it said something.
      final tooMany = SSHAuthAbortError('Connection closed before authentication',
          SSHDisconnectError(2, 'Too many authentication failures', authentic: true));
      expect(
        says(failed(tooMany, signInRefused: true, notTriedAgain: true)),
        'The host refused the sign-in.\nRejected user deploy.\n'
        'The host ended the connection. Its reason: Too many authentication failures\n$held',
      );
      final tooShort = SSHAuthAbortError('Connection closed before authentication',
          SSHKexGroupError('of 1024 bits', bits: 1024, shortestTaken: 2048));
      expect(says(failed(tooShort, notTriedAgain: true)).split('\n'), [
        'The check could not be made.',
        startsWith('This host offers only an outdated key exchange (a group of 1024 bits; none under 2048 bits is '
            'taken)'),
        held,
      ]);
      final notSigned = SSHHostkeyError('Signature verification failed', fault: SSHHostkeyFault.notSigned);
      expect(says(failed(via(JumpStage.signIn, notSigned), notTriedAgain: true)).split('\n'), [
        'The check could not be made.',
        startsWith('Signing in to the jump host vpn-gateway did not work. The host showed a key and could not prove '
            'that the key is its own'),
        held,
      ]);
      // The view is told by the status, and by nothing else.
      expect(failed(tooShort, notTriedAgain: true).notTriedAgain, isTrue);
      expect(failed(tooShort).notTriedAgain, isFalse);
      expect(says(failed(tooShort)), isNot(contains(held)));
      // A host that could not be reached is tried again, by a timer.
      expect(says(failed(timedOut)),
          'The host could not be reached.\nCould not reach web-01 within the timeout period.');
    });

    test('while recording, the names in what a check failed with are masked, as a session masks them', () {
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout
        ..registerNames(['vpn-gateway', 'db-primary', 'web-01']);
      addTearDown(() => Redactor.instance
        ..clearNames()
        ..enabled = false);
      for (final view in [
        failed(via(JumpStage.onward, SSHChannelOpenError(1, 'open failed'))),
        failed(via(JumpStage.reach, const SocketException('Connection refused'))),
        failed(notThere),
      ]) {
        final said = monitorPillTooltip(view, l10n, host: Redactable.host('web-01').display, port: 22);
        for (final name in ['vpn-gateway', 'db-primary', 'web-01']) {
          expect(said, isNot(contains(name)), reason: said);
        }
        expect(said.split('\n'), hasLength(2), reason: 'and it is still said');
      }
      // What a host said when it ended the connection, behind a refused sign-in, is masked as well.
      final named = SSHAuthAbortError('Connection closed before authentication',
          SSHDisconnectError(2, 'Too many authentication failures for deploy from vpn-gateway', authentic: true));
      expect(monitorPillTooltip(failed(named, signInRefused: true), l10n), isNot(contains('vpn-gateway')));
    });

    test('a check that failed has a report to copy, which says what was said of it and what it failed with; what '
        'cannot be checked for another reason has none', () {
      final view = failed(via(JumpStage.onward, SSHChannelOpenError(1, 'open failed')));
      final said = monitorPillTooltip(view, l10n, host: 'db-primary');
      final report = failedCheckReport(view, said)!;
      expect(report, contains('What: The check could not be made. The jump host vpn-gateway does not pass'));
      expect(report, contains('Where: Server Monitor: a check of a host'));
      expect(report, contains('SSHChannelOpenError'));
      expect(report, isNot(contains('What cut it off')));
      expect(failedCheckReport(at(MonitorHostState.needsCredentials), 'x'), isNull);

      // A sign-in that was cut off does not print what cut it off: the report has it behind the error, on a line
      // of its own, for the host and for a jump host on the way.
      final group = SSHKexGroupError('The server named a group of 1024 bits', bits: 1024, shortestTaken: 2048);
      final cutOff = SSHAuthAbortError('Connection closed before authentication', group);
      for (final failure in <Object>[cutOff, via(JumpStage.signIn, cutOff)]) {
        final lines = failedCheckReport(failed(failure), 'x')!.split('\n');
        final at = lines.indexWhere((line) => line.startsWith('Error: '));
        expect(lines[at], endsWith('SSHAuthAbortError(Connection closed before authentication)'), reason: '$failure');
        expect(lines[at + 1], '  What cut it off: SSHKexGroupError(The server named a group of 1024 bits)',
            reason: '$failure');
      }
      // One that nothing is known to have cut off has no such line.
      expect(failedCheckReport(failed(SSHAuthAbortError('Connection closed before authentication')), 'x'),
          isNot(contains('What cut it off')));
    });

    test('each kind of failure is said in every language', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        final lines = {
          l.zestMonitorTipSignInRefused,
          l.zestMonitorTipNotReached,
          l.zestMonitorTipCheckFailed,
          l.zestMonitorTipUnreachable,
          l.monitorNoFiguresCame,
          l.zestMonitorTipNotTriedAgain,
          l.zestMonitorTipHostKeyNew,
          l.zestMonitorTipHostKeyReview,
        };
        expect(lines, hasLength(8), reason: '$locale: each its own');
        if (locale.languageCode == 'en') continue;
        expect(l.zestMonitorTipNotTriedAgain, isNot(l10n.zestMonitorTipNotTriedAgain), reason: '$locale');
        expect(l.zestMonitorTipHostKeyNew, isNot(l10n.zestMonitorTipHostKeyNew), reason: '$locale');
        expect(l.zestMonitorTipSignInRefused, isNot(l10n.zestMonitorTipSignInRefused), reason: '$locale');
        expect(l.zestMonitorTipNotReached, isNot(l10n.zestMonitorTipNotReached), reason: '$locale');
        expect(l.zestMonitorTipCheckFailed, isNot(l10n.zestMonitorTipCheckFailed), reason: '$locale');
        expect(l.monitorNoFiguresCame, isNot(l10n.monitorNoFiguresCame), reason: '$locale');
      }
    });

    test('figures too old to trust are not a status', () {
      final old = ServerStats(
        diskPercent: 95,
        collectedAt: now.subtract(const Duration(hours: 2)),
        source: MetricSource.ssh,
      );
      final view = resolveMonitorHost(
        history: [old],
        stats: old,
        health: null,
        monitor: null,
        hasActiveSession: false,
        thresholds: kDefaultThresholds,
        debounceReadings: 2,
        staleAfter: const Duration(minutes: 15),
        now: now,
      );
      expect(view.bucket, MonitorBucket.cantCheck);
      expect(view.cantCheckReason, CantCheckReason.stale);
      expect(view.overLimit, isEmpty, reason: 'an old figure is not a live value');
    });
  });

  group('in every language', () {
    test('the tooltip of a status that waits has its three lines, with nothing left unfilled', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        for (var n = 2; n <= 10; n++) {
          final view = resolve([fine(), critical()], n: n);
          final lines = tip(view, l: l).split('\n');
          expect(lines, hasLength(3), reason: '$locale $n');
          for (final line in lines) {
            expect(line.trim(), isNotEmpty, reason: '$locale $n');
            expect(line, isNot(anyOf(contains('{'), contains('}'))), reason: '$locale $n: $line');
          }
          expect(lines[0], contains('95'), reason: '$locale');
          expect(lines[2], contains('12s ago'), reason: '$locale');
        }
        // The closing line alone, and the help for the setting.
        expect(l.zestMonitorTipChecked('12s ago'), contains('12s ago'), reason: '$locale');
        expect(l.zestThresholdDebounceHelp.trim(), isNotEmpty, reason: '$locale');
      }
      expect(AppLocalizations.supportedLocales, hasLength(12));
    });

    test('the number of checks is said in each language\'s own way', () {
      String pending(String code, int n) => lookupAppLocalizations(Locale(code)).zestMonitorTipPending(n);
      expect(pending('en', 2), 'The status changes when 2 checks in a row find this.');
      expect(pending('en', 1), 'The status changes when 1 check in a row finds this.');
      expect(pending('de', 3), 'Der Status ändert sich, wenn 3 Prüfungen in Folge dasselbe ergeben.');
      // Russian: 2 to 4 take one form, 5 and more another.
      expect(pending('ru', 2), contains('2 проверки подряд'));
      expect(pending('ru', 4), contains('4 проверки подряд'));
      expect(pending('ru', 5), contains('5 проверок подряд'));
      expect(pending('ru', 10), contains('10 проверок подряд'));
      // Arabic: two has a form of its own, 3 to 10 another.
      expect(pending('ar', 2), contains('فحصان متتاليان'));
      expect(pending('ar', 3), contains('3 فحوص متتالية'));
      expect(pending('ar', 10), contains('10 فحوص متتالية'));
    });
  });
}
