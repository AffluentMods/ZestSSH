import 'dart:async';

/// The write a [DebouncedWriter] fires. `quick` is true when the writer is
/// flushing under pressure (pane close, app background, a transfer running)
/// and the write must not spend a round trip: store what you have, skip the
/// `realpath` canonicalisation.
typedef DebouncedWrite = Future<void> Function({required bool quick});

/// Coalesces a burst of directory changes into one write (remember-last-
/// folder spec, section 2: "ten rapid navigations = one write").
///
/// Rules:
///   * Each [schedule] replaces the pending write and restarts the delay.
///   * When the delay fires while [canWriteNow] says no (a transfer is in
///     flight, which owns the SFTP channel), the write is re-armed for
///     [retry] instead of running, so it never competes with a transfer.
///   * [flush] runs the pending write at once, in `quick` mode when
///     [canWriteNow] says no, so a pane close or app background still lands
///     the path without an SFTP round trip.
class DebouncedWriter {
  DebouncedWriter({
    this.delay = const Duration(milliseconds: 1500),
    this.retry = const Duration(seconds: 3),
    bool Function()? canWriteNow,
  }) : _canWriteNow = canWriteNow ?? (() => true);

  final Duration delay;
  final Duration retry;
  final bool Function() _canWriteNow;

  DebouncedWrite? _pending;
  Timer? _timer;
  bool _disposed = false;

  bool get hasPending => _pending != null;

  void schedule(DebouncedWrite write) {
    if (_disposed) return;
    _pending = write;
    _timer?.cancel();
    _timer = Timer(delay, _fire);
  }

  Future<void> _fire() async {
    final w = _pending;
    if (w == null) return;
    if (!_canWriteNow()) {
      _timer?.cancel();
      _timer = Timer(retry, _fire);
      return;
    }
    _pending = null;
    await w(quick: false);
  }

  /// Run the pending write now (if any). Never throws.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final w = _pending;
    _pending = null;
    if (w == null) return;
    try {
      await w(quick: !_canWriteNow());
    } catch (_) {
      // A lost path is a shrug, never a crash on the way out.
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
