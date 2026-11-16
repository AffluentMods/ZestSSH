// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zest_ssh_core/src/sftp/sftp_client.dart';
import 'package:zest_ssh_core/src/sftp/sftp_packet.dart';
import 'package:zest_ssh_core/src/sftp/sftp_status_code.dart';
import 'package:zest_ssh_core/src/ssh_channel.dart';
import 'package:zest_ssh_core/src/ssh_message.dart';

/// An SFTP server that sends replies of a few bytes each, faster than the
/// client hands them out (32 a turn), filled the client's buffer without a
/// bound: the channel's window was opened again for every piece as it came
/// (the client read its channel without ever pausing it), so nothing stopped
/// the server. 8 pieces of 32 KB a turn for 200 turns left 47 MiB held (found
/// in a review of the SSH code, November 2026).
void main() {
  late List<SSHMessage> sent;
  late SSHChannelController controller;
  late SftpClient client;

  Uint8List framed(SftpPacket packet) {
    final payload = packet.encode();
    return (SSHMessageWriter()
          ..writeUint32(payload.length)
          ..writeBytes(payload))
        .takeBytes();
  }

  // A reply to a request nobody made: 21 bytes on the wire.
  final reply = framed(SftpStatusPacket(requestId: 0x7fffffff, code: SftpStatusCode.ok, message: ''));
  final perPiece = 32000 ~/ reply.length;
  final piece = Uint8List(perPiece * reply.length);
  for (var i = 0; i < perPiece; i++) {
    piece.setRange(i * reply.length, (i + 1) * reply.length, reply);
  }

  setUp(() async {
    sent = [];
    controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 2 * 1024 * 1024,
      remoteId: 2,
      remoteMaximumPacketSize: 32768,
      remoteInitialWindowSize: 2 * 1024 * 1024,
      sendMessage: sent.add,
    );
    client = SftpClient(controller.channel);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.handleMessage(SSH_Message_Channel_Data(recipientChannel: 1, data: framed(SftpVersionPacket(3))));
    await client.handshake;
  });
  tearDown(() => controller.destroy());

  test('a server that keeps to the window can make the client hold no more than a window and a bit', () async {
    var window = 2 * 1024 * 1024;
    var opened = 0;
    var most = 0;
    for (var turn = 0; turn < 200; turn++) {
      for (final m in sent.skip(opened)) {
        if (m is SSH_Message_Channel_Window_Adjust) window += m.bytesToAdd;
      }
      opened = sent.length;
      for (var i = 0; i < 8 && window >= piece.length; i++) {
        controller.handleMessage(SSH_Message_Channel_Data(recipientChannel: 1, data: piece));
        window -= piece.length;
      }
      if (client.bufferedBytes > most) most = client.bufferedBytes;
      await Future<void>.delayed(Duration.zero);
    }
    expect(most, lessThan(SftpClient.maxHeldBytes + 8 * piece.length),
        reason: 'the client held ${most >> 20} MiB of replies');
    expect(client.isClosed, isFalse);

    // Once the flood ends, what is held is handed out, and a request is
    // answered as ever.
    final clock = Stopwatch()..start();
    while (client.bufferedBytes > 0 && clock.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(client.bufferedBytes, 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final asked = client.absolute('.');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final request = sent.whereType<SSH_Message_Channel_Data>().last.data;
    final id = ByteData.sublistView(request, 5, 9).getUint32(0);
    controller.handleMessage(SSH_Message_Channel_Data(
      recipientChannel: 1,
      data: framed(SftpStatusPacket(requestId: id, code: SftpStatusCode.noSuchFile, message: 'gone')),
    ));
    await expectLater(asked, throwsA(anything));
    expect(client.isClosed, isFalse);
  });

  test('a server that does not keep to the window ends the channel, and nothing piles up', () async {
    for (var turn = 0; turn < 200; turn++) {
      for (var i = 0; i < 8; i++) {
        controller.handleMessage(SSH_Message_Channel_Data(recipientChannel: 1, data: piece));
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(client.bufferedBytes, lessThan(4 * 1024 * 1024),
        reason: 'the client holds ${client.bufferedBytes >> 20} MiB of replies');
  });
}
