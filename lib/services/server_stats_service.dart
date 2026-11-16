import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/utils/logger.dart';

/// What a Linux host has counted since it started, in ticks: all processor
/// time ([total]), and the part of it in which the processors had nothing to
/// do ([idle], which includes waiting for a disk: that is no work for a
/// processor).
typedef CpuTimes = ({int total, int idle});

/// Which collection mechanism produced a [ServerStats] sample (Doc-3 B5).
enum MetricSource {
  /// Scraped from a Prometheus node_exporter target.
  prometheus,

  /// Collected over an active SSH session via lightweight shell commands.
  ssh,

  /// Unknown / unrecorded - e.g. cached data written before this field
  /// existed. Rendered without a source label.
  none,
}

/// Usage of one mounted filesystem (Server Monitor detail pane §2.3).
///
/// [usedPercent] is the reported capacity (0-100). All byte counts are exact
/// bytes. Immutable value type.
class FilesystemUsage {
  final String mount;
  final int usedBytes;
  final int totalBytes;
  final double usedPercent;

  const FilesystemUsage({
    required this.mount,
    required this.usedBytes,
    required this.totalBytes,
    required this.usedPercent,
  });
}

/// Server resource usage statistics.
///
/// Every field beyond the original CPU/RAM/Disk/uptime/load set is nullable and
/// defaults to null. Null means "the host cannot report this metric" and MUST
/// render as `N/A` downstream, never as `0`. Capability detection
/// (`MonitorCapabilities`) is derived from which of these come back non-null on
/// the first successful check.
class ServerStats {
  /// CPU usage percentage (0-100), or null if unavailable.
  final double? cpuPercent;

  /// RAM used in MB, or null if unavailable.
  final int? ramUsedMB;

  /// Total RAM in MB, or null if unavailable.
  final int? ramTotalMB;

  /// RAM usage percentage (0-100), or null if unavailable.
  double? get ramPercent =>
      (ramUsedMB != null && ramTotalMB != null && ramTotalMB! > 0)
          ? (ramUsedMB! / ramTotalMB!) * 100
          : null;

  /// How much of the memory in use is ZFS's ARC cache that the kernel can
  /// give back when a program needs it (its size above its floor, `c_min`),
  /// in MB; null on a host without ZFS. Linux counts the ARC as used, so a
  /// ZFS host reads nearly full while it is not.
  final int? zfsArcFreeableMB;

  /// [ramPercent], with the ARC that can be given back counted as free where
  /// [arcAsFree] (a host's choice in its panel) and the host has one.
  double? ramPercentWith({required bool arcAsFree}) {
    final used = ramUsedMB;
    final total = ramTotalMB;
    if (used == null || total == null || total <= 0) return null;
    final arc = arcAsFree ? (zfsArcFreeableMB ?? 0) : 0;
    return ((used - arc).clamp(0, total) / total) * 100;
  }

  /// Disk usage percentage (0-100) for root filesystem, or null if unavailable.
  final double? diskPercent;

  /// System uptime string (e.g. "5 days, 3:42"), or null if unavailable.
  final String? uptime;

  /// Load average [1m, 5m, 15m], or null if unavailable.
  final List<double>? loadAverage;

  /// Timestamp when these stats were collected.
  final DateTime collectedAt;

  /// Which mechanism produced this sample (Doc-3 B5). Defaults to
  /// [MetricSource.none] so legacy cached entries deserialize safely.
  final MetricSource source;

  // ── Extended metrics (Server Monitor host detail pane §3) ──────────
  // All nullable; null = not reportable = renders N/A.

  /// Swap usage percentage (0-100), or null if the host has no swap.
  final double? swapPercent;

  /// The host said it has no swap at all (SwapTotal 0 in /proc/meminfo), as
  /// against swap that could not be read: the monitor says "No swap" only
  /// for this.
  final bool noSwap;

  /// Highest CPU-package/thermal-zone temperature in °C, or null if the host
  /// has no thermal sensor (VMs, many appliances).
  final double? tempC;

  /// Round trip to the host in milliseconds, on the connection the stats
  /// come over (so through the hosts it is reached through, where there are
  /// any), or null where the host did not answer in time.
  final int? pingMs;

  /// System uptime in whole seconds (from `/proc/uptime`), or null.
  final int? uptimeSeconds;

  /// Per-mount filesystem usage (real filesystems only), fullest first. Empty
  /// when the host could not report any.
  final List<FilesystemUsage> filesystems;

  /// Inode usage percentage (0-100) for the root filesystem, or null.
  final double? inodesRootPercent;

  /// Whether the host is flagged as needing a restart
  /// (`/var/run/reboot-required`). Null when not determinable.
  final bool? restartRequired;

  /// Total pending package updates, or null if not reportable.
  final int? updatesTotal;

  /// Of [updatesTotal], how many are security updates, or null.
  final int? updatesSecurity;

  /// Number of failed systemd units, or null on non-systemd hosts.
  final int? failedUnits;

  /// Total process count, or null if not reportable.
  final int? processesTotal;

  /// Zombie process count, or null if not reportable.
  final int? zombieProcesses;

  /// OS pretty name (e.g. "Ubuntu 24.04.3 LTS"), or null. Cached per host.
  final String? osName;

  /// Kernel release (e.g. "6.8.0-124"), or null. Cached per host.
  final String? kernel;

  // ── Behind the column chooser, off by default (§3.2) ───────────────

  /// Network receive throughput in bytes/sec, or null if not measured.
  final double? netRxBytesPerSec;

  /// Network transmit throughput in bytes/sec, or null if not measured.
  final double? netTxBytesPerSec;

  /// Disk read throughput in bytes/sec, or null if not measured.
  final double? diskReadBytesPerSec;

  /// Disk write throughput in bytes/sec, or null if not measured.
  final double? diskWriteBytesPerSec;

  /// 1-minute load average, or null. Derived from [loadAverage].
  double? get load1 =>
      (loadAverage != null && loadAverage!.isNotEmpty) ? loadAverage![0] : null;

  /// 5-minute load average, or null. Derived from [loadAverage].
  double? get load5 =>
      (loadAverage != null && loadAverage!.length > 1) ? loadAverage![1] : null;

