import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/services/sftp_sync_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// What the user chose in the mirror preview. [run] false means they closed it
/// (a dry run: they saw the plan and did not sync). [plan] is the plan actually
/// shown, re-planned if the user toggled Verify-by-content or Force, so the
/// caller runs exactly what the preview counted.
class SftpMirrorChoice {
  final bool run;
  final bool deleteRemoteOnly;
  final SftpSyncOptions options;
  final SyncPlan plan;
  const SftpMirrorChoice({
    required this.run,
    required this.deleteRemoteOnly,
    required this.options,
    required this.plan,
  });
}

/// Preview of a one-way folder sync (local -> remote) before it runs.
///
/// The whole safety of a folder sync is that the user sees EXACTLY what will be
/// created, replaced, skipped, and (only if they opt in) deleted, before a
/// single byte moves (spec 6). No per-file prompts, one decision. Closing the
/// dialog is the dry run. A plan that is partial (hit the entry cap, or the
/// scan was cancelled) can be looked at but never run.
class SftpMirrorPreviewDialog extends StatefulWidget {
  const SftpMirrorPreviewDialog({
    super.key,
    required this.sourceLabel,
    required this.destPath,
    required this.initialPlan,
    required this.initialOptions,
    required this.onReplan,
    this.verifyRemembered = false,
  });

  final String sourceLabel;
  final String destPath;
  final SyncPlan initialPlan;
  final SftpSyncOptions initialOptions;

  /// True when [initialOptions.verifyContent] was restored from this folder
  /// pair's remembered choice (not the default). Drives a one-line caption so
  /// the pre-ticked toggle is explained rather than mysterious.
  final bool verifyRemembered;

  /// Re-run the plan with new options (Verify-by-content / Force), so the
  /// preview counts stay truthful. Returns the fresh plan.
  final Future<SyncPlan> Function(SftpSyncOptions options) onReplan;

  static Future<SftpMirrorChoice?> show(
    BuildContext context, {
    required String sourceLabel,
    required String destPath,
    required SyncPlan initialPlan,
    required SftpSyncOptions initialOptions,
    required Future<SyncPlan> Function(SftpSyncOptions options) onReplan,
    bool verifyRemembered = false,
  }) {
    return showZestModal<SftpMirrorChoice>(
      context: context,
      size: ZestModalSize.standard,
      child: SftpMirrorPreviewDialog(
        sourceLabel: sourceLabel,
        destPath: destPath,
        initialPlan: initialPlan,
        initialOptions: initialOptions,
        onReplan: onReplan,
        verifyRemembered: verifyRemembered,
      ),
    );
  }

  @override
  State<SftpMirrorPreviewDialog> createState() =>
      _SftpMirrorPreviewDialogState();
}

class _SftpMirrorPreviewDialogState extends State<SftpMirrorPreviewDialog> {
  late SyncPlan _plan = widget.initialPlan;
  late SftpSyncOptions _options = widget.initialOptions;
  bool _deleteRemoteOnly = false;
  bool _busy = false;
  bool _replanFailed = false;

  /// The report of why the plan could not be made again, to copy.
  String? _replanReport;

  List<SyncPlanItem> get _uploads =>
      _plan.items.where((p) => p.action == SyncAction.upload).toList();
  int get _newCount => _uploads.where((p) => p.isNew).length;
  int get _changedCount => _uploads.where((p) => !p.isNew).length;
  int get _unchanged =>
      _plan.items.where((p) => p.action == SyncAction.skipUpToDate).length;
  List<SyncPlanItem> get _remoteOnly =>
      _plan.items.where((p) => p.action == SyncAction.deleteRemote).toList();

  /// Everything the plan will not touch for a stated reason (an exclude
  /// pattern, a symlink, a name the server holds twice, a file-vs-folder
  /// clash). Shown as one count so the numbers add up to the folder and no
  /// file is skipped invisibly.
  int get _skipped => _plan.items
      .where((p) =>
          p.action == SyncAction.skipExcluded ||
          p.action == SyncAction.skipCaseCollision ||
          p.action == SyncAction.skipLink ||
          p.action == SyncAction.skipTypeConflict)
      .length;

  /// A partial plan must never run: its "only on the server" list was computed
  /// against an incomplete walk.
  bool get _blocked => _plan.truncated || _plan.cancelled;

