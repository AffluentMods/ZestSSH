import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations_en.dart';
import 'package:zestssh/services/mosh/mosh_bootstrap.dart';

/// Starting mosh-server for the built-in Mosh client (4.0): the command, and
/// what the host prints read as a port and key, or as what went wrong, with
/// the key never in what is shown or logged. The outputs are mosh-server
/// 1.4.0's own (seen in WSL) and what shells say for a
/// program they do not have.
void main() {
  const key = 'gtwzcEPcVFEmGb/8f6cB6g';
  const banner = 'mosh-server (mosh 1.4.0) [build mosh 1.4.0]\n'
      'Copyright 2012 Keith Winstein <mosh-devel@mit.edu>\n'
      'License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n'
      'This is free software: you are free to change and redistribute it.\n'
      'There is NO WARRANTY, to the extent permitted by law.\n\n'
      '[mosh-server detached, pid = 381356]\n';
  final l10n = AppLocalizationsEn();

  group('the command', () {
    test('a new session, 256 colours, the ports, the locale, bound to the SSH address', () {
      expect(moshServerCommand(locale: 'LANG=en_US.UTF-8'),
          'mosh-server new -s -c 256 -p 60000:61000 -l LANG=en_US.UTF-8');
    });

    test('through a jump host it is not bound to the address SSH came in on', () {
      expect(moshServerCommand(locale: 'LANG=C.UTF-8', bindToSsh: false, server: '/usr/local/bin/mosh-server'),
          '/usr/local/bin/mosh-server new -c 256 -p 60000:61000 -l LANG=C.UTF-8');
    });
  });

  group('what mosh-server printed', () {
    test('its MOSH CONNECT line gives the port and the key', () {
      final s = parseMoshServerOutput('\r\nMOSH CONNECT 60014 $key\r\n', banner, 0);
      expect(s.port, 60014);
      expect(s.key, key);
      expect('$s', isNot(contains(key)), reason: 'never printed');
    });

    test('found on standard error too, and among other lines (a shell that prints at sign-in)', () {
      final s = parseMoshServerOutput('', 'Welcome to the host\n$banner\nMOSH CONNECT 60001 $key\n', 0);
      expect(s.port, 60001);
    });

    test('a line that only looks like it is not taken', () {
      for (final out in [
        'MOSH CONNECT 60001 tooShort\n',
        'MOSH CONNECT 0 $key\n',
        'MOSH CONNECT 70000 $key\n',
        'say MOSH CONNECT 60001 $key\n',
        'MOSH CONNECT 60001 ${key}x\n',
      ]) {
        expect(() => parseMoshServerOutput(out, '', 0), throwsA(isA<MoshStartFailure>()), reason: out);
      }
    });

    test('no mosh-server on the host: "mosh-server is not installed on the host"', () {
      for (final (out, err, code) in [
        ('', 'bash: line 1: mosh-server: command not found\n', 127),
        ('', 'zsh:1: command not found: mosh-server\n', 127),
        ('', 'sh: 1: mosh-server: not found\n', 127),
        ('', 'fish: Unknown command: mosh-server\n', 127),
        ('', '', 127),
        ('', 'bash: /opt/homebrew/bin/mosh-server: No such file or directory\n', 127),
      ]) {
        final e = _failure(() => parseMoshServerOutput(out, err, code));
        expect(e.problem, MoshStartProblem.notInstalled, reason: err);
        expect(e.code, ErrorCodes.moshServerMissing);
      }
      final text = moshStartFailureText(l10n, const MoshStartFailure(MoshStartProblem.notInstalled));
      expect(text, startsWith('mosh-server is not installed on the host'));
      expect(text, endsWith('(ZS-1004)'));
    });

    test('no UTF-8 locale: said as that, with what mosh-server said', () {
      const err = 'The locale requested by LANG=en_US.UTF-8 isn\'t available here.\n'
          "Running `locale-gen en_US.UTF-8' may be necessary.\n\n"
          'mosh-server needs a UTF-8 native locale to run.\n\n'
          'Unfortunately, the local environment ([no charset variables]) specifies\n'
          'the character set "US-ASCII",\n\n'
          'LANG=en_US.UTF-8\nLC_CTYPE="en_US.UTF-8"\nLC_ALL=\n';
      final e = _failure(() => parseMoshServerOutput('', err, 0));
      expect(e.problem, MoshStartProblem.locale);
      expect(e.said, contains('needs a UTF-8 native locale'));
      expect(e.said, isNot(contains('LC_CTYPE')), reason: 'the locale dump is left out');
      final text = moshStartFailureText(l10n, e);
      expect(text, contains('(ZS-1005)'));
      expect(text, contains('needs a UTF-8 native locale'));
    });

    test('anything else: did not start, with what it said, banner and keys taken out', () {
      final e = _failure(() => parseMoshServerOutput('', '${banner}Network exception: bind: Address already in use\n', 1));
      expect(e.problem, MoshStartProblem.noConnectLine);
      expect(e.code, ErrorCodes.moshServerDidNotStart);
      expect(e.said, contains('Address already in use'));
      expect(e.said, isNot(contains('Copyright')));
      expect(e.said, isNot(contains('GPL')));
      final silent = _failure(() => parseMoshServerOutput('', '', 0));
      expect(silent.problem, MoshStartProblem.noConnectLine);
    });

    test('a key on a line that is not quite right is taken out of what is shown', () {
      final e = _failure(() => parseMoshServerOutput('MOSH CONNECT 60001 $key extra\n', '', 0));
      expect(e.said, contains('MOSH CONNECT 60001 <key>'));
      expect(e.said, isNot(contains(key)));
      expect(redactMoshKeys('x MOSH CONNECT 60001 $key y'), 'x MOSH CONNECT 60001 <key> y');
    });

    test('what is shown is a few lines, each not too long', () {
      final long = List.generate(50, (i) => 'line $i ${'x' * 300}').join('\n');
      final e = _failure(() => parseMoshServerOutput('', long, 1));
      expect(e.said.split('\n').length, 8);
      expect(e.said.split('\n').every((l) => l.length <= 203), isTrue);
    });
  });

  group('starting it', () {
    test('by name, at once where it is there; the log never has the key', () async {
      final ran = <String>[];
      final log = <String>[];
      final s = await startMoshServer((c) async {
        ran.add(c);
        return (stdout: 'MOSH CONNECT 60002 $key\n', stderr: banner, exitCode: 0);
      }, onLog: log.add);
      expect(s.port, 60002);
      expect(ran, ['mosh-server new -s -c 256 -p 60000:61000 -l LANG=en_US.UTF-8']);
      expect(log.join('\n'), isNot(contains(key)));
      expect(log.last, contains('60002'));
    });

    test('a host with C.UTF-8 alone: the second locale', () async {
      final ran = <String>[];
      final s = await startMoshServer((c) async {
        ran.add(c);
        return c.contains('C.UTF-8')
            ? (stdout: 'MOSH CONNECT 60003 $key\n', stderr: '', exitCode: 0)
            : (stdout: '', stderr: 'mosh-server needs a UTF-8 native locale to run.\n', exitCode: 0);
      });
      expect(s.port, 60003);
      expect(ran.length, 2);
      expect(ran.last, endsWith('-l LANG=C.UTF-8'));
    });

    test('where the shell does not find it by name: where package managers put it', () async {
      final ran = <String>[];
      final s = await startMoshServer((c) async {
        ran.add(c);
        return c.startsWith('/opt/homebrew/bin/')
            ? (stdout: 'MOSH CONNECT 60004 $key\n', stderr: '', exitCode: 0)
            : (stdout: '', stderr: 'zsh:1: command not found: ${c.split(' ').first}\n', exitCode: 127);
      }, bindToSsh: false);
      expect(s.port, 60004);
      expect(ran.map((c) => c.split(' ').first), ['mosh-server', '/usr/local/bin/mosh-server', '/opt/homebrew/bin/mosh-server']);
      expect(ran.every((c) => !c.contains(' -s ')), isTrue);
    });

    test('nowhere: not installed, after every place was tried', () async {
      final ran = <String>[];
      final e = await _failureAsync(() => startMoshServer((c) async {
            ran.add(c);
            return (stdout: '', stderr: 'bash: ${c.split(' ').first}: command not found\n', exitCode: 127);
          }));
      expect(e.problem, MoshStartProblem.notInstalled);
      expect(ran.length, kMoshServerPaths.length);
    });

    test('another failure is not retried elsewhere', () async {
      var runs = 0;
      final e = await _failureAsync(() => startMoshServer((c) async {
            runs++;
            return (stdout: '', stderr: 'mosh-server: Network exception: bind: Address already in use\n', exitCode: 1);
          }));
      expect(e.problem, MoshStartProblem.noConnectLine);
      expect(runs, 1);
    });

    test('collects both streams of a command, at most so much of each', () async {
      final big = List.filled(kMoshBootstrapMaxBytes + 10, 65);
      final r = await collectMoshCommand(
        stdout: Stream.value(utf8Bytes('MOSH CONNECT 60001 $key\n')),
        stderr: Stream.fromIterable([utf8Bytes(String.fromCharCodes(big))]),
        done: Future.value(),
        exitCode: () => 0,
      );
      expect(r.stdout, contains('MOSH CONNECT'));
      expect(r.stderr.length, kMoshBootstrapMaxBytes);
      expect(r.exitCode, 0);
    });
  });
}

MoshStartFailure _failure(void Function() f) {
  try {
    f();
  } on MoshStartFailure catch (e) {
    return e;
  }
  fail('no MoshStartFailure');
}

Future<MoshStartFailure> _failureAsync(Future<void> Function() f) async {
  try {
    await f();
  } on MoshStartFailure catch (e) {
    return e;
  }
  fail('no MoshStartFailure');
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