  /// 15-minute load average, or null. Derived from [loadAverage].
  double? get load15 =>
      (loadAverage != null && loadAverage!.length > 2) ? loadAverage![2] : null;

  const ServerStats({
    this.cpuPercent,
    this.ramUsedMB,
    this.ramTotalMB,
    this.diskPercent,
    this.uptime,
    this.loadAverage,
    required this.collectedAt,
    this.source = MetricSource.none,
    this.swapPercent,
    this.noSwap = false,
    this.tempC,
    this.pingMs,
    this.uptimeSeconds,
    this.filesystems = const [],
    this.inodesRootPercent,
    this.restartRequired,
    this.updatesTotal,
    this.updatesSecurity,
    this.failedUnits,
    this.processesTotal,
    this.zombieProcesses,
    this.osName,
    this.kernel,
    this.netRxBytesPerSec,
    this.netTxBytesPerSec,
    this.diskReadBytesPerSec,
    this.diskWriteBytesPerSec,
    this.zfsArcFreeableMB,
  });

  ServerStats copyWith({
    double? cpuPercent,
    int? ramUsedMB,
    int? ramTotalMB,
    double? diskPercent,
    String? uptime,
    List<double>? loadAverage,
    DateTime? collectedAt,
    MetricSource? source,
    double? swapPercent,
    bool? noSwap,
    double? tempC,
    int? pingMs,
    int? uptimeSeconds,
    List<FilesystemUsage>? filesystems,
    double? inodesRootPercent,
    bool? restartRequired,
    int? updatesTotal,
    int? updatesSecurity,
    int? failedUnits,
    int? processesTotal,
    int? zombieProcesses,
    String? osName,
    String? kernel,
    double? netRxBytesPerSec,
    double? netTxBytesPerSec,
    double? diskReadBytesPerSec,
    double? diskWriteBytesPerSec,
    int? zfsArcFreeableMB,
  }) {
    return ServerStats(
      cpuPercent: cpuPercent ?? this.cpuPercent,
      ramUsedMB: ramUsedMB ?? this.ramUsedMB,
      ramTotalMB: ramTotalMB ?? this.ramTotalMB,
      diskPercent: diskPercent ?? this.diskPercent,
      uptime: uptime ?? this.uptime,
      loadAverage: loadAverage ?? this.loadAverage,
      collectedAt: collectedAt ?? this.collectedAt,
      source: source ?? this.source,
      swapPercent: swapPercent ?? this.swapPercent,
      noSwap: noSwap ?? this.noSwap,
      tempC: tempC ?? this.tempC,
      pingMs: pingMs ?? this.pingMs,
      uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
      filesystems: filesystems ?? this.filesystems,
      inodesRootPercent: inodesRootPercent ?? this.inodesRootPercent,
      restartRequired: restartRequired ?? this.restartRequired,
      updatesTotal: updatesTotal ?? this.updatesTotal,
      updatesSecurity: updatesSecurity ?? this.updatesSecurity,
      failedUnits: failedUnits ?? this.failedUnits,
      processesTotal: processesTotal ?? this.processesTotal,
      zombieProcesses: zombieProcesses ?? this.zombieProcesses,
      osName: osName ?? this.osName,
      kernel: kernel ?? this.kernel,
      netRxBytesPerSec: netRxBytesPerSec ?? this.netRxBytesPerSec,
      netTxBytesPerSec: netTxBytesPerSec ?? this.netTxBytesPerSec,
      diskReadBytesPerSec: diskReadBytesPerSec ?? this.diskReadBytesPerSec,
      diskWriteBytesPerSec: diskWriteBytesPerSec ?? this.diskWriteBytesPerSec,
      zfsArcFreeableMB: zfsArcFreeableMB ?? this.zfsArcFreeableMB,
    );
  }
}

/// Collects server resource stats by executing lightweight commands
/// over an existing SSH session.
///
/// Each command has a 5-second timeout to avoid blocking on slow servers.
/// Supports both Linux and macOS/BSD hosts by detecting the remote OS
/// via `uname -s` on the first call.
class ServerStatsService {
  static const _commandTimeout = Duration(seconds: 15);

  /// Cached remote OS (`uname -s`) per SSH client hashCode to avoid re-detecting.
  static final _osCache = <int, String>{};

  /// Cached (osName, kernel) per SSH client hashCode. OS/kernel change at most
  /// on reboot, so this is read once per connection, not every check (§3.1).
  static final _osInfoCache = <int, (String?, String?)>{};

  /// How long the round trip is waited for ([_measureRoundTrip]).
  static const _pingTimeout = Duration(seconds: 3);

