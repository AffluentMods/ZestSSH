import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/connection_health_service.dart';

/// One check of whether a host can be reached, as a REAL OpenSSH server
/// sees it: the second of the two servers in WSL that tool/test_sshd.sh
/// starts (127.0.0.1:2297, which nothing else in this suite connects to),
/// read from its own log. The test skips itself when that server is not
/// running. Override the location with ZESTSSH_TEST_SSHD_HOST,
/// ZESTSSH_TEST_REKEY_SSHD_PORT, ZESTSSH_TEST_SSHD_USER and
/// ZESTSSH_TEST_SSHD_DIR.
///
/// What it is for (a reported case): a check is a
/// connection that is closed the moment it stands. A server logs that as a
/// connection that ended before anyone signed in, in the very words that
/// fail2ban's sshd jail counts in its ddos and aggressive modes. Up to
/// 2.2.1 the app made one to every saved host every 20 seconds unless the
/// checks were turned off. That is why they are off until turned on, and
/// what the question before turning them on says.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final log = File('$dir/rekey/sshd.log');
  late bool up;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      // Not a bare connection of the test's own in the log it reads: it
      // says who it is first, as a client that means to sign in does.
      s.write('SSH-2.0-zestssh_test_is_it_up\r\n');
      await s.flush();
      s.destroy();
      up = log.existsSync();
    } catch (_) {
      up = false;
    }
  });

  /// What the server wrote from [from] on, once it has written [what] (it
  /// writes a moment after the connection ends).
  Future<String> written(int from, Pattern what) async {
    final waited = Stopwatch()..start();
    while (true) {
      final bytes = log.readAsBytesSync();
      final added = String.fromCharCodes(bytes.sublist(from < bytes.length ? from : bytes.length));
      if (added.contains(what) || waited.elapsed > const Duration(seconds: 10)) return added;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test('one check, as an OpenSSH server logs it: a connection that ended before anyone signed in', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    // The words a tool that bans for such connections looks for. OpenSSH
    // writes the first when the connection is closed and the second when
    // it is reset, which depends on whether its greeting had arrived.
    final endedBeforeSignIn = RegExp(r'kex_exchange_identification: (read: )?Connection (closed by remote host|reset by peer)');

    final before = log.lengthSync();
    final ms = await tcpReachabilityProbe(host, port);
    expect(ms, isNotNull, reason: 'the server is there');
    expect(ms, lessThan(3000));
    final added = await written(before, endedBeforeSignIn);
    expect(added, contains(endedBeforeSignIn), reason: 'what the server wrote:\n$added');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a host that is not there: no figure, and nothing thrown', () async {
    // A port of this machine that nothing listens on.
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final free = taken.port;
    await taken.close();
    expect(await tcpReachabilityProbe('127.0.0.1', free), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
