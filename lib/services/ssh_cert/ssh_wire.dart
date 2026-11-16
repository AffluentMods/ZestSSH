import 'dart:typed_data';

/// Reader for SSH wire-format byte streams (RFC 4251 §5).
///
/// Used by [SshCertParser]. The format is the same one OpenSSH uses for
/// every key, signature, and certificate blob: length-prefixed strings,
/// uint32 / uint64, mpint. We keep it independent of the `dartssh` fork
/// so the parser can be unit-tested in isolation without spinning up a
/// connection.
class SshWireReader {
  SshWireReader(this._bytes) : _offset = 0;

  final Uint8List _bytes;
  int _offset;

  /// Bytes consumed so far.
  int get position => _offset;

  /// Bytes remaining.
  int get remaining => _bytes.length - _offset;

  bool get isExhausted => _offset >= _bytes.length;

  /// Total length of the underlying byte buffer.
  int get totalLength => _bytes.length;

  /// Read [count] raw bytes; throws [FormatException] on underflow.
  Uint8List readBytes(int count) {
    if (count < 0) {
      throw const FormatException('SSH wire: negative byte count');
    }
    if (_offset + count > _bytes.length) {
      throw FormatException(
          'SSH wire: read past end (need $count, have $remaining)');
    }
    final out = Uint8List.sublistView(_bytes, _offset, _offset + count);
    _offset += count;
    return Uint8List.fromList(out);
  }

  /// Read a uint8.
  int readUint8() {
    if (_offset + 1 > _bytes.length) {
      throw const FormatException('SSH wire: truncated uint8');
    }
    return _bytes[_offset++];
  }

  /// Read a big-endian uint32.
  int readUint32() {
    if (_offset + 4 > _bytes.length) {
      throw const FormatException('SSH wire: truncated uint32');
    }
    final v = (_bytes[_offset] << 24) |
        (_bytes[_offset + 1] << 16) |
        (_bytes[_offset + 2] << 8) |
        _bytes[_offset + 3];
    _offset += 4;
    return v;
  }

  /// Read a big-endian uint64. Returned as Dart `int` - valid for
  /// values that fit (always true for cert serial / unix-second timestamps
  /// in any plausible range).
  int readUint64() {
    if (_offset + 8 > _bytes.length) {
      throw const FormatException('SSH wire: truncated uint64');
    }
    final hi = (_bytes[_offset] << 24) |
        (_bytes[_offset + 1] << 16) |
        (_bytes[_offset + 2] << 8) |
        _bytes[_offset + 3];
    final lo = (_bytes[_offset + 4] << 24) |
        (_bytes[_offset + 5] << 16) |
        (_bytes[_offset + 6] << 8) |
        _bytes[_offset + 7];
    _offset += 8;
    // Reconstruct via shift to avoid Dart's implicit truncation
    // surprises. Dart `int` is 64-bit on native; on web this would
    // round at 2^53 - we don't run cert parsing on web.
    return (hi << 32) | (lo & 0xFFFFFFFF);
  }

  /// Read a length-prefixed byte string. Reject lengths large enough to
  /// suggest garbage or a malicious blob (4 MiB cap is well above the
  /// largest legitimate SSH cert field - RSA-8192 keys are ~2 KB).
  Uint8List readString({int maxLength = 4 * 1024 * 1024}) {
    final len = readUint32();
    if (len < 0 || len > maxLength) {
      throw FormatException(
          'SSH wire: string length $len exceeds cap $maxLength');
    }
    return readBytes(len);
  }

  /// Read a length-prefixed UTF-8 string.
  String readUtf8String({int maxLength = 4 * 1024 * 1024}) {
    final bytes = readString(maxLength: maxLength);
    try {
      // Use latin1 fallback when bytes are not valid UTF-8 - some
      // legacy comments / key ids carry bytes outside ASCII.
      return String.fromCharCodes(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  /// Read a big-endian mpint (RFC 4251 §5).
  /// Returns the raw bytes (without the leading 00 padding byte if
  /// present). Caller decides whether to interpret as BigInt.
  Uint8List readMpint() {
    return readString();
  }

  /// Sub-reader that consumes a length-prefixed blob and returns a
  /// reader over its contents. Used to walk into "principals" lists
  /// and key-value option lists.
  SshWireReader readSubReader() {
    return SshWireReader(readString());
  }

  /// Bytes read so far. Useful for capturing the "to be signed" prefix
  /// when validating a cert signature.
  Uint8List bytesUpToHere() {
    return Uint8List.sublistView(_bytes, 0, _offset);
  }
}

/// Builder for SSH wire-format byte streams.
class SshWireWriter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  Uint8List takeBytes() => _buf.toBytes();
  int get length => _buf.length;

  void writeBytes(List<int> bytes) {
    _buf.add(bytes);
  }

  void writeUint8(int v) {
    _buf.addByte(v & 0xFF);
  }

  void writeUint32(int v) {
    _buf.addByte((v >> 24) & 0xFF);
    _buf.addByte((v >> 16) & 0xFF);
    _buf.addByte((v >> 8) & 0xFF);
    _buf.addByte(v & 0xFF);
  }

  void writeUint64(int v) {
    final hi = (v >> 32) & 0xFFFFFFFF;
    final lo = v & 0xFFFFFFFF;
    writeUint32(hi);
    writeUint32(lo);
  }

  void writeString(List<int> data) {
    writeUint32(data.length);
    _buf.add(data);
  }

  void writeUtf8String(String s) {
    final bytes = s.codeUnits;
    // For pure-ASCII strings (the common case for principals, key ids,
    // option names) codeUnits == utf8 bytes. For non-ASCII we want the
    // full utf8 encoding.
    final hasNonAscii = bytes.any((c) => c > 0x7F);
    final out = hasNonAscii
        ? const _Utf8Codec().encode(s)
        : Uint8List.fromList(bytes);
    writeString(out);
  }
}

/// Tiny private UTF-8 encoder so this file has zero non-Dart deps.
class _Utf8Codec {
  const _Utf8Codec();

  Uint8List encode(String s) {
    final out = <int>[];
    for (final cp in s.runes) {
      if (cp < 0x80) {
        out.add(cp);
      } else if (cp < 0x800) {
        out.add(0xC0 | (cp >> 6));
        out.add(0x80 | (cp & 0x3F));
      } else if (cp < 0x10000) {
        out.add(0xE0 | (cp >> 12));
        out.add(0x80 | ((cp >> 6) & 0x3F));
        out.add(0x80 | (cp & 0x3F));
      } else {
        out.add(0xF0 | (cp >> 18));
        out.add(0x80 | ((cp >> 12) & 0x3F));
        out.add(0x80 | ((cp >> 6) & 0x3F));
        out.add(0x80 | (cp & 0x3F));
      }
    }
    return Uint8List.fromList(out);
  }
}
