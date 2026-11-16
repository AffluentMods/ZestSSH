// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zest_ssh_core/src/message/msg_ignore.dart';
import 'package:zest_ssh_core/src/message/msg_kex.dart';

import 'played_server.dart';

/// An exchange of new keys that the server does not finish ends the
/// connection, with an error that says so (found in a security review of
/// November 2026).
///
/// What a session sends while new keys are being exchanged waits for them.
/// A server that never answered a proposal for new keys (the client's, after
/// a gigabyte, or its own) kept all of it waiting, typing and uploads alike,
/// for as long as the connection lasted, and an upload went on reading its
/// file into that wait: the drain an upload waits on between bursts ended at
/// once, as nothing was going to the socket. Now the exchange has
/// [SSHClient.rekeyPatience] (60 seconds where nothing is said), an upload's
/// drain waits for the new keys, and past [SSHClient.maxBytesAwaitingKeys]
/// waiting (64 MiB) the connection is ended.
void main() {
  const patience = Duration(seconds: 10);

  /// A client with the limits it is given, signed in to a played server.
  Future<PlayedServer> signedIn({
    Duration rekeyPatience = SSHTransport.defaultRekeyPatience,
    int maxBytesAwaitingKeys = SSHTransport.defaultMaxBytesAwaitingKeys,
    int? afterPackets,
  }) async {
    final server = await PlayedServer.signedIn(
      client: (socket, algorithms) => SSHClient(
        socket,
        username: 'deploy',
        algorithms: algorithms,
        keepAliveInterval: null,
        rekeyPatience: rekeyPatience,
        maxBytesAwaitingKeys: maxBytesAwaitingKeys,
        rekeyAfterPackets: afterPackets ?? SSHTransport.defaultRekeyAfterPackets,
      ),
    );
    addTearDown(server.client.close);
    return server;
  }

  /// What ending the connection came to: the error, or null.
  Future<Object?> endOf(SSHClient client) =>
      client.done.then<Object?>((_) => null, onError: (Object e) => e).timeout(patience);

  bool saysNewKeysDidNotCome(Object? e) =>
      e is SSHHandshakeError && e.message.contains('New keys were asked for and the exchange did not end');

  test('where nothing is said: a minute, and 64 MiB', () {
    expect(SSHTransport.defaultRekeyPatience, const Duration(seconds: 60));
    expect(SSHTransport.defaultMaxBytesAwaitingKeys, 64 * 1024 * 1024);
  });

  test('new keys the client asked for that never come end the connection, said as that', () async {
    final server = await signedIn(rekeyPatience: const Duration(milliseconds: 300), afterPackets: 20);
    for (var i = 0; i < 25; i++) {
      server.send([SSH_Message_Ignore(Uint8List(0)).encode()]);
    }
    expect(await server.sent(SSH_Message_KexInit.messageId), isTrue, reason: 'it asked');
    final watch = Stopwatch()..start();
    final error = await endOf(server.client);
    expect(saysNewKeysDidNotCome(error), isTrue, reason: '$error');
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('an exchange the server began and does not finish ends the connection too', () async {
    final server = await signedIn(rekeyPatience: const Duration(milliseconds: 300));
    await server.beginRekey();
    final error = await endOf(server.client);
    expect(saysNewKeysDidNotCome(error), isTrue, reason: '$error');
  });

  test('an exchange that ends in time leaves the connection as it was, and the clock with it', () async {
    final server = await signedIn(rekeyPatience: const Duration(milliseconds: 400));
    await server.beginRekey();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.finishRekey();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(server.client.isClosed, isFalse);
  });

  /// A command running on the server, with a channel that takes [window].
  Future<(SSHSession, PlayedChannel)> command(PlayedServer server,
      {int window = 16 * 1024 * 1024, int maxPacket = 32768}) async {
    final starting = server.client.execute('cat > /dev/null');
    final channel = await server.confirmChannel(window: window, maxPacket: maxPacket);
    await channel.nextRequest();
    server.send([channel.success]);
    return (await starting.timeout(patience), channel);
  }

  test('an upload waits for the new keys, and goes on once they come', () async {
    // Less than the upload: had it gone on reading its file into the wait,
    // the connection would have ended.
    final server = await signedIn(maxBytesAwaitingKeys: 600 * 1024);
    final (session, _) = await command(server);
    await server.beginRekey();

    const size = 2 * 1024 * 1024;
    session.stdin.add(Uint8List(size));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(server.client.isClosed, isFalse, reason: 'the upload waited');

    await server.finishRekey();
    var came = 0;
    while (came < size) {
      came += SSH_Message_Channel_Data.decode(await server.next(SSH_Message_Channel_Data.messageId)).data.length;
    }
    expect(came, size);
    expect(server.client.isClosed, isFalse);
  });

  test('more waiting for new keys than may: the connection is ended, said as that', () async {
    // (One packet past it: an upload's drain waits for the keys between its
    // bursts, so what is past it is what else is sent, here a channel whose
    // packets the server let be large.)
    final server = await signedIn(maxBytesAwaitingKeys: 50 * 1024);
    final (session, _) = await command(server, maxPacket: 256 * 1024);
    await server.beginRekey();
    session.stdin.add(Uint8List(200 * 1024));
    final error = await endOf(server.client);
    expect(error, isA<SSHHandshakeError>());
    expect((error! as SSHHandshakeError).message, contains('waited for new keys that did not come'));
  });
}
