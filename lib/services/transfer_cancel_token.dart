import 'dart:async';

import 'package:zestssh/utils/type_name.dart';

/// Thrown out of an SFTP transfer loop when the user cancels it. Callers
/// branch on this to mark the transfer cancelled (vs. failed) without
/// surfacing it as an error.
class TransferCancelledException implements Exception, HasTypeName {
  const TransferCancelledException([this.message]);
  final String? message;

  @override
  String toString() => 'TransferCancelledException: ${message ?? 'cancelled'}';

  @override
  String get typeName => 'TransferCancelledException';
}

/// A one-shot cancellation flag checked inside [SftpService]'s per-chunk
/// transfer loops. Deliberately simpler than a full CancelToken: a transfer
/// only needs "has the user asked to stop?" checked cheaply on every chunk.
///
/// Checking per chunk (not per progress callback) gives near-instant
/// cancellation - the desktop's throw-from-onProgress trick only fires on a
/// progress tick, which is percent-throttled on downloads and never fires on
/// a stalled stream.
class TransferCancelToken {
  bool _cancelled = false;
  final _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;

  /// Completes the instant [cancel] is called. Lets a transfer *race* a
  /// blocking read/write against cancellation (via `Future.any`) and abort
  /// immediately - instead of only noticing on the next chunk boundary, which
  /// never arrives if the underlying stream is wedged.
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_cancelledCompleter.isCompleted) _cancelledCompleter.complete();
  }

  /// Throws [TransferCancelledException] if [cancel] has been called.
  void throwIfCancelled() {
    if (_cancelled) throw const TransferCancelledException();
  }
}
