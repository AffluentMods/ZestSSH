// SPDX-License-Identifier: MIT
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/src/message/msg_kex_ecdh.dart';
import 'package:zest_ssh_core/src/ssh_message.dart';

/// SSH_MSG_KEX_ECDH_REPLY (RFC 5656 section 4): the host key, the server's
/// ephemeral key, the signature, in that order. encode wrote the first two
/// the other way round from how decode reads them; a client only reads this
/// message, so nothing met it until a test or a server role would have (found
/// in a security review of August 2026).
void main() {
  final hostKey = Uint8List.fromList(List.generate(51, (i) => i));
  final ephemeral = Uint8List.fromList(List.generate(32, (i) => 200 - i));
  final signature = Uint8List.fromList(List.generate(83, (i) => i * 3 & 0xff));

  test('a reply reads back as it was written', () {
    final back = SSH_Message_KexECDH_Reply.decode(SSH_Message_KexECDH_Reply(
      hostPublicKey: hostKey,
      ecdhPublicKey: ephemeral,
      signature: signature,
    ).encode());
    expect(back.hostPublicKey, hostKey);
    expect(back.ecdhPublicKey, ephemeral);
    expect(back.signature, signature);
  });

  test('on the wire the host key comes first, then the ephemeral key, then the signature', () {
    final bytes = SSH_Message_KexECDH_Reply(
      hostPublicKey: hostKey,
      ecdhPublicKey: ephemeral,
      signature: signature,
    ).encode();
    final reader = SSHMessageReader(bytes);
    expect(reader.readUint8(), SSH_Message_KexECDH_Reply.messageId);
    expect(reader.readString(), hostKey);
    expect(reader.readString(), ephemeral);
    expect(reader.readString(), signature);
  });
}
