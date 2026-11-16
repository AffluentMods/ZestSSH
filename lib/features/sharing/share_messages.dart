/// Session sharing (3.0): what a live view says inside its secure channel
/// (share_channel.dart). One message per frame; the first byte is its kind.
///
/// From the host to a viewer:
///   screen    the terminal as it is now, to start from: its size and the
///             escape sequences that rebuild it (terminal_snapshot.dart).
///             Longer than one frame, it continues in output messages.
///   output    what the terminal was sent since, as UTF-8 text.
///   resize    the terminal's new size.
///   keyboard  who may type now: this viewer, the host, or someone else.
///   end       the host stopped sharing, the session closed, or this viewer
///             was removed.
///
/// From a viewer to the host:
///   ready        "send me the screen" (at the start, and to start again).
///   input        keys to type. The host types them only while this viewer
///                holds the keyboard; at any other time they are dropped.
///   askKeyboard  asks for the keyboard. The host's person decides.
///   giveBack     hands the keyboard back.
///   leave        the viewer is going.
///   endSession   ends the shared session itself (session moderation).
///                The host acts on it only from someone it invited to; from
///                anyone else it is dropped.
///   ack          how many of the host's frames this viewer has taken so
///                far. The host sends output only while the viewer is within
///                a window of it; a viewer that falls behind gets no more
///                until it has caught up, and then the screen afresh. So a
///                flood of output never piles up anywhere: not on the host,
///                not on the relay, not on a slow phone.
///
/// A message that is not one of these, is of the wrong shape, or comes from
/// the wrong side is a [FormatException]: the receiver ends the channel
/// rather than guess.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/features/sharing/share_channel.dart';

/// The largest terminal either side accepts. Larger is not a terminal.
const int kShareMaxColumns = 1000;
const int kShareMaxRows = 500;

/// The most text an output or screen message carries, and the most keys an
/// input message carries. A paste longer than that is several messages.
const int kShareOutputMax = kShareFramePlainMax - 16;
const int kShareInputMax = 4096;

/// Why a live view ended.
enum ShareEndReason {
  /// The host stopped sharing.
  stopped,

  /// The shared session itself closed.
  sessionClosed,

  /// The host removed this viewer.
  removed,
}

/// Who holds the keyboard, as one viewer is told it.
enum ShareKeyboard {
  /// The host types; this viewer watches.
  host,

  /// This viewer types.
  you,

  /// Another viewer types.
  someoneElse,
}

sealed class ShareMessage {
  const ShareMessage();

  /// The bytes to seal into one frame.
  Uint8List encode();

  /// Whether the host sends it (true) or a viewer does (false).
  bool get fromHost;

  static const int _screen = 0x01;
  static const int _output = 0x02;
  static const int _resize = 0x03;
  static const int _keyboard = 0x04;
  static const int _end = 0x05;
  static const int _ready = 0x11;
  static const int _input = 0x12;
  static const int _askKeyboard = 0x13;
  static const int _giveBack = 0x14;
  static const int _leave = 0x15;
  static const int _ack = 0x16;
  static const int _endSession = 0x17;

  /// Reads a message a viewer received ([fromHost] true) or the host
  /// received (false). Throws [FormatException] for anything else.
  static ShareMessage decode(List<int> bytes, {required bool fromHost}) {
    if (bytes.isEmpty) throw const FormatException('an empty message');
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final body = Uint8List.sublistView(data, 1);
    final kind = data[0];
    if (fromHost) {
      switch (kind) {
        case _screen:
          if (body.length < 4) throw const FormatException('a short screen');
          final view = ByteData.sublistView(body);
          return ShareScreen(
            columns: _size(view.getUint16(0), kShareMaxColumns),
            rows: _size(view.getUint16(2), kShareMaxRows),
            text: _text(Uint8List.sublistView(body, 4)),
          );
        case _output:
          return ShareOutput(_text(body));
        case _resize:
          if (body.length != 4) throw const FormatException('a resize is 4 bytes');
          final view = ByteData.sublistView(body);
          return ShareResize(
            columns: _size(view.getUint16(0), kShareMaxColumns),
            rows: _size(view.getUint16(2), kShareMaxRows),
          );
        case _keyboard:
          if (body.length != 1 || body[0] >= ShareKeyboard.values.length) {
            throw const FormatException('not a keyboard state');
          }
          return ShareKeyboardState(ShareKeyboard.values[body[0]]);
        case _end:
          if (body.length != 1 || body[0] >= ShareEndReason.values.length) {
            throw const FormatException('not an end');
          }
          return ShareEnd(ShareEndReason.values[body[0]]);
      }
    } else {
      switch (kind) {
        case _ready:
          if (body.isNotEmpty) throw const FormatException('ready carries nothing');
          return const ShareReady();
        case _input:
          if (body.isEmpty || body.length > kShareInputMax) {
            throw const FormatException('input of the wrong size');
          }
          return ShareInput(Uint8List.fromList(body));
        case _askKeyboard:
          if (body.isNotEmpty) throw const FormatException('a request carries nothing');
          return const ShareAskKeyboard();
        case _giveBack:
          if (body.isNotEmpty) throw const FormatException('a hand-back carries nothing');
          return const ShareGiveBack();
        case _leave:
          if (body.isNotEmpty) throw const FormatException('leave carries nothing');
          return const ShareLeave();
        case _ack:
          if (body.length != 8) throw const FormatException('an ack is 8 bytes');
          final received = ByteData.sublistView(body).getUint64(0);
          if (received < 0) throw const FormatException('not a count');
          return ShareAck(received);
        case _endSession:
          if (body.isNotEmpty) throw const FormatException('ending carries nothing');
          return const ShareEndSession();
      }
    }
    throw FormatException('not a message for this side: $kind');
  }

