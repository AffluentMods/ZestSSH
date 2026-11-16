// A command run beside a session's shell, on the same connection, for what
// it prints (3.0, found while comparing the five versions):
// a snippet's list of the host's own ($[DOCKER], $[TMUX]) is read with it on
// every device (a computer's palette, Inspector and library had nothing to
// read it with, and said there was no session). The host is played by the
// test.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// What a played host sends of its own is not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_sign_in.dart';

void main() {
  final key = SSHKeyPair.fromPem(File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519')
          .readAsStringSync()
          .replaceAll('\r\n', '\n'))
      .single;

  /// Signs in to a host the test plays, which runs what it is asked: it
  /// prints [pieces] (bytes, each as it comes) and ends, or prints nothing
  /// and never ends where it [hangs], or says no to running it where it
  /// [refuses]. Returns the session and what the host was asked to run.
  Future<(SshService, Future<String?>)> open({List<List<int>> pieces = const [], bool hangs = false, bool refuses = false}) async {
    final server = PlayedServer();
    final asked = Completer<String?>();
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      keyPairs: [key],
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
    );
    var failed = false;
    unawaited(() async {
      await server.greet();
      if (!await PlayedSignIn(ways: ['publickey'], takesKey: true).play(server, over: () => failed)) return;
      final channel = await server.confirmChannel();
      final request = await channel.nextRequest();
      asked.complete(request.command);
      if (refuses) {
        server.send([channel.failure]);
        return;
      }
      server.send([channel.success]);
      if (hangs) return;
      server.send([
        for (final bytes in pieces)
          SSH_Message_Channel_Data(recipientChannel: channel.clientId, data: Uint8List.fromList(bytes)).encode(),
        channel.exitStatus(0),
        channel.eof,
        channel.close,
      ]);
    }());
    try {
      await ssh.connectExec();
    } catch (_) {
      failed = true;
      rethrow;
    }
    addTearDown(ssh.disconnect);
    return (ssh, asked.future);
  }

  test('what the command printed, trimmed, its characters whole where their bytes came in two pieces', () async {
    final all = utf8.encode('web-é\ndb\n');
    // The two bytes of "é" one in each piece.
    final cut = all.indexOf(0xc3) + 1;
    final (ssh, asked) = await open(pieces: [all.sublist(0, cut), all.sublist(cut)]);
    expect(await ssh.runOnce("docker ps --format '{{.Names}}'"), 'web-é\ndb');
    expect(await asked, "docker ps --format '{{.Names}}'");
  });

  test('a command of several lines is run as one script', () async {
    final (ssh, asked) = await open(pieces: [utf8.encode('ok')]);
    expect(await ssh.runOnce('cd /srv\r\nls'), 'ok');
    expect(await asked, 'cd /srv\nls');
  });

  test('nothing where it does not end in time, or the host will not run it', () async {
    final (slow, _) = await open(hangs: true);
    final clock = Stopwatch()..start();
    expect(await slow.runOnce('docker ps', timeout: const Duration(milliseconds: 300)), isNull);
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    final (refusing, _) = await open(refuses: true);
    expect(await refusing.runOnce('docker ps'), isNull);
  });
}
