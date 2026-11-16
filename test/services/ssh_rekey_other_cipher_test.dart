import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// The messages a played server reads are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A host that asks for new keys under another cipher or MAC than the one
/// the session began with, as the app's own SSH service lives through it
/// (3.0, from the SSH core's audit), with what the app itself offers a host:
/// chacha20-poly1305 first, then aes256-ctr and aes128-ctr, the "etm" MACs
/// before the plain ones, and the CBC ciphers in Compatibility Mode.
///
/// A host asks for new keys every so often (OpenSSH after a gigabyte or an
/// hour), and may then propose other algorithms than at the start. The SSH
/// core took what was agreed on into use before the new keys were there:
/// its own part of that exchange went out in the clear or under the wrong
/// framing, and the session was lost at the host's answer.
///
/// The host is played by the test (the package's played server, which the
/// OpenSSH client holds to what OpenSSH speaks).
void main() {
  const patience = Duration(seconds: 10);

  /// The app's own service in a shell on a played host that speaks [first].
  Future<({SshService ssh, PlayedServer server, PlayedChannel channel, List<int> printed})> inAShell(
    PlayedSuite first, {
    bool compatibility = false,
  }) async {
    final server = PlayedServer(suite: first);
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      compatibilityMode: compatibility,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    final printed = <int>[];
    ssh.stdout.listen(printed.addAll);
    final connecting = ssh.connect().timeout(patience);
    unawaited(connecting.then((_) {}, onError: (_) {}));
    await server.letIn();
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success, channel.data('deploy@web-01:~\$ ')]);
    await connecting;
    return (ssh: ssh, server: server, channel: channel, printed: printed);
  }

  /// What is typed reaches the host, and what the host prints reaches the
  /// terminal.
  Future<void> typedAndPrinted(
    ({SshService ssh, PlayedServer server, PlayedChannel channel, List<int> printed}) s,
    String typed,
    String printedBack,
  ) async {
    s.ssh.write(Uint8List.fromList(utf8.encode(typed)));
    final arrived = SSH_Message_Channel_Data.decode(await s.server.next(SSH_Message_Channel_Data.messageId));
    expect(utf8.decode(arrived.data), typed);
    s.server.send([s.channel.data(printedBack)]);
    final waited = Stopwatch()..start();
    while (!utf8.decode(s.printed).contains(printedBack)) {
      if (waited.elapsed > patience) fail('what the host printed did not reach the terminal: $printedBack');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(s.ssh.isConnected, isTrue);
  }

  for (final (first, then, compatibility, what) in [
    (PlayedSuite.chacha, PlayedSuite.ctrEtm, false, 'the cipher the app prefers, then the one it has for a host without it'),
    (PlayedSuite.ctrEtm, PlayedSuite.chacha, false, 'the other way round'),
    (PlayedSuite.ctrEtm, PlayedSuite.ctr, false, 'the same cipher with another kind of MAC'),
    (PlayedSuite.chacha, PlayedSuite.cbc, true, 'a cipher of the past, in Compatibility Mode'),
  ]) {
    test('a host that asks for new keys under other algorithms than before ($what): the shell goes on, and the '
        'session says what protects it now', () async {
      final s = await inAShell(first, compatibility: compatibility);
      expect(s.ssh.negotiatedCipher, first.cipher.name);
      await typedAndPrinted(s, 'uptime\n', ' 10:04:11 up 41 days\r\n');

      await s.server.rekey(suite: then);
      await typedAndPrinted(s, 'df -h\n', 'Filesystem      Size  Used Avail\r\n');
      expect(s.ssh.negotiatedCipher, then.cipher.name);

      // And once more, back to what it began with.
      await s.server.rekey(suite: first);
      await typedAndPrinted(s, 'exit\n', 'logout\r\n');
      expect(s.ssh.negotiatedCipher, first.cipher.name);
    });
  }

  test('new keys under the same algorithms, as a host usually asks: as before', () async {
    final s = await inAShell(PlayedSuite.chacha);
    await s.server.rekey();
    await typedAndPrinted(s, 'ls\n', 'notes.txt\r\n');
    await s.server.rekey();
    await typedAndPrinted(s, 'pwd\n', '/home/deploy\r\n');
    expect(s.ssh.negotiatedCipher, PlayedSuite.chacha.cipher.name);
  });
}
