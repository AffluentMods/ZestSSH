// The part of CBOR (RFC 8949) that CTAP2 speaks, and no more: whole numbers,
// byte strings, text strings, arrays, maps, true, false and null, every
// length said up front. A security key's answers are read with this, so
// what it reads is bounded: how deep, how many items, how long, and nothing
// it does not know (a tag, a float, a length left open, an integer the
// language cannot hold) is taken.
//
// What is read is plain Dart: int, Uint8List (a byte string), String, List,
// Map (keys int or String), bool, null.
import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/utils/type_name.dart';
/// What was read is not CBOR this reader takes; [message] says why.
class CborError implements Exception, HasTypeName {
  const CborError(this.message);

  final String message;

  @override
  String toString() => 'CBOR: $message';

  @override
  String get typeName => 'CborError';
}

/// How deep arrays and maps may nest. CTAP2's deepest answer nests four.
const int kCborMaxDepth = 8;

/// How many values one message may hold in all.
const int kCborMaxItems = 4096;

/// [value] as CTAP2's canonical CBOR: the shortest form of every number and
/// length, and a map's keys in CTAP2's order (whole numbers before text, a
/// shorter key before a longer one, then by their bytes).
Uint8List cborEncode(Object? value) {
  final out = BytesBuilder(copy: false);
  _write(out, value, 0);
  return out.toBytes();
}

void _head(BytesBuilder out, int major, int n) {
  final m = major << 5;
  if (n < 24) {
    out.addByte(m | n);
  } else if (n < 0x100) {
    out
      ..addByte(m | 24)
      ..addByte(n);
  } else if (n < 0x10000) {
    out
      ..addByte(m | 25)
      ..addByte(n >> 8)
      ..addByte(n & 0xff);
  } else if (n < 0x100000000) {
    out
      ..addByte(m | 26)
      ..add([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
  } else {
    out
      ..addByte(m | 27)
      ..add([for (var shift = 56; shift >= 0; shift -= 8) (n >> shift) & 0xff]);
  }
}

void _write(BytesBuilder out, Object? value, int depth) {
  if (depth > kCborMaxDepth) throw const CborError('nested too deep to write');
  switch (value) {
    case null:
      out.addByte(0xf6);
    case final bool b:
      out.addByte(b ? 0xf5 : 0xf4);
    case final int n:
      if (n >= 0) {
        _head(out, 0, n);
      } else {
        _head(out, 1, -1 - n);
      }
    case final Uint8List bytes:
      _head(out, 2, bytes.length);
      out.add(bytes);
    case final String text:
      final bytes = utf8.encode(text);
      _head(out, 3, bytes.length);
      out.add(bytes);
    case final List<Object?> list:
      _head(out, 4, list.length);
      for (final item in list) {
        _write(out, item, depth + 1);
      }
    case final Map<Object?, Object?> map:
      final entries = <(Uint8List, Object?)>[];
      for (final e in map.entries) {
        final key = e.key;
        if (key is! int && key is! String) throw const CborError('a map key that is neither a number nor text');
        entries.add((cborEncode(key), e.value));
      }
      entries.sort((a, b) => _compareKeys(a.$1, b.$1));
      for (var i = 1; i < entries.length; i++) {
        if (_compareKeys(entries[i - 1].$1, entries[i].$1) == 0) throw const CborError('a map key written twice');
      }
      _head(out, 5, entries.length);
      for (final (key, item) in entries) {
        out.add(key);
        _write(out, item, depth + 1);
      }
    default:
      throw const CborError('a value CBOR here does not write');
  }
}

/// CTAP2's order of two encoded keys: the lower major type first, then the
/// shorter, then the lower byte by byte.
int _compareKeys(Uint8List a, Uint8List b) {
  final major = (a[0] >> 5) - (b[0] >> 5);
  if (major != 0) return major;
  if (a.length != b.length) return a.length - b.length;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return 0;
}

/// The one value [bytes] hold. Throws [CborError] on anything else: bytes
/// left over, a value cut short, or what this reader does not take.
Object? cborDecode(Uint8List bytes) {
  final (value, end) = cborDecodeFirst(bytes);
  if (end != bytes.length) throw CborError('${bytes.length - end} bytes after the value');
  return value;
}

/// The first value in [bytes] and where it ends: a security key's
/// attestation data carries a CBOR key with other bytes after it.
(Object?, int) cborDecodeFirst(Uint8List bytes, [int start = 0]) {
  final reader = _Reader(bytes, start);
  final value = reader.read(0);
  return (value, reader.at);
}

class _Reader {
  _Reader(this.bytes, this.at);

  final Uint8List bytes;
  int at;
  int items = 0;

  int _byte() {
    if (at >= bytes.length) throw const CborError('cut short');
    return bytes[at++];
  }

  /// The number in a head whose low five bits are [info].
  int _number(int info) {
    if (info < 24) return info;
    final int width;
    switch (info) {
      case 24:
        width = 1;
      case 25:
        width = 2;
      case 26:
        width = 4;
      case 27:
        width = 8;
      case 31:
        throw const CborError('a length left open');
      default:
        throw const CborError('a head that means nothing');
    }
    if (bytes.length - at < width) throw const CborError('cut short');
    var n = 0;
    for (var i = 0; i < width; i++) {
      final b = bytes[at++];
      // (Eight bytes with the top bit set is more than a Dart int holds.)
      if (width == 8 && i == 0 && b > 0x7f) throw const CborError('a number too large');
      n = (n << 8) | b;
    }
    return n;
  }

  Uint8List _take(int length) {
    if (length > bytes.length - at) throw const CborError('a string longer than what is left');
    final out = Uint8List.sublistView(bytes, at, at + length);
    at += length;
    return Uint8List.fromList(out);
  }

  Object? read(int depth) {
    if (depth > kCborMaxDepth) throw const CborError('nested too deep');
    if (++items > kCborMaxItems) throw const CborError('too many values');
    final head = _byte();
    final major = head >> 5;
    final info = head & 0x1f;
    switch (major) {
      case 0:
        return _number(info);
      case 1:
        return -1 - _number(info);
      case 2:
        return _take(_number(info));
      case 3:
        try {
          return utf8.decode(_take(_number(info)));
        } on FormatException {
          throw const CborError('text that is not UTF-8');
        }
      case 4:
        final n = _number(info);
        // (Each item is a byte at least: a count beyond what is left is a lie.)
        if (n > bytes.length - at) throw const CborError('an array longer than what is left');
        return [for (var i = 0; i < n; i++) read(depth + 1)];
      case 5:
        final n = _number(info);
        if (n > (bytes.length - at) ~/ 2) throw const CborError('a map longer than what is left');
        final map = <Object, Object?>{};
        for (var i = 0; i < n; i++) {
          final key = read(depth + 1);
          if (key == null || (key is! int && key is! String)) {
            throw const CborError('a map key that is neither a number nor text');
          }
          if (map.containsKey(key)) throw const CborError('a map key twice');
          map[key] = read(depth + 1);
        }
        return map;
      case 6:
        throw const CborError('a tag');
      default:
        switch (info) {
          case 20:
            return false;
          case 21:
            return true;
          case 22:
            return null;
          default:
            throw const CborError('a simple value or a float');
        }
    }
  }
}
