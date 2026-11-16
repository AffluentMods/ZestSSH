// SPDX-License-Identifier: MIT
import 'dart:convert';
import 'dart:typed_data';

import 'package:zest_ssh_core/src/ssh_message.dart';

/// What a server calls a file is bytes, in whatever encoding its file system
/// has: SFTP version 3 says nothing of one, and an old name in Latin-1
/// (`caf\xE9.txt`) is no UTF-8. Read as UTF-8 with U+FFFD for what is not,
/// such a name was listed, and every request made with it (stat, open,
/// remove, rename) sent other bytes than the file has: it could not be
/// opened, downloaded, renamed or deleted, and a recursive delete of its
/// folder stopped at it.
///
/// So a name or path from a server is read by [sftpNameOf]: what is UTF-8 is
/// its characters, and each byte that is not stands as the character
/// U+10FE00 plus the byte (U+10FE80 to U+10FEFF, private use, which a font
/// draws as an unknown character). [sftpBytesOf] writes those characters
/// back as those bytes and the rest as UTF-8, so a name that came from the
/// server is asked for with the bytes it has. A name that is UTF-8 is read
/// and written as ever; one with the very characters of that range in it as
/// UTF-8 has their bytes stand for themselves, so it comes back whole too.
/// The string stays well formed: a lone surrogate, as Python stands a byte
/// for, cannot be drawn by Flutter.
const int sftpRawByteBase = 0x10FE00;

bool _isRawByteChar(int rune) => rune >= sftpRawByteBase + 0x80 && rune <= sftpRawByteBase + 0xFF;

/// The name [bytes] as a string; see [sftpRawByteBase].
String sftpNameOf(Uint8List bytes) {
  var ascii = true;
  for (final b in bytes) {
    if (b >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return String.fromCharCodes(bytes);

  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i++;
      continue;
    }
    final rune = _runeAt(bytes, i);
    if (rune == null || _isRawByteChar(rune.$1)) {
      out.writeCharCode(sftpRawByteBase + b);
      i++;
    } else {
      out.writeCharCode(rune.$1);
      i += rune.$2;
    }
  }
  return out.toString();
}

/// The character UTF-8 has at [i] of [bytes], and its length, or null where
/// what is there is no UTF-8 (RFC 3629: no overlong form, no surrogate,
/// nothing past U+10FFFF).
(int, int)? _runeAt(Uint8List bytes, int i) {
  final b = bytes[i];
  final int length;
  int rune;
  final int least;
  if (b >= 0xC2 && b <= 0xDF) {
    length = 2;
    rune = b & 0x1F;
    least = 0x80;
  } else if (b >= 0xE0 && b <= 0xEF) {
    length = 3;
    rune = b & 0x0F;
    least = 0x800;
  } else if (b >= 0xF0 && b <= 0xF4) {
    length = 4;
    rune = b & 0x07;
    least = 0x10000;
  } else {
    return null;
  }
  if (i + length > bytes.length) return null;
  for (var k = 1; k < length; k++) {
    final c = bytes[i + k];
    if (c & 0xC0 != 0x80) return null;
    rune = (rune << 6) | (c & 0x3F);
  }
  if (rune < least || rune > 0x10FFFF || (rune >= 0xD800 && rune <= 0xDFFF)) return null;
  return (rune, length);
}

/// The bytes the name [name] stands for; see [sftpRawByteBase].
Uint8List sftpBytesOf(String name) {
  // U+10FE80 to U+10FEFF in UTF-16: the high surrogate 0xDBFF, then 0xDE80
  // to 0xDEFF.
  var raw = false;
  for (var i = 0; i + 1 < name.length; i++) {
    if (name.codeUnitAt(i) == 0xDBFF) {
      final low = name.codeUnitAt(i + 1);
      if (low >= 0xDE80 && low <= 0xDEFF) {
        raw = true;
        break;
      }
    }
  }
  if (!raw) return utf8.encode(name);

  final out = BytesBuilder(copy: false);
  final text = StringBuffer();
  void flushText() {
    if (text.isEmpty) return;
    out.add(utf8.encode(text.toString()));
    text.clear();
  }

  for (final rune in name.runes) {
    if (_isRawByteChar(rune)) {
      flushText();
      out.addByte(rune - sftpRawByteBase);
    } else {
      text.writeCharCode(rune);
    }
  }
  flushText();
  return out.takeBytes();
}

/// [sftpNameOf] and [sftpBytesOf] for the names and paths of SFTP packets.
extension SftpNameReader on SSHMessageReader {
  String readSftpName() => sftpNameOf(readString());
}

extension SftpNameWriter on SSHMessageWriter {
  void writeSftpName(String name) => writeString(sftpBytesOf(name));
}
