import 'dart:convert';

/// The text of a stream of UTF-8 bytes that comes in pieces, piece by piece.
/// A character that a piece ends inside of waits for the rest of it in the
/// next piece. Decoded piece by piece on their own, such a character was
/// shown as replacement characters: two reads of a host's output (two SSH
/// packets, two pty reads) can cut one anywhere (found in a code review).
/// What is no UTF-8 is a replacement character, never
/// a throw.
class Utf8Chunks {
  Utf8Chunks() {
    _in = _open();
  }

  final _out = StringBuffer();
  late ByteConversionSink _in;

  ByteConversionSink _open() => const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(StringConversionSink.fromStringSink(_out));

  /// The text [bytes] complete; a character they end inside of comes with
  /// the next piece.
  String decode(List<int> bytes) {
    _in.add(bytes);
    return _take();
  }

  /// The end of the stream: a character left cut short is a replacement
  /// character. What comes after starts again from nothing.
  String finish() {
    _in.close();
    final rest = _take();
    _in = _open();
    return rest;
  }

  String _take() {
    if (_out.isEmpty) return '';
    final text = _out.toString();
    _out.clear();
    return text;
  }
}