  /// Collect all available stats from the remote server.
  ///
  /// Returns a [ServerStats] object with as many fields populated as possible.
  /// Fields that fail to parse or time out will be null.
  ///
  /// Everything is read over [client], the connection there is: nothing here
  /// connects to the host again (up to 2.2.1 each reading opened a connection
  /// of its own to the host's SSH port to time it, and closed it without
  /// signing in, which a server logs and may ban an address for). The
  /// extended metrics are gathered in ONE extra batched `sh` call plus a
  /// one-time (cached) OS/kernel read. The first check of a Linux host takes
  /// a second longer than the ones after it: its processor counters are read
  /// twice then.
  static Future<ServerStats> getStats(SSHClient client) async {
    // Detect remote OS once and cache it.
    final clientKey = client.hashCode;
    var os = _osCache[clientKey];
    if (os == null) {
      os = (await _execCommand(client, 'uname -s'))?.trim() ?? 'Linux';
      _osCache[clientKey] = os;
      AppLogger.debug('ServerStats: detected remote OS = $os');
    }

    final isDarwin = os == 'Darwin';

    // The round trip first, by itself: beside the commands it would also
    // time how long the host takes to start them.
    final pingMs = await roundTripMs(client);

    // Build platform-appropriate commands.
    final ramCmd = isDarwin
        ? 'vm_stat && sysctl -n hw.memsize'
        : "free -m | awk 'NR==2{print \$2,\$3}'";
    final diskCmd = "df -h / | awk 'NR==2{print \$5}'"; // works everywhere
    final uptimeCmd = isDarwin ? 'uptime' : 'uptime -p';
    // Load average - `uptime` output contains it on both Linux and macOS.
    // On Linux, /proc/loadavg is cleaner: "0.25 0.18 0.12 1/234 5678"
    // On macOS, `sysctl -n vm.loadavg` gives: "{ 0.25 0.18 0.12 }"
    final loadCmd =
        isDarwin ? 'sysctl -n vm.loadavg' : 'cat /proc/loadavg';
    // ZFS's ARC on Linux: its size and its floor, where the host has ZFS
    // (nothing is printed where it has not).
    const arcCmd = "awk '\$1==\"size\"||\$1==\"c_min\"{print \$1, \$3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null";

    // Processor use. On Linux it is worked out from the host's own counters
    // (see [collectCpuLinux]); the load average is a different thing and has
    // its own column.
    final Future<double?> cpuFuture = isDarwin
        ? _execCommand(client, "top -l 1 -n 0 | grep 'CPU usage'")
            .then(_parseCpuDarwin)
        : collectCpuLinux(clientKey, (cmd) => _execCommand(client, cmd));

    // Run the base commands in parallel for speed. The extended metric
    // batch, the one-time OS/kernel read, and the client-side ping are
    // kicked off alongside them so nothing is serialized.
    final baseFuture = Future.wait([
      _execCommand(client, ramCmd),
      _execCommand(client, diskCmd),
      _execCommand(client, uptimeCmd),
      _execCommand(client, loadCmd),
      if (!isDarwin) _execCommand(client, arcCmd),
    ]);

    // Extended /proc + df + systemd metrics - one cheap batched `sh` call.
    // Only meaningful on Linux; on Darwin/BSD the /proc paths are absent, so we
    // skip the call entirely and leave every extended field null (renders N/A).
    final Future<_ExtendedStats> extendedFuture =
        isDarwin ? Future.value(const _ExtendedStats.empty())
                 : _collectExtended(client, clientKey);

    // OS pretty-name + kernel: read once per connection, then cached.
    final osInfoFuture = _collectOsInfo(client, clientKey);

    final results = await baseFuture;
    final cpuPercent = await cpuFuture;
    final extended = await extendedFuture;
    final osInfo = await osInfoFuture;

    final ramResult = results[0];
    final diskResult = results[1];
    final uptimeResult = results[2];
    final loadResult = results[3];

    return ServerStats(
      cpuPercent: cpuPercent,
      ramUsedMB: isDarwin
          ? _parseRamUsedDarwin(ramResult)
          : _parseRamUsed(ramResult),
      ramTotalMB: isDarwin
          ? _parseRamTotalDarwin(ramResult)
          : _parseRamTotal(ramResult),
      diskPercent: _parseDisk(diskResult),
      uptime: _parseUptime(uptimeResult),
      loadAverage: _parseLoadAverage(loadResult),
      collectedAt: DateTime.now(),
      source: MetricSource.ssh,
      // Extended metrics.
      pingMs: pingMs,
      swapPercent: extended.swapPercent,
      noSwap: extended.noSwap,
      tempC: extended.tempC,
      uptimeSeconds: extended.uptimeSeconds,
      filesystems: extended.filesystems,
      inodesRootPercent: extended.inodesRootPercent,
      restartRequired: extended.restartRequired,
      updatesTotal: extended.updatesTotal,
      updatesSecurity: extended.updatesSecurity,
      failedUnits: extended.failedUnits,
      processesTotal: extended.processesTotal,
      zombieProcesses: extended.zombieProcesses,
      netRxBytesPerSec: extended.netRxBytesPerSec,
      netTxBytesPerSec: extended.netTxBytesPerSec,
      diskReadBytesPerSec: extended.diskReadBytesPerSec,
      diskWriteBytesPerSec: extended.diskWriteBytesPerSec,
      osName: osInfo.$1,
      kernel: osInfo.$2,
      zfsArcFreeableMB: isDarwin ? null : parseZfsArcFreeableMB(results[4]),
    );
  }

  /// The ARC that can be given back, in MB, from the `size` and `c_min` lines
  /// of `/proc/spl/kstat/zfs/arcstats` (bytes each): null where they are not
  /// both there (no ZFS).
  @visibleForTesting
  static int? parseZfsArcFreeableMB(String? output) {
    if (output == null) return null;
    int? size;
    int? floor;
    for (final line in output.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      final v = int.tryParse(parts[1]);
      if (parts[0] == 'size') size = v;
      if (parts[0] == 'c_min') floor = v;
    }
    if (size == null || floor == null) return null;
    final bytes = size - floor;
    return bytes <= 0 ? 0 : bytes ~/ (1024 * 1024);
  }

  /// Clear cached OS detection + OS/kernel info and the counters the last
  /// check read (e.g. when a connection closes).
  static void clearCache(SSHClient client) => clearCacheFor(client.hashCode);

  /// [clearCache] by the key the caches go by (a client's hashCode).
  @visibleForTesting
  static void clearCacheFor(int key) {
    _osCache.remove(key);
    _osInfoCache.remove(key);
    _prevIoCounters.remove(key);
    _prevCpu.remove(key);
  }

  /// Cap on accumulated stdout per command. [_commandTimeout] bounds time but
  /// not memory, so a compromised / malicious monitored host could stream
  /// unbounded output within the window and OOM the client on the auto-refresh
  /// timer. The metric commands emit at most a few KB, so 1 MB is far above any
  /// legitimate output.
  static const int _maxCommandOutputBytes = 1024 * 1024; // 1 MB

  /// Execute a single command with a timeout AND an output byte cap. The
  /// channel is closed at either: closed by asking, a host could go on sending
  /// for as long as the connection lasted, and with no limit on the time a
  /// command that never ended held its check up for good.
  static Future<String?> _execCommand(SSHClient client, String command) async {
    try {
      final bytes = await client.runCapped(command, maxBytes: _maxCommandOutputBytes, timeout: _commandTimeout);
      // allowMalformed: crafted bad UTF-8 from a hostile host degrades to
      // replacement chars rather than throwing.
      return utf8.decode(bytes, allowMalformed: true).trim();
    } catch (e) {
      AppLogger.debug('ServerStats command failed: $command - $e');
      return null;
    }
  }

