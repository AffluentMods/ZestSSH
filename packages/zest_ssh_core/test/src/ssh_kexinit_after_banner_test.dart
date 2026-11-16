// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_ssh_core/src/message/msg_kex.dart';

/// A client sends its version line and nothing else until the server's
/// version has come, as OpenSSH does.
///
/// It sent its proposal for the key exchange (KEXINIT) straight behind its
/// version, before the server had said anything. A VPS behind a provider's
/// filter (VirtFusion, Ubuntu 24.04, OpenSSH 9.6p1, 3 November 2026) took
/// the version line and never the proposal: its `sshd -ddd` showed our
/// version arrive and its own KEXINIT go, and never a KEXINIT from us. The
/// connection ran out of time, where the system's own ssh connected.
void main() {
  const serverVersion = 'SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20';

  test(
      'before the server has said anything, the version line is all that goes out',
      () async {
    final socket = _RecordingSocket();
    final client = SSHClient(socket, username: 'demo');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final sent = latin1.decode(socket.written);
    expect(sent, startsWith('SSH-2.0-'));
    expect(sent, endsWith('\r\n'));
    expect('\n'.allMatches(sent), hasLength(1),
        reason: 'one line and nothing behind it');
    client.close();
  });

  test('the proposal follows once the server\'s version has come', () async {
    final socket = _RecordingSocket();
    final client = SSHClient(socket, username: 'demo');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    socket.say('$serverVersion\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(socket.packetIds(), [SSH_Message_KexInit.messageId]);
    client.close();
  });

  test(
      'a server that sends its version and its proposal in one read gets one proposal back, '
      'and the exchange goes on', () async {
    final socket = _RecordingSocket();
    final client = SSHClient(socket, username: 'demo');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(socket.packetIds(), isEmpty);

    final proposal = SSH_Message_KexInit(
      kexAlgorithms: const [
        'curve25519-sha256',
        'kex-strict-s-v00@openssh.com'
      ],
      serverHostKeyAlgorithms: const ['ssh-ed25519'],
      encryptionClientToServer: const ['aes256-ctr'],
      encryptionServerToClient: const ['aes256-ctr'],
      macClientToServer: const ['hmac-sha2-256'],
      macServerToClient: const ['hmac-sha2-256'],
      compressionClientToServer: const ['none'],
      compressionServerToClient: const ['none'],
      firstKexPacketFollows: false,
    ).encode();
    socket.sayBytes(
        [...latin1.encode('$serverVersion\r\n'), ..._inTheClear(proposal)]);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final ids = socket.packetIds();
    expect(
        ids.where((id) => id == SSH_Message_KexInit.messageId), hasLength(1));
    expect(ids.first, SSH_Message_KexInit.messageId,
        reason: 'our proposal goes before our part of the exchange');
    expect(ids, contains(30),
        reason: 'SSH_MSG_KEX_ECDH_INIT: the exchange went on');
    client.close();
  });
}

/// [payload] as a packet goes before any keys are in force: its length, the
/// length of its padding, itself, and the padding, to a multiple of 8.
Uint8List _inTheClear(Uint8List payload) {
  var padding = 8 - (5 + payload.length) % 8;
  if (padding < 4) padding += 8;
  final length = 1 + payload.length + padding;
  final packet = ByteData(4 + length);
  packet.setUint32(0, length);
  packet.setUint8(4, padding);
  final bytes = packet.buffer.asUint8List();
  bytes.setRange(5, 5 + payload.length, payload);
  return bytes;
}

/// The server's end of a connection that keeps what the client writes.
class _RecordingSocket implements SSHSocket {
  final _input = StreamController<Uint8List>();
  final _done = Completer<void>();
  final _written = BytesBuilder(copy: true);

  Uint8List get written => _written.toBytes();

  void say(String text) => sayBytes(latin1.encode(text));

  void sayBytes(List<int> bytes) => _input.add(Uint8List.fromList(bytes));

  /// The message ids of the packets the client wrote after its version
  /// line, read as packets in the clear (all a handshake's first packets
  /// are).
  List<int> packetIds() {
    final bytes = written;
    final lineEnd = bytes.indexOf(0x0A);
    if (lineEnd < 0) return const [];
    final ids = <int>[];
    var at = lineEnd + 1;
    while (at + 6 <= bytes.length) {
      final length = ByteData.sublistView(bytes, at, at + 4).getUint32(0);
      ids.add(bytes[at + 5]);
      at += 4 + length;
    }
    return ids;
  }

  @override
  Future<void> flush() async {}

  @override
  Stream<Uint8List> get stream => _input.stream;

  @override
  StreamSink<List<int>> get sink => _Sink(_written);

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _input.close();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_input.close());
  }
}

class _Sink implements StreamSink<List<int>> {
  _Sink(this._into);

  final BytesBuilder _into;

  @override
  void add(List<int> data) => _into.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Completer<void>().future;
}
