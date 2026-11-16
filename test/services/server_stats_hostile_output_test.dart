import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// Server Monitor's patterns on what a host prints (found in a review of
/// hostile servers). The app has one isolate for its screen and every session, and
/// Monitor reads these on it: one host's output must not hold it. A host prints
/// up to a megabyte per command before it is cut off.
void main() {
  const megabyte = 1024 * 1024;

  Duration time(void Function() body) {
    final clock = Stopwatch()..start();
    body();
    return clock.elapsed;
  }

  // (The first took 10.5 s for 4,000 digits, the second 4.6 s for 80 KB. The
  // limit is far above what they take now, and far below what they took.)
  const limit = Duration(seconds: 2);

  group('updates', () {
    test('a line of digits', () {
      expect(time(() => ServerStatsService.parseUpdates('1' * 4000)), lessThan(limit));
      expect(time(() => ServerStatsService.parseUpdates('1' * megabyte)), lessThan(limit));
    });

    test('a megabyte of lines of digits, of the longest length that is read', () {
      final block = '${'1' * 4095}\n' * 256;
      expect(time(() => ServerStatsService.parseUpdates(block)), lessThan(limit));
    });

    test('digits and spaces', () {
      final block = '${'1 ' * 2000}\n' * 256;
      expect(time(() => ServerStatsService.parseUpdates(block)), lessThan(limit));
    });

    test('a megabyte of the word it looks for', () {
      final block = '${'1securit' * 500}\n' * 256;
      expect(time(() => ServerStatsService.parseUpdates(block)), lessThan(limit));
    });

    test('letters that come out longer in lower case do not put it past the line', () {
      expect(ServerStatsService.parseUpdates('İİİ1 securit'), (null, 1));
      expect(ServerStatsService.parseUpdates('${'İ' * 100} securit'), (null, null));
    });

    test('what real hosts say is read as it was', () {
      expect(ServerStatsService.parseUpdates('12 updates can be applied immediately.\n5 of these updates are standard security updates.\nTo see these additional updates run: apt list --upgradable'), (12, 5));
      expect(ServerStatsService.parseUpdates('0 packages can be updated.\n0 updates are security updates.'), (null, 0));
      expect(ServerStatsService.parseUpdates('3 updates are Security updates.'), (null, 3));
      expect(ServerStatsService.parseUpdates('7 updates can be applied immediately.'), (7, null));
      expect(ServerStatsService.parseUpdates('Security updates: none'), (null, null));
      expect(ServerStatsService.parseUpdates(''), (null, null));
      expect(ServerStatsService.parseUpdates(null), (null, null));
    });
  });

  group('the processor on a Mac', () {
    test('a line of digits', () {
      expect(time(() => ServerStatsService.parseCpuDarwin('1' * 80000)), lessThan(limit));
      expect(time(() => ServerStatsService.parseCpuDarwin('1' * megabyte)), lessThan(limit));
      expect(ServerStatsService.parseCpuDarwin('1' * 80000), isNull);
    });

    test('the longest line that is read', () {
      expect(time(() => ServerStatsService.parseCpuDarwin('1.' * 2048)), lessThan(limit));
    });

    test('what a Mac says is read as it was', () {
      expect(ServerStatsService.parseCpuDarwin('CPU usage: 5.26% user, 10.52% sys, 84.21% idle'), closeTo(15.79, 0.01));
      expect(ServerStatsService.parseCpuDarwin('CPU usage: 5.00% user, 10.00% sys'), closeTo(15.0, 0.01));
      expect(ServerStatsService.parseCpuDarwin('nothing here'), isNull);
    });
  });
}
