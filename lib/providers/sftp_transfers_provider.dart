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
  /// oldest go, a whole operation at a time and only once every file of it
  /// has finished (so no operation that is still running loses rows its
  /// counts go by). Failed rows stay for Retry, and the person's Clear
  /// completed is there as before.
  ///
  /// Nothing went until the person cleared it: every file ever sent in the
  /// life of the app stayed in the list (a 100,000-file tree was 100,000
  /// rows), and the whole list is copied at each publish (found in
  /// a code audit).
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
    final byOp = <String, List<TransferItem>>{};
    for (final t in _items) {
      final op = t.operationId;
      if (op != null && finished(t)) (byOp[op] ??= []).add(t);
    }
    final drop = <TransferItem>{};
    for (final t in _items) {
      if (count <= maxFinishedRows) break;
      if (!finished(t) || drop.contains(t)) continue;
      final op = t.operationId;
      if (op == null) {
        drop.add(t);
        count--;
        continue;
      }
      if (open.contains(op)) continue;
      // The whole operation goes at once, never part of its rows.
      for (final u in byOp.remove(op) ?? const <TransferItem>[]) {
        drop.add(u);
        count--;
      }
    }
    if (drop.isEmpty) return;
    for (final t in drop) {
      _cancellers.remove(t.id);
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
    _items.removeWhere((t) => t.id == id);
    _publishNow();
  }

  /// Remove items that have terminated (completed / cancelled).
  /// Failed transfers stay so the user can retry them.
  void clearCompleted() {
    _items.removeWhere((t) =>
        t.status == TransferStatus.completed ||
        t.status == TransferStatus.cancelled);
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
