// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zest_ssh_core/src/sftp/sftp_packet.dart';
import 'package:zest_ssh_core/src/ssh_channel.dart';
import 'package:zest_ssh_core/src/ssh_message.dart';
import 'package:zest_ssh_core/src/transport/ssh_events.dart';

import '../test_utils.dart';
import 'played_server.dart';

/// A server played to a real client, doing what no honest server does after
/// the person has trusted its key and signed in: memory must not grow at its
/// word, whatever it says and for however long it goes on.
/// Waits for [what] to be so, for a client that may be busy.
Future<void> _until(bool Function() what) async {
  for (var i = 0; i < 1000 && !what(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('runCapped', () {
    const command = 'cat /etc/os-release 2>/dev/null || uname -s';

    test('the answer of a command that ends', () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      final asked = server.client.runCapped(command,
          maxBytes: 1024, timeout: const Duration(seconds: 30));
      final channel = await server.confirmChannel();
      expect((await channel.nextRequest()).command, command);
      server.send([
        channel.success,
        channel.data('ID=debian\n'),
        channel.errorData('not this\n'),
        channel.eof,
        channel.close
      ]);
      expect(String.fromCharCodes(await asked), 'ID=debian\n');
    });

    test(
        'at the limit it has its answer and closes the channel: nothing more comes',
        () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      final asked = server.client.runCapped(command,
          maxBytes: 10, timeout: const Duration(seconds: 30));
      final channel = await server.confirmChannel();
      await channel.nextRequest();
      server.send([channel.success, channel.data('ID=debian and on')]);
      expect(String.fromCharCodes(await asked), 'ID=debian ');
      await server.next(SSH_Message_Channel_Close.messageId);

      // The host goes on: its window is not opened again.
      server.takeSent();
      server.send([channel.data('x' * 30000), channel.data('x' * 30000)]);
      await server.settle();
      expect(await server.sent(SSH_Message_Channel_Window_Adjust.messageId),
          isFalse);
    });

    test(
        'at the timeout it fails, and closes the channel: what the host then sends is not kept',
        () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      Object? failure;
      final asked = server.client
          .runCapped(command,
              maxBytes: 1024, timeout: const Duration(milliseconds: 150))
          .then<void>((_) {}, onError: (Object e) => failure = e);
      final channel = await server.confirmChannel();
      await channel.nextRequest();
      server.send([channel.success]);
      await asked;
      expect(failure, isA<TimeoutException>());
      await server.next(SSH_Message_Channel_Close.messageId);

      server.takeSent();
      for (var i = 0; i < 64; i++) {
        server.send([channel.data('x' * 32000)]);
      }
      await server.settle();
      expect(await server.sent(SSH_Message_Channel_Window_Adjust.messageId),
          isFalse,
          reason:
              'its window stayed shut: with run() under a timeout it went on opening for good');
    });

    test('a channel that opens after the timeout is closed as soon as it does',
        () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      Object? failure;
      final asked = server.client
          .runCapped(command,
              maxBytes: 1024, timeout: const Duration(milliseconds: 100))
          .then<void>((_) {}, onError: (Object e) => failure = e);
      final open = SSH_Message_Channel_Open.decode(
          await server.next(SSH_Message_Channel_Open.messageId));
      await asked;
      expect(failure, isA<TimeoutException>());
      // The host answers late.
      server.send([
        SSH_Message_Channel_Confirmation(
          recipientChannel: open.senderChannel,
          senderChannel: 7,
          initialWindowSize: 1 << 20,
          maximumPacketSize: 32768,
          data: Uint8List(0),
        ).encode(),
      ]);
      // (It goes on to ask for the command; only then is the session there.)
      await server.next(SSH_Message_Channel_Request.messageId);
      server.send([
        SSH_Message_Channel_Success(recipientChannel: open.senderChannel)
            .encode()
      ]);
      await server.next(SSH_Message_Channel_Close.messageId);
    });
  });

  group('what nobody reads', () {
    test(
        'a stream nobody listens to keeps what can come before a listener, and no more',
        () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      final session = server.client.execute('do-something');
      final channel = await server.confirmChannel();
      await channel.nextRequest();
      server.send([channel.success]);
      final running = await session;

      // Stdout is read; stderr, as with most commands here, is not. A host that
      // fills it fills the app: the window goes on opening for stdout's sake.
      final out = <int>[];
      running.stdout.listen(out.addAll);
      const piece = 32000;
      for (var i = 0; i < 128; i++) {
        server.send([channel.errorData('e' * piece)]);
        if (i % 16 == 0) await server.settle();
      }
      server.send([channel.data('still read')]);
      await _until(() => out.isNotEmpty);
      expect(String.fromCharCodes(out), 'still read');

      // Whoever comes late gets what was kept.
      final err = <int>[];
      running.stderr.listen(err.addAll);
      await _until(() => err.isNotEmpty);
      await server.settle();
      expect(err.length, lessThanOrEqualTo(SSHSession.maxUnreadBytes));
      expect(err.length, greaterThan(SSHSession.maxUnreadBytes - 2 * piece));
    });

    test('what comes before a listener is there when one comes, in order',
        () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      final session = server.client.execute('do-something');
      final channel = await server.confirmChannel();
      await channel.nextRequest();
      server.send(
          [channel.success, channel.data('first '), channel.data('second')]);
      final running = await session;
      await server.settle();
      final out = <int>[];
      running.stdout.listen(out.addAll);
      await _until(() => out.length >= 'first second'.length);
      expect(String.fromCharCodes(out), 'first second');
    });

    test('destroy closes it from this side, whatever the server does',
        () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      final session = server.client.execute('do-something');
      final channel = await server.confirmChannel();
      await channel.nextRequest();
      server.send([channel.success]);
      final running = await session;
      var ended = false;
      unawaited(running.done.then((_) => ended = true));
      running.destroy();
      await server.next(SSH_Message_Channel_Close.messageId);
      await _until(() => ended);
      expect(ended, isTrue);
    });
  });

  group('a confirmation for a channel nobody opened', () {
    Uint8List confirmation(int recipient, int sender) =>
        SSH_Message_Channel_Confirmation(
          recipientChannel: recipient,
          senderChannel: sender,
          initialWindowSize: 0,
          maximumPacketSize: 32768,
          data: Uint8List(0),
        ).encode();

    test('makes no channel, however many come', () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      var opened = 0;
      final sub = server.client.events.listen((e) {
        if (e is SSHEventChannelOpened) opened++;
      });
      addTearDown(sub.cancel);
      server.send([for (var i = 0; i < 2000; i++) confirmation(5000 + i, i)]);
      await server.settle();
      expect(opened, 0);
    });

    test('and takes no place of a channel that is open', () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      final session = server.client.execute('do-something');
      final channel = await server.confirmChannel();
      await channel.nextRequest();
      server.send([channel.success]);
      final running = await session;
      final out = <int>[];
      running.stdout.listen(out.addAll);
      // The same number again, with another server side to it.
      server.send(
          [confirmation(channel.clientId, 99), channel.data('still this one')]);
      await _until(() => out.isNotEmpty);
      expect(String.fromCharCodes(out), 'still this one');
    });

    test(
        'the one that was asked for still opens its channel, and what comes with it is read',
        () async {
      final server = await PlayedServer.signedIn();
      addTearDown(server.client.close);
      final session = server.client.execute('do-something');
      final open = SSH_Message_Channel_Open.decode(
          await server.next(SSH_Message_Channel_Open.messageId));
      server.send([confirmation(open.senderChannel, 3)]);
      await server.next(SSH_Message_Channel_Request.messageId);
      server.send([
        SSH_Message_Channel_Success(recipientChannel: open.senderChannel)
            .encode()
      ]);
      expect(await session, isNotNull);
    });
  });

  group('an endless directory', () {
    /// A client on a channel whose other end [answer] plays: it is given each
    /// packet the client sends, and sends back what it returns.
    SftpClient clientOf(SftpPacket? Function(Uint8List packet) answer) {
      late SSHChannelController controller;
      void reply(SftpPacket packet) {
        final data = packet.encode();
        final w = SSHMessageWriter();
        w.writeUint32(data.length);
        w.writeBytes(data);
        controller.handleMessage(
            SSH_Message_Channel_Data(recipientChannel: 1, data: w.takeBytes()));
      }

      controller = SSHChannelController(
        localId: 1,
        localMaximumPacketSize: 1024 * 1024,
        localInitialWindowSize: 1 << 30,
        remoteId: 2,
        remoteMaximumPacketSize: 1024 * 1024,
        remoteInitialWindowSize: 1 << 30,
        sendMessage: (message) {
          if (message is! SSH_Message_Channel_Data) return;
          final reader = SSHMessageReader(message.data);
          final packet = reader.readBytes(reader.readUint32());
          Timer.run(() {
            final out = answer(packet);
            if (out != null) reply(out);
          });
        },
      );
      return SftpClient(controller.channel);
    }

    /// A directory that has no end: [perPiece] names of [longname] each time it
    /// is asked for more.
    SftpClient endless(
        {required void Function() onClosed,
        int perPiece = 1000,
        String longname = 'name'}) {
      final handle = Uint8List.fromList([7, 7, 7]);
      final names = [
        for (var i = 0; i < perPiece; i++)
          SftpName(
              filename: 'name-$i', longname: longname, attr: SftpFileAttrs()),
      ];
      return clientOf((packet) {
        switch (packet[0]) {
          case SftpInitPacket.packetType:
            return SftpVersionPacket(3);
          case SftpOpenDirPacket.packetType:
            return SftpHandlePacket(
                SftpOpenDirPacket.decode(packet).requestId, handle);
          case SftpReadDirPacket.packetType:
            return SftpNamePacket(
                SftpReadDirPacket.decode(packet).requestId, names);
          case SftpClosePacket.packetType:
            onClosed();
            return SftpStatusPacket(
                requestId: SftpClosePacket.decode(packet).requestId,
                code: 0,
                message: '');
        }
        return null;
      });
    }

    test(
        'a listing ends at the most names it takes, says so, and lets go of the directory',
        () async {
      var closed = false;
      final client = endless(onClosed: () => closed = true);
      await expectLater(
        client.listdir('/srv/endless', maxNames: 5000),
        throwsA(isA<SftpListingTooLongError>()
            .having((e) => e.maxNames, 'the most it takes', 5000)
            .having((e) => e.message, 'what it says',
                allOf(contains('/srv/endless'), contains('5000')))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isTrue);
    });

    test('the most it takes unless told otherwise is a million', () {
      expect(SftpClient.defaultMaxListedNames, 1000000);
    });

    test('and at so many characters, whatever the number of names', () async {
      final client =
          endless(onClosed: () {}, perPiece: 10, longname: 'x' * 1024);
      await expectLater(client.listdir('/srv/long', maxCharacters: 50000),
          throwsA(isA<SftpListingTooLongError>()));
    });

    test('a listing that fits is what it was', () async {
      final handle = Uint8List.fromList([1]);
      var pieces = 0;
      final client = clientOf((packet) {
        switch (packet[0]) {
          case SftpInitPacket.packetType:
            return SftpVersionPacket(3);
          case SftpOpenDirPacket.packetType:
            return SftpHandlePacket(
                SftpOpenDirPacket.decode(packet).requestId, handle);
          case SftpReadDirPacket.packetType:
            final id = SftpReadDirPacket.decode(packet).requestId;
            if (pieces++ == 3)
              return SftpStatusPacket(requestId: id, code: 1, message: 'end');
            return SftpNamePacket(id, [
              SftpName(
                  filename: 'n$pieces',
                  longname: 'n$pieces',
                  attr: SftpFileAttrs())
            ]);
          case SftpClosePacket.packetType:
            return SftpStatusPacket(
                requestId: SftpClosePacket.decode(packet).requestId,
                code: 0,
                message: '');
        }
        return null;
      });
      expect((await client.listdir('/srv')).map((n) => n.filename),
          ['n1', 'n2', 'n3']);
    });

    test(
        'one packet that claims more names than any has is refused before they are read',
        () {
      final w = SSHMessageWriter();
      w.writeUint8(SftpNamePacket.packetType);
      w.writeUint32(1);
      w.writeUint32(SftpNamePacket.maxNames + 1);
      expect(() => SftpNamePacket.decode(w.takeBytes()),
          throwsA(isA<FormatException>()));
    });
  });

  group('the agent', () {
    test('says when it signed, and not when it did not', () async {
      final keyPair = (await getTestKeyPairs()).single;
      var signed = 0;
      final agent = SSHKeyPairAgent([keyPair], onSigned: () => signed++);
      final blob = keyPair.toPublicKey().encode();

      Uint8List request(Uint8List key) {
        final w = SSHMessageWriter();
        w.writeUint8(SSHAgentProtocol.signRequest);
        w.writeString(key);
        w.writeString(Uint8List.fromList([1, 2, 3]));
        w.writeUint32(0);
        return w.takeBytes();
      }

      final answer = await agent.handleRequest(request(blob));
      expect(answer[0], SSHAgentProtocol.signResponse);
      expect(signed, 1);

      final none =
          await agent.handleRequest(request(Uint8List.fromList([9, 9, 9])));
      expect(none[0], SSHAgentProtocol.failure);
      expect(signed, 1, reason: 'a key it does not have signed nothing');

      final w = SSHMessageWriter()
        ..writeUint8(SSHAgentProtocol.requestIdentities);
      await agent.handleRequest(w.takeBytes());
      expect(signed, 1, reason: 'listing what it has signs nothing');
    });
  });
}
