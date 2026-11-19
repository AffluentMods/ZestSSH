import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/byte_size.dart';

/// Direction of a file transfer.
enum TransferDirection { upload, download }

/// Status of an individual transfer.
///
/// [holding] is the remote-delete hold window (delete safety spec): the unlink
/// has NOT been issued yet, the rows are hidden, and a countdown with Undo /
/// Delete now is shown. It commits to [active] then [completed]/[failed], or is
/// dropped entirely on Undo.
enum TransferStatus { holding, pending, active, completed, failed, cancelled }

/// Outcome of the optional post-transfer checksum. [none] = not attempted;
/// [ok] = both ends' SHA-256 matched; [mismatch] = they differed (the copy is
/// corrupt); [unavailable] = couldn't hash one side (no `sha256sum` on the
/// server, or too large), so it's neither confirmed nor denied.
enum SftpVerifyResult { none, ok, mismatch, unavailable }

/// Kind of long-running operation in the unified Activity queue. Uploads and
/// downloads are byte transfers; delete / chmod / mkdir are count-based
/// operations that used to run fire-and-forget with no feedback (the delete
/// defect). All now share one queue, one progress model, and one cancel.
enum SftpOperationKind { upload, download, delete, chmod, mkdir, sync }

/// Represents a single file transfer in the queue.
///
/// Items can be grouped into "operations" - a single drag-drop of a
/// directory becomes ONE operation with N items inside. The panel
/// renders the operation as a collapsible parent row with aggregated
/// progress, the way WinSCP / FileZilla do. Standalone files (a
/// single dragged file with no batch) leave the operation fields
/// null and render as flat rows in the same panel.
class TransferItem {
  final String id;

  /// Optional id of the parent batch (one drop = one operation). When
  /// null, the item renders ungrouped.
  final String? operationId;

  /// Optional human-readable name of the parent batch - usually the
  /// dropped folder's name or "N files" for a multi-file drop. Used
  /// as the operation row label in the panel.
  final String? operationLabel;

  /// Optional source-root prefix to strip from [fileName] when
  /// rendering child rows. Lets us show `assets/icon.png` instead of
  /// `/home/foo/proj/dist/assets/icon.png` for a child of an op
  /// rooted at `/home/foo/proj/dist`.
  final String? operationSourceRoot;

  /// Names of the entries dragged in a multi-entry drop ("N items"), less any
  /// pruned before it started. One list shared by every item of the drop; the
  /// collapsed operation row previews it (see [operationRootsPreview]). Null
  /// for a single-entry drop, whose label already names it, and for items
  /// outside an operation.
  final List<String>? operationRoots;

  final String localPath;
  final String remotePath;
  final String fileName;
  final TransferDirection direction;

  /// Which pane (0 = left, 1 = right) the transfer's source and destination
  /// were, plus their source ids at enqueue time. Retry resolves the exact
  /// panes from these instead of guessing by direction - guessing picked the
  /// wrong host for local→local / remote→remote drops and could upload a file
  /// to the wrong server. Null on transfers that don't originate from a drop.
  final int? srcSide;
  final int? dstSide;
  final String? srcSourceId;
  final String? dstSourceId;

  int totalBytes;
  int transferredBytes;
  TransferStatus status;

  /// Why it failed, in the app's language (see [failWith]).
  String? errorMessage;

  /// The report of why it failed, to copy (ErrorReport.build: every address
  /// taken out, and no file named, as a report names none). (3.0: before,
  /// the raw error was kept, and shown only on hover over the progress
  /// bar, with nothing to copy.)
  String? errorReport;

  /// What was thrown when it failed ([failWith]), for a report that gathers
  /// several items.
  Object? failure;
  DateTime startedAt;
  DateTime? completedAt;

  /// Wall-clock instant the delete hold commits (delete safety spec). Only set
  /// while [status] == [TransferStatus.holding]; drives the "Deleting in Ns"
  /// countdown. Null otherwise.
  DateTime? holdUntil;

  /// Post-transfer checksum outcome (byte transfers only). Set after a
  /// successful transfer when verification is applicable.
  SftpVerifyResult verify = SftpVerifyResult.none;

  /// Finished files of this row's operation whose own rows the list no
  /// longer keeps (past [SftpTransfersNotifier.maxFinishedRows] the oldest
  /// go), counted on the operation's oldest row that is kept: its folder
  /// row still says how many files it moved, and how many bytes.
  int earlierCompleted = 0;
  int earlierCancelled = 0;
  int earlierTotalBytes = 0;
  int earlierTransferredBytes = 0;

  /// The files this row stands for in its folder row: itself and the
  /// earlier ones counted on it.
  int get fileCount => 1 + earlierCompleted + earlierCancelled;

  /// Counts [gone], a row of the same operation that the list drops, and
  /// what was counted on it, on this row.
  void foldIn(TransferItem gone) {
    earlierCompleted += gone.earlierCompleted + (gone.status == TransferStatus.completed ? 1 : 0);
    earlierCancelled += gone.earlierCancelled + (gone.status == TransferStatus.cancelled ? 1 : 0);
    earlierTotalBytes += gone.earlierTotalBytes + gone.totalBytes;
    earlierTransferredBytes += gone.earlierTransferredBytes + gone.transferredBytes;
  }

  /// Forgets the earlier files counted on this row (Clear completed).
  void forgetEarlier() {
    earlierCompleted = 0;
    earlierCancelled = 0;
    earlierTotalBytes = 0;
    earlierTransferredBytes = 0;
  }

  /// Non-transfer operation kind (delete / chmod / mkdir). Null for a plain
  /// upload/download, where [direction] carries the kind. Drives count-based
  /// vs byte-based progress and the Activity row's icon.
  final SftpOperationKind? _kind;

  /// Count-based progress for a delete / chmod operation: items processed of
  /// the total to process. Unused (0) for byte transfers.
  int totalItems;
  int processedItems;

  /// Display overrides for a non-transfer operation ("Deleting old build
  /// output" / "/root/dist"). Transfers render from [fileName] + paths instead.
  final String? title;
  final String? subtitle;

