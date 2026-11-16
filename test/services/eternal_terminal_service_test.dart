import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/eternal_terminal_service.dart';
import 'package:zestssh/services/mosh_service.dart';
import 'package:zestssh/utils/windows_programs.dart';

void main() {
  group('EternalTerminalService.buildArgs', () {
    test('default: etserver port, user@host, nothing else', () {
      final s = EternalTerminalService(host: 'box.example', username: 'me');
      expect(s.buildArgs(), ['--port', '2022', 'me@box.example']);
    });

    test('a non-default SSH port reaches ssh as -oPort', () {
      final s = EternalTerminalService(
          host: 'box.example', port: 2222, username: 'me');
      expect(s.buildArgs(),
          ['--port', '2022', '--ssh-option', 'Port=2222', 'me@box.example']);
    });

    test('a key reaches ssh as IdentityFile and pins IdentitiesOnly', () {
      final s = EternalTerminalService(
        host: '10.0.0.5',
        username: 'root',
        sshIdentityPath: '/tmp/zestssh_mosh_ab12/id_key',
      );
      expect(s.buildArgs(), [
        '--port',
        '2022',
        '--ssh-option',
        'IdentityFile=/tmp/zestssh_mosh_ab12/id_key',
        '--ssh-option',
        'IdentitiesOnly=yes',
        'root@10.0.0.5',
      ]);
    });

    test('a custom etserver port is honoured', () {
      final s = EternalTerminalService(
          host: 'h', username: 'u', etPort: 2222, port: 22);
      expect(s.buildArgs().sublist(0, 2), ['--port', '2222']);
    });

    test('rejects hosts and users that could read as options or shell', () {
      for (final host in ['-evil', 'a b', 'h;rm', r'h`x`', r'h$(x)', "h'"]) {
        expect(
          () => EternalTerminalService(host: host, username: 'u').buildArgs(),
          throwsArgumentError,
          reason: 'host=$host',
        );
      }
      for (final user in ['-x', 'a b', 'u;x', 'u@h', '']) {
        expect(
          () => EternalTerminalService(host: 'h', username: user).buildArgs(),
          throwsArgumentError,
          reason: 'user=$user',
        );
      }
    });

    test('rejects out-of-range ports', () {
      expect(
        () => EternalTerminalService(host: 'h', username: 'u', port: 0)
            .buildArgs(),
        throwsArgumentError,
      );
      expect(
        () => EternalTerminalService(host: 'h', username: 'u', etPort: 70000)
            .buildArgs(),
        throwsArgumentError,
      );
    });

    test("install commands name each system's tooling", () {
      expect(etInstallCommands('macos').single, contains('brew'));
      expect(etInstallCommands('linux'), contains(startsWith('sudo apt install et')));
      expect(etInstallCommands('windows'), ['wsl --install', 'wsl sudo apt install et']);
    });
  });

  // On Windows et runs in WSL. Started as `wsl.exe et ...`, wsl.exe handed
  // the line to the Linux account's shell, which read it again (found
  // in the whitepaper check); `--exec` starts et itself, each
  // value one argument, as it is.
  group('on Windows, through WSL', () {
    test('et is started by --exec, with its arguments one by one', () {
      final s = EternalTerminalService(host: 'box.example', port: 2222, username: 'me');
      expect(s.windowsArguments(), ['--exec', 'et', '--port', '2022', '--ssh-option', 'Port=2222', 'me@box.example']);
    });

    test("a key's path with spaces, quotes and shell characters stays one argument, as it is", () {
      const path = r"/tmp/zest key's $(id);rm -rf ~/id_key";
      final s = EternalTerminalService(host: '10.0.0.5', username: 'root', sshIdentityPath: path);
      final args = s.windowsArguments();
      expect(args.take(2), ['--exec', 'et']);
      expect(args, contains('IdentityFile=$path'));
      expect(args.last, 'root@10.0.0.5');
    });

    test('the same holds for Mosh, and for looking for either', () {
      final mosh = MoshService(host: 'box.example', username: 'me', port: 2222, sshIdentityPath: '/tmp/a b/key');
      final args = mosh.windowsArguments();
      expect(args.take(2), ['--exec', 'mosh']);
      expect(args, contains("ssh -p 2222 -i '/tmp/a b/key'"), reason: 'the --ssh value is one argument');
      expect(wslExecArguments('which', ['et']), ['--exec', 'which', 'et']);
      for (final file in ['lib/services/eternal_terminal_service.dart', 'lib/services/mosh_service.dart']) {
        final source = File(file).readAsStringSync();
        expect(source, isNot(contains("['et', ...args]")), reason: file);
        expect(source, isNot(contains("['mosh', ...args]")), reason: file);
        expect(source, isNot(contains("['which', ")), reason: file);
      }
    });
  });
}
