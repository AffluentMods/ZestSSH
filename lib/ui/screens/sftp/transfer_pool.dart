import 'dart:async';

/// A small concurrency limiter for the files of one drop in the two-pane
/// file screen: at most [concurrency] run at once, the rest wait their turn.
class TransferPool {
  TransferPool(this.concurrency) : assert(concurrency >= 1, 'concurrency must be >= 1');

  final int concurrency;
  final List<Completer<void>> _waiters = [];
  int _running = 0;

  /// Run [task] when a slot is free. The returned future completes when the
  /// task does (so callers can `Future.wait` the whole batch at the end of a
  /// drop operation).
  ///
  /// When [cancelled] says yes as the task's turn comes (its operation was
  /// cancelled while it waited), the task is never run and its slot goes to
  /// the next. Cancel all stopped only the three files running at that
  /// moment: each one that ended woke the next waiting file, which started,
  /// and the rest of the folder went on.
  Future<void> run(Future<void> Function() task, {bool Function()? cancelled}) async {
    if (_running >= concurrency) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _running++;
    try {
      if (cancelled?.call() ?? false) return;
      await task();
    } finally {
      _running--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
  }
}
