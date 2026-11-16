import 'dart:async';

import 'package:zestssh/utils/logger.dart';

/// One session's output between two frames (16 ms): what the terminal draws,
/// and the work that only reads the text (the transcript, the session logs,
/// the alert rules and the two counters the screen shows).
///
/// Before, the drawing was batched but the rest ran for every chunk the
/// network delivered: a session pouring out a build log ran the transcript,
/// two logs, every alert rule and two provider writes thousands of times a
/// second on the screen's isolate (found in a code audit). Now all of it
/// runs once a batch, with the batch's text: the same text, in the same
/// order, in fewer and larger pieces.
class OutputBatch {
  OutputBatch({
    required this.draw,
    required this.read,
    this.every = const Duration(milliseconds: 16),
  });

  /// Puts [text] on the screen (and wherever the screen is watched from).
  final void Function(String text) draw;

  /// Everything that only reads the output: [text] is the batch's, [bytes]
  /// how many bytes the network delivered for it.
  final void Function(String text, int bytes) read;

  final Duration every;

  final StringBuffer _text = StringBuffer();
  int _bytes = 0;
  Timer? _timer;
  bool _finished = false;

  /// Whether output waits for the next batch.
  bool get waiting => _timer != null;

  /// [text] decoded from [bytes] bytes, for the next batch.
  void add(String text, int bytes) {
    if (_finished) return;
    _text.write(text);
    _bytes += bytes;
    _timer ??= Timer(every, _flush);
  }

  void _flush() {
    _timer = null;
    _run(drawIt: true);
  }

  /// What waits is drawn and read now, not at the end of the 16 ms (the
  /// connection dropped: what the host said last is shown before the rest is
  /// torn down). Later output starts a batch of its own.
  void flushNow() {
    if (_finished) return;
    _timer?.cancel();
    _timer = null;
    _run(drawIt: true);
  }

  /// The output ended: what waits is drawn and read now, [last] (a character
  /// the output ended inside of) after it, and nothing more is taken.
  void finish([String last = '']) {
    if (_finished) return;
    _text.write(last);
    _timer?.cancel();
    _timer = null;
    _run(drawIt: true);
    _finished = true;
  }

  /// The session is closed or connects again: what waits is read (the logs
  /// and the transcript keep every byte that arrived) but not drawn, as the
  /// closing did before, and nothing more is taken.
  void close() {
    if (_finished) return;
    _timer?.cancel();
    _timer = null;
    _run(drawIt: false);
    _finished = true;
  }

  void _run({required bool drawIt}) {
    if (_text.isEmpty && _bytes == 0) return;
    final text = _text.toString();
    final bytes = _bytes;
    _text.clear();
    _bytes = 0;
    // The drawing first, and each part on its own: nothing the reading does
    // can stop the screen, and a drawing that throws (a single `ESC [ 1 K` at
    // the first column, up to 3.2.7) leaves the logs whole.
    if (drawIt && text.isNotEmpty) {
      try {
        draw(text);
      } catch (e, st) {
        AppLogger.error('Drawing the output of a session failed', e, st);
      }
    }
    try {
      read(text, bytes);
    } catch (e, st) {
      AppLogger.error('Reading the output of a session failed', e, st);
    }
  }
}
