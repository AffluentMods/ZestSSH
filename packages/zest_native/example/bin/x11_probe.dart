// ZestSSH 4.0 spike, developer only: X11 forwarding over zest_ssh_core without the screen view.
// Connects, prepares the forwarder (-X untrusted by default, ZS_X11_TRUSTED=1 for -Y), runs each
// argument as a remote command with x11-req on its own session channel, one after another, and
// prints JSON lines: the forwarder's events, each command's output, exit status and time.
//
//   dart run bin/x11_probe.dart 'xdpyinfo | head -3' 'xwd -root -silent | wc -c'
//
// Settings from the environment (nothing printed or stored): ZS_SSH_HOST, ZS_SSH_PORT (2240),
// ZS_USER, ZS_PASSWORD; ZS_X11_DISPLAY (the local X server, DISPLAY-style; 127.0.0.1:41 is the
// test servers' stand-in), ZS_X11_COOKIE (its MIT-MAGIC-COOKIE-1 in hex; empty: no access
// control), ZS_X11_TRUSTED=1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zest_screen_example/x11_forward.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart';

void out(Map<String, Object?> m) => stdout.writeln(jsonEncode(m));

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final cookie = env['ZS_X11_COOKIE'] ?? '';
  final display = X11Display.parse(env['ZS_X11_DISPLAY'] ?? '127.0.0.1:41');
  final trusted = env['ZS_X11_TRUSTED'] == '1';
  final fwd = X11Forwarder(
    display: display,
    real: cookie.isEmpty ? const X11Auth.none() : X11Auth.cookie(hexBytes(cookie)),
    trusted: trusted,
    log: out,
  );
  final sw = Stopwatch()..start();
  // What detection sees: with the cookie, without it, and on display numbers nothing serves.
  out({'event': 'probe', 'auth': 'cookie', ...await probeX11(display, fwd.real)});
  out({'event': 'probe', 'auth': 'none', ...await probeX11(display, const X11Auth.none())});
  out({'event': 'probe', 'auth': 'none', ...await probeX11(X11Display.parse('127.0.0.1:7'), const X11Auth.none())});
  if (env['ZS_X11_PROBE_ONLY'] == '1') return;
  await fwd.start();
  out({'event': 'forwarder_ready', 'display': '$display', 'mode': trusted ? 'trusted (-Y)' : 'untrusted (-X)', 'ms': sw.elapsedMilliseconds});
  final socket = await SSHSocket.connect(env['ZS_SSH_HOST']!, int.parse(env['ZS_SSH_PORT'] ?? '2240'),
      timeout: const Duration(seconds: 10));
  // Spike: the test server's host key is accepted as it is.
  final ssh = SSHClient(socket,
      username: env['ZS_USER']!,
      onPasswordRequest: () => env['ZS_PASSWORD'],
      onVerifyHostKey: (_, _) => true,
      onX11Forward: fwd.handle);
  await ssh.authenticated;
  out({'event': 'ssh_authenticated', 'ms': sw.elapsedMilliseconds});
  for (final command in args) {
    final t0 = sw.elapsedMicroseconds;
    final session = await ssh.execute(command, x11: fwd.config);
    final o = StringBuffer(), e = StringBuffer();
    final a = session.stdout.cast<List<int>>().transform(utf8.decoder).forEach(o.write);
    final b = session.stderr.cast<List<int>>().transform(utf8.decoder).forEach(e.write);
    await session.done;
    await Future.wait([a, b]);
    out({
      'event': 'command',
      'command': command,
      'exit': session.exitCode,
      'ms': (sw.elapsedMicroseconds - t0) / 1000,
      'stdout': o.toString(),
      'stderr': e.toString(),
    });
  }
  await fwd.close();
  ssh.close();
  await ssh.done.catchError((_) {});
  out({'event': 'done', 'ms': sw.elapsedMilliseconds});
}
