import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// A Mac host's memory in use, as Server Monitor reads it from `vm_stat`, is
/// counted in the page size `vm_stat` states in its first line: 16,384 bytes
/// on Apple silicon, 4,096 on an Intel Mac. It was counted in 4,096 byte pages
/// whatever `vm_stat` said, so an Apple silicon Mac showed a quarter of the
/// memory it had in use (found in a review).
class _FakeMac implements SSHClient {
  _FakeMac(this.answers);

  final Map<String, String> answers;

  @override
  Future<Uint8List> runCapped(String command, {required int maxBytes, required Duration timeout}) async =>
      Uint8List.fromList(utf8.encode(answers[command] ?? ''));

  @override
  Future<void> ping() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What `vm_stat` prints (its first line states the page size), then
/// `sysctl -n hw.memsize` for 16 GB.
String _vmStat(String firstLine) => '''
$firstLine
Pages free:                                5000.
Pages active:                            300000.
Pages inactive:                          290000.
Pages speculative:                         2000.
Pages throttled:                              0.
Pages wired down:                        150000.
Pages purgeable:                           1000.
"Translation faults":                 100000000.
Pages copy-on-write:                    5000000.
Pages zero filled:                     50000000.
Pages reactivated:                      1000000.
Pages purged:                            100000.
File-backed pages:                       200000.
Anonymous pages:                         390000.
Pages stored in compressor:              400000.
Pages occupied by compressor:            100000.
Decompressions:                         2000000.
Compressions:                           3000000.
Pageins:                                1000000.
Pageouts:                                 10000.
Swapins:                                      0.
Swapouts:                                     0.
17179869184''';

Future<ServerStats> _statsOf(String vmStat) async {
  final client = _FakeMac({
    'uname -s': 'Darwin',
    'vm_stat && sysctl -n hw.memsize': vmStat,
  });
  final stats = await ServerStatsService.getStats(client);
  ServerStatsService.clearCache(client);
  return stats;
}

void main() {
  // active + wired + occupied by compressor = 550,000 pages.
  const pages = 550000;

  test('memory in use on an Apple silicon Mac is counted in its own 16 KB pages', () async {
    final stats = await _statsOf(_vmStat('Mach Virtual Memory Statistics: (page size of 16384 bytes)'));
    expect(stats.ramTotalMB, 16384);
    expect(stats.ramUsedMB, pages * 16384 ~/ (1024 * 1024), // 8,593 MB, 52% of 16 GB
        reason: 'vm_stat says its pages are 16,384 bytes; read as 4,096 the Mac shows '
            '${stats.ramPercent?.toStringAsFixed(0)}% of its memory in use where it has 52%');
  });

  test('an Intel Mac stays at its 4 KB pages', () async {
    final stats = await _statsOf(_vmStat('Mach Virtual Memory Statistics: (page size of 4096 bytes)'));
    expect(stats.ramUsedMB, pages * 4096 ~/ (1024 * 1024));
  });

  test('a first line with no page size, or a page size that is not one, counts 4 KB pages', () async {
    for (final first in [
      'Mach Virtual Memory Statistics:',
      'Mach Virtual Memory Statistics: (page size of 3000 bytes)',
      'Mach Virtual Memory Statistics: (page size of 0 bytes)',
      'Mach Virtual Memory Statistics: (page size of 9999999 bytes)',
    ]) {
      final stats = await _statsOf(_vmStat(first));
      expect(stats.ramUsedMB, pages * 4096 ~/ (1024 * 1024), reason: first);
    }
  });
}