  TransferItem({
    required this.id,
    required this.localPath,
    required this.remotePath,
    required this.fileName,
    required this.direction,
    required this.totalBytes,
    this.srcSide,
    this.dstSide,
    this.srcSourceId,
    this.dstSourceId,
    this.operationId,
    this.operationLabel,
    this.operationSourceRoot,
    this.operationRoots,
    this.transferredBytes = 0,
    this.status = TransferStatus.pending,
    this.errorMessage,
    DateTime? startedAt,
    this.completedAt,
    SftpOperationKind? kindOverride,
    this.totalItems = 0,
    this.processedItems = 0,
    this.title,
    this.subtitle,
  })  : _kind = kindOverride,
        startedAt = startedAt ?? DateTime.now();

  /// A non-transfer operation (delete / chmod / mkdir) for the unified Activity
  /// queue. Progress is item-count based; [title]/[subtitle] label the row.
  factory TransferItem.operation({
    required String id,
    required SftpOperationKind kind,
    required String title,
    String? subtitle,
    int totalItems = 0,
    TransferStatus status = TransferStatus.pending,
  }) {
    return TransferItem(
      id: id,
      localPath: '',
      remotePath: subtitle ?? '',
      fileName: title,
      // Placeholder - a count op reads [kind], never [direction].
      direction: TransferDirection.upload,
      totalBytes: 0,
      kindOverride: kind,
      totalItems: totalItems,
      title: title,
      subtitle: subtitle,
      status: status,
    );
  }

  /// The operation kind - the explicit [_kind] for delete/chmod/mkdir, else
  /// derived from the transfer [direction].
  SftpOperationKind get kind =>
      _kind ??
      (direction == TransferDirection.upload
          ? SftpOperationKind.upload
          : SftpOperationKind.download);

  /// Failed with [error]: said in the app's language for [op], about [name]
  /// (its own file name when not given), with the report of it to copy.
  void failWith(Object error, {StackTrace? stack, SftpOp op = SftpOp.generic, String? name}) {
    status = TransferStatus.failed;
    failure = error;
    errorMessage = sftpErrorMessage(error, name: name ?? fileName, op: op);
    errorReport = ErrorReport.build(
      // (Said without the file's name.)
      what: sftpErrorMessage(error, op: op),
      where: _where,
      error: error,
      stack: stack,
    );
  }

  /// Failed for some of its items ([failures]: each one's name and error):
  /// one is said for itself (unless not [oneByItself]: a lost connection is
  /// said as such however many it failed), several as [several]; the report
  /// has what was thrown for each.
  void failWithAll(
    List<({String name, Object error})> failures, {
    required String several,
    SftpOp op = SftpOp.generic,
    bool oneByItself = true,
  }) {
    status = TransferStatus.failed;
    final one = oneByItself && failures.length == 1;
    errorMessage = one
        ? sftpErrorMessage(failures.single.error, name: failures.single.name, op: op)
        : several;
    errorReport = ErrorReport.build(
      // (Said without the file's name.)
      what: one ? sftpErrorMessage(failures.single.error, op: op) : several,
      where: _where,
      details: [for (final f in failures) '${f.error}'].join('\n'),
    );
  }

  /// Where a report says it failed (English, for support).
  String get _where => 'Files: ${_kind?.name ?? direction.name}';

  /// True for delete / chmod / mkdir / sync ops, which track item counts not
  /// bytes (a folder sync reports files done, and it is never retried as a
  /// single upload).
  bool get isCountBased =>
      _kind == SftpOperationKind.delete ||
      _kind == SftpOperationKind.chmod ||
      _kind == SftpOperationKind.mkdir ||
      _kind == SftpOperationKind.sync;

  double get progress {
    if (isCountBased) {
      return totalItems > 0 ? processedItems / totalItems : 0.0;
    }
    return totalBytes > 0 ? transferredBytes / totalBytes : 0.0;
  }

  /// True for a count op with no known total - a plain delete, which no longer
  /// pre-counts its tree. The row shows an indeterminate bar and a bare item
  /// count instead of a bogus "N of 0".
  bool get isIndeterminate => isCountBased && totalItems == 0;

  /// Formatted human-readable progress: "128 of 312" for a counted op, "1,234
  /// items" for a delete with no known total, else "24.3 KB / 38.1 KB". A
  /// model has no context, so the words come from the app-wide localizations.
  String get formattedProgress {
    if (isCountBased) {
      if (totalItems == 0) {
        return processedItems > 0
            ? gl10n.sftpItemsProcessed(processedItems)
            : '';
      }
      return gl10n.sftpCountOf(processedItems, totalItems);
    }
    return '${_formatBytes(transferredBytes)} / ${_formatBytes(totalBytes)}';
  }

  /// Calculate transfer speed in bytes/sec based on elapsed time.
  double get speedBytesPerSec {
    final elapsed = (completedAt ?? DateTime.now()).difference(startedAt);
    if (elapsed.inMilliseconds == 0) return 0;
    return transferredBytes / (elapsed.inMilliseconds / 1000);
  }

  /// Formatted transfer speed.
  String get formattedSpeed {
    final speed = speedBytesPerSec;
    return formatByteRate(speed);
  }

  /// Estimated time remaining.
  String get formattedEta {
    if (status != TransferStatus.active) return '';
    final speed = speedBytesPerSec;
    if (speed <= 0) return '--:--';
    final remaining = totalBytes - transferredBytes;
    final seconds = (remaining / speed).round();
    // The shared compact length, to the second as it ticks ("4m 3s").
    return durationWords(gl10n, Duration(seconds: seconds), seconds: true);
  }

  static String _formatBytes(int bytes) => formatByteSize(bytes);
}

/// Callback to cancel a transfer.
typedef OnCancelTransfer = void Function(String transferId);

/// Collapsible panel showing active, pending, and completed transfers.
///
/// Sits at the bottom of the dual-pane SFTP screen and provides real-time
/// progress feedback for file transfers between local and remote.
/// Callback to retry a failed transfer.
typedef OnRetryTransfer = void Function(String transferId);

class TransferQueuePanel extends StatefulWidget {
  final List<TransferItem> transfers;
  final OnCancelTransfer? onCancel;

  /// Cancel all on an operation's row: receives the operation's id, and stops
  /// the files of it still waiting their turn too. Without it, Cancel all
  /// cancels the rows there are with [onCancel].
  final OnCancelTransfer? onCancelOperation;
  final OnRetryTransfer? onRetry;

