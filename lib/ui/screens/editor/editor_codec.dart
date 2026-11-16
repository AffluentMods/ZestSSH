import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/utils/type_name.dart';

/// The encodings the file editor reads and writes a file in (3.4). A file
/// that is not UTF-8 opens in the closest match with a notice instead of
/// being refused, and the status bar can reopen it in, or save it with,
/// another.
enum EditorEncoding {
  utf8('UTF-8'),
  utf8Bom('UTF-8 with BOM'),
  windows1252('Windows-1252'),
  latin1('ISO-8859-1'),
  latin9('ISO-8859-15'),
  utf16le('UTF-16 LE'),
  utf16be('UTF-16 BE');

  const EditorEncoding(this.label);

  /// Its name, the same in every language.
  final String label;

  /// Whether every character there is can be written in it.
  bool get isUnicode => this == utf8 || this == utf8Bom || this == utf16le || this == utf16be;
}

/// The line breaks a file has: kept as they were when it is saved, and
/// changed only when asked.
enum EditorLineBreak {
  lf('LF', '\n'),
  crlf('CRLF', '\r\n'),
  cr('CR', '\r');

  const EditorLineBreak(this.label, this.chars);

  final String label;
  final String chars;
}

/// A character the encoding chosen to save with has no byte for: the save is
/// refused, the text is kept, and the status bar says which encoding to pick.
class EditorEncodeException implements Exception, HasTypeName {
  const EditorEncodeException(this.encoding, this.char, this.line);

  final EditorEncoding encoding;

  /// The first character that does not fit, and its line (from 1).
  final String char;
  final int line;

  @override
  String toString() => 'EditorEncodeException: U+${char.runes.first.toRadixString(16).toUpperCase().padLeft(4, '0')} '
      'on line $line has no byte in ${encoding.label}';

  @override
  String get typeName => 'EditorEncodeException';
}

/// What a file's bytes read as: the text with its line breaks made '\n' (the
/// editor works in lines), and what to write it back with.
class DecodedFile {
  const DecodedFile({
    required this.text,
    required this.encoding,
    required this.lineBreak,
    this.mixedLineBreaks = false,
    this.notUtf8 = false,
  });

  final String text;
  final EditorEncoding encoding;
  final EditorLineBreak lineBreak;

  /// The file had more than one kind of line break: it is saved with the
  /// one it had most of.
  final bool mixedLineBreaks;

  /// It was not UTF-8 and was opened in the closest match ([encoding]), for
  /// the one-line notice that says so.
  final bool notUtf8;
}

