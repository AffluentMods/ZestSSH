import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/services/ssh_service.dart';

/// "Open an X program in a screen tab" (4.0) against a real host, on
/// the path the app takes (ActiveSessionsNotifier._createXProgramShell): a
/// ScreenShellService over an SshService signed in with no terminal, the host
/// script on one exec channel (XProgramRun), direct-streamlocal to the
/// private Xvnc's socket it names, and the Rust engine. A second SSH
/// connection of the same account looks at the host meanwhile: the folder's
/// and the socket's modes, the Xvnc's listening sockets, another client
/// without the cookie, and what is left once it ends.
///
/// Runs only when ZESTSSH_TEST_XPROG_HOST names an SSH server whose account
/// has TigerVNC's Xvnc, xauth, xterm, xeyes, xdpyinfo and ss: the WSL sshd
/// that `wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start`
/// starts (port 2240, account alex; WSL's own address, `wsl hostname -I`),
/// with the account's password in ZESTSSH_TEST_XPROG_PASSWORD, read without
/// printing it:
///
///   eval "$(wsl -d Ubuntu -u root cat /etc/zestscreens/env)"
///   ZESTSSH_TEST_XPROG_HOST=$(wsl hostname -I | cut -d' ' -f1) \
///   ZESTSSH_TEST_XPROG_PASSWORD="$ZS_PASSWORD" \
///   flutter test test/native/x_program_integration_test.dart
///
/// Optional: ZESTSSH_TEST_XPROG_USER (alex), ZESTSSH_TEST_XPROG_PORT (2240).
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_XPROG_HOST'];
  final user = env['ZESTSSH_TEST_XPROG_USER'] ?? 'alex';
  final password = env['ZESTSSH_TEST_XPROG_PASSWORD'];
  final port = int.tryParse(env['ZESTSSH_TEST_XPROG_PORT'] ?? '') ?? 2240;
  final skip = host == null
      ? 'ZESTSSH_TEST_XPROG_HOST is not set (tool/remote_screens_test_servers.sh)'
      : password == null
          ? 'ZESTSSH_TEST_XPROG_PASSWORD is not set'
          : null;

  late List<String> log;
  late SshService look;
  final measured = <String>[];

  SshService ssh() => SshService(
        host: host!,
        port: port,
        username: user,
        password: password,
        onHostKeyVerify: (_, _, _) async => true,
        onLog: log.add,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    log = [];
    if (skip != null) return;
    look = ssh();
    await look.connectForScreen();
  });

  tearDown(() async {
    if (skip != null) return;
    await look.disconnect();
    for (final line in log) {
      expect(line, isNot(contains(password!)), reason: 'the SSH password in the log');
    }
  });

  tearDownAll(() {
    for (final m in measured) {
      // ignore: avoid_print
      print(m);
    }
  });

  /// What [command] prints on the host, through the second connection.
  Future<String> on(String command) async => (await look.runOnce(command, timeout: const Duration(seconds: 15))) ?? '';

  ScreenShellService xProgram(String program, {int width = 1024, int height = 768}) => ScreenShellService(
        target: XProgramTarget(program, width, height),
        trust: const XProgramScreenTrust(),
        carrier: ssh(),
        carrierLabel: 'wsl-test',
        onLog: log.add,
      );

  Future<ScreenFrame> firstFrame(ScreenSession s) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10)) {
      final f = s.takeFrame();
      if (f != null) return f;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no picture within 10 s');
  }

  Future<void> until(Future<bool> Function() check, String what, {Duration within = const Duration(seconds: 15)}) async {
    final sw = Stopwatch()..start();
    while (!await check()) {
      if (sw.elapsed > within) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// The private folder of a started X program (its socket's).
  String folderOf(ScreenShellService shell) {
    final socket = shell.xProgram!.socketPath;
    return socket.substring(0, socket.lastIndexOf('/'));
  }

  void typeText(ScreenSession s, String text) {
    for (final c in text.codeUnits) {
      s.key(c, down: true);
      s.key(c, down: false);
    }
  }

  test('xterm with a quoted command line: the picture, keys typed reach the program, the folder 0700 and the '
      'socket 0600, nothing on TCP, no other client without the cookie; the program\'s end ends the tab with its '
      'exit status and leaves nothing', () async {
    await on(r'rm -f "$HOME/xprog-typed"');
    // Quotes, $ and a pipe inside the program line, run as typed in a terminal on the host.
    const program = r'''xterm -geometry 80x20+0+0 -e sh -c 'read line; printf "%s|%s" "$line" "it'\''s" > "$HOME/xprog-typed"' ''';
    final shell = xProgram(program.trim());
    final sw = Stopwatch()..start();
    await shell.connect();
    final readyMs = sw.elapsedMilliseconds;
    final info = shell.connectedInfo!;
    expect(info.security, isNot('VncAuth'));
    expect((info.width, info.height), (1024, 768));
    expect(shell.isConnected, isTrue);
    final frame = await firstFrame(shell.session!);
    final firstMs = sw.elapsedMilliseconds;
    expect((frame.width, frame.height), (1024, 768));
    frame.free();
    measured.add('xprog xterm: connected ${readyMs}ms, first picture ${firstMs}ms (sign-in included)');

    final folder = folderOf(shell);
    expect(folder, startsWith('/tmp/zestssh-x.'));
    expect(await on('stat -c %a "$folder"'), '700');
    expect(await on('stat -c %a:%F "$folder/vnc.sock"'), '600:socket');
    final xvnc = await on('cat "$folder/xvnc.pid"');
    expect(xvnc, matches(RegExp(r'^\d+$')));
    expect(await on('ps -p $xvnc -o comm='), 'Xvnc');
    // Nothing of this Xvnc listens on TCP (ss names the process of one's own account).
    expect(await on('ss -ltnpH | grep -c "pid=$xvnc," || true'), '0');
    // The X display takes no client without the folder's cookie (any account on the host could try).
    final display = shell.xProgram!.display;
    final refused = await on('XAUTHORITY=/dev/null xdpyinfo -display :$display >/dev/null 2>&1; echo \$?');
    expect(refused, isNot('0'), reason: 'a client without the cookie reached the private display');
    expect(await on('XAUTHORITY="$folder/Xauthority" xdpyinfo -display :$display >/dev/null 2>&1; echo \$?'), '0');

    // Keys typed into the picture reach the program: a line, then Return.
    final s = shell.session!;
    s.pointer(200, 100, 0);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    typeText(s, 'zs-xprog-OK');
    s.key(0xff0d, down: true);
    s.key(0xff0d, down: false);
    await until(() async => (await on(r'cat "$HOME/xprog-typed" 2>/dev/null')).isNotEmpty, 'the typed line on the host');
    expect(await on(r'cat "$HOME/xprog-typed"'), "zs-xprog-OK|it's");

    // The program ended (xterm closes when its command does): the tab ends with its exit status.
    await shell.connectionState.firstWhere((c) => !c).timeout(const Duration(seconds: 15));
    expect(shell.exitedCleanly, isTrue);
    expect(shell.exitCode, 0);
    expect(shell.closedWith!.reason, ScreenCloseReason.serverClosed);
    await until(() async => (await on('test -e "$folder" && echo left || echo gone')) == 'gone', 'the folder removed');
    expect(await on('ps -p $xvnc -o comm= || true'), isEmpty);
    expect(log.join('\n'), isNot(contains('xprog-typed')), reason: 'the program line is never logged');
    await shell.disconnect();
    await on(r'rm -f "$HOME/xprog-typed"');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('closing the tab, and a dropped connection, end the program and its Xvnc and remove the folder; a live '
      'run beside them is left alone', () async {
    final a = xProgram('xeyes -geometry 123x77');
    final b = xProgram('xeyes -geometry 124x78');
    await a.connect();
    await b.connect();
    final fa = folderOf(a);
    final fb = folderOf(b);
    final xa = await on('cat "$fa/xvnc.pid"');
    final xb = await on('cat "$fb/xvnc.pid"');
    expect(await on("pgrep -u $user -f '[x]eyes -geometry 123x77' | wc -l"), isNot('0'));

    // The tab closed.
    final sw = Stopwatch()..start();
    await a.disconnect();
    await until(() async => (await on('test -e "$fa" && echo left || echo gone')) == 'gone', 'the first folder removed');
    measured.add('xprog close: folder gone ${sw.elapsedMilliseconds}ms after disconnect returned');
    expect(await on('ps -p $xa -o comm= || true'), isEmpty);
    expect(await on("pgrep -u $user -f '[x]eyes -geometry 123x77' | wc -l"), '0');
    // The other one runs on.
    expect(await on('stat -c %a "$fb"'), '700');
    expect(await on('ps -p $xb -o comm='), 'Xvnc');
    expect(b.isConnected, isTrue);

    // The connection drops (closed under the session, the script's channel never closed by us).
    b.carrier!.client.close();
    await until(() async => (await on('test -e "$fb" && echo left || echo gone')) == 'gone', 'the second folder removed');
    expect(await on('ps -p $xb -o comm= || true'), isEmpty);
    expect(await on("pgrep -u $user -f '[x]eyes -geometry 124x78' | wc -l"), '0');
    await b.disconnect();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('what a killed run left (its folder, its Xvnc) is removed by the next start; a folder not ours is not '
      'touched', () async {
    // A run killed with SIGKILL: a folder whose script is gone, and its Xvnc still up.
    final stale = await on(r'''d=$(mktemp -d /tmp/zestssh-x.XXXXXXXX) && chmod 700 "$d" && sh -c 'echo $$' > "$d/pid" && '''
        r'''(setsid Xvnc :97 -auth "$d/none" -rfbport -1 -rfbunixpath "$d/old.sock" -nolisten tcp -nolisten unix </dev/null >/dev/null 2>&1 & echo $! > "$d/xvnc.pid") && '''
        r'''sleep 0.5 && echo "$d"''');
    expect(stale, startsWith('/tmp/zestssh-x.'));
    final staleXvnc = await on('cat "$stale/xvnc.pid"');
    expect(await on('ps -p $staleXvnc -o comm='), 'Xvnc');
    // A link that only looks like one of ours.
    await on(r'rm -f /tmp/zestssh-x.zzlink; ln -s "$HOME" /tmp/zestssh-x.zzlink');

    final shell = xProgram('xclock');
    await shell.connect();
    expect(await on('test -e "$stale" && echo left || echo gone'), 'gone');
    await until(() async => (await on('ps -p $staleXvnc -o comm= || true')).isEmpty, 'the stale Xvnc stopped');
    expect(await on(r'test -L /tmp/zestssh-x.zzlink && test -d "$HOME" && echo kept'), 'kept');
    await on('rm -f /tmp/zestssh-x.zzlink');
    await shell.disconnect();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a program the host does not have: ZS-1811 with status 127, and nothing left', () async {
    Future<Set<String>> folders() async =>
        (await on('ls -d /tmp/zestssh-x.* 2>/dev/null')).split('\n').where((l) => l.isNotEmpty).toSet();
    final before = await folders();
    final shell = xProgram('xtrem-not-here -geometry 80x24');
    final sw = Stopwatch()..start();
    final e = await shell.connect().then<Object?>((_) => null, onError: (Object e) => e);
    measured.add('xprog not found: said in ${sw.elapsedMilliseconds}ms');
    expect(e, isA<ScreenFailure>().having((f) => f.kind, 'kind', ScreenFailureKind.xProgramEnded));
    expect((e as ScreenFailure).exitStatus, 127);
    expect(e.code?.code, 'ZS-1811');
    expect(shell.carrier!.isConnected, isFalse);
    // No folder of its own is left (an earlier run's may have been cleared).
    await until(() async => (await folders()).difference(before).isEmpty, 'nothing left');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