  /// Drop a single finished row (the per-row dismiss ×). Distinct from
  /// [onClearCompleted], which sweeps every done row at once.
  final OnCancelTransfer? onDismiss;
  final VoidCallback? onClearCompleted;

  /// Undo a delete that is still in its hold window (nothing was sent, so the
  /// rows just come back). Receives the op id.
  final OnCancelTransfer? onUndoHold;

  /// Commit a held delete immediately ("Delete now"). Receives the op id.
  final OnCancelTransfer? onCommitHold;

  const TransferQueuePanel({
    super.key,
    required this.transfers,
    this.onCancel,
    this.onCancelOperation,
    this.onRetry,
    this.onDismiss,
    this.onClearCompleted,
    this.onUndoHold,
    this.onCommitHold,
  });

  @override
  State<TransferQueuePanel> createState() => _TransferQueuePanelState();

  /// Test-only window onto the per-file row construction counter (see
  /// [_TransferQueuePanelState.debugTransferRowBuilds]). Public so the perf
  /// test can read and reset it; not for production use.
  @visibleForTesting
  static int get debugRowBuildCountForTest =>
      _TransferQueuePanelState.debugTransferRowBuilds;

  @visibleForTesting
  static set debugRowBuildCountForTest(int value) =>
      _TransferQueuePanelState.debugTransferRowBuilds = value;
}

class _TransferQueuePanelState extends State<TransferQueuePanel> {
  /// Collapsed by default - the panel shows a single overall progress
  /// bar + summary line in the title, which is enough for most
  /// transfers. Clicking the title expands the drawer to reveal
  /// per-operation rows (and per-file rows when each operation is
  /// expanded). Mirrors the Chrome / VS Code download bar pattern:
  /// quiet by default, detail on demand.
  bool _isExpanded = false;
  Timer? _refreshTimer;

  /// Test-only counter of per-file row widgets CONSTRUCTED per build. The
  /// panel builds rows lazily through [ListView.builder], so this stays near
  /// the number of visible rows even when an operation holds 16k files. It is
  /// the guard that fails if rows are ever built eagerly again (the regression
  /// that made a folder upload lag): see transfer_queue_panel_perf_test.dart.
  @visibleForTesting
  static int debugTransferRowBuilds = 0;

  /// Operation ids the user has chosen to expand. Collapsed by default
  /// so a 300-file batch shows ONE row instead of 300. The cancellation
  /// + retry buttons on the parent row act on every child.
  final Set<String> _expandedOps = {};

  /// Items whose report was just copied: their copy button shows a tick for
  /// a moment.
  final Set<String> _copiedReports = {};

