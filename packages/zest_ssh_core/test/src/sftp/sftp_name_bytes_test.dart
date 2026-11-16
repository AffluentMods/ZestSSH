// SPDX-License-Identifier: MIT
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zest_ssh_core/src/sftp/sftp_client.dart';
import 'package:zest_ssh_core/src/sftp/sftp_file_attrs.dart';
import 'package:zest_ssh_core/src/sftp/sftp_name_bytes.dart';
import 'package:zest_ssh_core/src/sftp/sftp_packet.dart';
import 'package:zest_ssh_core/src/sftp/sftp_packet_ext.dart';
import 'package:zest_ssh_core/src/sftp/sftp_status_code.dart';
import 'package:zest_ssh_core/src/ssh_channel.dart';
import 'package:zest_ssh_core/src/ssh_message.dart';

/// A file whose name on the server is no UTF-8 (an old Latin-1 name,
/// "caf\xE9.txt") was listed with U+FFFD in its name, and every request made
/// with that name (stat, open, remove, rename) sent other bytes than the
/// file's: it was listed and could not be opened, downloaded, renamed or
/// deleted, and a recursive delete of its folder stopped at it (found in a
/// review of the SSH code, November 2026).
void main() {
  final latin1Name = Uint8List.fromList([0x63, 0x61, 0x66, 0xE9, 0x2E, 0x74, 0x78, 0x74]); // caf\xE9.txt

  test('a name the server listed is asked for with the same bytes', () async {
    final sent = <SSHMessage>[];
    final controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: 32768,
      localInitialWindowSize: 2 * 1024 * 1024,
      remoteId: 2,
      remoteMaximumPacketSize: 32768,
      remoteInitialWindowSize: 2 * 1024 * 1024,
      sendMessage: sent.add,
    );
    addTearDown(controller.destroy);
    final client = SftpClient(controller.channel);
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    void serverSendsRaw(Uint8List payload) {
      final w = SSHMessageWriter()
        ..writeUint32(payload.length)
        ..writeBytes(payload);
      controller.handleMessage(SSH_Message_Channel_Data(recipientChannel: 1, data: w.takeBytes()));
    }

    List<Uint8List> clientPackets() => [
          for (final m in sent.whereType<SSH_Message_Channel_Data>())
            () {
              final r = SSHMessageReader(m.data);
              return r.readBytes(r.readUint32());
            }(),
        ];
    int idOf(Uint8List packet) => ByteData.sublistView(packet, 1, 5).getUint32(0);
    Uint8List pathOf(Uint8List packet) => (SSHMessageReader(packet)
          ..readUint8()
          ..readUint32())
        .readString();

    await settle();
    serverSendsRaw(SftpVersionPacket(3).encode());
    await client.handshake;

    final listing = client.listdir('/srv');
    await settle();
    serverSendsRaw(SftpHandlePacket(idOf(clientPackets().last), Uint8List.fromList([1])).encode());
    await settle();
    // NAME: type, id, count 1, filename, longname, attrs (no flags).
    final name = SSHMessageWriter()
      ..writeUint8(SftpNamePacket.packetType)
      ..writeUint32(idOf(clientPackets().last))
      ..writeUint32(1)
      ..writeString(latin1Name)
      ..writeString(latin1Name)
      ..writeUint32(0);
    serverSendsRaw(name.takeBytes());
    await settle();
    serverSendsRaw(SftpStatusPacket(requestId: idOf(clientPackets().last), code: SftpStatusCode.eof, message: '').encode());
    await settle();
    serverSendsRaw(SftpStatusPacket(requestId: idOf(clientPackets().last), code: SftpStatusCode.ok, message: '').encode());
    final names = await listing.timeout(const Duration(seconds: 5));
    final listed = names.single.filename;
    expect(listed, isNot(contains('�')));
    expect(names.single.longname, 'caf�.txt', reason: 'the long name is only shown');

    unawaited(client.stat('/srv/$listed').then((_) {}, onError: (_) {}));
    await settle();
    expect(pathOf(clientPackets().last), [...'/srv/'.codeUnits, ...latin1Name],
        reason: 'listed as "$listed", asked for as other bytes than the file has');

    unawaited(client.remove('/srv/$listed').then((_) {}, onError: (_) {}));
    await settle();
    expect(pathOf(clientPackets().last), [...'/srv/'.codeUnits, ...latin1Name]);
  });

  group('sftpNameOf and sftpBytesOf', () {
    Uint8List roundTrip(List<int> bytes) => sftpBytesOf(sftpNameOf(Uint8List.fromList(bytes)));

    bool wellFormed(String s) {
      for (var i = 0; i < s.length; i++) {
        final u = s.codeUnitAt(i);
        if (u >= 0xD800 && u <= 0xDBFF) {
          if (i + 1 >= s.length) return false;
          final next = s.codeUnitAt(i + 1);
          if (next < 0xDC00 || next > 0xDFFF) return false;
          i++;
        } else if (u >= 0xDC00 && u <= 0xDFFF) {
          return false;
        }
      }
      return true;
    }

    test('a name in UTF-8 is read and written as ever', () {
      for (final name in ['report.txt', '', 'café 中文 🍊', 'a/b/c', 'with\u0000nul']) {
        final bytes = utf8.encode(name);
        expect(sftpNameOf(bytes), name);
        expect(sftpBytesOf(name), bytes);
      }
    });

    test('a name in Latin-1 keeps its bytes, and is a well formed string', () {
      final name = sftpNameOf(latin1Name);
      expect(name, 'caf${String.fromCharCode(sftpRawByteBase + 0xE9)}.txt');
      expect(wellFormed(name), isTrue);
      expect(sftpBytesOf(name), latin1Name);
      expect(sftpBytesOf('/srv/$name'), [...'/srv/'.codeUnits, ...latin1Name]);
    });

    test('what is no UTF-8 comes back as it was', () {
      for (final bytes in <List<int>>[
        [0x80],
        [0xFF, 0xFE],
        [0xC3], // cut short at the end
        [0xE4, 0xB8, 0x41], // cut short by a letter
        [0xC0, 0xAF], // overlong
        [0xE0, 0x80, 0xAF], // overlong
        [0xED, 0xA0, 0x80], // a surrogate
        [0xF4, 0x90, 0x80, 0x80], // past U+10FFFF
        [0xF5, 0x80, 0x80, 0x80],
        for (var b = 0x80; b <= 0xFF; b++) [0x61, b, 0x62],
      ]) {
        expect(roundTrip(bytes), bytes, reason: '$bytes');
        expect(wellFormed(sftpNameOf(Uint8List.fromList(bytes))), isTrue);
      }
    });

    test('a name with the very characters that stand for bytes, in UTF-8, comes back whole', () {
      final name = 'x${String.fromCharCode(sftpRawByteBase + 0x90)}y';
      final bytes = utf8.encode(name);
      expect(roundTrip(bytes), bytes);
    });

    test('any bytes come back as they were', () {
      final random = Random(5);
      for (var n = 0; n < 2000; n++) {
        final bytes = [for (var i = random.nextInt(24); i > 0; i--) random.nextInt(256)];
        expect(roundTrip(bytes), bytes, reason: '$bytes');
      }
    });
  });

  test('each request that names a path sends its bytes', () {
    final name = '/srv/${sftpNameOf(latin1Name)}';
    final raw = [...'/srv/'.codeUnits, ...latin1Name];
    List<int> firstPath(Uint8List packet) => (SSHMessageReader(packet)
          ..readUint8()
          ..readUint32())
        .readString();

    expect(firstPath(SftpOpenPacket(1, name, 1, SftpFileAttrs()).encode()), raw);
    expect(firstPath(SftpLStatPacket(1, name).encode()), raw);
    expect(firstPath(SftpOpenDirPacket(1, name).encode()), raw);
    expect(firstPath(SftpRemovePacket(1, name).encode()), raw);
    expect(firstPath(SftpRmdirPacket(1, name).encode()), raw);
    expect(firstPath(SftpRealpathPacket(1, name).encode()), raw);
    expect(firstPath(SftpReadlinkPacket(1, name).encode()), raw);

    final rename = SSHMessageReader(SftpRenamePacket(1, name, '$name.old').encode())
      ..readUint8()
      ..readUint32();
    expect(rename.readString(), raw);
    expect(rename.readString(), [...raw, ...'.old'.codeUnits]);
    expect(SftpRenamePacket.decode(SftpRenamePacket(1, name, 'b').encode()).oldPath, name);

    final posix = SSHMessageReader(SftpPosixRenameRequest(oldPath: name, newPath: 'b').encode())..readString();
    expect(posix.readString(), raw);
  });
}
