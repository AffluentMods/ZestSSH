import 'dart:async';
import 'dart:typed_data';

/// Coalesces and rate-limits the worker's terminal stdout before it crosses the
/// `SendPort` to the UI isolate (Design B).
///
/// Two jobs, both from the throughput section of
/// `docs/sftp-isolation-architecture.md`:
///
///   * **Batching.** A `cat biglog` firehose arrives as a storm of small chunks.
///     Sending each as its own message floods the port and wastes a serialize
///     per chunk. Chunks that land in the same event-loop turn are merged into
///     one batch flushed on a microtask, so an interactive echo (its own turn)
///     still goes out immediately, while a burst collapses into one hand-off. A
///     chunk at or above [flushThreshold] flushes synchronously so a single big
///     read never sits buffered.
///
///   * **Backpressure.** The batcher tracks bytes sent but not yet acknowledged
///     by the UI isolate. Above [highWaterMark] it calls [onPause] (the
///     transport pauses reading the shell channel); once the UI [ack]s enough
///     that the outstanding total falls to [lowWaterMark] or below it calls
///     [onResume]. This bounds memory and stops the port queue growing without
///     limit, while the terminal channel's own SSH flow window keeps its bytes
///     moving independently of any SFTP burst.
///
/// Pure and isolate-agnostic: it takes callbacks, so it is unit-tested with no
/// isolate and reused verbatim inside the worker.
class TerminalOutputBatcher {
  /// Emit one coalesced batch toward the UI isolate.
  final void Function(Uint8List batch) onBatch;

  /// Ask the transport to pause reading the shell channel (too much unacked).
  final void Function() onPause;

  /// Ask the transport to resume reading the shell channel.
  final void Function() onResume;

  /// A chunk at or above this size flushes immediately instead of waiting for
  /// the microtask coalesce, so one large read is never left buffered.
  final int flushThreshold;

  /// Pause reading once this many bytes are sent-but-unacked.
  final int highWaterMark;

  /// Resume reading once outstanding falls to this or below.
  final int lowWaterMark;

  TerminalOutputBatcher({
    required this.onBatch,
    required this.onPause,
    required this.onResume,
    this.flushThreshold = 16 * 1024,
    this.highWaterMark = 256 * 1024,
    this.lowWaterMark = 64 * 1024,
  })  : assert(lowWaterMark < highWaterMark),
        assert(flushThreshold > 0);

  final BytesBuilder _pending = BytesBuilder(copy: false);
  bool _flushScheduled = false;
  int _outstanding = 0;
  bool _paused = false;

  /// Queue a stdout chunk. Coalesced with anything else from the same turn
  /// unless it alone reaches [flushThreshold].
  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _pending.add(chunk);
    if (_pending.length >= flushThreshold) {
      _flushNow();
    } else if (!_flushScheduled) {
      _flushScheduled = true;
      scheduleMicrotask(_flushNow);
    }
  }

  /// Flush any buffered bytes right now (e.g. just before teardown).
  void flush() => _flushNow();

  void _flushNow() {
    _flushScheduled = false;
    if (_pending.isEmpty) return;
    final batch = _pending.takeBytes();
    _outstanding += batch.length;
    onBatch(batch);
    if (!_paused && _outstanding >= highWaterMark) {
      _paused = true;
      onPause();
    }
  }

  /// The UI isolate consumed [bytes] of terminal output. Lets the transport
  /// resume once the backlog drains to [lowWaterMark].
  void ack(int bytes) {
    _outstanding -= bytes;
    if (_outstanding < 0) _outstanding = 0;
    if (_paused && _outstanding <= lowWaterMark) {
      _paused = false;
      onResume();
    }
  }

  /// Bytes sent to the UI isolate but not yet acknowledged.
  int get outstanding => _outstanding;

  /// Whether the transport has been asked to pause reading.
  bool get isPaused => _paused;
}