  Future<void> _copyReport(TransferItem item) async {
    final report = item.errorReport;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    setState(() => _copiedReports.add(item.id));
    Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedReports.remove(item.id));
    });
  }

  @override
  void initState() {
    super.initState();
    // Refresh every 500ms to update speed/ETA while transfers are active.
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (mounted &&
            widget.transfers.any((t) => t.status == TransferStatus.active)) {
          setState(() {});
        }
      },
    );
    // NOTE: finished rows are NOT auto-cleared any more - the Activity panel is
    // a session-long history now (user request). The user clears it with the
    // per-row dismiss or the "Clear completed" button.
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Group items by [operationId]. Items with a null [operationId]
  /// (legacy or one-off transfers) are returned as ungrouped at the
  /// end of the list. Order within each group is insertion order;
  /// order of operations is "newest first" (most recent group at the
  /// top of the panel) for parity with WinSCP.
  ({
    List<_OperationGroup> groups,
    List<TransferItem> ungrouped,
  }) _groupTransfers() {
    final byOp = <String, List<TransferItem>>{};
    final ungrouped = <TransferItem>[];
    for (final t in widget.transfers) {
      final opId = t.operationId;
      if (opId == null) {
        ungrouped.add(t);
      } else {
        (byOp[opId] ??= []).add(t);
      }
    }
    // Order operations newest-first by first item's startedAt.
    final groups = byOp.entries
        .map((e) => _OperationGroup(id: e.key, items: e.value))
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return (groups: groups, ungrouped: ungrouped);
  }

  /// Every title-bar aggregate from a SINGLE walk of the queue.
  _Totals _computeTotals() {
    var active = 0;
    var pending = 0;
    var completed = 0;
    var failed = 0;
    var totalBytes = 0;
    var transferredBytes = 0;
    var speed = 0.0;
    for (final t in widget.transfers) {
      totalBytes += t.totalBytes;
      transferredBytes += t.transferredBytes;
      switch (t.status) {
        case TransferStatus.active:
          active++;
          speed += t.speedBytesPerSec;
        case TransferStatus.pending:
          pending++;
        case TransferStatus.completed:
          completed++;
        case TransferStatus.failed:
          failed++;
        default:
          break;
      }
    }
    Duration? eta;
    if (speed > 0) {
      final remaining = totalBytes - transferredBytes;
      if (remaining > 0) eta = Duration(seconds: (remaining / speed).round());
    }
    return _Totals(
      active: active,
      pending: pending,
      completed: completed,
      failed: failed,
      totalBytes: totalBytes,
      transferredBytes: transferredBytes,
      speed: speed,
      eta: eta,
    );
  }

  /// The time left, in the shared compact words ("47s left", "1h 59m left"),
  /// or nothing while none is known.
  String _formatEta(AppLocalizations l10n, Duration? d) {
    if (d == null || d.inSeconds <= 0) return '';
    return timeLeftWords(l10n, d, seconds: true);
  }

  @override
  Widget build(BuildContext context) {
    // The panel is ALWAYS present (even with no transfers) so it doubles as a
    // session-long history and a stable place to look (user request) - it no
    // longer vanishes to a zero-height strip when the queue is empty.
    final empty = widget.transfers.isEmpty;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        border: Border(top: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title bar (always visible)
          _buildTitleBar(),
          // Expandable content
          if (_isExpanded && !empty) _buildTransferList(),
          if (_isExpanded && empty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  AppLocalizations.of(context)!.sftpActivityEmpty,
                  style:
                      TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTitleBar() {
    // ONE pass over the queue for every title-bar figure. This used to be ~8
    // separate O(N) getters (counts, byte sums, speed, ETA), each walking all N
    // items on EVERY rebuild - and rebuilds fire on every progress publish.
    final l10n = AppLocalizations.of(context)!;
    final totals = _computeTotals();
    final total = widget.transfers.length;
    final done = totals.completed;
    final failed = totals.failed;
    final active = totals.active + totals.pending;
    final allDone = active == 0 && done + failed == total;
    final progress =
        totals.totalBytes > 0 ? totals.transferredBytes / totals.totalBytes : 0.0;
    final speedText = active > 0
        ? formatByteRate(totals.speed)
        : '';
    final etaText = _formatEta(l10n, totals.eta);

    // Status line right of the label - leads with running/done counts
    // ("1 running, 3 done"), then rate, ETA, failures:
    //   - actively transferring: "2 running, 45 done  •  2.3 MB/s  •  47s left"
    //   - everything done: "303 done"
    //   - mix with failures: "303 done  •  4 failed"
    // One vocabulary in the tree: if checksum verification ran,
    // the aggregate reads "N done, verified" to match the children's "Verified";
    // otherwise both say "Done".
    final anyVerified = widget.transfers.any((t) =>
        t.status == TransferStatus.completed &&
        t.verify == SftpVerifyResult.ok);
    final countText = active > 0
        ? (done > 0
            ? l10n.sftpActivityRunningDone(active, done)
            : l10n.sftpActivityRunning(active))
        : (total > 0
            ? (anyVerified
                ? l10n.sftpActivityDoneVerified(done)
                : l10n.sftpActivityDone(done))
            : '');
    final segments = <String>[if (countText.isNotEmpty) countText];
    if (active > 0 && speedText.isNotEmpty) segments.add(speedText);
    if (active > 0 && etaText.isNotEmpty) segments.add(etaText);
    if (failed > 0) segments.add(l10n.sftpActivityFailed(failed));
    // With nothing queued the collapsed bar still reads clearly rather than
    // sitting blank.
    final statusLine =
        segments.isEmpty ? l10n.sftpActivityNone : segments.join('  •  ');

    // Expanded or not, to a screen reader (4.0 accessibility pass).
    return Semantics(
      expanded: _isExpanded,
      child: InkWell(
      onTap: () => setState(() => _isExpanded = !_isExpanded),
      child: Container(
        // Taller than before because we render a real progress bar
        // along the bottom of the title strip - the user wanted a
        // single overall indicator visible even when the panel is
        // collapsed. (2 above and below: Clear completed is 32 square.)
        height: 44,
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Row 1: chevron + label + status + actions
            Row(
              children: [
                Icon(
                  _isExpanded
                      ? LucideIcons.chevronDown
                      : LucideIcons.chevronRight,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  // The queue is unified now - deletes, chmods and mkdirs run
                  // here alongside transfers - so it is "Activity", not
                  // "Transfers". Per-op rows carry their own verb, the status
                  // line the counts.
                  l10n.sftpActivityTitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    statusLine,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
                const Spacer(),
                if (widget.onClearCompleted != null && done > 0)
                  Tooltip(
                    message: l10n.remoteTransferClearCompleted,
                    child: InkWell(
                      onTap: widget.onClearCompleted,
                      borderRadius: BorderRadius.circular(4),
                      // 32 square to a mouse (it was 24).
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(LucideIcons.listX,
                            size: 16, color: AppColors.textSecondary),
                      ),
                    ),
                  ),
              ],
            ),
            // Row 2: the full-width overall progress bar - only when something
            // is (or was) queued; an empty bar on an idle panel is noise.
            if (total > 0) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: allDone ? 1.0 : progress,
                  color: failed > 0 && allDone
                      ? AppColors.warning
                      : active > 0
                          ? AppColors.brandOrange
                          : AppColors.textSecondary,
                  backgroundColor: AppColors.surfaceLight,
                  minHeight: 4,
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildTransferList() {
    final grouped = _groupTransfers();

    // Build a flat INDEX of "what to render": one parent row per
    // operation, child rows only when that operation is expanded,
    // then ungrouped one-off transfers at the end. Only the index is
    // built here; the row WIDGETS are built by the ListView on demand
    // (visible rows only). Building every row widget up front cost
    // ~50 ms per publish with a 16k-item operation expanded (measured
    // in test/ui/transfer_queue_panel_perf_test.dart), 15x a second for
    // the whole of a folder upload.
    final sections = <_RowSection>[];
    var rowCount = 0;
    for (final group in grouped.groups) {
      final isExpanded = _expandedOps.contains(group.id);
      final count = 1 + (isExpanded ? group.items.length : 0);
      sections.add(_RowSection(
        group: group,
        expanded: isExpanded,
        start: rowCount,
        count: count,
      ));
      rowCount += count;
    }
    final ungroupedStart = rowCount;
    rowCount += grouped.ungrouped.length;

    Widget rowAt(int i) {
      if (i >= ungroupedStart) {
        return _buildTransferRow(grouped.ungrouped[i - ungroupedStart],
            indent: false);
      }
      // One section per operation, so a linear scan is cheap.
      for (final s in sections) {
        if (i < s.start + s.count) {
          final local = i - s.start;
          if (local == 0) return _buildOperationRow(s.group, s.expanded);
          return _buildTransferRow(s.group.items[local - 1], indent: true);
        }
      }
      throw StateError('transfer row $i out of range ($rowCount rows)');
    }

    // Roughly: parent rows = 44px, child rows = 38px. Cap at ~6 row
    // heights so the panel never eats half the screen; scroll past
    // that. Empty state is handled at the build() level.
    const collapsedRowHeight = 44.0;
    final cap = collapsedRowHeight * 6;
    final naturalHeight = rowCount * collapsedRowHeight + 8;
    final maxHeight = naturalHeight > cap ? cap : naturalHeight;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 4),
        itemCount: rowCount,
        itemBuilder: (context, i) => rowAt(i),
      ),
    );
  }

  /// Parent row for one transfer operation - collapsed by default,
  /// click to expand. Shows aggregated progress, file count, and
  /// status badge. Matches WinSCP's "main panel row + drawer of
  /// per-file rows" pattern.
  Widget _buildOperationRow(_OperationGroup group, bool isExpanded) {
    final label = group.label;
    final direction = group.direction;
    final total = group.totalBytes;
    final transferred = group.transferredBytes;
    final progress = total > 0 ? transferred / total : 0.0;
    final done = group.completedCount;
    final failed = group.failedCount;
    final cancelled = group.cancelledCount;
    final active = group.activeCount;
    final pending = group.pendingCount;
    final overallStatus = group.aggregateStatus;
    final hasActive = active > 0 || pending > 0;
    final preview = operationRootsPreview(group.roots);
    final l10n = AppLocalizations.of(context)!;
    final subStyle = TextStyle(
      fontSize: 10,
      color: AppColors.textSecondary,
      fontFamily: 'JetBrainsMono',
    );

    return InkWell(
      onTap: () {
        setState(() {
          if (isExpanded) {
            _expandedOps.remove(group.id);
          } else {
            _expandedOps.add(group.id);
          }
        });
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            // Expand chevron
            Icon(
              isExpanded
                  ? LucideIcons.chevronDown
                  : LucideIcons.chevronRight,
              size: 14,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 4),
            // Folder icon w/ direction tint
            Icon(
              direction == TransferDirection.upload
                  ? LucideIcons.folderUp
                  : LucideIcons.folderArchive,
              size: 16,
              color: AppColors.accentInk,
            ),
            const SizedBox(width: 8),
            // Operation name + count subline
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurface,
                    ),
                  ),
                  // "rag-corpus, pipeline +1  ·  67 / 70 files": an "N items"
                  // batch names what was dragged, so running batches can be
                  // told apart without expanding them. The names give way
                  // (ellipsis) before the count does.
                  Row(
                    children: [
                      if (preview.isNotEmpty) ...[
                        Flexible(
                          child: Text(
                            preview,
                            key: const ValueKey('operation-roots-preview'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: subStyle,
                          ),
                        ),
                        Text('  ·  ', style: subStyle),
                      ],
                      Text(
                        [
                          l10n.sftpOpFilesProgress(done, group.fileCount),
                          if (failed > 0) l10n.sftpActivityFailed(failed),
                          if (cancelled > 0)
                            l10n.sftpActivityCancelled(cancelled),
                        ].join('  •  '),
                        maxLines: 1,
                        style: subStyle,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Aggregated progress
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    LinearProgressIndicator(
                      value: hasActive ? progress : (done == group.fileCount
                          ? 1.0
                          : progress),
                      color: _statusColor(overallStatus),
                      backgroundColor: AppColors.surfaceLight,
                      minHeight: 3,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${TransferItem._formatBytes(transferred)} / '
                      '${TransferItem._formatBytes(total)}',
                      style: TextStyle(
                        fontSize: 9,
                        color: AppColors.textSecondary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Aggregated speed / status
            SizedBox(
              width: 120,
              child: Text(
                hasActive
                    ? formatByteRate(group.speedBytesPerSec)
                    : _statusLabel(l10n, overallStatus),
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'JetBrainsMono',
                  color: _statusColor(overallStatus),
                ),
              ),
            ),
            // Cancel all / retry all
            if (hasActive && widget.onCancel != null)
              Tooltip(
                message: l10n.sftpOverwriteCancelAll,
                child: InkWell(
                  onTap: () {
                    if (widget.onCancelOperation != null) {
                      widget.onCancelOperation!(group.id);
                      return;
                    }
                    for (final t in group.items) {
                      if (t.status == TransferStatus.active ||
                          t.status == TransferStatus.pending) {
                        widget.onCancel?.call(t.id);
                      }
                    }
                  },
                  borderRadius: BorderRadius.circular(4),
                  // A stop square in the destructive colour: it halts work in
                  // flight, so it must not share the grey x that only clears a
                  // finished row from the list.
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(LucideIcons.square,
                        size: 15, color: AppColors.sftpCrit),
                  ),
                ),
              )
            else if (failed > 0 && widget.onRetry != null)
              Tooltip(
                message: l10n.sftpRetryFailed,
                child: InkWell(
                  onTap: () {
                    for (final t in group.items) {
                      if (t.status == TransferStatus.failed) {
                        widget.onRetry?.call(t.id);
                      }
                    }
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(LucideIcons.refreshCw,
                        size: 14, color: AppColors.accentInk),
                  ),
                ),
              )
            else
              const SizedBox(width: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferRow(TransferItem item, {bool indent = false}) {
    debugTransferRowBuilds++;
    // For child rows under an operation, render the relative path
    // (e.g. `assets/icon.png`) instead of just the leaf name so the
    // user can see WHERE in the dropped tree the file lives. For
    // ungrouped rows, fall back to the bare file name as before.
    String displayName = item.fileName;
    if (indent && item.operationSourceRoot != null) {
      // remotePath / localPath corresponds to the destination side;
      // we want to derive the relative path from the source path of
      // the operation root. The TransferItem stores localPath as the
      // SOURCE absolute path, so subtract the operation source root.
      final root = item.operationSourceRoot!;
      // Strip trailing separator on root for clean prefix comparison.
      final normalizedRoot = root.endsWith('/') || root.endsWith(r'\')
          ? root.substring(0, root.length - 1)
          : root;
      if (item.localPath.startsWith(normalizedRoot) &&
          item.localPath.length > normalizedRoot.length) {
        var rel = item.localPath.substring(normalizedRoot.length);
        if (rel.startsWith('/') || rel.startsWith(r'\')) {
          rel = rel.substring(1);
        }
        if (rel.isNotEmpty) displayName = rel;
      }
    }

    final nameStyle = TextStyle(
      fontSize: 12,
      fontFamily: indent ? 'JetBrainsMono' : null,
      color: indent ? AppColors.textSecondary : AppColors.onSurface,
    );
    // Why it failed, as its second line (3.0: only on hover over
    // the progress bar, raw).
    final why = item.status == TransferStatus.failed ? item.errorMessage : null;

    return Container(
      height: 38,
      padding: EdgeInsets.only(
        left: indent ? 36 : 12,
        right: 12,
        top: 2,
        bottom: 2,
      ),
      child: Row(
        children: [
          // What the row says is one sentence to a screen reader (4.0
          // accessibility pass: its name, its second line, its progress and
          // its state were read apart); its buttons stay controls of their own.
          Expanded(
            child: MergeSemantics(
              child: Row(
                children: [
          // Operation-kind glyph in a tinted tile, coloured by
          // STATUS (one colour per state): orange running, green done, red on
          // failure, muted queued/cancelled.
          _kindTile(item),
          const SizedBox(width: 10),
          // Name + a second line: the destination ("to /root") for a transfer,
          // or the op's own subtitle (its path) for a delete/chmod/mkdir. Child
          // rows already show the relative path as their name, so they skip it.
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The path (child rows) can outrun its column. Truncate on the
                // LEFT with a leading "..." so the file NAME stays visible
                // (`.../nested/deploy.sh`, not `scripts/very/long/pa...`); the
                // full path is on hover. A bare leaf keeps end-ellipsis.
                Tooltip(
                  message: displayName,
                  waitDuration: const Duration(milliseconds: 500),
                  child: (displayName.contains('/') ||
                          displayName.contains(r'\'))
                      ? _LeftEllipsisText(displayName, style: nameStyle)
                      : Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: nameStyle,
                        ),
                ),
                if (why != null)
                  Tooltip(
                    message: why,
                    waitDuration: const Duration(milliseconds: 500),
                    child: Text(
                      why,
                      key: ValueKey('transfer-failure-${item.id}'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 10, color: AppColors.sftpCrit),
                    ),
                  )
                else if (!indent && _subtitleFor(item) != null)
                  Tooltip(
                    message: _subtitleFor(item)!,
                    waitDuration: const Duration(milliseconds: 500),
                    child: Text(
                      _subtitleFor(item)!,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Progress bar
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _buildProgressContent(item),
            ),
          ),
          // Speed / ETA while running; on completion, the checksum verdict
          // ("Verified" / "Checksum mismatch") when one was computed, else "Done".
          SizedBox(
            width: 120,
            child: Text(
              _rowStateText(item),
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'JetBrainsMono',
                color: _rowStateColor(item),
              ),
            ),
          ),
                ],
              ),
            ),
          ),
          _buildRowTrailing(item),
        ],
      ),
    );
  }

  /// The trailing control(s) on a row. A running item shows a red stop square
  /// (Cancel transfer: it stops work in flight); a finished one shows a grey x
  /// (Remove from list: harmless). Two shapes, so the safe x never trains a
  /// click that lands on a live transfer. A failed BYTE transfer also shows a retry
  /// ↻ (a failed delete/chmod has no path to re-run, so it only gets dismiss -
  /// the panel used to render a retry that fired a nonsensical empty transfer).
  Widget _buildRowTrailing(TransferItem item) {
    // A held delete offers Undo (nothing sent yet) and Delete now, nothing else.
    if (item.status == TransferStatus.holding) {
      final l10n = AppLocalizations.of(context)!;
      final children = <Widget>[
        if (widget.onUndoHold != null)
          _rowTextButton(l10n.sftpDeleteUndo, AppColors.brandOrange,
              () => widget.onUndoHold!(item.id)),
        if (widget.onCommitHold != null)
          _rowTextButton(l10n.sftpDeleteNow, AppColors.sftpCrit,
              () => widget.onCommitHold!(item.id)),
      ];
      if (children.isEmpty) return const SizedBox(width: 22);
      return Row(mainAxisSize: MainAxisSize.min, children: children);
    }
    final isActive = item.status == TransferStatus.active ||
        item.status == TransferStatus.pending;
    final l10n = AppLocalizations.of(context)!;
    final children = <Widget>[];
    if (isActive) {
      if (widget.onCancel != null) {
        children.add(_rowIconButton(LucideIcons.square, AppColors.sftpCrit,
            l10n.sftpCancelTransfer, () => widget.onCancel!(item.id)));
      }
    } else {
      // Its report, to copy for support or an assistant.
      if (item.status == TransferStatus.failed && item.errorReport != null) {
        final copied = _copiedReports.contains(item.id);
        children.add(_rowIconButton(
          copied ? LucideIcons.check : LucideIcons.copy,
          AppColors.textSecondary,
          copied ? l10n.migrationErrorCopied : l10n.desktopShellCopyDetails,
          () => _copyReport(item),
        ));
      }
      if (item.status == TransferStatus.failed &&
          !item.isCountBased &&
          widget.onRetry != null) {
        children.add(_rowIconButton(LucideIcons.refreshCw, AppColors.brandOrange,
            l10n.retry, () => widget.onRetry!(item.id)));
      }
      if (widget.onDismiss != null) {
        children.add(_rowIconButton(LucideIcons.x, AppColors.textSecondary,
            l10n.sftpRemoveFromList, () => widget.onDismiss!(item.id)));
      }
    }
    if (children.isEmpty) return const SizedBox(width: 22);
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _rowIconButton(
      IconData icon, Color color, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        // 32 square to a mouse (4.0 accessibility pass: 18), the icon as it
        // was.
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }

  /// A small text action (Undo / Delete now) on a held-delete row.
  Widget _rowTextButton(String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        // 32 high to a mouse (it was some 20).
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }

  /// The op-kind glyph in a small tinted tile. Colour tracks
  /// status - orange active, green done, red on failure, muted otherwise.
  Widget _kindTile(TransferItem item) {
    // Row-state colour so a destructive op's tile stays crit.
    final c = _rowStateColor(item);
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.withValues(alpha: 0.34)),
      ),
      child: Icon(_iconForKind(item.kind), size: 13, color: c),
    );
  }

  /// Second line under a row's name: the op's own subtitle (its path) for a
  /// count op, else the destination directory of a transfer ("to /root").
  String? _subtitleFor(TransferItem item) {
    final sub = item.subtitle;
    if (sub != null && sub.isNotEmpty) return sub;
    final dest = item.direction == TransferDirection.upload
        ? item.remotePath
        : item.localPath;
    final dir = _dirname(dest);
    return dir.isEmpty ? null : AppLocalizations.of(context)!.sftpToPath(dir);
  }

  String _dirname(String p) {
    if (p.isEmpty) return '';
    final norm = p.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    if (i < 0) return '';
    return i == 0 ? '/' : norm.substring(0, i);
  }

  Widget _buildProgressContent(TransferItem item) {
    if (item.status == TransferStatus.holding) {
      // Nothing is happening yet - an empty crit bar, the countdown lives in
      // the trailing state text.
      return LinearProgressIndicator(
        value: 0,
        color: AppColors.sftpCrit,
        backgroundColor: AppColors.surfaceLight,
        minHeight: 3,
      );
    }
    if (item.status == TransferStatus.completed) {
      // Done bar takes the row-state colour: --ok green normally, crit for a
      // finished destructive op - never #22c55e.
      return LinearProgressIndicator(
        value: 1.0,
        color: _rowStateColor(item),
        backgroundColor: AppColors.surfaceLight,
        minHeight: 3,
      );
    }
    if (item.status == TransferStatus.failed) {
      return Tooltip(
        message: item.errorMessage ??
            AppLocalizations.of(context)!.notifPrefsTransferFailed,
        child: LinearProgressIndicator(
          value: item.progress,
          color: AppColors.sftpCrit,
          backgroundColor: AppColors.surfaceLight,
          minHeight: 3,
        ),
      );
    }
    if (item.status == TransferStatus.cancelled) {
      return LinearProgressIndicator(
        value: item.progress,
        color: AppColors.textSecondary,
        backgroundColor: AppColors.surfaceLight,
        minHeight: 3,
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        LinearProgressIndicator(
          // Indeterminate (animated) while pending, or for a plain delete that
          // has no known total - so it never sits at a stuck-looking 0%.
          value: item.status == TransferStatus.pending || item.isIndeterminate
              ? null
              : item.progress,
          // Running is brand, but a running DESTRUCTIVE op is crit
          // so a delete in flight must not read as an ordinary transfer.
          color: _rowStateColor(item),
          backgroundColor: AppColors.surfaceLight,
          minHeight: 3,
        ),
        const SizedBox(height: 2),
        Text(
          item.formattedProgress,
          style: TextStyle(
            fontSize: 9,
            color: AppColors.textSecondary,
            fontFamily: 'JetBrainsMono',
          ),
        ),
      ],
    );
  }

  String _statusLabel(AppLocalizations l10n, TransferStatus status) {
    return switch (status) {
      TransferStatus.holding => l10n.sftpStatusHolding,
      TransferStatus.pending => l10n.sftpStatusPending,
      TransferStatus.active => l10n.sftpStatusActive,
      TransferStatus.completed => l10n.done,
      TransferStatus.failed => l10n.automationHistoryStatusFailed,
      TransferStatus.cancelled => l10n.sftpStatusCancelled,
    };
  }

  /// The right-hand state text: live rate/ETA while running, or on completion
  /// the checksum verdict when a verification ran.
  String _rowStateText(TransferItem item) {
    final l10n = AppLocalizations.of(context)!;
    if (item.status == TransferStatus.holding) {
      final until = item.holdUntil;
      final ms =
          until == null ? 0 : until.difference(DateTime.now()).inMilliseconds;
      final s = ms <= 0 ? 0 : (ms / 1000).ceil();
      return l10n.sftpDeleteHolding(s);
    }
    if (item.status == TransferStatus.active) {
      return item.isCountBased
          ? _activeVerb(l10n, item.kind)
          : '${item.formattedSpeed}  ${item.formattedEta}';
    }
    if (item.status == TransferStatus.completed) {
      // A finished destructive op reads "Deleted", not "Done".
      if (_isDestructive(item)) return l10n.sftpDeleted;
      switch (item.verify) {
        case SftpVerifyResult.ok:
          return l10n.sftpVerified;
        case SftpVerifyResult.mismatch:
          return l10n.sftpChecksumMismatch;
        case SftpVerifyResult.none:
        case SftpVerifyResult.unavailable:
          return l10n.done;
      }
    }
    return _statusLabel(l10n, item.status);
  }

  /// A verified-mismatch is a failure of integrity - the one coloured outcome
  /// on an otherwise-muted completed row.
  /// A destructive op (delete) stays CRIT at every live stage - a finished
  /// delete must never draw as a green success line.
  bool _isDestructive(TransferItem item) =>
      item.kind == SftpOperationKind.delete;

  Color _rowStateColor(TransferItem item) {
    if (_isDestructive(item) &&
        item.status != TransferStatus.pending &&
        item.status != TransferStatus.cancelled) {
      return AppColors.sftpCrit;
    }
    if (item.status == TransferStatus.completed &&
        item.verify == SftpVerifyResult.mismatch) {
      return AppColors.sftpCrit;
    }
    return _statusColor(item.status);
  }

  // One colour per state: queued muted, running brand,
  // done --ok #4f9d69 (the palette green, NOT #22c55e), failed crit, cancelled
  // muted. The one exception is destructive ops, handled in _rowStateColor.
  Color _statusColor(TransferStatus status) {
    return switch (status) {
      // A holding delete is destructive from the first frame - crit, never green.
      TransferStatus.holding => AppColors.sftpCrit,
      TransferStatus.pending => AppColors.textSecondary,
      TransferStatus.active => AppColors.brandOrange,
      TransferStatus.completed => AppColors.sftpOk,
      TransferStatus.failed => AppColors.sftpCrit,
      TransferStatus.cancelled => AppColors.textSecondary,
    };
  }

  /// Activity-row glyph per operation kind.
  IconData _iconForKind(SftpOperationKind kind) {
    return switch (kind) {
      SftpOperationKind.upload => LucideIcons.upload,
      SftpOperationKind.download => LucideIcons.download,
      SftpOperationKind.delete => LucideIcons.trash2,
      SftpOperationKind.chmod => LucideIcons.lock,
      SftpOperationKind.mkdir => LucideIcons.folderPlus,
      SftpOperationKind.sync => LucideIcons.folderSync,
    };
  }

  /// Present-tense verb shown while a count operation runs, in the slot a
  /// byte transfer uses for its rate (a delete has no "bytes per second").
  String _activeVerb(AppLocalizations l10n, SftpOperationKind kind) {
    return switch (kind) {
      SftpOperationKind.delete => l10n.sftpActiveDeleting,
      SftpOperationKind.chmod => l10n.sftpActiveApplying,
      SftpOperationKind.mkdir => l10n.sftpActiveCreating,
      SftpOperationKind.sync => l10n.sftpActiveSyncing,
      _ => l10n.sftpActiveWorking,
    };
  }
}

/// All [TransferItem]s sharing the same [TransferItem.operationId],
/// pre-aggregated. Exists only inside the panel - the upstream
/// transfer pipeline doesn't need to know about it.
/// One operation's slice of the flat row index: its header row at [start],
/// then (when [expanded]) one row per item.
class _RowSection {
  const _RowSection({
    required this.group,
    required this.expanded,
    required this.start,
    required this.count,
  });

  final _OperationGroup group;
  final bool expanded;
  final int start;
  final int count;
}

/// Every title-bar aggregate, computed in one pass (see _computeTotals).
class _Totals {
  const _Totals({
    required this.active,
    required this.pending,
    required this.completed,
    required this.failed,
    required this.totalBytes,
    required this.transferredBytes,
    required this.speed,
    required this.eta,
  });

  final int active;
  final int pending;
  final int completed;
  final int failed;
  final int totalBytes;
  final int transferredBytes;
  final double speed;
  final Duration? eta;
}

/// The collapsed preview of a multi-entry batch: its first two names, then
/// "+N" for the rest ("rag-corpus, pipeline +1"). Empty when there are none.
String operationRootsPreview(List<String>? roots) {
  if (roots == null || roots.isEmpty) return '';
  if (roots.length <= 2) return roots.join(', ');
  return '${roots.take(2).join(', ')} +${roots.length - 2}';
}

class _OperationGroup {
  /// Aggregates are computed ONCE here, in a single pass over [items]. They
  /// used to be ~12 separate getters that each re-walked every item, and the
  /// operation row read all of them on every rebuild - O(12N) per publish,
  /// which at 16k files (a website tree with node_modules) was the bulk of the
  /// main-isolate time during a folder upload.
  factory _OperationGroup({
    required String id,
    required List<TransferItem> items,
  }) {
    var totalBytes = 0;
    var transferredBytes = 0;
    var completed = 0;
    var failed = 0;
    var cancelled = 0;
    var active = 0;
    var pending = 0;
    var speed = 0.0;
    var files = 0;
    for (final t in items) {
      // With the finished files whose rows the list no longer keeps.
      totalBytes += t.totalBytes + t.earlierTotalBytes;
      transferredBytes += t.transferredBytes + t.earlierTransferredBytes;
      completed += t.earlierCompleted;
      cancelled += t.earlierCancelled;
      files += t.fileCount;
      switch (t.status) {
        case TransferStatus.completed:
          completed++;
        case TransferStatus.failed:
          failed++;
        case TransferStatus.cancelled:
          cancelled++;
        case TransferStatus.active:
          active++;
          speed += t.speedBytesPerSec;
        case TransferStatus.pending:
          pending++;
        default:
          break;
      }
    }
    return _OperationGroup._(
      id: id,
      items: items,
      fileCount: files,
      totalBytes: totalBytes,
      transferredBytes: transferredBytes,
      completedCount: completed,
      failedCount: failed,
      cancelledCount: cancelled,
      activeCount: active,
      pendingCount: pending,
      speedBytesPerSec: speed,
    );
  }

  const _OperationGroup._({
    required this.id,
    required this.items,
    required this.fileCount,
    required this.totalBytes,
    required this.transferredBytes,
    required this.completedCount,
    required this.failedCount,
    required this.cancelledCount,
    required this.activeCount,
    required this.pendingCount,
    required this.speedBytesPerSec,
  });

  final String id;
  final List<TransferItem> items;

  /// The operation's files: one per row, and the finished ones whose rows
  /// the list no longer keeps.
  final int fileCount;

  final int totalBytes;
  final int transferredBytes;
  final int completedCount;
  final int failedCount;
  final int cancelledCount;
  final int activeCount;
  final int pendingCount;

  /// Sum of per-item speeds across the active items. Approximates the
  /// throughput of the operation as a whole (in WinSCP this is the number
  /// under the "Transferring at" label).
  final double speedBytesPerSec;

  /// First file's start time - used to sort groups newest-first.
  DateTime get startedAt => items.first.startedAt;

  /// Label inherited from the first item in the batch. Every item
  /// in a group has the same [TransferItem.operationLabel] so this
  /// is just the cheap accessor.
  String get label => items.first.operationLabel ?? id;

  /// Direction inherited from the first item - every item in a
  /// batch shares the same source / destination.
  TransferDirection get direction => items.first.direction;

  /// The dragged entries' names for a multi-entry drop, shared by every item.
  List<String>? get roots => items.first.operationRoots;

  /// Pick the most "interesting" status for the parent row badge.
  /// Priority: active > pending > failed > cancelled > completed.
  /// (Failures stay visible even after everything else finishes so
  /// the user notices them.)
  TransferStatus get aggregateStatus {
    if (activeCount > 0) return TransferStatus.active;
    if (pendingCount > 0) return TransferStatus.pending;
    if (failedCount > 0) return TransferStatus.failed;
    if (cancelledCount > 0 && completedCount == 0) {
      return TransferStatus.cancelled;
    }
    return TransferStatus.completed;
  }
}

/// A single-line text that truncates on the LEFT with a leading "..." so the
/// END stays visible when it overflows: a long transfer path keeps its file
/// name (`.../nested/deploy.sh`) instead of clipping it off the right edge
/// (`scripts/very/long/pa...`). Pair it with a Tooltip to reveal the full text.
///
/// Flutter's TextOverflow only ellipsizes the end, so this measures with a
/// TextPainter and binary-searches the longest visible suffix that fits.
class _LeftEllipsisText extends StatelessWidget {
  const _LeftEllipsisText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        Widget plain(String s) =>
            Text(s, style: style, maxLines: 1, softWrap: false);
        if (!maxWidth.isFinite || maxWidth <= 0) return plain(text);

        double widthOf(String s) {
          final tp = TextPainter(
            text: TextSpan(text: s, style: style),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout();
          return tp.width;
        }

        if (widthOf(text) <= maxWidth) return plain(text);

        const lead = '...';
        // Largest k such that "..." + the last k characters still fits.
        var lo = 0;
        var hi = text.length;
        var best = lead;
        while (lo <= hi) {
          final mid = (lo + hi) >> 1;
          final candidate = lead + text.substring(text.length - mid);
          if (widthOf(candidate) <= maxWidth) {
            best = candidate;
            lo = mid + 1;
          } else {
            hi = mid - 1;
          }
        }
        return Text(best,
            style: style, maxLines: 1, softWrap: false, overflow: TextOverflow.clip);
      },
    );
  }
}
