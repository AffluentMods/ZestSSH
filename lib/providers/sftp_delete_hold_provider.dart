import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/services/sftp_error_messages.dart' show SftpOp;
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// What a held delete did once it was made: the items that failed, each with
/// what was thrown; or that the connection went, or it was cancelled.
typedef DeleteOutcome = ({List<({String name, Object error})> failures, bool connectionLost, bool cancelled});

/// One pending remote-delete hold (delete safety spec, section 2). The unlink
/// has NOT been issued; the rows are already hidden from the pane. When the
/// [deadline] passes (or Delete now / a lifecycle commit fires) the deletes are
/// issued; Undo drops the hold and nothing was ever sent.
class DeleteHold {
  DeleteHold({
    required this.opId,
    required this.sessionId,
    required this.hostLabel,
    required this.source,
    required this.targets,
    required this.deadline,
    required this.connectionLostText,
    required this.skippedText,
    required this.failedText,
    this.onRefresh,
    this.onDone,
  });

  /// Localized commit-outcome strings, captured at hold time (the manager runs
  /// without a BuildContext).
  final String connectionLostText;
  final String Function(int count) skippedText;
  final String Function(int count) failedText;

  /// The Activity [TransferItem.id] this hold drives.
  final String opId;

  /// The remote session this delete targets. Used to commit / fail exactly the
  /// holds for a host on a source switch or a dropped connection. Null for a
  /// local hold (the OS-trash fallback path).
  final String? sessionId;

  final String hostLabel;

  /// The source that will issue the unlinks and re-stat the paths. App-scoped
  /// (the SFTP session), so a commit survives the SFTP screen being torn down.
  final PaneFileSource source;

  /// The held items, kept for the pre-commit re-stat (skip a path that changed)
  /// and their original size/mtime.
  final List<PaneFileEntry> targets;

  /// Wall-clock commit instant. The countdown runs on this, not a frame timer,
  /// so sleeping past it commits on wake instead of resuming a stale count.
  final DateTime deadline;

  /// Refresh the originating pane's listing (undo, or a skip / failure that
  /// leaves files behind). No-op if the pane is gone.
  final void Function()? onRefresh;

  /// Told what the delete did once it is made, whatever has become of the
  /// screen it was asked on (a phone, which has no Activity, says it).
  final void Function(DeleteOutcome outcome)? onDone;

  bool committing = false;
}

/// App-scoped manager for the remote-delete hold window. Lives above the SFTP
/// screen so holds commit correctly even as the widget tree churns.
final sftpDeleteHoldProvider = Provider<SftpDeleteHoldManager>((ref) {
  final m = SftpDeleteHoldManager(ref);
  ref.onDispose(m.dispose);
  return m;
});

class SftpDeleteHoldManager {
  SftpDeleteHoldManager(this._ref);

  final Ref _ref;
  final Map<String, DeleteHold> _holds = {};
  // In-flight commit futures per session - a hold that is now issuing unlinks,
  // so no longer in [_holds]. [commitSessionThenClose] gates the session close
  // on these so a delete already running (an instant hold-off delete, or an
  // expired hold) is never cut off when the SFTP screen closes - that was the
  // "delete fails when I leave the SFTP" bug. Null key = adopted / local holds.
  final Map<String?, Set<Future<void>>> _inFlight = {};
  // Commits that ended in failure (connection lost / errors), for the app-quit
  // "N files were not deleted" next-launch notice. Drained by [takeFailures].
  final List<({String hostLabel, int count})> _commitFailures = [];
  Timer? _ticker;

  SftpTransfersNotifier get _transfers =>
      _ref.read(sftpTransfersProvider.notifier);

  bool get hasHolds => _holds.isNotEmpty;
  int get holdCount => _holds.length;

