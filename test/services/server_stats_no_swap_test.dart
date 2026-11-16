import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/server_stats_service.dart';

// The monitor says "No swap" only for a host that said it has none
// (SwapTotal 0), never for swap it could not read (it
// guessed from the uptime having been read).
void main() {
  test('SwapTotal 0 is no swap', () {
    expect(ServerStatsService.hasNoSwap('SwapTotal:            0 kB\nSwapFree:             0 kB'), isTrue);
  });

  test('a host with swap has swap', () {
    expect(ServerStatsService.hasNoSwap('SwapTotal:      2097148 kB\nSwapFree:       2097148 kB'), isFalse);
  });

  test('swap not read is not no swap', () {
    expect(ServerStatsService.hasNoSwap(null), isFalse);
    expect(ServerStatsService.hasNoSwap(''), isFalse);
    expect(ServerStatsService.hasNoSwap('SwapFree:       0 kB'), isFalse);
  });

  test('copyWith keeps it', () {
    final s = ServerStats(collectedAt: DateTime(2026, 10, 22), noSwap: true);
    expect(s.copyWith(cpuPercent: 3).noSwap, isTrue);
    expect(s.copyWith(noSwap: false).noSwap, isFalse);
  });
}