  static int _size(int value, int max) {
    if (value < 1 || value > max) throw const FormatException('not a terminal size');
    return value;
  }

  static String _text(Uint8List bytes) {
    if (bytes.length > kShareOutputMax) throw const FormatException('too much output');
    // Malformed UTF-8 is not something the host ever sends.
    return utf8.decode(bytes);
  }
}

Uint8List _framed(int kind, [List<int> body = const []]) =>
    Uint8List.fromList([kind, ...body]);

Uint8List _sizes(int columns, int rows) {
  final out = ByteData(4)
    ..setUint16(0, columns)
    ..setUint16(2, rows);
  return out.buffer.asUint8List();
}

/// The terminal as it is now. The viewer empties its own terminal, makes it
/// [columns] by [rows], and writes [text].
class ShareScreen extends ShareMessage {
  const ShareScreen({required this.columns, required this.rows, required this.text});
  final int columns;
  final int rows;
  final String text;

  @override
  bool get fromHost => true;

  @override
  Uint8List encode() =>
      _framed(ShareMessage._screen, [..._sizes(columns, rows), ...utf8.encode(text)]);
}

/// What the terminal was sent since the last message.
class ShareOutput extends ShareMessage {
  const ShareOutput(this.text);
  final String text;

  @override
  bool get fromHost => true;

  @override
  Uint8List encode() => _framed(ShareMessage._output, utf8.encode(text));
}

class ShareResize extends ShareMessage {
  const ShareResize({required this.columns, required this.rows});
  final int columns;
  final int rows;

  @override
  bool get fromHost => true;

  @override
  Uint8List encode() => _framed(ShareMessage._resize, _sizes(columns, rows));
}

class ShareKeyboardState extends ShareMessage {
  const ShareKeyboardState(this.holder);
  final ShareKeyboard holder;

  @override
  bool get fromHost => true;

  @override
  Uint8List encode() => _framed(ShareMessage._keyboard, [holder.index]);
}

class ShareEnd extends ShareMessage {
  const ShareEnd(this.reason);
  final ShareEndReason reason;

  @override
  bool get fromHost => true;

  @override
  Uint8List encode() => _framed(ShareMessage._end, [reason.index]);
}

class ShareReady extends ShareMessage {
  const ShareReady();

  @override
  bool get fromHost => false;

  @override
  Uint8List encode() => _framed(ShareMessage._ready);
}

/// Keys to type, as the bytes the viewer's terminal would have sent.
class ShareInput extends ShareMessage {
  const ShareInput(this.bytes);
  final Uint8List bytes;

  @override
  bool get fromHost => false;

  @override
  Uint8List encode() => _framed(ShareMessage._input, bytes);
}

class ShareAskKeyboard extends ShareMessage {
  const ShareAskKeyboard();

  @override
  bool get fromHost => false;

  @override
  Uint8List encode() => _framed(ShareMessage._askKeyboard);
}

class ShareGiveBack extends ShareMessage {
  const ShareGiveBack();

  @override
  bool get fromHost => false;

  @override
  Uint8List encode() => _framed(ShareMessage._giveBack);
}

class ShareLeave extends ShareMessage {
  const ShareLeave();

  @override
  bool get fromHost => false;

  @override
  Uint8List encode() => _framed(ShareMessage._leave);
}

/// Ends the shared session itself: from someone invited to (session
/// moderation).
class ShareEndSession extends ShareMessage {
  const ShareEndSession();

  @override
  bool get fromHost => false;

  @override
  Uint8List encode() => _framed(ShareMessage._endSession);
}

/// How many of the host's frames the viewer has taken so far.
class ShareAck extends ShareMessage {
  const ShareAck(this.received);
  final int received;

  @override
  bool get fromHost => false;

  @override
  Uint8List encode() {
    final count = ByteData(8)..setUint64(0, received);
    return _framed(ShareMessage._ack, count.buffer.asUint8List());
  }
}

/// [text] cut into pieces whose UTF-8 form fits one output message, never
/// through the middle of a character (nor between the two halves of a
/// surrogate pair).
Iterable<String> shareOutputPieces(String text, {int max = kShareOutputMax}) sync* {
  if (text.isEmpty) return;
  final piece = StringBuffer();
  var size = 0;
  for (final rune in text.runes) {
    final width = rune < 0x80
        ? 1
        : rune < 0x800
            ? 2
            : rune < 0x10000
                ? 3
                : 4;
    if (size + width > max && size > 0) {
      yield piece.toString();
      piece.clear();
      size = 0;
    }
    piece.writeCharCode(rune);
    size += width;
  }
  if (size > 0) yield piece.toString();
}
