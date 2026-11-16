import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
// The messages a played server reads and says are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/xprogram/x_program_run.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import '../../../packages/zest_ssh_core/test/src/played_server.dart';

/// "Open an X program in a screen tab" (4.0): the host script, the
/// one line that runs it, and its run over an SSH connection played by the
/// test. All made up.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  /// The two printf formats and the size in a command [xProgramCommand] made.
  ({String script, String program, String size}) partsOf(String command) {
    final m = RegExp(r"""^exec sh -c 'eval "\$\(printf "\$1"\)"' zestssh-x '([^']*)' '([^']*)' (\d+ \d+)$""")
        .firstMatch(command);
    expect(m, isNotNull, reason: 'the command is not the fixed line: $command');
    return (script: m!.group(1)!, program: m.group(2)!, size: m.group(3)!);
  }

  group('the line the login shell reads', () {
    const nasty = <String>[
      'xterm',
      "xterm -T 'it'\\''s mine'",
      r'xterm -e "echo $HOME; ls `pwd`" && rm -rf ~ ; $(reboot) | tee /x > /y < /z',
      r'printf "%s %d\n" \\ \x41 !! !$',
      '-x starts with a dash',
      'gedit "Überblick über Größen.txt" 日本語 ف',
      'a\u00a0b',
    ];

    test('the script and every program travel as printf formats that decode to them byte for byte', () {
      for (final program in nasty) {
        final p = partsOf(xProgramCommand(program, 1280, 800));
        expect(printfFormatDecoded(p.script), xProgramScriptText);
        expect(xProgramScriptText, xProgramScript.replaceAll('\r', ''));
        expect(printfFormatDecoded(p.script), isNot(contains('\r')), reason: 'a CR from a Windows checkout');
        expect(printfFormatDecoded(p.program), program, reason: program);
        expect(p.size, '1280 800');
      }
    });

    test('no quote, newline, dollar, backtick, bang, percent, dash or backslash but an octal escape reaches the shell',
        () {
      for (final program in nasty) {
        final p = partsOf(xProgramCommand(program, 640, 480));
        for (final format in [p.script, p.program]) {
          // Every backslash begins three octal digits.
          expect(RegExp(r'\\(?![0-7]{3})').hasMatch(format), isFalse);
          final bare = format.replaceAll(RegExp(r'\\[0-7]{3}'), '');
          expect(RegExp(r'''['"\n\r$`!%\-;&|<>(){}*?\[\]~#\t]''').hasMatch(bare), isFalse, reason: bare);
          // The format never begins with a dash (printf would read an option).
          expect(format.startsWith('-'), isFalse);
        }
      }
    });

    test(r'the program is never spliced into the script: it is $2, run on purpose with sh -c', () {
      expect(xProgramScript, contains(r'prog=$(printf "$2")'));
      expect(xProgramScript, contains(r'sh -c "$prog"'));
      expect(xProgramScript, isNot(contains('eval')));
    });

    test('Git Bash or a Unix sh runs the line and the script says its first word', () async {
      final sh = Platform.isWindows ? r'C:\Program Files\Git\bin\sh.exe' : '/bin/sh';
      if (!File(sh).existsSync()) {
        markTestSkipped('no sh at $sh');
        return;
      }
      // With no Xvnc on the PATH the script stops at once and names no
      // package manager (none is on that PATH either).
      final r = await Process.run(sh, ['-c', xProgramCommand("xterm -T 'it'\\''s'", 800, 600)],
          environment: {'PATH': '/nonexistent'}, includeParentEnvironment: false);
      expect('${r.stdout}'.trim(), 'ZSX {"error":"no-xvnc","pm":""}', reason: '${r.stderr}');
      expect(r.exitCode, 1);
    });
  });

  group('the program line', () {
    test('one line, 1 to 1024 bytes, no control characters', () {
      expect(xProgramProblem('xterm'), isNull);
      expect(xProgramProblem('   '), XProgramProblem.empty);
      expect(xProgramProblem(''), XProgramProblem.empty);
      expect(xProgramProblem('x' * 1024), isNull);
      expect(xProgramProblem('x' * 1025), XProgramProblem.tooLong);
      expect(xProgramProblem('é' * 513), XProgramProblem.tooLong, reason: 'counted in UTF-8 bytes');
      for (final c in ['\n', '\r', '\t', '\u0000', '\u001b', '\u007f', '\u0085', '\u2028']) {
        expect(xProgramProblem('xterm${c}rm -rf ~'), XProgramProblem.controlCharacters, reason: c.codeUnits.toString());
      }
      expect(() => xProgramCommand('a\nb', 1, 1), throwsArgumentError);
    });

    test('its name: the first word past settings and env, as a file name; never the arguments', () {
      expect(xProgramName('xterm -fa Mono -e top'), 'xterm');
      expect(xProgramName('/usr/bin/gedit /etc/secret.conf'), 'gedit');
      expect(xProgramName('LANG=C GDK_SCALE=2 env exec "/opt/my app/run"'), 'my');
      expect(xProgramName('  firefox --new-instance  '), 'firefox');
      expect(xProgramName('='), '=');
      expect(xProgramName('x' * 80).length, 40);
    });
  });

  group('the lines it says', () {
    test('ready, a missing tool with the package manager, another error, the exit; anything else is no line', () {
      final ready = XProgramLine.parse('ZSX {"socket":"/tmp/zestssh-x.Ab3/vnc.sock","display":12}');
      expect(ready, isA<XProgramReady>().having((r) => r.socket, 'socket', '/tmp/zestssh-x.Ab3/vnc.sock'));
      expect((ready! as XProgramReady).display, 12);
      final missing = XProgramLine.parse('ZSX {"error":"no-xvnc","pm":"dnf"}')! as XProgramError;
      expect((missing.toolMissing, missing.pm), (true, 'dnf'));
      final none = XProgramLine.parse('ZSX {"error":"no-xauth","pm":""}')! as XProgramError;
      expect((none.toolMissing, none.pm), (true, null));
      final other = XProgramLine.parse('ZSX {"error":"no-tmp"}')! as XProgramError;
      expect(other.toolMissing, isFalse);
      expect(XProgramLine.parse('ZSX {"exited":127}'), isA<XProgramExited>().having((e) => e.status, 's', 127));
      for (final junk in ['hello', 'ZSX', 'ZSX {', 'ZSX []', 'ZSX {"socket":"relative","display":1}', ' ZSX {}']) {
        expect(XProgramLine.parse(junk), isNull, reason: junk);
      }
    });

    test('install commands for apt, dnf, yum, pacman and zypper; none for anything else', () {
      expect(xProgramInstallCommand('apt-get'), 'sudo apt install tigervnc-standalone-server xauth');
      expect(xProgramInstallCommand('dnf'), 'sudo dnf install tigervnc-server-minimal xorg-x11-xauth');
      expect(xProgramInstallCommand('yum'), 'sudo yum install tigervnc-server-minimal xorg-x11-xauth');
      expect(xProgramInstallCommand('pacman'), 'sudo pacman -S tigervnc xorg-xauth');
      expect(xProgramInstallCommand('zypper'), 'sudo zypper install xorg-x11-Xvnc xauth');
      expect(xProgramInstallCommand(null), isNull);
      expect(xProgramInstallCommand('apk'), isNull);
    });

    test('the script keeps its folder private, listens on no TCP, and cleans up', () {
      for (final part in [
        'umask 077',
        r'mktemp -d "$t/zestssh-x.XXXXXXXX"',
        '-rfbport -1',
        '-rfbunixmode 0600',
        '-nolisten tcp',
        r'-auth "$d/Xauthority"',
        'trap cleanup EXIT',
        r'rm -rf "$d"',
        r'[ ! -L "$f" ] && [ -O "$f" ]',
      ]) {
        expect(xProgramScript, contains(part));
      }
      expect(xProgramScript, isNot(contains('sudo')));
      // POSIX sh only: no bash-isms that dash would refuse. (xauth's own
      // command "source -" is no shell word: it is taken out first.)
      final shell = xProgramScript.replaceAll('xauth -q -f "\$d/Xauthority" source -', 'xauth');
      for (final bashism in ['[[', 'function ', 'local ', r'$RANDOM', '<<<', 'source ']) {
        expect(shell, isNot(contains(bashism)), reason: bashism);
      }
    });

    // The cookie is all that keeps another account of the host off the X
    // display. As an argument of xauth it stood in a command line every
    // account can read (found in a security review).
    test('the cookie reaches xauth on its input, never in its command line', () async {
      final lines = xProgramScript.split('\n').where((l) => !l.trimLeft().startsWith('#') && l.contains('xauth') && l.contains('cookie')).toList();
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(line, contains(r'''printf 'add %s . %s\n' '''), reason: line);
        expect(line, contains(r'| xauth -q -f "$d/Xauthority" source - || fail xauth'), reason: line);
        expect(line.substring(line.indexOf('| xauth')), isNot(contains('cookie')), reason: line);
      }
      final sh = Platform.isWindows ? r'C:\Program Files\Git\bin\sh.exe' : '/bin/sh';
      if (!File(sh).existsSync()) {
        markTestSkipped('no sh at $sh');
        return;
      }
      // A stand-in xauth that writes down its arguments and its input.
      final dir = Directory.systemTemp.createTempSync('zs_xauth_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final unix = dir.path.replaceAll(r'\', '/');
      File('${dir.path}/xauth').writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$*" >> "$unix/args"\ncat >> "$unix/input"\n');
      final script = [
        'chmod +x "$unix/xauth"',
        'fail() { echo "failed \$1"; exit 1; }',
        'd="$unix"; n=7; cookie=0123456789abcdef0123456789abcdef',
        ...lines,
      ].join('\n');
      final r = await Process.run(sh, ['-c', script], environment: {'PATH': '$unix:/usr/bin:/bin'});
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final args = File('${dir.path}/args').readAsStringSync();
      final input = File('${dir.path}/input').readAsStringSync();
      expect(args, isNot(contains('0123456789abcdef')), reason: 'the cookie is in no argument');
      expect(args.trim().split('\n'), everyElement(endsWith('source -')));
      expect(input, 'add zestssh/unix:0 . 0123456789abcdef0123456789abcdef\nadd :7 . 0123456789abcdef0123456789abcdef\n');
    });
  });

  group('a run over SSH', () {
    late PlayedServer server;
    setUp(() async => server = await PlayedServer.signedIn());

    Future<(Future<XProgramRun>, PlayedChannel)> started({Duration timeout = XProgramRun.readyTimeout, List<String>? log}) async {
      final run = XProgramRun.start(server.client,
          program: "xterm -T 'secret title'", width: 1024, height: 768, host: 'gw', timeout: timeout, onLog: log?.add);
      final exec = await server.confirmChannel();
      final ask = await exec.nextRequest();
      expect(ask.requestType, 'exec');
      expect(partsOf(ask.command!).size, '1024 768');
      server.send([exec.success]);
      return (run, exec);
    }

    test('the ready line gives the socket; the exit line, later, the status; the program\'s output is kept, not '
        'logged; close ends the channel', () async {
      final log = <String>[];
      final (future, exec) = await started(log: log);
      server.send([exec.errorData('xterm: warning\n'), exec.data('ZSX {"socket":"/tmp/zestssh-x.q/vnc.sock","display":3}\n')]);
      final run = await future;
      expect((run.socketPath, run.display, run.exitStatus), ('/tmp/zestssh-x.q/vnc.sock', 3, null));
      server.send([exec.data('ZSX {"exited":0}\n'), exec.exitStatus(0), exec.eof, exec.close]);
      expect(await run.exited, 0);
      expect(run.exitStatus, 0);
      expect(run.output, contains('xterm: warning'));
      expect(log.join('\n'), allOf(contains('Starting xterm'), contains('display :3'), isNot(contains('secret'))));
    });

    test('close ends the channel\'s input (EOF): the script\'s stdin ends there, and it cleans up', () async {
      final (future, exec) = await started();
      server.send([exec.data('ZSX {"socket":"/tmp/zestssh-x.q/vnc.sock","display":3}\n')]);
      final run = await future;
      run.close();
      await server.next(SSH_Message_Channel_EOF.messageId);
    });

    test('no Xvnc: ZS-1809 with the install command for the host\'s package manager', () async {
      final (future, exec) = await started();
      server.send([exec.data('ZSX {"error":"no-xvnc","pm":"pacman"}\n'), exec.exitStatus(1), exec.eof, exec.close]);
      final e = await future.then<ScreenFailure?>((_) => null, onError: (Object e) => e as ScreenFailure);
      expect(e!.kind, ScreenFailureKind.xProgramToolsMissing);
      expect(e.hint, 'sudo pacman -S tigervnc xorg-xauth');
      expect(screenFailureText(en, e), allOf(contains('gw has no Xvnc'), contains('\nsudo pacman -S tigervnc xorg-xauth'),
          endsWith('(ZS-1809)')));
      const unknown = ScreenFailure(ScreenFailureKind.xProgramToolsMissing, 'x', carrier: 'gw');
      expect(screenFailureText(en, unknown), allOf(contains("TigerVNC's Xvnc and xauth"), endsWith('(ZS-1809)')));
      expect(e.reconnectCannotHelp, isTrue);
    });

    test('Xvnc stops as it starts: ZS-1810 with its last words', () async {
      final (future, exec) = await started();
      server.send([
        exec.errorData('Fatal server error:\n(EE) Cannot establish any listening sockets\n'),
        exec.data('ZSX {"error":"xvnc-exited"}\n'),
        exec.eof,
        exec.close,
      ]);
      final e = await future.then<ScreenFailure?>((_) => null, onError: (Object e) => e as ScreenFailure);
      expect(e!.kind, ScreenFailureKind.xProgramFailed);
      expect(e.detail, allOf(startsWith('xvnc-exited'), contains('Cannot establish')));
      expect(screenFailureText(en, e), allOf(contains('did not start on gw'), endsWith('(ZS-1810)')));
    });

    test('a login shell that is no Unix one (the script never says a word): ZS-1810 with what the host said',
        () async {
      final (future, exec) = await started();
      server.send([exec.errorData("'exec' is not recognized as an internal or external command\n"), exec.exitStatus(1),
          exec.eof, exec.close]);
      final e = await future.then<ScreenFailure?>((_) => null, onError: (Object e) => e as ScreenFailure);
      expect(e!.kind, ScreenFailureKind.xProgramFailed);
      expect(e.detail, contains('is not recognized'));
    });

    test('the program ends as it starts: ZS-1811; 127 says it is not on the host', () async {
      final log = <String>[];
      final (future, exec) = await started(log: log);
      server.send([exec.errorData('sh: 1: xtrem: not found\n'), exec.data('ZSX {"exited":127}\n'), exec.eof, exec.close]);
      final e = await future.then<ScreenFailure?>((_) => null, onError: (Object e) => e as ScreenFailure);
      expect((e!.kind, e.exitStatus, e.hint), (ScreenFailureKind.xProgramEnded, 127, 'xterm'));
      expect(screenFailureText(en, e), allOf(contains('xterm was not found on gw'), endsWith('(ZS-1811)')));
      const other = ScreenFailure(ScreenFailureKind.xProgramEnded, 'x', hint: 'firefox', exitStatus: 0);
      expect(screenFailureText(en, other), allOf(contains('firefox ended as it started (exit status 0)'),
          endsWith('(ZS-1811)')));
      expect(log.last, contains('not found'));
    });

    test('no answer in time: ZS-1810, and the channel is closed', () async {
      final (future, _) = await started(timeout: const Duration(milliseconds: 200));
      final e = await future.then<ScreenFailure?>((_) => null, onError: (Object e) => e as ScreenFailure);
      expect(e!.kind, ScreenFailureKind.xProgramFailed);
      expect(e.detail, contains('no answer'));
      await server.next(SSH_Message_Channel_EOF.messageId);
    });

    test('a host that only talks before the script answers is stopped past 64 KB', () async {
      final (future, exec) = await started();
      final chatter = '${'motd ' * 100}\n';
      for (var i = 0; i < 140; i++) {
        server.send([exec.data(chatter)]);
      }
      final e = await future.then<ScreenFailure?>((_) => null, onError: (Object e) => e as ScreenFailure);
      expect(e!.kind, ScreenFailureKind.xProgramFailed);
      expect(e.detail, contains('64 KB'));
    });
  });

  test('ZS-1809 to ZS-1811 are listed', () {
    expect(ErrorCodes.all.map((c) => c.code), containsAll(['ZS-1809', 'ZS-1810', 'ZS-1811']));
  });
}
