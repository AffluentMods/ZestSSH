import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// Global, screen-independent list of all SFTP transfers (active,
/// completed, failed, cancelled).
///
/// Holding the transfer queue at app scope - rather than inside
/// [SftpDualPaneScreen]'s State - lets the user start a transfer,
/// navigate away to a terminal pane (or any other workspace), and
/// come back to the SFTP screen with the queue intact. The widget
/// tree can churn freely; the transfers list does not.
///
/// It also unlocks a global "transfers in progress" indicator
/// elsewhere in the chrome (pill bar / notification center) - any
/// widget can `ref.watch(sftpTransfersProvider)` to know about
/// active uploads/downloads regardless of where the SFTP screen is
/// mounted.
///
/// PERFORMANCE - publishing is COALESCED. [state] is a snapshot of the
/// private [_items] list that is republished at most once per
/// [_publishInterval]. Every publish rebuilds every watcher (the Activity
/// panel does a full pass over all N items per rebuild), and a folder drop
/// fires several mutations per file (add, progress, complete, verify). With
/// per-mutation publishing that was O(files x N) main-isolate work: a 16k-file
/// tree (a website with node_modules) produced ~64k rebuilds x 16k items and
/// pegged the UI isolate for the whole transfer. Coalescing bounds rebuilds to
/// ~15/sec regardless of how fast tiny files churn.
class SftpTransfersNotifier extends StateNotifier<List<TransferItem>> {
  SftpTransfersNotifier() : super(const []);

  /// Source of truth. [state] is only ever a coalesced snapshot of this.
  final List<TransferItem> _items = [];

  Timer? _publishTimer;
  static const Duration _publishInterval = Duration(milliseconds: 66);

  /// Cancel callbacks for in-flight COUNT operations (delete / chmod / mkdir),
  /// keyed by operation id. Byte transfers carry their own [TransferCancelToken]
  /// resolved by the screen; count ops register a flag-flipper here so the
  /// Activity panel's cancel button - which only knows the id - can reach them.
  final Map<String, void Function()> _cancellers = {};

  void registerCanceller(String id, void Function() cancel) =>
      _cancellers[id] = cancel;

  /// Fire the registered canceller for [id] (no-op if none / already gone).
  void requestCancel(String id) => _cancellers[id]?.call();

  void unregisterCanceller(String id) => _cancellers.remove(id);

  void add(TransferItem item) {
    _items.add(item);
    _schedulePublish();
  }

  /// The most rows of finished work (completed or cancelled) the list keeps.
  static const int maxFinishedRows = 1000;

  /// Keeps at most [maxFinishedRows] rows of finished work (looked at as the
  /// list is published, at most about 15 times a second): past that, the
  /// oldest go, row by row, so the newest finished rows stay, of a folder
  /// larger than the limit too. An operation that still has a file to send
  /// keeps every row (its counts go by them). A folder that loses some of
  /// its rows keeps its count: what went is counted on its oldest row that
  /// stays ([TransferItem.foldIn]), so its folder row still says how many
  /// files it moved. Failed rows stay for Retry, and the person's Clear
  /// completed is there as before.
  ///
  /// Nothing went until the person cleared it: every file ever sent in the
  /// life of the app stayed in the list (a 100,000-file tree was 100,000
  /// rows), and the whole list is copied at each publish. A whole
  /// operation went at a time, so one folder of more than the limit left no
  /// row of it at all.
  void _trimFinished() {
    bool finished(TransferItem t) =>
        t.status == TransferStatus.completed || t.status == TransferStatus.cancelled;
    var count = 0;
    for (final t in _items) {
      if (finished(t)) count++;
    }
    if (count <= maxFinishedRows) return;
    // Operations with a file not finished yet keep every row.
    final open = <String>{
      for (final t in _items)
        if (t.operationId != null && !finished(t) && t.status != TransferStatus.failed) t.operationId!,
    };
    // The oldest first: [_items] is in the order they were added.
    final drop = <TransferItem>{};
    for (final t in _items) {
      if (count <= maxFinishedRows) break;
      if (!finished(t)) continue;
      final op = t.operationId;
      if (op != null && open.contains(op)) continue;
      drop.add(t);
      count--;
    }
    if (drop.isEmpty) return;
    // Each operation's oldest row that stays counts the rows of it that go.
    final keeps = <String, TransferItem>{};
    for (final t in _items) {
      final op = t.operationId;
      if (op != null && !drop.contains(t)) keeps.putIfAbsent(op, () => t);
    }
    for (final t in drop) {
      _cancellers.remove(t.id);
      final op = t.operationId;
      if (op != null) keeps[op]?.foldIn(t);
    }
    _items.removeWhere(drop.contains);
  }

