import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/utils/command_text.dart';

/// What a real shell does with the line ends of a command, on a real OpenSSH
/// server: why a command written on Windows is typed and run through
/// [CommandText].
///
/// A bug in 2.2.1: a snippet of several lines was double spaced:
/// every line was followed by an empty one. Its lines ended in a carriage
/// return and a line feed, and a shell at its prompt takes each of the two
/// for Enter.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (the one
/// test/features/orchards/certs/team_certificate_login_test.dart uses); its
/// own client key logs in. Skips itself when the server is not running.
/// Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ??
      '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;
  SSHKeyPair? key;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port,
          timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    } catch (_) {
      up = false;
    }
  });

  Future<T> withClient<T>(Future<T> Function(SSHClient client) body) async {
    final client = SSHClient(await SSHSocket.connect(host, port),
        username: user, identities: [key!]);
    try {
      await client.authenticated;
      return await body(client);
    } finally {
      client.close();
      await client.done;
    }
  }

  /// Types [keys] at the prompt of a fresh bash and gives back how many
  /// times it showed its "more of this command, please" prompt before the
  /// command ran.
  Future<int> continuationPrompts(String keys) => withClient((client) async {
        final shell = await client.shell(
            pty: const SSHPtyConfig(width: 120, height: 40));
        final seen = StringBuffer();
        final done = Completer<void>();
        final sub = shell.stdout.listen((chunk) {
          seen.write(utf8.decode(chunk, allowMalformed: true));
          if (seen.toString().contains('all-done-42') && !done.isCompleted) {
            done.complete();
          }
        });
        void type(String text) => shell.write(utf8.encode(text));

        // A bash of its own, with prompts that can be counted.
        type('exec bash --norc --noprofile -i\r');
        type("PS1='READY> '; PS2='MORE> '\r");
        await Future<void>.delayed(const Duration(milliseconds: 600));
        seen.clear();
        type(keys);
        type('echo all-done-\$((40+2))\r');
        await done.future.timeout(const Duration(seconds: 15));
        await sub.cancel();
        shell.close();
        return 'MORE> '.allMatches(seen.toString()).length;
      });

  const written =
      '(\r\necho one\r\necho two\r\n)'; // four lines, written on Windows

  test('typed as written on Windows, every line is followed by an empty one',
      () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    // The three lines after "(" each ask for more twice: once for the
    // carriage return, once for the line feed.
    expect(await continuationPrompts('$written\r'), 6);
  });

  test('typed by the rule, every line is entered once', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    expect(await continuationPrompts(CommandText.entered(written)), 3);
  });

  test('handed whole to the shell as written on Windows, it does not run',
      () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    final result = await withClient(
        (c) => c.runWithResult('cd /tmp\r\npwd', stderr: true));
    final out = utf8.decode(result.output, allowMalformed: true);
    expect(out.trim(), isNot('/tmp'),
        reason: 'the carriage return is taken for the end of the folder name');
  });

  test('handed whole to the shell by the rule, it runs', () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    final out = await withClient((c) async => utf8.decode(
        await c.run(CommandText.script('cd /tmp\r\npwd'), stderr: false)));
    expect(out.trim(), '/tmp');
  });

  test('the command that goes into a folder takes a name no shell reads as a command',
      () async {
    if (!up) return markTestSkipped('test sshd not running on $host:$port');
    // A name with a quote, $, a backtick or a backslash gets no command at all
    // (CommandText.standsInAnyShell, from a review: POSIX quotes
    // do not hold in cmd.exe, PowerShell or fish). Names of letters of any
    // script, digits, symbols, spaces and . _ / + @ , : = ~ # ( ) [ ] - do.
    for (final refused in [
      "it's here",
      r'two  spaces $HOME `id`',
      "x'; echo RAN-BY-ITSELF; '",
      r'back\slash "double"',
    ]) {
      expect(CommandText.cdInto('/tmp/zest-cd-test/$refused'), isNull, reason: refused);
    }
    const names = [
      'two  spaces (1)',
      'Ünïcödé + #tag [x]',
      'a,b=c~d@e:f',
    ];
    final out = await withClient((c) async {
      final lines = <String>[];
      for (final name in names) {
        final path = '/tmp/zest-cd-test/$name';
        // The folder is made with the same quoting, then gone into.
        lines.add(utf8.decode(await c.run(
            'mkdir -p ${CommandText.quoted(path)} && ${CommandText.cdInto(path)} && pwd',
            stderr: false)));
      }
      await c.run("rm -rf '/tmp/zest-cd-test'");
      return lines;
    });
    expect([for (final line in out) line.trimRight()],
        [for (final name in names) '/tmp/zest-cd-test/$name']);
    expect(out.join(), isNot(contains('RAN-BY-ITSELF\n')),
        reason: 'the name is a name, not a command');
  });
}
