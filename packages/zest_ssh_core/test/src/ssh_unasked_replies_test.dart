// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zest_ssh_core/src/message/msg_request.dart';
import 'package:zest_ssh_core/src/ssh_channel.dart';
import 'package:zest_ssh_core/src/ssh_message.dart';

import 'played_server.dart';

/// A reply to a request that was not made is dropped (found in a security review
/// of November 2026).
///
/// Every SSH_MSG_REQUEST_SUCCESS and REQUEST_FAILURE a server sent went into
/// the connection's queue of replies, whether a request was waiting for one
/// or not, each with a view of the whole packet it came in; and every
/// CHANNEL_SUCCESS and CHANNEL_FAILURE into its channel's. A hostile server
/// grew the client's memory as fast as it sent them, and the requests made
/// after them (a remote forward, a keep-alive, a channel's request) were
/// answered by them at once, in place of their own replies. Now a reply is
/// taken only where a request is owed one, and what a yes carries is copied
/// out of its packet.
void main() {
  const patience = Duration(seconds: 10);

  /// How [asked] ended, or 'waiting' when it has not after a moment.
  Future<Object?> endOf<T>(Future<T> asked) => asked
      .then<Object?>((answer) => answer, onError: (Object e) => e)
      .timeout(const Duration(milliseconds: 300), onTimeout: () => 'waiting');

  group('the connection', () {
    Future<PlayedServer> signedIn() async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      return server;
    }

    /// Fifty yeses to no request, each a packet of 30 KB; done once the
    /// client has read them all, which it shows by answering a request of the
    /// server's that comes behind them (it reads in order).
    Future<void> unasked(PlayedServer server) async {
      server.send([
        ...List.filled(50, SSH_Message_Request_Success(Uint8List(30000)).encode()),
        SSH_Message_Global_Request(requestName: 'zest-test@example.com', wantReply: true).encode(),
      ]);
      await server.next(SSH_Message_Request_Failure.messageId);
    }

    test('a remote forward asked for after replies nobody asked for waits for its own, and is refused', () async {
      final server = await signedIn();
      await unasked(server);
      final asked = server.client.forwardRemote(host: '127.0.0.1', port: 10022);
      await server.next(SSH_Message_Global_Request.messageId);
      expect(await endOf(asked), 'waiting', reason: 'not answered by a yes nobody asked for');
      server.send([SSH_Message_Request_Failure().encode()]);
      expect(await asked.timeout(patience), isNull);
      expect(server.client.isClosed, isFalse);
    });

    test('a keep-alive waits for its own reply', () async {
      final server = await signedIn();
      await unasked(server);
      final pinged = server.client.ping();
      await server.next(SSH_Message_Global_Request.messageId);
      expect(await endOf(pinged), 'waiting');
      server.send([SSH_Message_Request_Failure().encode()]);
      await pinged.timeout(patience);
    });

    test('replies in their turn still answer the requests in theirs', () async {
      final server = await signedIn();
      final first = server.client.forwardRemote(host: '127.0.0.1', port: 10022);
      final second = server.client.forwardRemote(host: '127.0.0.1', port: 0);
      await server.next(SSH_Message_Global_Request.messageId);
      await server.next(SSH_Message_Global_Request.messageId);
      final port = ByteData(4)..setUint32(0, 40123);
      server.send([
        SSH_Message_Request_Failure().encode(),
        SSH_Message_Request_Success(port.buffer.asUint8List()).encode(),
      ]);
      expect(await first.timeout(patience), isNull);
      expect((await second.timeout(patience))?.port, 40123);
    });
  });

  test("what a yes carries is a copy, not a view of the packet it came in", () {
    final packet = Uint8List(30001)..[0] = SSH_Message_Request_Success.messageId;
    final message = SSH_Message_Request_Success.decode(packet);
    expect(message.requestData, hasLength(30000));
    expect(message.requestData.buffer.lengthInBytes, 30000);
    expect(identical(message.requestData.buffer, packet.buffer), isFalse);
  });

  group('a channel', () {
    (SSHChannelController, List<SSHMessage>) make() {
      final sent = <SSHMessage>[];
      final controller = SSHChannelController(
        localId: 1,
        localMaximumPacketSize: 32768,
        localInitialWindowSize: 1024,
        remoteId: 2,
        remoteMaximumPacketSize: 32768,
        remoteInitialWindowSize: 1024,
        sendMessage: sent.add,
      );
      return (controller, sent);
    }

    test('a request after replies nobody asked for waits for its own', () async {
      final (controller, _) = make();
      for (var i = 0; i < 1000; i++) {
        controller.handleMessage(SSH_Message_Channel_Success(recipientChannel: 1));
      }
      final asked = controller.sendEnv('LANG', 'C');
      expect(await endOf(asked), 'waiting');
      controller.handleMessage(SSH_Message_Channel_Failure(recipientChannel: 1));
      expect(await endOf(asked), isFalse);
      controller.destroy();
    });

    test('a reply after the one owed is dropped too', () async {
      final (controller, _) = make();
      final pty = controller.sendPtyReq();
      controller.handleMessage(SSH_Message_Channel_Success(recipientChannel: 1));
      controller.handleMessage(SSH_Message_Channel_Success(recipientChannel: 1));
      expect(await endOf(pty), isTrue);
      final shell = controller.sendShell();
      expect(await endOf(shell), 'waiting');
      controller.handleMessage(SSH_Message_Channel_Failure(recipientChannel: 1));
      expect(await endOf(shell), isFalse);
      controller.destroy();
    });
  });
}