  // ─── Linux parsers ──────────────────────────────────────────────

  // Processor use (Linux).
  //
  // The figure is the share of processor time that went to work between two
  // readings of the host's own counters (the first line of /proc/stat),
  // which is what `top` shows. It is NOT the load average divided by the
  // number of processors, which every version up to 2.2.1 showed as "CPU":
  // the load average also counts whatever waits for a disk, and in a
  // container it is the whole machine's while the container sees only its
  // own few processors, so an idle host read 100% and Critical.

  /// Reads the counters once: the use since the last check is worked out
  /// against what that check read. (No redirection and nothing a shell has
  /// to understand beyond `;`, so it runs under any login shell.)
  @visibleForTesting
  static const String cpuReadCmd = 'head -n 1 /proc/stat';

  /// Reads them twice, a second apart: a host checked for the first time
  /// has nothing to compare with yet.
  @visibleForTesting
  static const String cpuSampleCmd =
      'head -n 1 /proc/stat; sleep 1; head -n 1 /proc/stat';

  /// Fewer ticks than this between two readings (a tenth of a second on one
  /// processor) say nothing new: the last figure stands.
  static const int _minCpuTicks = 10;

  /// No counter of a real host comes near this (a thousand processors for a
  /// thousand years do not); beyond it a line is not taken, so a hostile
  /// host cannot make the sums overflow.
  static const int _maxCpuTicks = 1 << 53;

  /// A reading older than this is not compared with. Checks are an hour
  /// apart at most, so an older reading is from before a pause, and the
  /// average over the pause tells little about now.
  @visibleForTesting
  static const Duration cpuReadingMaxAge = Duration(minutes: 90);

  /// What the last check read from a host's counters, when, and the figure
  /// it gave, per SSH client. Cleared on disconnect via [clearCache].
  static final Map<int, ({CpuTimes times, double? percent, DateTime at})>
      _prevCpu = {};

  /// Every reading of the counters in [output]: the lines that start with
  /// `cpu` alone (the sum over all processors).
  ///
  /// `cpu  user nice system idle iowait irq softirq steal guest guest_nice`
  @visibleForTesting
  static List<CpuTimes> parseCpuTimes(String? output) {
    if (output == null || output.isEmpty) return const [];
    final readings = <CpuTimes>[];
    for (final line in output.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      // At least user, nice, system and idle (older kernels have no more).
      if (parts.first != 'cpu' || parts.length < 5) continue;
      // The first eight are all of the time; guest time, which follows, is
      // already counted in user and nice.
      final ticks = [for (final p in parts.skip(1).take(8)) int.tryParse(p)];
      if (ticks.any((t) => t == null || t < 0 || t > _maxCpuTicks)) continue;
      var total = 0;
      for (final t in ticks) {
        total += t!;
      }
      final idle = ticks[3]! + (ticks.length > 4 ? ticks[4]! : 0);
      readings.add((total: total, idle: idle));
    }
    return readings;
  }

  /// The share of processor time (0-100) that went to work between the
  /// readings [before] and [after]. Null when no time passed between them,
  /// or when a counter went backwards (the host restarted, or a container's
  /// counters were set anew): no figure can be had from such a pair.
  @visibleForTesting
  static double? cpuPercentBetween(CpuTimes before, CpuTimes after) {
    final total = after.total - before.total;
    final idle = after.idle - before.idle;
    if (total <= 0 || idle < 0 || idle > total) return null;
    return (total - idle) / total * 100;
  }

  /// Processor use of the Linux host behind [clientKey], through [run]
  /// (which runs a command there and returns what it printed, or null).
  ///
  /// The first check reads the counters twice, a second apart. Every check
  /// after it reads them once and gives the use since the check before, so
  /// the figure is the average over the time between two checks and costs
  /// the host nothing. Null when the host has no such counters. [clock] is
  /// the time now (for tests).
  @visibleForTesting
  static Future<double?> collectCpuLinux(
    int clientKey,
    Future<String?> Function(String command) run, {
    DateTime Function() clock = DateTime.now,
  }) async {
    var prev = _prevCpu[clientKey];
    if (prev != null && clock().difference(prev.at) > cpuReadingMaxAge) {
      _prevCpu.remove(clientKey);
      prev = null;
    }
    if (prev == null) {
      final readings = parseCpuTimes(await run(cpuSampleCmd));
      if (readings.isEmpty) return null;
      final percent = readings.length > 1
          ? cpuPercentBetween(readings.first, readings.last)
          : null;
      _prevCpu[clientKey] =
          (times: readings.last, percent: percent, at: clock());
      return percent;
    }
    final readings = parseCpuTimes(await run(cpuReadCmd));
    if (readings.isEmpty) {
      _prevCpu.remove(clientKey);
      return null;
    }
    final now = readings.last;
    final passed = now.total - prev.times.total;
    // Asked again within a moment: what the last check found stands, and
    // the next one measures from where that one read.
    if (passed >= 0 && passed < _minCpuTicks && now.idle >= prev.times.idle) {
      return prev.percent;
    }
    final percent = cpuPercentBetween(prev.times, now);
    if (percent == null) {
      // The counters went backwards: what was read before says nothing
      // about them any more. Measure afresh, as on a first check.
      _prevCpu.remove(clientKey);
      return collectCpuLinux(clientKey, run, clock: clock);
    }
    _prevCpu[clientKey] = (times: now, percent: percent, at: clock());
    return percent;
  }

  /// Parse RAM usage from `free -m` output (Linux).
  /// Expected format: "totalMB usedMB"
  static int? _parseRamUsed(String? output) {
    if (output == null || output.isEmpty) return null;
    try {
      final parts = output.split(RegExp(r'\s+'));
      if (parts.length < 2) return null;
      return int.parse(parts[1]);
    } catch (e) {
      return null;
    }
  }

  static int? _parseRamTotal(String? output) {
    if (output == null || output.isEmpty) return null;
    try {
      final parts = output.split(RegExp(r'\s+'));
      if (parts.isEmpty) return null;
      return int.parse(parts[0]);
    } catch (e) {
      return null;
    }
  }

