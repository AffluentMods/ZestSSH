// ZestSSH 4.0 spike, developer only: "X program in a VNC tab" without the screen view. Starts the
// program on the host in a private Xvnc (lib/x_program.dart), opens the direct-streamlocal channel
// to its VNC socket, reads the RFB banner, then closes, and prints JSON lines with the times.
//
//   dart run bin/x_program_probe.dart [program] [runs]
//
// Settings from the environment: ZS_SSH_HOST, ZS_SSH_PORT (2240), ZS_USER, ZS_PASSWORD.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zest_screen_example/x_program.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart';

void out(Map<String, Object?> m) => stdout.writeln(jsonEncode(m));

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final program = args.isNotEmpty ? args[0] : 'xeyes';
  final runs = args.length > 1 ? int.parse(args[1]) : 1;
  final sw = Stopwatch()..start();
  final socket = await SSHSocket.connect(env['ZS_SSH_HOST']!, int.parse(env['ZS_SSH_PORT'] ?? '2240'),
      timeout: const Duration(seconds: 10));
  final ssh = SSHClient(socket,
      username: env['ZS_USER']!, onPasswordRequest: () => env['ZS_PASSWORD'], onVerifyHostKey: (_, _) => true);
  await ssh.authenticated;
  out({'event': 'ssh_authenticated', 'ms': sw.elapsedMilliseconds});
  for (var r = 0; r < runs; r++) {
    final t0 = sw.elapsedMicroseconds;
    double ms() => (sw.elapsedMicroseconds - t0) / 1000;
    final x = await XProgram.start(ssh, program, 1280, 800);
    final readyMs = ms();
    final ch = await ssh.forwardLocalUnix(x.socketPath);
    final channelMs = ms();
    final banner = Completer<Uint8List>();
    final sub = ch.stream.listen((d) {
      if (!banner.isCompleted) banner.complete(d);
    });
    final b = await banner.future.timeout(const Duration(seconds: 5));
    out({
      'event': 'x_program',
      'run': r,
      'program': program,
      'display': x.display,
      'ready_ms': readyMs,
      'channel_ms': channelMs,
      'banner_ms': ms(),
      'banner': String.fromCharCodes(b.take(12)).trim(),
    });
    await sub.cancel();
    ch.destroy();
    x.close();
    await x.session.done.timeout(const Duration(seconds: 5), onTimeout: () {});
    out({'event': 'closed', 'run': r, 'ms': ms()});
  }
  ssh.close();
}