  /// [TransferItem] is intentionally mutable - the progress callback
  /// fires many times per second, and rebuilding an immutable copy
  /// on every chunk would be wasteful. After mutating an item in
  /// place (status, transferredBytes, errorMessage, completedAt),
  /// call [touch] to publish a new list reference so listeners
  /// re-render. Publishes are coalesced (see class doc), so calling this
  /// per chunk or per file is cheap.
  void touch() => _schedulePublish();

  /// Like [touch] but publishes immediately, bypassing the coalescing window.
  /// Use it for a terminal transition (completed / failed / cancelled): a
  /// finished or failed row should appear the instant it happens, not up to
  /// [_publishInterval] later. Progress ticks stay coalesced via [touch].
  void touchNow() => _publishNow();

  TransferItem? findById(String id) {
    for (final t in _items) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Drop a single item from the queue by id (the per-row dismiss ×).
  /// Used on a finished row - a completed/failed/cancelled item the user
  /// wants off the list without clearing the rest.
  void remove(String id) {
    _cancellers.remove(id);
    final gone = findById(id);
    _items.removeWhere((t) => t.id == id);
    // What was counted on it stays with its operation: the folder row's
    // count drops by the one row dismissed, not by the files counted on it.
    final op = gone?.operationId;
    if (gone != null && op != null && gone.fileCount > 1) {
      final next = _items.where((t) => t.operationId == op).firstOrNull;
      if (next != null) {
        next.earlierCompleted += gone.earlierCompleted;
        next.earlierCancelled += gone.earlierCancelled;
        next.earlierTotalBytes += gone.earlierTotalBytes;
        next.earlierTransferredBytes += gone.earlierTransferredBytes;
      }
    }
    _publishNow();
  }

  /// Remove items that have terminated (completed / cancelled).
  /// Failed transfers stay so the user can retry them.
  void clearCompleted() {
    _items.removeWhere((t) =>
        t.status == TransferStatus.completed ||
        t.status == TransferStatus.cancelled);
    // The finished files counted on a row that stays go with them.
    for (final t in _items) {
      t.forgetEarlier();
    }
    _publishNow();
  }

  void _schedulePublish() {
    if (_publishTimer != null) return;
    _publishTimer = Timer(_publishInterval, _publishNow);
  }

  void _publishNow() {
    _publishTimer?.cancel();
    _publishTimer = null;
    if (!mounted) return;
    _trimFinished();
    state = List<TransferItem>.of(_items);
  }

  @override
  void dispose() {
    _publishTimer?.cancel();
    _publishTimer = null;
    super.dispose();
  }
}

final sftpTransfersProvider =
    StateNotifierProvider<SftpTransfersNotifier, List<TransferItem>>(
        (_) => SftpTransfersNotifier());

/// Convenience: true while any transfer is in flight. Cheap derived
/// state - chrome indicators can watch this without listening to
/// the whole list and getting rebuilt on every progress tick.
final sftpHasActiveTransferProvider = Provider<bool>((ref) {
  final all = ref.watch(sftpTransfersProvider);
  for (final t in all) {
    if (t.status == TransferStatus.active ||
        t.status == TransferStatus.pending) {
      return true;
    }
  }
  return false;
});
