// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/src/message/msg_channel.dart';

import 'played_server.dart';

/// A channel the server refuses to open (SSH_MSG_CHANNEL_OPEN_FAILURE: a
/// forward to a port where nothing listens, a SOCKS request for a host that
/// cannot be reached, a session past the server's MaxSessions) kept its
/// channel number for as long as the connection lasted: SSHClient's
/// _waitChannelOpen threw without giving it back. After 65,535 refusals no
/// channel could be opened on the connection at all ("No more channel ids
/// available"): no terminal, no SFTP, no forward, until it was connected
/// again. A forward to a database that is down, with a program that tries
/// again every second, got there in about 18 hours (found in a review of
/// the SSH code, November 2026).
void main() {
  test('a refused channel open gives its number back', () async {
    final server = await PlayedServer.signedIn();
    addTearDown(server.client.close);

    const batch = 1024;
    var refused = 0;
    while (refused < 65535) {
      final n = refused + batch > 65535 ? 65535 - refused : batch;
      final opens = [
        for (var i = 0; i < n; i++)
          server.client.forwardLocal('10.50.0.9', 5432).then<Object?>((_) => null, onError: (Object e) => e),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final asked = <Uint8List>[];
      while (asked.length < n) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        asked.addAll(server.takeSent().where((p) => p[0] == SSH_Message_Channel_Open.messageId));
      }
      server.send([
        for (final p in asked)
          SSH_Message_Channel_Open_Failure(
            recipientChannel: SSH_Message_Channel_Open.decode(p).senderChannel,
            reasonCode: SSH_Message_Channel_Open_Failure.codeConnectFailed,
            description: 'connect failed: Connection refused',
          ).encode(),
      ]);
      final outcomes = await Future.wait(opens);
      expect(outcomes.whereType<Object>().map((e) => e.runtimeType.toString()).toSet(), {'SSHChannelOpenError'});
      refused += n;
    }

    // The next forward after all those refusals is asked for, and opens.
    final next = server.client.forwardLocal('10.50.0.9', 5432);
    final failedAtOnce = await next.then<Object?>((_) => null, onError: (Object e) => e).timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => null,
        );
    expect('$failedAtOnce', isNot(contains('No more channel ids')),
        reason: 'after 65,535 refused opens the connection opens nothing');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final open = server.takeSent().where((p) => p[0] == SSH_Message_Channel_Open.messageId).toList();
    expect(open, hasLength(1), reason: 'the next open was asked for');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
