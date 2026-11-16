import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// How a shell ended, as the app's own SSH service says it (3.0, from the
/// SSH core's audit), with a server played by the test: it says what it
/// sends, message by message, and what is handed over at once comes in one
/// read.
///
/// The service told a shell that ended by itself from a connection that
/// dropped by whether the host had said how the shell ended (an exit
/// status, a signal). A host that says nothing of that (there is network
/// gear that never does) was a dropped connection every time its person
/// typed `exit`, and was connected to again. A session the host closes in
/// order is an end by itself as well, said or not.
void main() {
  const patience = Duration(seconds: 10);

  /// The app's own service, connecting to a played server that has let it
  /// in, given it a channel and a terminal, and been asked for a shell.
  Future<({SshService ssh, PlayedServer server, PlayedChannel channel, Future<void> connecting, List<int> printed})>
      asked() async {
    final server = PlayedServer();
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    final printed = <int>[];
    ssh.stdout.listen(printed.addAll);
    // (Listened to from the start, so that a failure is seen where it is waited for.)
    final connecting = ssh.connect().timeout(patience);
    unawaited(connecting.then((_) {}, onError: (_) {}));
    await server.letIn();
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    return (ssh: ssh, server: server, channel: channel, connecting: connecting, printed: printed);
  }

  /// The end of the session, as whoever asked for the connection hears of
  /// it: they listen once connect() has returned.
  Future<void> ended(SshService ssh) => ssh.connectionState.firstWhere((connected) => !connected).timeout(patience);

  test('a shell that prints a notice and leaves, all in one read with the host\'s yes to it: connected, the notice '
      'handed on, and ended by itself with its exit status', () async {
    final s = await asked();
    s.server.send([
      s.channel.success,
      s.channel.data('This account is currently not available.\r\n'),
      s.channel.exitStatus(1),
      s.channel.eof,
      s.channel.close,
    ]);
    await s.connecting;
    await ended(s.ssh);
    expect(s.ssh.exitedCleanly, isTrue);
    expect(s.ssh.exitCode, 1);
    expect(s.ssh.exitSignal, isNull);
    expect(utf8.decode(s.printed), contains('This account is currently not available.'));
  });

  test('a shell the host ends in order and says nothing of how (a host that reports no exit status): ended by itself, '
      'not a connection that dropped', () async {
    final s = await asked();
    s.server.send([s.channel.success]);
    await s.connecting;
    final over = ended(s.ssh);
    s.server.send([s.channel.data('Connection closed.\r\n'), s.channel.eof, s.channel.close]);
    await over;
    expect(s.ssh.exitedCleanly, isTrue);
    expect(s.ssh.exitCode, isNull);
    expect(s.ssh.exitSignal, isNull);
  });

  test('the same in one read with the yes, and with the end of the session a moment after the end of its output',
      () async {
    final atOnce = await asked();
    atOnce.server.send([atOnce.channel.success, atOnce.channel.data('bye\r\n'), atOnce.channel.eof, atOnce.channel.close]);
    await atOnce.connecting;
    await ended(atOnce.ssh);
    expect(atOnce.ssh.exitedCleanly, isTrue);
    expect(atOnce.ssh.exitCode, isNull);

    final later = await asked();
    later.server.send([later.channel.success]);
    await later.connecting;
    final over = ended(later.ssh);
    later.server.send([later.channel.eof]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(later.ssh.isConnected, isTrue, reason: 'whether it was cut off is not known yet');
    later.server.send([later.channel.close]);
    await over;
    expect(later.ssh.exitedCleanly, isTrue);
  });

  test('a shell that a signal ended: by itself, and which signal', () async {
    final s = await asked();
    s.server.send([s.channel.success]);
    await s.connecting;
    final over = ended(s.ssh);
    s.server.send([s.channel.exitSignal('HUP'), s.channel.eof, s.channel.close]);
    await over;
    expect(s.ssh.exitedCleanly, isTrue);
    expect(s.ssh.exitSignal, 'HUP');
    expect(s.ssh.exitCode, isNull);
  });

  test('the connection ends under a running shell: a connection that dropped, as before', () async {
    final s = await asked();
    s.server.send([s.channel.success, s.channel.data('deploy@web-01:~\$ ')]);
    await s.connecting;
    final over = ended(s.ssh);
    s.server.hangUp();
    await over;
    expect(s.ssh.exitedCleanly, isFalse);
    expect(s.ssh.exitCode, isNull);
    expect(s.ssh.exitSignal, isNull);
  });

  test('the end of its output, and then the connection ends with the session still open: a connection that dropped',
      () async {
    final s = await asked();
    s.server.send([s.channel.success]);
    await s.connecting;
    final over = ended(s.ssh);
    s.server.send([s.channel.eof]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    s.server.hangUp();
    await over;
    expect(s.ssh.exitedCleanly, isFalse);
  });

  test('the end of its output and then nothing: after two seconds it is taken for a connection that dropped',
      () async {
    final s = await asked();
    s.server.send([s.channel.success]);
    await s.connecting;
    final over = ended(s.ssh);
    final waited = Stopwatch()..start();
    s.server.send([s.channel.eof]);
    await over;
    expect(waited.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 1900)));
    expect(s.ssh.exitedCleanly, isFalse);
  });

  test('ended from here: not an end by itself, whatever the host does with it', () async {
    final s = await asked();
    s.server.send([s.channel.success]);
    await s.connecting;
    await s.ssh.disconnect();
    expect(s.ssh.exitedCleanly, isFalse);
    expect(s.ssh.isConnected, isFalse);
  });
}