  // ─── macOS / Darwin parsers ────────────────────────────────────

  /// Parse CPU usage from macOS `top -l 1` output.
  ///
  /// Example line: "CPU usage: 5.26% user, 10.52% sys, 84.21% idle"
  ///
  /// The patterns are bounded, as every pattern on a host's output must be: the
  /// app has one isolate for its screen and every session, and `[\d.]+` went
  /// back over every digit from every digit (80 KB of digits held it for
  /// 4.6 s; the cap on what is read is a megabyte).
  @visibleForTesting
  static double? parseCpuDarwin(String? output) => _parseCpuDarwin(output);

  static double? _parseCpuDarwin(String? output) {
    if (output == null || output.isEmpty || output.length > _maxParsedLine) return null;
    try {
      // Extract idle percentage and compute usage = 100 - idle
      final idleMatch = RegExp(r'([\d.]{1,32})%\s{0,8}idle').firstMatch(output);
      if (idleMatch != null) {
        final idle = double.parse(idleMatch.group(1)!);
        return (100.0 - idle).clamp(0.0, 100.0);
      }
      // Fallback: sum user + sys
      final userMatch = RegExp(r'([\d.]{1,32})%\s{0,8}user').firstMatch(output);
      final sysMatch = RegExp(r'([\d.]{1,32})%\s{0,8}sys').firstMatch(output);
      if (userMatch != null && sysMatch != null) {
        final user = double.parse(userMatch.group(1)!);
        final sys = double.parse(sysMatch.group(1)!);
        return (user + sys).clamp(0.0, 100.0);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Parse RAM usage from macOS `vm_stat` + `sysctl hw.memsize` output.
  ///
  /// `vm_stat` reports pages; last line of combined output is total bytes
  /// from `sysctl -n hw.memsize`. A page is the size `vm_stat` states in its
  /// first line ("page size of 16384 bytes" on Apple silicon, 4096 on Intel).
  static int? _parseRamUsedDarwin(String? output) {
    if (output == null || output.isEmpty) return null;
    try {
      final pageSize = _vmStatPageSize(output);
      final active = _extractVmStatPages(output, 'Pages active');
      final wired = _extractVmStatPages(output, 'Pages wired down');
      final compressed =
          _extractVmStatPages(output, 'Pages occupied by compressor');

      if (active == null && wired == null) return null;

      final usedPages = (active ?? 0) + (wired ?? 0) + (compressed ?? 0);
      return (usedPages * pageSize) ~/ (1024 * 1024); // → MB
    } catch (e) {
      return null;
    }
  }

  static int? _parseRamTotalDarwin(String? output) {
    if (output == null || output.isEmpty) return null;
    try {
      // Last line from `sysctl -n hw.memsize` is total bytes
      final lines = output.split('\n');
      for (final line in lines.reversed) {
        final trimmed = line.trim();
        final bytes = int.tryParse(trimmed);
        if (bytes != null && bytes > 0) {
          return bytes ~/ (1024 * 1024); // → MB
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// The page size `vm_stat` states in its first line, or 4096 (an Intel
  /// Mac's) where it states none that is a power of two up to 1 MiB.
  static int _vmStatPageSize(String output) {
    final match = RegExp(r'page size of (\d{1,7}) bytes').firstMatch(output);
    final size = match == null ? null : int.tryParse(match.group(1)!);
    if (size == null || size < 512 || size > 1 << 20 || size & (size - 1) != 0) return 4096;
    return size;
  }

  /// Extract a page count from `vm_stat` output.
  ///
  /// Example line: "Pages active:    123456."
  static int? _extractVmStatPages(String output, String label) {
    final pattern = RegExp('$label:\\s+(\\d+)');
    final match = pattern.firstMatch(output);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  // ─── Common parsers ────────────────────────────────────────────

  /// Parse disk usage from `df -h /` output.
  /// Expected format: "42%"
  static double? _parseDisk(String? output) {
    if (output == null || output.isEmpty) return null;
    try {
      final cleaned = output.replaceAll('%', '').trim();
      return double.parse(cleaned);
    } catch (e) {
      return null;
    }
  }

  /// Parse uptime string.
  ///
  /// Linux: `uptime -p` → "up 5 days, 3 hours, 42 minutes"
  /// macOS: `uptime` → "10:30  up 5 days, 3:42, 2 users, load averages: ..."
  static String? _parseUptime(String? output) {
    if (output == null || output.isEmpty) return null;
    // Extract the "up ..." portion
    final upIndex = output.indexOf('up ');
    if (upIndex == -1) return output.trim();
    var trimmed = output.substring(upIndex + 3).trim();
    // Strip trailing user/load info (macOS)
    final userIdx = trimmed.indexOf(' user');
    if (userIdx > 0) {
      // Go back to last comma before " user"
      final commaIdx = trimmed.lastIndexOf(',', userIdx);
      if (commaIdx > 0) trimmed = trimmed.substring(0, commaIdx).trim();
    }
    // Strip trailing comma
    if (trimmed.endsWith(',')) {
      trimmed = trimmed.substring(0, trimmed.length - 1).trim();
    }
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Parse load average from /proc/loadavg (Linux) or sysctl vm.loadavg (macOS).
  ///
  /// Linux /proc/loadavg: "0.25 0.18 0.12 1/234 5678"
  /// macOS sysctl: "{ 0.25 0.18 0.12 }"
  static List<double>? _parseLoadAverage(String? output) {
    if (output == null || output.isEmpty) return null;
    try {
      // Clean up macOS format: remove braces
      final cleaned = output.replaceAll('{', '').replaceAll('}', '').trim();
      final parts = cleaned.split(RegExp(r'\s+'));
      if (parts.length < 3) return null;

      final load1 = double.tryParse(parts[0]);
      final load5 = double.tryParse(parts[1]);
      final load15 = double.tryParse(parts[2]);

      if (load1 == null || load5 == null || load15 == null) return null;
      return [load1, load5, load15];
    } catch (e) {
      return null;
    }
  }

  // ─── Extended metric collection (Server Monitor §3) ─────────────

  /// One batched POSIX-sh command that emits each metric block behind a
  /// `__Zxxx__` marker line. Cheap: it only cats a few /proc + /sys files,
  /// runs `df` twice, and counts processes/units. Everything that may be
  /// absent is guarded so the block simply comes back empty (→ null → N/A).
  ///
  /// Assumes an sh-compatible login shell (bash/sh/zsh/dash), matching the
  /// existing collector's `awk`/pipe usage. `\$z` is escaped for Dart.
  static const String _extendedBatchCmd =
      'echo __ZSWAP__; grep -E "^(SwapTotal|SwapFree):" /proc/meminfo 2>/dev/null; '
      'echo __ZTEMP__; for z in /sys/class/thermal/thermal_zone*/temp; do cat "\$z" 2>/dev/null; done; '
      'echo __ZUP__; cat /proc/uptime 2>/dev/null; '
      'echo __ZDF__; df -Pk 2>/dev/null; '
      'echo __ZDFI__; df -Pi / 2>/dev/null; '
      'echo __ZRB__; if [ -f /var/run/reboot-required ]; then echo 1; else echo 0; fi; '
      'echo __ZUPD__; cat /var/lib/update-notifier/updates-available 2>/dev/null; '
      'echo __ZUNITS__; if command -v systemctl >/dev/null 2>&1; then systemctl --failed --no-legend --plain 2>/dev/null | wc -l; fi; '
      'echo __ZPROC__; ps -eo stat= 2>/dev/null; '
      'echo __ZNET__; cat /proc/net/dev 2>/dev/null; '
      'echo __ZDISK__; cat /proc/diskstats 2>/dev/null; '
      'echo __ZEND__';

  /// One-time OS pretty-name + kernel read.
  static const String _osInfoCmd =
      'echo __ZOS__; cat /etc/os-release 2>/dev/null; '
      'echo __ZKERN__; uname -r 2>/dev/null; echo __ZOSEND__';

  /// Run [_extendedBatchCmd] and parse every block. Any failure yields an
  /// empty result (all-null), so the extended fields degrade to N/A.
  static Future<_ExtendedStats> _collectExtended(
      SSHClient client, int clientKey) async {
    final out = await _execCommand(client, _extendedBatchCmd);
    if (out == null || out.isEmpty) return const _ExtendedStats.empty();
    final blocks = _splitBlocks(out);
    final updates = _parseUpdates(blocks['UPD']);
    final procs = _parseProcesses(blocks['PROC']);
    final io = _computeIoRates(clientKey, blocks['NET'], blocks['DISK']);
    return _ExtendedStats(
      swapPercent: _parseSwap(blocks['SWAP']),
      noSwap: hasNoSwap(blocks['SWAP']),
      tempC: _parseTemp(blocks['TEMP']),
      uptimeSeconds: _parseUptimeSeconds(blocks['UP']),
      filesystems: _parseFilesystems(blocks['DF']),
      inodesRootPercent: _parseInodes(blocks['DFI']),
      restartRequired: _parseReboot(blocks['RB']),
      updatesTotal: updates.$1,
      updatesSecurity: updates.$2,
      failedUnits: _parseFailedUnits(blocks['UNITS']),
      processesTotal: procs.$1,
      zombieProcesses: procs.$2,
      netRxBytesPerSec: io.$1,
      netTxBytesPerSec: io.$2,
      diskReadBytesPerSec: io.$3,
      diskWriteBytesPerSec: io.$4,
    );
  }

  /// Cumulative net/disk counters from the previous check, per client, so the
  /// single-snapshot batch can be turned into an interval-averaged rate.
  /// Cleared on disconnect via [clearCache].
  static final Map<int, ({int rx, int tx, int dr, int dw, DateTime at})>
      _prevIoCounters = {};

  /// Turn the cumulative /proc/net/dev + /proc/diskstats counters into
  /// bytes/sec, averaged over the interval since this client's previous check.
  /// Returns nulls on the first check (no baseline yet) or on a counter reset
  /// (reboot made a counter go backwards) - each renders N/A that round.
  static (double?, double?, double?, double?) _computeIoRates(
      int clientKey, String? netBlock, String? diskBlock) {
    final net = _parseNetDevCounters(netBlock);
    final disk = _parseDiskStatsCounters(diskBlock);
    if (net == null && disk == null) {
      _prevIoCounters.remove(clientKey);
      return (null, null, null, null);
    }
    final now = DateTime.now();
    final prev = _prevIoCounters[clientKey];
    _prevIoCounters[clientKey] = (
      rx: net?.$1 ?? 0,
      tx: net?.$2 ?? 0,
      dr: disk?.$1 ?? 0,
      dw: disk?.$2 ?? 0,
      at: now,
    );
    if (prev == null) return (null, null, null, null);
    final secs = now.difference(prev.at).inMilliseconds / 1000.0;
    if (secs <= 0.5) return (null, null, null, null);
    // A cumulative counter is never negative; a negative value means a hostile
    // host overflowed/wrapped it - treat as N/A rather than render garbage.
    double? rate(int? cur, int old) =>
        (cur == null || cur < 0 || cur < old) ? null : (cur - old) / secs;
    return (
      net == null ? null : rate(net.$1, prev.rx),
      net == null ? null : rate(net.$2, prev.tx),
      disk == null ? null : rate(disk.$1, prev.dr),
      disk == null ? null : rate(disk.$2, prev.dw),
    );
  }

  /// Sum receive/transmit bytes across all non-loopback interfaces in
  /// /proc/net/dev (columns: rx bytes = field 0, tx bytes = field 8 after the
  /// `iface:` prefix). Null when the file is absent (non-Linux) or empty.
  static (int, int)? _parseNetDevCounters(String? block) {
    if (block == null || block.isEmpty) return null;
    var rx = 0, tx = 0;
    var any = false;
    for (final line in block.split('\n')) {
      final t = line.trim();
      final colon = t.indexOf(':');
      if (colon <= 0) continue; // header rows have no early colon
      final iface = t.substring(0, colon).trim();
      if (iface.isEmpty || iface == 'lo') continue;
      final nums = t.substring(colon + 1).trim().split(RegExp(r'\s+'));
      if (nums.length < 9) continue;
      final r = int.tryParse(nums[0]);
      final x = int.tryParse(nums[8]);
      if (r == null || x == null) continue;
      rx += r;
      tx += x;
      any = true;
    }
    return any ? (rx, tx) : null;
  }

  /// Sum read/write BYTES across whole physical disks in /proc/diskstats
  /// (sectorsRead = field 5, sectorsWritten = field 9; sectors are 512 bytes).
  /// Only whole disks are counted (partitions, loop, ram and dm-* are skipped)
  /// so throughput is not double-counted.
  static (int, int)? _parseDiskStatsCounters(String? block) {
    if (block == null || block.isEmpty) return null;
    final whole = RegExp(
        r'^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+|mmcblk\d+)$');
    var readSectors = 0, writeSectors = 0;
    var any = false;
    for (final line in block.split('\n')) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 10) continue;
      if (!whole.hasMatch(f[2])) continue;
      final rs = int.tryParse(f[5]);
      final ws = int.tryParse(f[9]);
      if (rs == null || ws == null) continue;
      readSectors += rs;
      writeSectors += ws;
      any = true;
    }
    return any ? (readSectors * 512, writeSectors * 512) : null;
  }

  /// Read OS pretty-name + kernel once per connection, caching the result.
  static Future<(String?, String?)> _collectOsInfo(
      SSHClient client, int clientKey) async {
    final cached = _osInfoCache[clientKey];
    if (cached != null) return cached;
    final out = await _execCommand(client, _osInfoCmd);
    final parsed = _parseOsInfo(out);
    // Only cache once we actually got something; a transient failure should be
    // retried on the next check rather than pinned to (null, null).
    if (parsed.$1 != null || parsed.$2 != null) {
      _osInfoCache[clientKey] = parsed;
    }
    return parsed;
  }

  /// How long one round trip to the host takes on [client]'s connection, in
  /// milliseconds: a keep-alive question, which an SSH server answers at once
  /// whether it knows the question or not, timed. Null where no answer came
  /// in time.
  static Future<int?> roundTripMs(SSHClient client) async {
    try {
      final sw = Stopwatch()..start();
      await client.ping().timeout(_pingTimeout);
      sw.stop();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  /// Split marker-delimited output into `{KEY: block}` where each `__ZKEY__`
  /// line starts a new block. Shared by the extended batch and OS-info reads.
  static Map<String, String> _splitBlocks(String out) {
    final buffers = <String, List<String>>{};
    final marker = RegExp(r'^__Z([A-Z]+)__\s*$');
    String? current;
    for (final line in out.split('\n')) {
      final m = marker.firstMatch(line.trim());
      if (m != null) {
        current = m.group(1);
        buffers.putIfAbsent(current!, () => <String>[]);
        continue;
      }
      if (current != null) buffers[current]!.add(line);
    }
    return buffers.map((k, v) => MapEntry(k, v.join('\n').trim()));
  }

  /// Swap usage percentage from `/proc/meminfo`. Null when there is no swap
  /// (SwapTotal 0 or absent) so a swap-less host renders N/A rather than 0.
  static double? _parseSwap(String? block) {
    if (block == null || block.isEmpty) return null;
    int? total;
    int? free;
    for (final line in block.split('\n')) {
      final m = RegExp(r'^(SwapTotal|SwapFree):\s+(\d+)').firstMatch(line.trim());
      if (m == null) continue;
      final v = int.tryParse(m.group(2)!);
      if (m.group(1) == 'SwapTotal') {
        total = v;
      } else {
        free = v;
      }
    }
    if (total == null || total == 0 || free == null) return null;
    final used = total - free;
    return (used / total * 100).clamp(0.0, 100.0);
  }

  /// Whether `/proc/meminfo` says the host has no swap at all (SwapTotal 0).
  /// False where the block is missing or has no SwapTotal line: that is swap
  /// not read, not swap not there.
  static bool hasNoSwap(String? block) {
    if (block == null) return false;
    for (final line in block.split('\n')) {
      final m = RegExp(r'^SwapTotal:\s+(\d+)').firstMatch(line.trim());
      if (m != null) return int.tryParse(m.group(1)!) == 0;
    }
    return false;
  }

  /// Highest thermal-zone temperature (°C). Values are millidegrees; sane range
  /// filtered so a bogus 0 or absurd reading is ignored.
  static double? _parseTemp(String? block) {
    if (block == null || block.isEmpty) return null;
    double? maxC;
    for (final line in block.split('\n')) {
      final v = int.tryParse(line.trim());
      if (v == null) continue;
      final c = v / 1000.0;
      if (c <= 0 || c > 200) continue;
      if (maxC == null || c > maxC) maxC = c;
    }
    return maxC;
  }

  /// Whole-second uptime from `/proc/uptime` ("12345.67 8901.23").
  static int? _parseUptimeSeconds(String? block) {
    if (block == null || block.isEmpty) return null;
    final parts = block.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return null;
    final v = double.tryParse(parts.first);
    return v?.round();
  }

  /// Real (non-virtual) filesystems from `df -Pk`, fullest first.
  static List<FilesystemUsage> _parseFilesystems(String? block) {
    if (block == null || block.isEmpty) return const [];
    final result = <FilesystemUsage>[];
    for (final raw in block.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('Filesystem')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 6) continue;
      final device = parts[0];
      final totalKb = int.tryParse(parts[1]);
      final usedKb = int.tryParse(parts[2]);
      final capacity = double.tryParse(parts[4].replaceAll('%', ''));
      final mount = parts.sublist(5).join(' ');
      if (totalKb == null || usedKb == null || capacity == null) continue;
      if (totalKb == 0) continue;
      if (_isVirtualFs(device, mount)) continue;
      result.add(FilesystemUsage(
        mount: mount,
        usedBytes: usedKb * 1024,
        totalBytes: totalKb * 1024,
        usedPercent: capacity.clamp(0.0, 100.0),
      ));
    }
    result.sort((a, b) => b.usedPercent.compareTo(a.usedPercent));
    return result;
  }

  static const _virtualFsDevices = {
    'tmpfs', 'devtmpfs', 'udev', 'overlay', 'squashfs', 'none', 'cgroup',
    'cgroup2', 'sysfs', 'proc', 'ramfs', 'mqueue', 'hugetlbfs', 'debugfs',
    'tracefs', 'securityfs', 'pstore', 'efivarfs', 'configfs', 'fusectl',
    'binfmt_misc', 'devpts', 'shm',
  };

  static bool _isVirtualFs(String device, String mount) {
    if (_virtualFsDevices.contains(device)) return true;
    for (final p in const ['/proc', '/sys', '/dev', '/run', '/snap']) {
      if (mount == p || mount.startsWith('$p/')) return true;
    }
    return mount.contains('/docker/');
  }

  /// Root-filesystem inode usage percentage from `df -Pi /`.
  static double? _parseInodes(String? block) {
    if (block == null || block.isEmpty) return null;
    for (final raw in block.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('Filesystem')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 6) continue;
      final pct = double.tryParse(parts[4].replaceAll('%', ''));
      if (pct != null) return pct.clamp(0.0, 100.0);
    }
    return null;
  }

  /// `/var/run/reboot-required` presence flag ("1"/"0").
  static bool? _parseReboot(String? block) {
    if (block == null) return null;
    final t = block.trim();
    if (t == '1') return true;
    if (t == '0') return false;
    return null;
  }

  /// The longest line of a host's output a parser with a pattern looks at; no
  /// line it asks for comes near this.
  static const int _maxParsedLine = 4096;

  /// `(total, security)` pending updates from the update-notifier MOTD cache.
  ///
  /// `(\d+).*securit` went back over every digit and every place after it, for
  /// every digit: 4,000 digits on one line held the app for 10.5 s, and any
  /// host can put them in the file. The same is read here by hand, in one pass:
  /// the first number on the line that stands before the word.
  @visibleForTesting
  static (int?, int?) parseUpdates(String? block) => _parseUpdates(block);

  static (int?, int?) _parseUpdates(String? block) {
    if (block == null || block.trim().isEmpty) return (null, null);
    int? total;
    int? security;
    for (final raw in block.split('\n')) {
      final line = raw.trim();
      if (line.length > _maxParsedLine) continue;
      final word = line.toLowerCase().lastIndexOf('securit');
      if (word > 0) {
        // (Made lower case, a letter can come to more than one unit.)
        final number = _firstNumberIn(line, word < line.length ? word : line.length);
        if (number != null) {
          security ??= int.tryParse(number);
          continue;
        }
      }
      final upd =
          RegExp(r'(\d{1,18})\s{1,8}update', caseSensitive: false).firstMatch(line);
      if (upd != null) total ??= int.tryParse(upd.group(1)!);
    }
    return (total, security);
  }

  /// The first run of digits in [line] before [end].
  static String? _firstNumberIn(String line, int end) {
    var start = 0;
    while (start < end && !_isDigit(line.codeUnitAt(start))) {
      start++;
    }
    if (start == end) return null;
    var stop = start;
    while (stop < end && _isDigit(line.codeUnitAt(stop))) {
      stop++;
    }
    return line.substring(start, stop);
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  /// Failed systemd unit count (from `systemctl --failed ... | wc -l`). Null
  /// when the block is empty (non-systemd host) so it renders N/A, not 0.
  static int? _parseFailedUnits(String? block) {
    if (block == null) return null;
    final t = block.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t.split('\n').first.trim());
  }

  /// `(total, zombie)` process counts from `ps -eo stat=` (one STAT per line).
  static (int?, int?) _parseProcesses(String? block) {
    if (block == null || block.isEmpty) return (null, null);
    var total = 0;
    var zombie = 0;
    for (final raw in block.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      total++;
      if (line.startsWith('Z')) zombie++;
    }
    if (total == 0) return (null, null);
    return (total, zombie);
  }

  /// `(osName, kernel)` from `/etc/os-release` + `uname -r`.
  static (String?, String?) _parseOsInfo(String? out) {
    if (out == null || out.isEmpty) return (null, null);
    final blocks = _splitBlocks(out);
    String? osName;
    final osBlock = blocks['OS'];
    if (osBlock != null && osBlock.isNotEmpty) {
      final pretty = RegExp(r'^PRETTY_NAME="?(.*?)"?$', multiLine: true)
          .firstMatch(osBlock);
      if (pretty != null) {
        osName = pretty.group(1);
      } else {
        final name =
            RegExp(r'^NAME="?(.*?)"?$', multiLine: true).firstMatch(osBlock);
        if (name != null) osName = name.group(1);
      }
    }
    if (osName != null && osName.trim().isEmpty) osName = null;
    final kernBlock = blocks['KERN'];
    final kernel = (kernBlock != null && kernBlock.trim().isNotEmpty)
        ? kernBlock.trim()
        : null;
    return (osName, kernel);
  }

  /// Execute a command and return stdout. Public for use by detail screen.
  static Future<String?> execCommand(SSHClient client, String command) =>
      _execCommand(client, command);
}

/// Parsed extended-metric block from [ServerStatsService._collectExtended].
class _ExtendedStats {
  final double? swapPercent;
  final bool noSwap;
  final double? tempC;
  final int? uptimeSeconds;
  final List<FilesystemUsage> filesystems;
  final double? inodesRootPercent;
  final bool? restartRequired;
  final int? updatesTotal;
  final int? updatesSecurity;
  final int? failedUnits;
  final int? processesTotal;
  final int? zombieProcesses;
  final double? netRxBytesPerSec;
  final double? netTxBytesPerSec;
  final double? diskReadBytesPerSec;
  final double? diskWriteBytesPerSec;

  const _ExtendedStats({
    this.swapPercent,
    this.noSwap = false,
    this.tempC,
    this.uptimeSeconds,
    this.filesystems = const [],
    this.inodesRootPercent,
    this.restartRequired,
    this.updatesTotal,
    this.updatesSecurity,
    this.failedUnits,
    this.processesTotal,
    this.zombieProcesses,
    this.netRxBytesPerSec,
    this.netTxBytesPerSec,
    this.diskReadBytesPerSec,
    this.diskWriteBytesPerSec,
  });

  const _ExtendedStats.empty() : this();
}