  /// Register a hold and (re)start the one-second countdown ticker.
  void hold(DeleteHold h) {
    _holds[h.opId] = h;
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// Run a commit and track its future in [_inFlight] under the hold's session,
  /// so [commitSessionThenClose] can wait for it before the session is closed.
  Future<void> _runCommit(DeleteHold h) {
    final sid = h.sessionId;
    final f = _commit(h);
    (_inFlight[sid] ??= <Future<void>>{}).add(f);
    f.whenComplete(() {
      final set = _inFlight[sid];
      if (set != null) {
        set.remove(f);
        if (set.isEmpty) _inFlight.remove(sid);
      }
    });
    return f;
  }

  void _tick() {
    if (_holds.isEmpty) {
      _stopTicker();
      return;
    }
    final now = DateTime.now();
    // Commit anything whose wall-clock deadline has passed (covers sleep/wake:
    // waking after the window commits immediately rather than resuming).
    final due = _holds.values
        .where((h) => !h.committing && !now.isBefore(h.deadline))
        .toList();
    for (final h in due) {
      unawaited(_runCommit(h));
    }
    // Repaint the remaining countdowns.
    if (_holds.isNotEmpty) _transfers.touch();
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _stopTickerIfIdle() {
    if (_holds.isEmpty) _stopTicker();
  }

  /// Undo: drop the hold. Nothing was ever sent, so there is nothing to recover
  /// and nothing can fail - the Activity row goes away and the pane re-lists.
  void undo(String opId) {
    final h = _holds.remove(opId);
    if (h == null) return;
    _transfers.remove(opId);
    h.onRefresh?.call();
    _stopTickerIfIdle();
  }

  /// Delete now: commit this hold immediately.
  Future<void> commitNow(String opId) async {
    final h = _holds[opId];
    if (h == null) return;
    await _runCommit(h);
  }

  /// Commit every hold for [sessionId] (source switched away from that host, or
  /// the SFTP window/tab closed). Fire-and-forget against the app-scoped session.
  void commitSession(String? sessionId) {
    for (final h in _holds.values
        .where((h) => sessionId == null || h.sessionId == sessionId)
        .toList()) {
      unawaited(_runCommit(h));
    }
  }

  /// Commit ALL holds (app quit) with a hard [timeout] so the quit can never
  /// hang. Returns the holds that did NOT delete - timed out before finishing,
  /// or failed - each as (hostLabel, count), for the next-launch notice. Empty =
  /// everything was deleted.
  Future<List<({String hostLabel, int count})>> commitAllReporting(
      Duration timeout) async {
    final pending = _holds.values.where((h) => !h.committing).toList();
    if (pending.isEmpty) return const [];
    final summary = {
      for (final h in pending)
        h.opId: (hostLabel: h.hostLabel, count: h.targets.length)
    };
    final completed = <String>{};
    final futures = pending
        .map((h) => _runCommit(h).then((_) => completed.add(h.opId)))
        .toList();
    try {
      await Future.wait(futures).timeout(timeout);
    } catch (_) {
      // Timed out (or a stray error) - proceed; the report below captures it.
    }
    final result = <({String hostLabel, int count})>[];
    // Commits that never finished within the timeout.
    for (final e in summary.entries) {
      if (!completed.contains(e.key)) result.add(e.value);
    }
    // Commits that finished but failed (connection lost / errors).
    result.addAll(_commitFailures);
    _commitFailures.clear();
    return result;
  }

  /// Commit [sessionId]'s pending holds, wait for EVERY in-flight delete on that
  /// session to finish, THEN run [close]. Gating on the in-flight commits (not
  /// just the pending holds) is what stops the session being torn down under a
  /// delete that is already running - an instant hold-off delete, or a hold that
  /// just expired - which is the "delete fails when I leave the SFTP" bug. The
  /// manager is app-scoped, so this all runs in the background after the SFTP
  /// screen is gone: the user can leave and the delete still lands.
  Future<void> commitSessionThenClose(
      String sessionId, Future<void> Function() close) async {
    for (final h in _holds.values
        .where((h) => h.sessionId == sessionId)
        .toList()) {
      _runCommit(h);
    }
    while (_inFlight[sessionId]?.isNotEmpty ?? false) {
      await Future.wait(_inFlight[sessionId]!.toList());
    }
    await close();
  }

  /// Seconds left before [opId] commits (0 if past / gone). For the countdown.
  int secondsLeft(String opId) {
    final h = _holds[opId];
    if (h == null) return 0;
    final ms = h.deadline.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  Future<void> _commit(DeleteHold h) async {
    if (h.committing) return;
    h.committing = true;
    _holds.remove(h.opId);
    _stopTickerIfIdle();

    final item = _transfers.findById(h.opId);
    if (item == null) return; // row dismissed out from under us

    // Leaving the hold: this is deliberately the PLAIN delete the app always
    // did - the hold window was the entire feature. No pre-count walk (it
    // traversed the whole tree a second time before deleting, doubling the work
    // on a big folder and producing a bogus "N of M") and no re-stat: once the
    // countdown hits zero we just delete. processedItems climbs as directories
    // are removed and shows as an indeterminate "N items" (no denominator).
    item.status = TransferStatus.active;
    item.holdUntil = null;
    _transfers.touch();

    var cancelled = false;
    _transfers.registerCanceller(h.opId, () => cancelled = true);

    var deleted = 0;
    var connectionLost = false;
    final failures = <({String name, Object error})>[];
    for (final t in h.targets) {
      if (cancelled) break;
      try {
        if (t.isDirectory) {
          await h.source.deleteDirectoryRecursive(
            t.path,
            isCancelled: () => cancelled,
            onDeleted: (_) {
              deleted++;
              item.processedItems = deleted;
              _transfers.touch();
            },
          );
        } else {
          await h.source.deleteFile(t.path);
          deleted++;
          item.processedItems = deleted;
          _transfers.touch();
        }
      } catch (e) {
        failures.add((name: t.name, error: e));
        // A connection-level failure fails the whole commit, not just one item.
        if (_looksLikeConnectionLoss(e)) {
          connectionLost = true;
          break;
        }
      }
    }

    _transfers.unregisterCanceller(h.opId);
    item.completedAt = DateTime.now();
    if (cancelled) {
      item.status = TransferStatus.cancelled;
    } else if (connectionLost) {
      // The whole commit failed with the connection; what was thrown is in
      // the report.
      item.failWithAll(failures, several: h.connectionLostText, op: SftpOp.delete, oneByItself: false);
      _commitFailures
          .add((hostLabel: h.hostLabel, count: h.targets.length));
    } else if (failures.isNotEmpty) {
      // Each failure said for itself when it is one, every one in the report
      // (it was the raw '<name>: <error>').
      item.failWithAll(failures, several: h.failedText(failures.length), op: SftpOp.delete);
      _commitFailures.add((hostLabel: h.hostLabel, count: failures.length));
    } else {
      item.status = TransferStatus.completed;
    }
    _transfers.touch();

    // Re-list the pane whenever reality now differs from the optimistic hide:
    // a failure / lost connection / cancel left rows that must come back.
    if (failures.isNotEmpty || connectionLost || cancelled) {
      h.onRefresh?.call();
    }
    h.onDone?.call((failures: failures, connectionLost: connectionLost, cancelled: cancelled));
    // The session close (if one is queued) is driven by [commitSessionThenClose],
    // which waits on [_inFlight] - so it already accounts for this commit.
  }

  bool _looksLikeConnectionLoss(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('closed') ||
        s.contains('not connected') ||
        s.contains('connection') ||
        s.contains('broken pipe') ||
        s.contains('socket');
  }

  void dispose() {
    _stopTicker();
    _holds.clear();
  }
}
