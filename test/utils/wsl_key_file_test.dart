import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/windows_programs.dart';
import 'package:zestssh/utils/wsl_key_file.dart';

/// A key for Mosh or Eternal Terminal on Windows is written where they read
/// it (found while comparing the five versions, in released
/// versions too). They run inside WSL there, and were handed the key's path in
/// Windows, which WSL's ssh cannot open (nor would it take a key from
/// Windows' folders, readable by everyone as it sees them). Now the key is
/// written inside WSL, into a folder of its own that the WSL account alone
/// can open, from the command's input, and removed with its folder when the
/// session ends; what a crash left there goes once an hour old.
void main() {
  const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\r\nb3BlbnNzaC1rZXktdjEAAAAA\r\n-----END OPENSSH PRIVATE KEY-----\r\n';

  group('with WSL played by the test', () {
    late List<(List<String>, String?)> ran;
    late ({int code, String out}) answer;
    setUp(() {
      ran = [];
      answer = (code: 0, out: '/tmp/zestssh_mosh_Ab12Cd/id_key');
    });
    Future<({int code, String out})> wsl(List<String> arguments, {String? input}) async {
      ran.add((arguments, input));
      return answer;
    }

    test('a key is written by one command that reads it from its input, with the line ends of Linux; never on its '
        'command line; and its path in WSL is what comes back', () async {
      expect(await writeKeyInWsl(pem, run: wsl), '/tmp/zestssh_mosh_Ab12Cd/id_key');
      expect(ran, hasLength(1));
      final (arguments, input) = ran.single;
      expect(arguments.take(3), ['--exec', 'sh', '-c']);
      expect(arguments.skip(3).first, contains('umask 077'));
      expect(arguments.skip(3).first, contains(r'mktemp -d "$1/zestssh_mosh_XXXXXX"'));
      expect(arguments.skip(4), ['sh', '/tmp']);
      expect(input, '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n');
      expect(arguments.join(' '), isNot(contains('b3BlbnNzaC1rZXktdjEAAAAA')));
    });

    test('a key not written, or a path that is not one it makes, is a failure', () async {
      for (final (code, out) in [
        (1, ''),
        (0, ''),
        (0, '/home/alex/.ssh/id_ed25519'),
        (0, '/tmp/zestssh_mosh_Ab12Cd/id_key\n/tmp/other'),
        (0, '/tmp/zestssh_mosh_Ab12Cd/../id_key'),
        (127, '/tmp/zestssh_mosh_Ab12Cd/id_key'),
      ]) {
        answer = (code: code, out: out);
        await expectLater(writeKeyInWsl(pem, run: wsl), throwsStateError, reason: '$code $out');
      }
    });

    test('a key is removed with its folder; anything else is left alone', () async {
      await removeKeyInWsl('/tmp/zestssh_mosh_Ab12Cd/id_key', run: wsl);
      expect(ran.single.$1, ['--exec', 'rm', '-rf', '--', '/tmp/zestssh_mosh_Ab12Cd']);
      ran.clear();
      for (final other in [
        '',
        '/tmp',
        '/tmp/zestssh_mosh_Ab12Cd',
        '/tmp/zestssh_mosh_Ab12Cd/id_key2',
        '/tmp/zestssh_mosh_Ab12Cd/../../home/alex/id_key',
        '/home/alex/zestssh_mosh_Ab12Cd/id_key',
        r'C:\Users\alex\AppData\Local\Temp\zestssh_mosh_Ab12Cd\id_key',
      ]) {
        await removeKeyInWsl(other, run: wsl);
      }
      expect(ran, isEmpty);
    });

    test('what a crash left is cleared by one command; WSL not reached is no failure', () async {
      await clearLeftoverKeysInWsl(run: wsl);
      expect(ran.single.$1.take(3), ['--exec', 'sh', '-c']);
      expect(ran.single.$1.skip(4), ['sh', '/tmp']);
      Future<({int code, String out})> unreached(List<String> arguments, {String? input}) =>
          throw const ProcessException('wsl.exe', [], 'not there');
      await clearLeftoverKeysInWsl(run: unreached);
      await removeKeyInWsl('/tmp/zestssh_mosh_Ab12Cd/id_key', run: unreached);
    });

    test('Mosh and Eternal Terminal on Windows have their key written in WSL and removed there', () {
      final sessions = File('lib/providers/terminal_providers.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final writer = sessions.substring(sessions.indexOf('Future<String?> _resolveIdentityKeyPath('));
      expect(writer, contains('    if (Platform.isWindows) {\n      await clearLeftoverKeysInWsl();\n      return writeKeyInWsl(pem);\n    }\n'));
      expect(writer.indexOf('return writeKeyInWsl(pem);'), lessThan(writer.indexOf('Directory.systemTemp.createTemp(')));
      expect(File('lib/services/mosh_service.dart').readAsStringSync(),
          contains('if (Platform.isWindows) return removeKeyInWsl(sshIdentityPath!);'));
      expect(File('lib/services/eternal_terminal_service.dart').readAsStringSync(),
          contains('if (Platform.isWindows) return removeKeyInWsl(path);'));
    });
  });

  group('in WSL itself', () {
    // In a folder of the test's own in WSL's /tmp: a folder the app made there for a real session is never touched.
    late String root;
    Future<String> sh(String script) async {
      final r = await Process.run(windowsSystemProgram('wsl.exe'), ['--exec', 'sh', '-c', script],
          stdoutEncoding: utf8);
      expect(r.exitCode, 0, reason: '$script: ${r.stdout}');
      return (r.stdout as String).trim();
    }

    final hasWsl = Platform.isWindows && File(windowsSystemProgram('wsl.exe')).existsSync();

    setUp(() async {
      root = await sh('mktemp -d /tmp/zest-app-wsl-key-test-XXXXXX');
      expect(root, startsWith('/tmp/zest-app-wsl-key-test-'));
      addTearDown(() => sh('rm -rf -- "$root"'));
    });

    test('a key is written readable by the WSL account alone, as it was given, and removed with its folder',
        () async {
      final path = await writeKeyInWsl(pem, root: root);
      expect(isWslKeyPath(path, root: root), isTrue);
      final folder = path.substring(0, path.lastIndexOf('/'));
      expect(await sh('stat -c %a "$folder"'), '700');
      expect(await sh('stat -c %a "$path"'), '600');
      expect(await sh('stat -c %U "$path"'), await sh('whoami'));
      expect(await sh('cat "$path"'), pem.replaceAll('\r\n', '\n').trim());

      await removeKeyInWsl(path, root: root);
      expect(await sh('ls -A "$root"'), isEmpty);
    }, skip: hasWsl ? false : 'needs WSL on Windows');

    test('a sweep removes what a crash left an hour ago and nothing else', () async {
      await sh('cd "$root" && mkdir zestssh_mosh_Old111 zestssh_mosh_New222 zestssh_mosh_Two333 notours_Old444 && '
          'for d in zestssh_mosh_Old111 zestssh_mosh_New222 zestssh_mosh_Two333 notours_Old444; do echo key > "\$d/id_key"; done && '
          'echo notes > zestssh_mosh_Two333/notes.txt && '
          "touch -d '2 hours ago' zestssh_mosh_Old111/id_key zestssh_mosh_Old111 zestssh_mosh_Two333/id_key "
          'zestssh_mosh_Two333/notes.txt zestssh_mosh_Two333 notours_Old444/id_key notours_Old444');

      await clearLeftoverKeysInWsl(root: root);

      expect(await sh('ls -A "$root" | sort | tr "\\n" " "'), 'notours_Old444 zestssh_mosh_New222 zestssh_mosh_Two333');
    }, skip: hasWsl ? false : 'needs WSL on Windows');
  });
}
