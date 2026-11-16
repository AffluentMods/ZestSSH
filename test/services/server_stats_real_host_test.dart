import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// The Server Monitor's figures from a REAL Linux host, over a real SSH
/// connection: the OpenSSH server in WSL on 127.0.0.1:2299 (the same one
/// rsa_cert_login_test.dart uses; tool/test_sshd.sh starts it).
/// Every test skips itself when that server is not running. Override the
/// location with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
///
/// What it is for: up to 2.2.1 the "CPU" figure of a Linux host was its load
/// average divided by its processors. A host whose load average is high
/// while its processors are idle (a container, which reports the whole
/// machine's load; anything waiting for a disk) read 100% and Critical. The
/// last test puts a real host into exactly that state and reads it.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;
  final clients = <SSHClient>[];

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      up = File('$dir/client_ed25519').existsSync();
    } catch (_) {
      up = false;
    }
  });

  tearDown(() async {
    for (final client in clients) {
      ServerStatsService.clearCache(client);
      client.close();
      await client.done.catchError((_) {});
    }
    clients.clear();
  });

  Future<SSHClient> connect() async {
    final key = SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()).single;
    final client = SSHClient(await SSHSocket.connect(host, port), username: user, identities: [key]);
    await client.authenticated;
    clients.add(client);
    return client;
  }

  Future<String> sh(SSHClient client, String command) async =>
      String.fromCharCodes(await client.run(command)).trim();

  /// What the host itself says its processors did over a second: `vmstat`'s
  /// second line counts what happened since its first.
  Future<double> usedByVmstat(SSHClient client) async {
    final lines = (await sh(client, 'vmstat 1 2')).split('\n');
    final names = lines[1].trim().split(RegExp(r'\s+'));
    final values = lines.last.trim().split(RegExp(r'\s+'));
    double of(String name) => double.parse(values[names.indexOf(name)]);
    return 100 - of('id') - of('wa');
  }

  const skipped = 'test sshd not running';

  test('every figure of a real host is read, and its CPU figure is what the host itself says', () async {
    if (!up) return markTestSkipped('$skipped on $host:$port');
    final client = await connect();
    final results = await Future.wait([
      ServerStatsService.getStats(client),
      usedByVmstat(client),
    ]);
    final stats = results[0] as ServerStats;
    final byVmstat = results[1] as double;

    expect(stats.cpuPercent, isNotNull);
    expect(stats.cpuPercent, inInclusiveRange(0, 100));
    expect(stats.cpuPercent, closeTo(byVmstat, 12), reason: 'vmstat over the same second says $byVmstat');

    // The other figures still come from the right commands.
    expect(stats.ramTotalMB, greaterThan(100));
    expect(stats.ramUsedMB, inInclusiveRange(1, stats.ramTotalMB!));
    expect(stats.ramTotalMB, int.parse(await sh(client, "free -m | awk 'NR==2{print \$2}'")));
    expect(stats.diskPercent, inInclusiveRange(0, 100));
    expect(stats.diskPercent, double.parse((await sh(client, "df -h / | awk 'NR==2{print \$5}'")).replaceAll('%', '')));
    expect(stats.uptime, isNotEmpty);
    expect(stats.uptime, isNot(contains('load')));
    expect(stats.loadAverage, hasLength(3));
    expect(stats.uptimeSeconds, greaterThan(0));
    expect(stats.processesTotal, greaterThan(0));
    expect(stats.kernel, await sh(client, 'uname -r'));
    expect(stats.source, MetricSource.ssh);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // A reported case (addresses banned by fail2ban's sshd
  // jail in its ddos mode): up to 2.2.1 every reading opened a connection of
  // its own to the host's SSH port to time it, and closed it without signing
  // in, which a server logs as a connection that ended before sign-in. Every
  // reading of every session and of Server Monitor did.
  test('a reading connects nowhere: how long a round trip takes is measured on the connection it has', () async {
    if (!up) return markTestSkipped('$skipped on $host:$port');
    final client = await connect();
    final dialled = <String>[];
    final stats = await IOOverrides.runZoned(
      () => ServerStatsService.getStats(client),
      socketConnect: (address, port, {sourceAddress, int sourcePort = 0, Duration? timeout}) {
        dialled.add('$address:$port');
        throw const SocketException('a reading connects nowhere');
      },
      socketStartConnect: (address, port, {sourceAddress, int sourcePort = 0}) {
        dialled.add('$address:$port');
        throw const SocketException('a reading connects nowhere');
      },
    );
    expect(dialled, isEmpty);
    expect(stats.pingMs, isNotNull, reason: 'the host answered on the session');
    expect(stats.pingMs, inInclusiveRange(0, 2000), reason: 'a host on this machine');
    expect(stats.cpuPercent, isNotNull, reason: 'and the reading is whole');
    // Asked again, it is measured again (and the session is still good).
    final again = await ServerStatsService.getStats(client);
    expect(again.pingMs, isNotNull);
    expect(await sh(client, 'echo still-here'), 'still-here');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('work shows in the figure, as the share of all processors, and is gone when the work is', () async {
    if (!up) return markTestSkipped('$skipped on $host:$port');
    final client = await connect();
    final cores = int.parse(await sh(client, 'nproc'));
    final busy = (cores / 2).ceil();

    final idle = await ServerStatsService.getStats(client);
    expect(idle.cpuPercent, lessThan(20), reason: 'the host is idle before the work starts');

    // Half the processors spin for six seconds.
    final work = client.run(
      'for i in \$(seq $busy); do timeout 6 sh -c "while :; do :; done" & done; wait',
    );
    await Future<void>.delayed(const Duration(seconds: 4));
    final during = await ServerStatsService.getStats(client);
    final expected = busy / cores * 100;
    // Since the check before: four seconds, nearly all of them at work.
    expect(during.cpuPercent, inInclusiveRange(expected * 0.6, expected * 1.15),
        reason: '$busy of $cores processors spun');

    await work;
    await ServerStatsService.getStats(client); // the rest of the work falls in this one
    await Future<void>.delayed(const Duration(seconds: 3));
    final after = await ServerStatsService.getStats(client);
    expect(after.cpuPercent, lessThan(20), reason: 'three seconds after the work ended');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a host with a high load average and idle processors reads idle (it read 100% and Critical)', () async {
    if (!up) return markTestSkipped('$skipped on $host:$port');
    final client = await connect();
    if ((await sh(client, 'command -v cc || true')).isEmpty) {
      return markTestSkipped('no C compiler on the test host');
    }
    final cores = int.parse(await sh(client, 'nproc'));
    addTearDown(() async {
      final c = await connect();
      await sh(c, 'pkill -x zest_loadhold; rm -f /tmp/zest_loadhold /tmp/zest_loadhold.c; true');
    });

    // A process that waits in vfork() for its child is counted in the load
    // average, like one that waits for a disk, and uses no processor. Four
    // per processor take the one-minute average past the number of
    // processors within twenty seconds.
    await sh(client, r'''
cat > /tmp/zest_loadhold.c <<'EOF'
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 30;
  if (vfork() == 0) {
    sleep(seconds);
    _exit(0);
  }
  return 0;
}
EOF
cc -o /tmp/zest_loadhold /tmp/zest_loadhold.c''');
    final holders = cores * 4;
    unawaited(client.run('for i in \$(seq $holders); do /tmp/zest_loadhold 60 & done; wait').then((_) {}, onError: (_) {}));

    var load = 0.0;
    final waited = Stopwatch()..start();
    while (waited.elapsed < const Duration(seconds: 45)) {
      load = double.parse((await sh(client, 'cat /proc/loadavg')).split(' ').first);
      if (load >= cores) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (load < cores) {
      return markTestSkipped('the load average of this host did not rise ($load on $cores processors)');
    }

    final stats = await ServerStatsService.getStats(client);
    final byVmstat = await usedByVmstat(client);

    // What every version up to 2.2.1 showed as CPU for this host.
    final before = (stats.loadAverage!.first / cores * 100).clamp(0.0, 100.0);
    expect(before, 100, reason: 'load ${stats.loadAverage!.first} on $cores processors');
    expect(before, greaterThanOrEqualTo(kDefaultThresholds[MonitorMetric.cpu]!.crit));

    // What it shows now: what the processors do.
    expect(stats.cpuPercent, isNotNull);
    expect(stats.cpuPercent, lessThan(20), reason: 'the processors are idle; vmstat says $byVmstat');
    expect(stats.cpuPercent, lessThan(kDefaultThresholds[MonitorMetric.cpu]!.warn));
    // The load average is still shown, in its own column.
    expect(stats.loadAverage!.first, greaterThanOrEqualTo(cores * 0.9));
    // ignore: avoid_print
    print('load ${stats.loadAverage!.first} on $cores processors: was ${before.toStringAsFixed(0)}%, '
        'is ${stats.cpuPercent!.toStringAsFixed(1)}% (vmstat: ${byVmstat.toStringAsFixed(1)}%)');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
