import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/sftp_service.dart';

/// Following a file on a host as it grows (the file panes' live view of a
/// log), on a real OpenSSH server (3.0, from the SSH core's audit).
///
/// Two things were wrong. Closing the view closed the app's side of the
/// command's channel and nothing more: `tail -f` reads nothing from there,
/// so it went on running on the host, one more for every time a log was
/// looked at, until the whole connection ended. And what the file held was
/// taken a byte for a letter: any letter that is more than one byte in
/// UTF-8 (an umlaut, an accent, any other alphabet) came out as two or
/// three wrong ones.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it); its own client key logs in. Skips itself when the server is
/// not running. Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT /
/// _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  const patience = Duration(seconds: 15);
  late bool up;
  List<SSHKeyPair>? keys;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) keys = SSHKeyPair.fromPem(file.readAsStringSync());
    } catch (_) {
      up = false;
    }
  });

  Future<SSHClient> connect() async {
    final client = SSHClient(await SSHSocket.connect(host, port), username: user, identities: keys);
    addTearDown(client.close);
    await client.authenticated.timeout(patience);
    return client;
  }

  Future<String> run(SSHClient client, String command) async =>
      utf8.decode(await client.run(command).timeout(patience)).trim();

  /// A folder of the test's own on the host, with a log in it that holds
  /// three lines; gone when the test is over.
  Future<({SSHClient client, String folder, String log})> withLog({String name = 'app.log'}) async {
    final client = await connect();
    final folder = await run(client, 'mktemp -d /tmp/zest-tail-test.XXXXXX');
    expect(folder, startsWith('/tmp/zest-tail-test.'));
    addTearDown(() async {
      final cleaner = await connect();
      await run(cleaner, "rm -rf '$folder'");
      cleaner.close();
    });
    final log = '$folder/$name';
    final quoted = "'${log.replaceAll("'", "'\\''")}'";
    await run(client, "printf 'one\\ntwo\\nthree\\n' > $quoted");
    return (client: client, folder: folder, log: log);
  }

  /// How many `tail` programs follow something in [folder] on the host.
  Future<int> tailsIn(SSHClient client, String folder) async =>
      int.parse(await run(client, "pgrep -fc 'tail -n [0-9]+ -f .?$folder' || true"));

  Future<void> until(FutureOr<bool> Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!await check()) {
      if (clock.elapsed > patience) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('the last lines of a file, and each line it gains, with letters of any alphabet whole', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final s = await withLog();
    final tail = await SftpService(s.client).tailFile(s.log, initialLines: 2);
    final lines = <String>[];
    final sub = tail.lines.listen(lines.add);
    await until(() => lines.length >= 2, 'the last two lines');
    expect(lines, ['two', 'three']);

    // A line in another alphabet, and one with letters of two and three bytes.
    final writer = await connect();
    final greek = String.fromCharCodes([0x3b3, 0x3b5, 0x3b9, 0x3b1]);
    final mixed = 'gr${String.fromCharCode(0xfc)}${String.fromCharCode(0xdf)}e ${String.fromCharCode(0x20ac)}5';
    await run(writer, "printf '%s\\n%s\\n' '$greek' '$mixed' >> '${s.log}'");
    await until(() => lines.length >= 4, 'the two new lines');
    expect(lines.sublist(2), [greek, mixed]);

    // A letter whose two bytes come in two pieces is one letter still.
    await run(writer, "printf 'f\\303' >> '${s.log}'; sleep 0.4; printf '\\274r\\n' >> '${s.log}'");
    await until(() => lines.length >= 5, 'the line that came in pieces');
    expect(lines[4], 'f${String.fromCharCode(0xfc)}r');

    // A byte that is no UTF-8 is a mark in its line, and the lines go on.
    await run(writer, "printf 'bad\\377byte\\nnext\\n' >> '${s.log}'");
    await until(() => lines.length >= 7, 'the lines after a byte that is no UTF-8');
    expect(lines.sublist(5), ['bad${String.fromCharCode(0xfffd)}byte', 'next']);

    await sub.cancel();
    await tail.cancel();
    expect(await tail.said.timeout(patience), '', reason: 'ended from here: nothing to say of why');
  });

  test('closing the view ends the program on the host, and the connection goes on', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final s = await withLog();
    final service = SftpService(s.client);
    final watcher = await connect();
    final tail = await service.tailFile(s.log);
    final lines = <String>[];
    var done = false;
    tail.lines.listen(lines.add, onDone: () => done = true);
    await until(() => lines.length >= 3, 'the lines');
    expect(await tailsIn(watcher, s.folder), 1);

    await tail.cancel().timeout(patience);
    await until(() async => await tailsIn(watcher, s.folder) == 0, 'the program on the host to end');
    expect(done, isTrue, reason: 'the lines are over for whoever listened');

    // The same connection follows the file again, and once more: nothing piles up on the host.
    for (var i = 0; i < 2; i++) {
      final again = await service.tailFile(s.log, initialLines: 1);
      expect(await again.lines.first.timeout(patience), 'three');
      await again.cancel().timeout(patience);
    }
    await until(() async => await tailsIn(watcher, s.folder) == 0, 'the programs on the host to end');
    expect(s.client.isClosed, isFalse);
  });

  test('a file with spaces and brackets in its name', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final s = await withLog(name: 'the app (1) [old].log');
    final tail = await SftpService(s.client).tailFile(s.log, initialLines: 1);
    expect(await tail.lines.first.timeout(patience), 'three');
    await tail.cancel().timeout(patience);
  });

  // A quote ends POSIX quotes in the shell of a Windows host or in fish (found in a
  // security review): such a name goes into no
  // command, and nothing runs on the host.
  test('a file with a quote in its name is not followed, and nothing is started for it', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final s = await withLog(name: "the app's log.txt");
    final watcher = await connect();
    await expectLater(SftpService(s.client).tailFile(s.log, initialLines: 1),
        throwsA(isA<SftpNameNotInCommandException>()));
    expect(await tailsIn(watcher, s.folder), 0);
  });

  test('a file that is not there: the lines end, and nothing is left running', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final s = await withLog();
    final watcher = await connect();
    final tail = await SftpService(s.client).tailFile('${s.folder}/no-such.log');
    expect(await tail.lines.toList().timeout(patience), isEmpty);
    // What the program on the host said of it is kept, on one line.
    final said = await tail.said.timeout(patience);
    expect(said, contains('No such file or directory'));
    expect(said, contains('no-such.log'));
    expect(said, isNot(contains('\n')));
    await tail.cancel().timeout(patience);
    expect(await tailsIn(watcher, s.folder), 0);
  });

  test('a file that may not be read: the lines end, with what the host said of it', () async {
    if (!up) {
      markTestSkipped('no test sshd at $host:$port');
      return;
    }
    final s = await withLog();
    await run(s.client, "chmod 000 '${s.log}'");
    final tail = await SftpService(s.client).tailFile(s.log);
    expect(await tail.lines.toList().timeout(patience), isEmpty);
    expect(await tail.said.timeout(patience), contains('Permission denied'));
    await tail.cancel().timeout(patience);
  });

  test('the script that follows a file: `tail` beside a `cat` that ends with the app\'s side, and a watch on `tail`',
      () {
    final script = SftpService.tailScript(50);
    expect(script, startsWith('tail -n 50 -f "\$1" & t=\$!; '));
    expect(script, contains('cat >/dev/null 2>&1; kill "\$t" "\$w" 2>/dev/null'));
    expect(script, contains('while kill -0 "\$t" 2>/dev/null; do sleep 1; done; kill "\$\$" 2>/dev/null'));
    // It is handed to `sh` between single quotes: it holds none.
    expect(script, isNot(contains("'")));
    expect(SftpService.tailScript(200), contains('tail -n 200 -f'));
  });
}
