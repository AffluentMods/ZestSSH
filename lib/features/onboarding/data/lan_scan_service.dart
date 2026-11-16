import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:zestssh/features/networks/engine/network_state.dart';

/// The bounded scope of a local-network scan: a single /24 derived from the
/// device's current IPv4 address. Shown to the user BEFORE any probing starts
/// so they know exactly what will be touched.
class LanScanScope {
  const LanScanScope({required this.cidr, required this.hostCount});

  /// Human-readable range, e.g. `192.168.1.0/24`.
  final String cidr;

  /// Number of host addresses that will be probed (254 for a /24).
  final int hostCount;
}

/// A host that answered on port 22.
class LanScanHit {
  const LanScanHit({required this.host, required this.latencyMs});
  final String host;
  final int latencyMs;
}

/// Probes the current /24 for SSH (TCP port 22).
///
/// Deliberately simple and self-contained:
///  * Scope is resolved from the active network's IPv4 address.
///  * Only ever a single /24 (254 hosts) - bounded by construction.
///  * A worker pool caps concurrency so we never open hundreds of sockets.
///  * [cancel] stops the scan promptly; in-flight probes are abandoned.
///
/// Nothing runs until [scan] is called - resolving the scope does no probing.
class LanScanService {
  LanScanService({
    this.concurrency = 32,
    this.timeout = const Duration(milliseconds: 400),
  });

  final int concurrency;
  final Duration timeout;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  bool get isCancelled => _cancelled;

  /// Resolve the /24 to scan from the device's current IPv4 address, or null
  /// when there's no usable local network (e.g. cellular-only, or offline).
  Future<LanScanScope?> resolveScope() async {
    final state = await readCurrentNetworkState();
    final ipv4 = state.localAddresses.firstWhere(
      _isScannableIpv4,
      orElse: () => '',
    );
    if (ipv4.isEmpty) return null;
    final parts = ipv4.split('.');
    if (parts.length != 4) return null;
    final base = '${parts[0]}.${parts[1]}.${parts[2]}';
    return LanScanScope(cidr: '$base.0/24', hostCount: 254);
  }

  /// Run the scan for [scope], invoking [onHit] as each host answers and
  /// [onProgress] after every probe completes. Resolves when the scan
  /// finishes or is cancelled.
  Future<void> scan({
    required LanScanScope scope,
    required void Function(LanScanHit hit) onHit,
    required void Function(int scanned, int total) onProgress,
  }) async {
    _cancelled = false;
    final base = scope.cidr.split('/').first; // a.b.c.0
    final prefix = base.substring(0, base.lastIndexOf('.'));
    final queue = Queue<String>.of(
      List.generate(254, (i) => '$prefix.${i + 1}'),
    );
    final total = queue.length;
    var scanned = 0;

    Future<void> worker() async {
      while (!_cancelled && queue.isNotEmpty) {
        final ip = queue.removeFirst();
        final hit = await _probe(ip);
        scanned++;
        if (_cancelled) return;
        onProgress(scanned, total);
        if (hit != null) onHit(hit);
      }
    }

    final workerCount = concurrency < total ? concurrency : total;
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<LanScanHit?> _probe(String host) async {
    Socket? socket;
    try {
      final sw = Stopwatch()..start();
      socket = await Socket.connect(host, 22, timeout: timeout);
      sw.stop();
      return LanScanHit(host: host, latencyMs: sw.elapsedMilliseconds);
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// Only scan private-looking IPv4 addresses - we never want to fan out a
  /// 254-socket sweep across a public range if the device reports one.
  static bool _isScannableIpv4(String addr) {
    if (!addr.contains('.') || addr.contains(':')) return false;
    final parts = addr.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
    final a = octets[0]!;
    final b = octets[1]!;
    // RFC1918 + link-local (skip link-local 169.254 as not useful to scan).
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    return false;
  }
}