  Future<void> _replan(SftpSyncOptions next) async {
    setState(() => _busy = true);
    try {
      final fresh = await widget.onReplan(next);
      if (!mounted) return;
      setState(() {
        _plan = fresh;
        _options = next;
        _replanFailed = false;
        _replanReport = null;
      });
    } catch (e, stack) {
      // Connection dropped mid-scan (hashing is a shell exec): keep the
      // previous plan/options pair, which is still internally consistent, and
      // say so instead of silently snapping the checkbox back.
      if (mounted) {
        setState(() {
          _replanFailed = true;
          _replanReport = ErrorReport.build(
            what: gl10n.sftpSyncReplanFailed,
            where: 'Files: planning a mirror again',
            error: e,
            stack: stack,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtSize(int bytes) => formatByteSize(bytes);

  /// A remote path shown relative to the destination root, so a long list of
  /// deletions reads as file names, not repeated prefixes.
  String _relName(String remotePath) {
    var root = widget.destPath;
    if (root.length > 1 && root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    if (remotePath.startsWith('$root/')) {
      return remotePath.substring(root.length + 1);
    }
    return remotePath;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final uploads = _uploads;
    final totalBytes = uploads.fold<int>(0, (a, p) => a + p.size);
    final remoteOnly = _remoteOnly;
    final syncCount =
        uploads.length + (_deleteRemoteOnly ? remoteOnly.length : 0);
    final nothingToDo = syncCount == 0;
    final runDisabled = _busy || nothingToDo || _blocked;

    // The shell (the dialog rules of 3.4): the counts and options in the
    // body, its warnings in amber sentences, Cancel and Sync in the footer,
    // the main button red where it also deletes on the server.
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.folderSync,
      title: l10n.sftpSyncPreviewTitle(widget.sourceLabel, widget.destPath),
      body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The plan is being made again (Verify by content, Force).
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(
                    key: const ValueKey('sftp-mirror-replanning'),
                    minHeight: 2,
                    color: AppColors.v3TextSecondary,
                    backgroundColor: AppColors.v3BorderSubtle,
                  ),
                ),
              // Counts, the heart of the preview. They add up to the folder.
              _countRow(l10n.sftpSyncChanged(_changedCount), _changedCount > 0),
              _countRow(l10n.sftpSyncNew(_newCount), _newCount > 0),
              _countRow(l10n.sftpSyncUnchanged(_unchanged), false),
              if (remoteOnly.isNotEmpty)
                _countRow(l10n.sftpSyncRemoteOnly(remoteOnly.length), false),
              if (_skipped > 0) _countRow(l10n.sftpSyncSkipped(_skipped), false),
              if (uploads.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(l10n.sftpSyncBytesToSend(_fmtSize(totalBytes)),
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ],
              const SizedBox(height: 12),
              // Reasons this plan cannot run, or should be read carefully.
              if (_plan.truncated)
                _warn(l10n.sftpSyncTooManyEntries(SftpSyncService.maxEntries)),
              for (final dir in _plan.unreadableDirs)
                _warn(l10n.sftpSyncUnreadableDir(dir)),
              // Case / Unicode collision warnings (spec 5d, 5b).
              for (final pair in _plan.caseCollisions)
                _warn(l10n.sftpCaseCollision(
                    pair.split(' / ').first, pair.split(' / ').last)),
              if (_replanFailed) _warn(l10n.sftpSyncReplanFailed),
              if (_replanFailed && _replanReport != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CopyDetailsButton(detail: _replanReport!),
                  ),
                ),
              // The server was proven on an earlier run to drop the timestamps
              // we set, so unchanged files are matched by size only, which can
              // miss a same-size content change. Say so, and Verify by content
              // is the escape hatch.
              if (_plan.mtimeUnreliable && !_options.verifyContent)
                _warn(l10n.sftpSyncMtimeUnreliableHint),
              // Options.
              _toggle(
                label: l10n.sftpSyncVerifyContent,
                sub: l10n.sftpSyncVerifyContentDesc,
                value: _options.verifyContent,
                onChanged: _busy
                    ? null
                    : (v) => _replan(_options.copyWith(verifyContent: v)),
              ),
              if (widget.verifyRemembered && _options.verifyContent)
                Padding(
                  padding: const EdgeInsets.only(left: 28, bottom: 4),
                  child: Text(
                    l10n.sftpSyncVerifyRemembered,
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              _toggle(
                label: l10n.sftpForceReupload,
                sub: l10n.sftpForceReuploadDesc,
                value: _options.forceReupload,
                onChanged: _busy
                    ? null
                    : (v) => _replan(_options.copyWith(forceReupload: v)),
              ),
              if (remoteOnly.isNotEmpty) ...[
                // Every name the user would be opting to delete, in full: a
                // deletion is never agreed to on the strength of a truncated
                // list (spec 6, "listed by name").
                Container(
                  margin: const EdgeInsets.only(top: 6, bottom: 4),
                  constraints: const BoxConstraints(maxHeight: 140),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: remoteOnly.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        child: Text(
                          _relName(remoteOnly[i].remotePath),
                          style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'JetBrainsMono',
                              color: AppColors.onSurface),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                _toggle(
                  label: l10n.sftpSyncDeleteRemoteOnly,
                  sub: '',
                  value: _deleteRemoteOnly,
                  danger: true,
                  onChanged: _blocked
                      ? null
                      : (v) => setState(() => _deleteRemoteOnly = v),
                ),
              ],
            ],
          ),
      // Closing it syncs nothing: the preview was the dry run.
      secondaryKey: const ValueKey('sftp-mirror-close'),
      secondaryAction: (
        label: l10n.sftpSyncDryRun,
        onPressed: _busy ? null : () => Navigator.of(context).pop(null),
      ),
      primaryKey: const ValueKey('sftp-mirror-run'),
      primaryDanger: _deleteRemoteOnly && !runDisabled,
      primaryAction: (
        label: nothingToDo ? l10n.sftpSyncNothingToDo : l10n.sftpSyncConfirm(syncCount),
        icon: null,
        onPressed: runDisabled
            ? null
            : () => Navigator.of(context).pop(SftpMirrorChoice(
                  run: true,
                  deleteRemoteOnly: _deleteRemoteOnly,
                  options: _options.copyWith(deleteRemoteOnly: _deleteRemoteOnly),
                  plan: _plan,
                )),
      ),
    );
  }

  Widget _countRow(String text, bool emphasize) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(text,
            style: TextStyle(
              fontSize: 13,
              color: emphasize ? AppColors.onSurface : AppColors.textSecondary,
              fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
            )),
      );

  /// A reason the plan cannot run, or should be read with care: the amber
  /// of a warning sentence (ZestCallout), the only amber a dialog has.
  Widget _warn(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ZestCallout(text),
      );

  Widget _toggle({
    required String label,
    required String sub,
    required bool value,
    required ValueChanged<bool>? onChanged,
    bool danger = false,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: value,
              onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
              fillColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.selected)
                      ? (danger ? AppColors.error : AppColors.onSurfaceVariant)
                      : Colors.transparent),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: danger ? AppColors.error : AppColors.onSurface)),
              if (sub.isNotEmpty)
                Text(sub,
                    style: TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      );
}
