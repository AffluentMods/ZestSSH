import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// What a command prints, kept as it comes, so that it is there when the
/// command's time is up: no more than [atMost] bytes of it. What comes
/// beyond that is read and dropped: a command which prints a great deal
/// goes on to its end, and a server that never stops writing cannot grow
/// what is kept without limit. (A scheduled task's run and a run on hosts
/// keep what a command prints this way.)
///
/// Where [alsoTo] is given, all of what is printed (not only what is kept)
/// is handed to it as text, piece by piece as it comes (a team's log of a
/// run on hosts).
class CommandOutput {
  CommandOutput(Stream<Uint8List> stream, this.atMost, {void Function(String text)? alsoTo}) {
    final also = alsoTo == null ? null : const Utf8Decoder(allowMalformed: true).startChunkedConversion(_Pieces(alsoTo));
    // A stream that fails is over as well: what came is kept.
    stream.listen(
      (chunk) {
        _take(chunk);
        also?.add(chunk);
      },
      onDone: () {
        also?.close();
        _end();
      },
      onError: (Object _) {
        also?.close();
        _end();
      },
    );
  }

  void _end() {
    if (!_ended.isCompleted) _ended.complete();
  }

  final int atMost;
  final _kept = BytesBuilder(copy: false);
  final _ended = Completer<void>();
  var _cut = false;

  /// Completes when the command has closed what it prints to.
  Future<void> get ended => _ended.future;

  /// Whether more came than is kept.
  bool get cut => _cut;

  void _take(Uint8List chunk) {
    final room = atMost - _kept.length;
    if (chunk.length <= room) return _kept.add(chunk);
    if (room > 0) _kept.add(Uint8List.sublistView(chunk, 0, room));
    _cut = true;
  }

  /// What has come so far, as text (what is no UTF-8 in it never throws).
  String get text {
    final text = kept;
    return _cut ? '$text\n[output truncated at ${atMost ~/ 1024} KiB]' : text;
  }

  /// What is kept of it, as text, with no word of whether more came ([cut]).
  String get kept => utf8.decode(_kept.toBytes(), allowMalformed: true);
}

/// Each piece of text, as it is decoded, to [_to].
class _Pieces implements Sink<String> {
  _Pieces(this._to);

  final void Function(String text) _to;

  @override
  void add(String data) {
    if (data.isNotEmpty) _to(data);
  }

  @override
  void close() {}
}
