import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/command_history/history_table.dart';

/// What a computer's History page reads of the recorded commands (3.0): the
/// trivial ones, a home folder written `~`, a run time written short, and
/// the rows grouped by day with repeats counted.
void main() {
  CommandHistoryEntry e(String id, String command, DateTime at, {String? host = 'c1', String? label = 'web-01'}) =>
      CommandHistoryEntry(id: id, command: command, connectionId: host, hostLabel: label, createdAt: at);

  group('isTrivialCommand', () {
    test('moving around, looking and clearing are trivial', () {
      for (final c in ['cd', 'cd ~', 'cd ..', ' ls -la ', 'll', 'pwd', 'clear', 'exit', 'history', 'whoami']) {
        expect(isTrivialCommand(c), isTrue, reason: c);
      }
    });

    test('anything that does more is not', () {
      for (final c in [
        'ls | grep x',
        'cd /srv && make',
        'cd /srv; make',
        'ls > files.txt',
        'cd \$(mktemp -d)',
        'clear\nrm -rf build',
        'lsblk',
        'cdk deploy',
        'sudo ls /root',
        '',
      ]) {
        expect(isTrivialCommand(c), isFalse, reason: c);
      }
    });
  });

  group('shortenHomeFolder', () {
    test("the user's home is ~", () {
      expect(shortenHomeFolder('/home/ana', 'ana'), '~');
      expect(shortenHomeFolder('/home/ana/', 'ana'), '~');
      expect(shortenHomeFolder('/home/ana/site/src', 'ana'), '~/site/src');
      expect(shortenHomeFolder('/Users/ana/site', 'ana'), '~/site');
      expect(shortenHomeFolder('/root/build', 'root'), '~/build');
    });

    test('anything else stays as it is', () {
      expect(shortenHomeFolder('/home/anabel/site', 'ana'), '/home/anabel/site');
      expect(shortenHomeFolder('/home/bob', 'ana'), '/home/bob');
      expect(shortenHomeFolder('/srv/app', 'ana'), '/srv/app');
      expect(shortenHomeFolder('/root', 'ana'), '/root');
      expect(shortenHomeFolder('/home/ana', null), '/home/ana');
    });
  });

  test('formatTook writes a run time short', () {
    String took(int ms, [String sep = '.']) => formatTook(
          ms,
          seconds: (s) => '${s}s',
          minutes: (m) => '${m}m',
          hours: (h, m) => '${h}h ${m}m',
          decimalSeparator: sep,
        );
    expect(took(40), '<0.1s');
    expect(took(100), '0.1s');
    expect(took(1840), '1.8s');
    expect(took(1840, ','), '1,8s');
    expect(took(9990), '10s');
    expect(took(12300), '12s');
    expect(took(41000), '41s');
    expect(took(59700), '59s');
    expect(took(18 * 60000 + 30000), '18m');
    expect(took(2 * 3600000 + 5 * 60000), '2h 5m');
  });

  group('groupHistoryByDay', () {
    final day1 = DateTime(2026, 10, 20, 13);
    final day2 = DateTime(2026, 10, 15, 18);

    test('days newest first, each with its count', () {
      final days = groupHistoryByDay([
        e('a', 'uptime', day1),
        e('b', 'df -h', day1.subtract(const Duration(minutes: 1))),
        e('c', 'uptime', day2),
      ]);
      expect([for (final d in days) d.day], [DateTime(2026, 10, 20), DateTime(2026, 10, 15)]);
      expect([for (final d in days) d.count], [2, 1]);
    });

    test('the same command right after itself on the same host is one row with its count', () {
      final days = groupHistoryByDay([
        e('a', 'make', day1),
        e('b', 'make', day1.subtract(const Duration(minutes: 1))),
        e('c', 'make', day1.subtract(const Duration(minutes: 2))),
        e('d', 'make', day1.subtract(const Duration(minutes: 3)), host: 'c2', label: 'db-01'),
        e('e', 'ls', day1.subtract(const Duration(minutes: 4))),
        e('f', 'make', day1.subtract(const Duration(minutes: 5))),
      ]);
      final runs = days.single.runs;
      expect([for (final r in runs) (r.entry.id, r.repeat)], [('a', 3), ('d', 1), ('e', 1), ('f', 1)]);
      expect(days.single.count, 6);
      expect([for (final r in days.single.trivialRuns) r.entry.id], ['e']);
    });

    test('a repeat never runs over midnight', () {
      final days = groupHistoryByDay([
        e('a', 'make', DateTime(2026, 10, 20, 0, 1)),
        e('b', 'make', DateTime(2026, 10, 19, 23, 59)),
      ]);
      expect([for (final d in days) d.runs.single.repeat], [1, 1]);
    });

    test('hosts are told apart by saved host, else by name', () {
      expect(historyHostKey(e('a', 'x', day1)), 'id:c1');
      expect(historyHostKey(e('a', 'x', day1, host: null)), 'label:web-01');
      expect(historyHostKey(e('a', 'x', day1, host: null, label: null)), isNull);
    });
  });
}