abstract final class EditorCodec {
  /// [bytes] read as text: in [as] where given, else by its byte order mark,
  /// else UTF-8 where it is, else Windows-1252 (the closest match for the
  /// text files of a Western server that are not UTF-8: every byte reads as
  /// something, so nothing is lost, and saving it back gives the same bytes).
  static DecodedFile decode(List<int> bytes, {EditorEncoding? as}) {
    var encoding = as;
    var notUtf8 = false;
    if (encoding == null) {
      if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
        encoding = EditorEncoding.utf8Bom;
      } else if (_startsWith(bytes, const [0xFF, 0xFE])) {
        encoding = EditorEncoding.utf16le;
      } else if (_startsWith(bytes, const [0xFE, 0xFF])) {
        encoding = EditorEncoding.utf16be;
      } else {
        try {
          const Utf8Decoder().convert(bytes);
          encoding = EditorEncoding.utf8;
        } on FormatException {
          encoding = EditorEncoding.windows1252;
          notUtf8 = true;
        }
      }
    }
    final raw = _decode(bytes, encoding);
    final crlf = '\r\n'.allMatches(raw).length;
    final crOnly = '\r'.allMatches(raw).length - crlf;
    final lfOnly = '\n'.allMatches(raw).length - crlf;
    final kinds = [crlf, crOnly, lfOnly].where((n) => n > 0).length;
    final EditorLineBreak lineBreak;
    if (crlf >= lfOnly && crlf >= crOnly && crlf > 0) {
      lineBreak = EditorLineBreak.crlf;
    } else if (crOnly > lfOnly && crOnly > 0) {
      lineBreak = EditorLineBreak.cr;
    } else {
      lineBreak = EditorLineBreak.lf;
    }
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return DecodedFile(
      text: text,
      encoding: encoding,
      lineBreak: lineBreak,
      mixedLineBreaks: kinds > 1,
      notUtf8: notUtf8,
    );
  }

  /// [text] (lines broken by '\n') as the bytes of a file in [encoding] with
  /// [lineBreak]. Throws [EditorEncodeException] where a character has no
  /// byte in [encoding].
  static Uint8List encode(String text, EditorEncoding encoding, EditorLineBreak lineBreak) {
    final withBreaks = lineBreak == EditorLineBreak.lf ? text : text.replaceAll('\n', lineBreak.chars);
    switch (encoding) {
      case EditorEncoding.utf8:
        return Uint8List.fromList(const Utf8Encoder().convert(withBreaks));
      case EditorEncoding.utf8Bom:
        return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...const Utf8Encoder().convert(withBreaks)]);
      case EditorEncoding.utf16le:
      case EditorEncoding.utf16be:
        final little = encoding == EditorEncoding.utf16le;
        final units = withBreaks.codeUnits;
        final out = Uint8List(2 + units.length * 2);
        out[0] = little ? 0xFF : 0xFE;
        out[1] = little ? 0xFE : 0xFF;
        for (var i = 0; i < units.length; i++) {
          final u = units[i];
          out[2 + i * 2] = little ? u & 0xFF : u >> 8;
          out[3 + i * 2] = little ? u >> 8 : u & 0xFF;
        }
        return out;
      case EditorEncoding.latin1:
      case EditorEncoding.latin9:
      case EditorEncoding.windows1252:
        final table = _reverse(encoding);
        final out = Uint8List(withBreaks.length);
        var n = 0;
        var line = 1;
        for (final rune in withBreaks.runes) {
          if (rune == 0x0A) line++;
          final b = rune < 0x80 ? rune : table[rune];
          if (b == null) {
            throw EditorEncodeException(encoding, String.fromCharCode(rune), line);
          }
          out[n++] = b;
        }
        return Uint8List.sublistView(out, 0, n);
    }
  }

  static bool _startsWith(List<int> bytes, List<int> head) {
    if (bytes.length < head.length) return false;
    for (var i = 0; i < head.length; i++) {
      if (bytes[i] != head[i]) return false;
    }
    return true;
  }

  static String _decode(List<int> bytes, EditorEncoding encoding) {
    switch (encoding) {
      case EditorEncoding.utf8:
        // Read as UTF-8 even with a mark at its start, which is then kept as
        // the character it is (the person chose plain UTF-8 for it).
        return const Utf8Decoder(allowMalformed: true).convert(bytes);
      case EditorEncoding.utf8Bom:
        final body = _startsWith(bytes, const [0xEF, 0xBB, 0xBF]) ? bytes.sublist(3) : bytes;
        return const Utf8Decoder(allowMalformed: true).convert(body);
      case EditorEncoding.utf16le:
      case EditorEncoding.utf16be:
        final little = encoding == EditorEncoding.utf16le;
        var start = 0;
        if (_startsWith(bytes, little ? const [0xFF, 0xFE] : const [0xFE, 0xFF])) start = 2;
        final units = <int>[];
        for (var i = start; i + 1 < bytes.length; i += 2) {
          units.add(little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
        }
        return String.fromCharCodes(units);
      case EditorEncoding.latin1:
        return const Latin1Decoder().convert(bytes);
      case EditorEncoding.latin9:
      case EditorEncoding.windows1252:
        final high = encoding == EditorEncoding.latin9 ? _latin9 : _cp1252;
        final sb = StringBuffer();
        for (final b in bytes) {
          sb.writeCharCode(high[b] ?? b);
        }
        return sb.toString();
    }
  }

  static final Map<EditorEncoding, Map<int, int>> _reverseTables = {};

  /// Character to byte, for the single-byte encodings.
  static Map<int, int> _reverse(EditorEncoding encoding) => _reverseTables.putIfAbsent(encoding, () {
        final out = <int, int>{};
        for (var b = 0x80; b <= 0xFF; b++) {
          final mapped = switch (encoding) {
            EditorEncoding.windows1252 => _cp1252[b] ?? b,
            EditorEncoding.latin9 => _latin9[b] ?? b,
            _ => b,
          };
          // Windows-1252 leaves five bytes unset; they read as the control
          // character of the same number and write back as that byte.
          out[mapped] = b;
        }
        return out;
      });

  /// Where Windows-1252 differs from ISO-8859-1 (0x80 to 0x9F).
  static const Map<int, int> _cp1252 = {
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
    0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D,
    0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
    0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
  };

  /// Where ISO-8859-15 differs from ISO-8859-1.
  static const Map<int, int> _latin9 = {
    0xA4: 0x20AC, 0xA6: 0x0160, 0xA8: 0x0161, 0xB4: 0x017D, 0xB8: 0x017E, 0xBC: 0x0152, 0xBD: 0x0153,
    0xBE: 0x0178,
  };
}
