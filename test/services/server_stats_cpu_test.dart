import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// The Server Monitor's CPU figure on a Linux host: the share of processor
/// time that went to work between two readings of the host's own counters
/// (the first line of /proc/stat), which is what `top` shows.
///
/// Up to 2.2.1 the figure was the load average divided by the number of
/// processors. A container reports the whole machine's load average and sees
/// only its own processors, so an idle host with a load of 2.2 and two
/// processors read 100% and Critical. The load average plays no part any
/// more: nothing here reads it.

/// One reading of the counters, as the host prints it.
String stat({
  int user = 0,
  int nice = 0,
  int system = 0,
  int idle = 0,
  int iowait = 0,
  int irq = 0,
  int softirq = 0,
  int steal = 0,
  int guest = 0,
  int guestNice = 0,
}) =>
    'cpu  $user $nice $system $idle $iowait $irq $softirq $steal $guest $guestNice';

/// A host that answers each command with the next of [answers] and keeps
/// what it was asked.
class Host {
  Host(this.answers);
  final List<String?> answers;
  final asked = <String>[];

  Future<String?> run(String command) async {
    asked.add(command);
    return answers.removeAt(0);
  }
}

void main() {
  const key = 4711;
  const read = ServerStatsService.cpuReadCmd;
  const sample = ServerStatsService.cpuSampleCmd;

  setUp(() => ServerStatsService.clearCacheFor(key));

  group('reading the counters', () {
    test('all of the time is the first eight numbers, and idle time includes waiting for a disk', () {
      final readings = ServerStatsService.parseCpuTimes(
        'cpu  206 0 737 9371 97 0 112 0 0 0',
      );
      expect(readings, hasLength(1));
      expect(readings.single.total, 206 + 737 + 9371 + 97 + 112);
      expect(readings.single.idle, 9371 + 97);
    });

    test('guest time is not counted twice: it is part of user and nice already', () {
      final plain = ServerStatsService.parseCpuTimes(stat(user: 500, nice: 20, idle: 1000));
      final guest = ServerStatsService.parseCpuTimes(
        stat(user: 500, nice: 20, idle: 1000, guest: 300, guestNice: 10),
      );
      expect(guest.single, plain.single);
    });

    test('every reading in the output is taken, in order, and nothing else', () {
      final readings = ServerStatsService.parseCpuTimes([
        stat(user: 10, idle: 90),
        'cpu0 5 0 0 45 0 0 0 0 0 0',
        'cpu1 5 0 0 45 0 0 0 0 0 0',
        'intr 12345 0 0',
        '',
        '  ${stat(user: 30, idle: 170)}  ',
      ].join('\n'));
      expect(readings.map((r) => r.total), [100, 200]);
      expect(readings.map((r) => r.idle), [90, 170]);
    });

    test('an old kernel that counts only user, nice, system and idle is read too', () {
      final readings = ServerStatsService.parseCpuTimes('cpu 10 5 15 70');
      expect(readings.single, (total: 100, idle: 70));
    });

    test('what is not a reading is left out: too few numbers, words, a negative or absurd count', () {
      for (final bad in [
        null,
        '',
        'cpu',
        'cpu 1 2 3',
        'cpu 1 2 x 4 5 6 7 8',
        'cpu 1 2 3 -4 5 6 7 8',
        'cpu 1 2 3 4.5 5 6 7 8',
        'cpu 1 2 3 ${1 << 60} 5 6 7 8',
        'cpu 1 2 3 99999999999999999999999 5 6 7 8',
        'cpus 1 2 3 4 5 6 7 8',
        'head: cannot open /proc/stat',
      ]) {
        expect(ServerStatsService.parseCpuTimes(bad), isEmpty, reason: '$bad');
      }
    });
  });

  group('the share of time that went to work', () {
    CpuTimes at(String line) => ServerStatsService.parseCpuTimes(line).single;

    test('an idle host is near nothing, a busy one near all', () {
      final before = at(stat(user: 1000, system: 500, idle: 100000));
      expect(
        ServerStatsService.cpuPercentBetween(before, at(stat(user: 1001, system: 501, idle: 100198))),
        closeTo(1.0, 1e-9),
      );
      expect(
        ServerStatsService.cpuPercentBetween(before, at(stat(user: 1150, system: 540, idle: 100010))),
        closeTo(95.0, 1e-9),
      );
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(user: 1000, system: 500, idle: 100200))), 0);
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(user: 1100, system: 600, idle: 100000))), 100);
    });

    test('waiting for a disk is not work; time taken by other machines on the same hardware, interrupts and nice are', () {
      final before = at(stat());
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(iowait: 80, idle: 20))), 0);
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(steal: 25, idle: 75))), 25);
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(irq: 5, softirq: 5, nice: 10, idle: 80))), 20);
    });

    test('no figure when no time passed or a counter went backwards', () {
      final before = at(stat(user: 1000, system: 500, idle: 100000));
      expect(ServerStatsService.cpuPercentBetween(before, before), isNull);
      // The host restarted: everything starts again.
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(user: 3, system: 4, idle: 50))), isNull);
      // Idle went backwards while the total went on.
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(user: 2500, system: 500, idle: 99000))), isNull);
      // Work went backwards while idle went on: more idle than there was time.
      expect(ServerStatsService.cpuPercentBetween(before, at(stat(user: 900, system: 500, idle: 100200))), isNull);
    });
  });

  group('checking a host', () {
    test('the first check reads twice, a second apart, and gives the use in between', () async {
      // An idle container: two ticks of work in a second on two processors.
      final host = Host([
        '${stat(user: 5000, system: 3000, idle: 900000)}\n${stat(user: 5001, system: 3001, idle: 900198)}',
      ]);
      final percent = await ServerStatsService.collectCpuLinux(key, host.run);
      expect(percent, closeTo(1.0, 1e-9));
      expect(host.asked, [sample]);
      expect(sample, 'head -n 1 /proc/stat; sleep 1; head -n 1 /proc/stat');
    });

    test('every check after it reads once and gives the use since the check before', () async {
      final host = Host([
        '${stat(user: 5000, idle: 900000)}\n${stat(user: 5002, idle: 900198)}',
        stat(user: 5602, idle: 905598), // a minute on: 600 of 6000 ticks worked
        stat(user: 11002, idle: 906198), // another: 5400 of 6000
      ]);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(1.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(10.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(90.0, 1e-9));
      expect(host.asked, [sample, read, read]);
      expect(read, 'head -n 1 /proc/stat');
    });

    test('each host is measured against its own last reading', () async {
      const other = key + 1;
      addTearDown(() => ServerStatsService.clearCacheFor(other));
      final a = Host(['${stat(idle: 1000)}\n${stat(idle: 1200)}', stat(user: 100, idle: 1300)]);
      final b = Host(['${stat(user: 7000)}\n${stat(user: 7200)}', stat(user: 7250, idle: 150)]);
      expect(await ServerStatsService.collectCpuLinux(key, a.run), 0);
      expect(await ServerStatsService.collectCpuLinux(other, b.run), 100);
      expect(await ServerStatsService.collectCpuLinux(key, a.run), closeTo(50.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(other, b.run), closeTo(25.0, 1e-9));
    });

    test('asked again within a moment, the last figure stands and the next check measures from the same reading', () async {
      final host = Host([
        '${stat(user: 100, idle: 900)}\n${stat(user: 150, idle: 1050)}', // 25%
        stat(user: 153, idle: 1056), // nine ticks on
        stat(user: 950, idle: 1250), // 800 of 1000 since the first check
      ]);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(25.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(25.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(80.0, 1e-9));
      expect(host.asked, [sample, read, read]);
    });

    test('ten ticks are enough to measure', () async {
      final host = Host([
        '${stat(user: 100, idle: 900)}\n${stat(user: 150, idle: 1050)}',
        stat(user: 155, idle: 1055),
      ]);
      await ServerStatsService.collectCpuLinux(key, host.run);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(50.0, 1e-9));
    });

    test('counters that went backwards are measured afresh, twice a second apart', () async {
      final host = Host([
        '${stat(user: 5000, idle: 900000)}\n${stat(user: 5002, idle: 900198)}',
        stat(user: 12, idle: 300), // the host restarted
        '${stat(user: 14, idle: 340)}\n${stat(user: 74, idle: 480)}', // 30%
        stat(user: 174, idle: 1380), // 10% since
      ]);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(1.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(30.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(10.0, 1e-9));
      expect(host.asked, [sample, read, sample, read]);
    });

    test('a few ticks backwards are a reset too, not a moment', () async {
      final host = Host([
        '${stat(user: 100, idle: 900)}\n${stat(user: 150, idle: 1050)}',
        stat(user: 149, idle: 1050), // one tick less than before
        '${stat(user: 149, idle: 1050)}\n${stat(user: 189, idle: 1210)}', // 20%
        stat(user: 199, idle: 1205), // five ticks on, and idle five ticks less
        '${stat(user: 199, idle: 1205)}\n${stat(user: 259, idle: 1345)}', // 30%
      ]);
      await ServerStatsService.collectCpuLinux(key, host.run);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(20.0, 1e-9));
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(30.0, 1e-9));
      expect(host.asked, [sample, read, sample, read, sample]);
    });

    test('a reading from before a pause (older than an hour and a half) is not compared with', () async {
      var now = DateTime.utc(2026, 10, 1, 9);
      final host = Host([
        '${stat(user: 100, idle: 900)}\n${stat(user: 150, idle: 1050)}', // 25%
        stat(user: 1150, idle: 10050), // exactly an hour and a half on: 10%
        '${stat(user: 90000, idle: 10050)}\n${stat(user: 90180, idle: 10070)}', // 90% now
      ]);
      await ServerStatsService.collectCpuLinux(key, host.run, clock: () => now);
      now = now.add(ServerStatsService.cpuReadingMaxAge);
      expect(await ServerStatsService.collectCpuLinux(key, host.run, clock: () => now), closeTo(10.0, 1e-9));
      // The checks were paused for longer than that: the hours in between
      // are not averaged in, the host is measured now.
      now = now.add(ServerStatsService.cpuReadingMaxAge + const Duration(seconds: 1));
      expect(await ServerStatsService.collectCpuLinux(key, host.run, clock: () => now), closeTo(90.0, 1e-9));
      expect(host.asked, [sample, read, sample]);
      // Longer than the longest time between two checks (an hour).
      expect(ServerStatsService.cpuReadingMaxAge, const Duration(minutes: 90));
    });

    test('a host with no such counters has no figure, at every check', () async {
      final host = Host([null, '', 'head: cannot open /proc/stat']);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), isNull);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), isNull);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), isNull);
      expect(host.asked, [sample, sample, sample]);
    });

    test('a first check that got one reading only has no figure yet, and the next one has', () async {
      final host = Host([
        stat(user: 100, idle: 900), // the second reading never came
        stat(user: 400, idle: 1600), // 30% since
      ]);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), isNull);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(30.0, 1e-9));
      expect(host.asked, [sample, read]);
    });

    test('a check that reads nothing forgets the last reading: the next one starts over', () async {
      final host = Host([
        '${stat(user: 100, idle: 900)}\n${stat(user: 150, idle: 1050)}',
        null,
        '${stat(user: 5000, idle: 9000)}\n${stat(user: 5120, idle: 9080)}', // 60%
      ]);
      await ServerStatsService.collectCpuLinux(key, host.run);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), isNull);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(60.0, 1e-9));
      expect(host.asked, [sample, read, sample]);
    });

    test('a host whose connection closed is measured afresh when it is back', () async {
      final host = Host([
        '${stat(user: 100, idle: 900)}\n${stat(user: 150, idle: 1050)}', // 25%
        '${stat(user: 7000, idle: 2000)}\n${stat(user: 7020, idle: 2180)}', // 10%
      ]);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(25.0, 1e-9));
      ServerStatsService.clearCacheFor(key);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), closeTo(10.0, 1e-9));
      expect(host.asked, [sample, sample]);
    });

    test('a first check whose two readings are the same has no figure', () async {
      final host = Host(['${stat(user: 100, idle: 900)}\n${stat(user: 100, idle: 900)}']);
      expect(await ServerStatsService.collectCpuLinux(key, host.run), isNull);
    });

    test('the figure is between 0 and 100 whatever the host prints', () async {
      for (final second in [
        stat(user: 1 << 53, idle: 900),
        stat(user: 100, idle: 1 << 53),
        stat(user: 100, nice: 1 << 53, system: 1 << 53, idle: 1 << 53, iowait: 1 << 53, irq: 1 << 53, softirq: 1 << 53, steal: 1 << 53),
      ]) {
        ServerStatsService.clearCacheFor(key);
        final host = Host(['${stat(user: 100, idle: 900)}\n$second']);
        final percent = await ServerStatsService.collectCpuLinux(key, host.run);
        expect(percent, isNotNull, reason: second);
        expect(percent, inInclusiveRange(0, 100), reason: second);
      }
    });
  });
}
