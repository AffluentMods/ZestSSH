import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart' show NewPasswordFields;
import 'package:zestssh/utils/file_manager.dart' show revealFileInFileManager;
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform;

/// Icon for each entity a reconcile can surface. Only the user-recognizable
/// types [SyncDataService.assessStaleReconcile] reports appear here; their
/// localized singular/plural labels come from [_entityLabel].
const Map<String, IconData> _entityIcons = {
  'connections': LucideIcons.server,
  'identities': LucideIcons.keyRound,
  'connection_groups': LucideIcons.folder,
  'snippets': LucideIcons.code,
  'networks': LucideIcons.wifi,
  'port_forward_rules': LucideIcons.arrowLeftRight,
};

/// The localized "N connections" style label for [key] at count [n].
String _entityLabel(AppLocalizations l10n, String key, int n) {
  switch (key) {
    case 'connections':
      return l10n.staleReconcileConnectionCount(n);
    case 'identities':
      return l10n.staleReconcileKeyCount(n);
    case 'connection_groups':
      return l10n.staleReconcileGroupCount(n);
    case 'snippets':
      return l10n.staleReconcileSnippetCount(n);
    case 'networks':
      return l10n.staleReconcileNetworkCount(n);
    case 'port_forward_rules':
      return l10n.staleReconcilePortForwardRuleCount(n);
    default:
      return '';
  }
}

/// Prompt a device that has been offline longer than the tombstone-retention
/// window before it merges (and would resurrect) rows the cloud has forgotten.
///
/// Resolves with the user's [StaleReconcileChoice]. Dismissing the dialog
/// (Escape / scrim / the close control) resolves to
/// [StaleReconcileChoice.cancel] - sync stays paused this cycle and asks again
/// next time, so a dismissal can never silently resurrect anything.
Future<StaleReconcileChoice> showStaleReconcileDialog(
  BuildContext context, {
  required StaleReconcileReport report,
  DateTime? lastSync,
}) async {
  final dialog = GlobalKey<_StaleReconcileDialogState>();
  final choice = await showZestModal<StaleReconcileChoice>(
    context: context,
    size: ZestModalSize.standard,
    // Not closed while the backup is being written.
    onDismissAttempt: () async => !(dialog.currentState?._exporting ?? false),
    child: _StaleReconcileDialog(key: dialog, report: report, lastSync: lastSync),
  );
  return choice ?? StaleReconcileChoice.cancel;
}

class _StaleReconcileDialog extends ConsumerStatefulWidget {
  const _StaleReconcileDialog({super.key, required this.report, this.lastSync});

  final StaleReconcileReport report;
  final DateTime? lastSync;

  @override
  ConsumerState<_StaleReconcileDialog> createState() =>
      _StaleReconcileDialogState();
}

/// One dialog, changed in place (the dialog rules of 3.4): the question, or
/// the backup's password, typed twice. ("Export backup first" opened the
/// password in a second dialog over this one, and the saved file came back
/// with a button of its own in the body.)
class _StaleReconcileDialogState extends ConsumerState<_StaleReconcileDialog> {
  final _password = TextEditingController();
  final _again = TextEditingController();
  final _form = GlobalKey<FormState>();

  /// The backup's password is asked, in this dialog's place.
  bool _askingPassword = false;
  bool _exporting = false;

  /// Path of the encrypted backup written this session, once "Export backup
  /// first" has succeeded. Shown as a reassurance above the footer.
  String? _exportedPath;

  @override
  void dispose() {
    _password.dispose();
    _again.dispose();
    super.dispose();
  }

  void _askPassword(bool ask) => setState(() {
        _askingPassword = ask;
        _password.clear();
        _again.clear();
      });

  Future<void> _exportFirst() async {
    if (_exporting || !_form.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _exporting = true);
    final result = await ref.read(backupServiceProvider).exportBackup(_password.text);
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _askingPassword = false;
      if (result.success) _exportedPath = result.filePath ?? '';
    });
    if (!result.success) {
      showTopSnackBar(
        context,
        l10n.staleReconcileBackupFailed(result.error ?? ''),
        isError: true,
        details: result.detail,
      );
    }
  }

  Widget _passwordStep(AppLocalizations l10n) {
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.download,
      title: l10n.staleReconcileExportBackupTitle,
      subtitle: l10n.staleReconcileExportBackupSubtitle,
      // The cross goes back to the question, as Cancel does.
      onClose: _exporting ? () {} : () => _askPassword(false),
      body: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Typed twice: a slip in it would make a backup nobody can open.
            NewPasswordFields(
              password: _password,
              again: _again,
              onSubmit: _exportFirst,
              words: (
                label: l10n.staleReconcileBackupPassword,
                hint: null,
                againLabel: l10n.backupPasswordConfirmHint,
                mismatch: l10n.backupPasswordMismatch,
                tooShort: l10n.staleReconcileMinPasswordChars,
                keys: 'reconcile-backup-password',
              ),
            ),
            if (_exporting) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3TextSecondary),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.staleReconcileExporting,
                      style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
                ],
              ),
            ],
          ],
        ),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _exporting ? null : () => _askPassword(false)),
      primaryKey: const ValueKey('reconcile-backup-password-set'),
      primaryAction: (label: l10n.staleReconcileExport, icon: null, onPressed: _exporting ? null : _exportFirst),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_askingPassword) return _passwordStep(l10n);
    final report = widget.report;

    // Build the per-entity breakdown lines, biggest count first.
    final rows = <(IconData, String)>[];
    final entries = report.localOnlyIds.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final e in entries) {
      final icon = _entityIcons[e.key];
      final n = e.value.length;
      if (icon == null || n == 0) continue;
      rows.add((icon, _entityLabel(l10n, e.key, n)));
    }

    final days = widget.lastSync == null
        ? null
        : DateTime.now().difference(widget.lastSync!).inDays;
    final exported = _exportedPath;

    return ZestDialogShell(
      size: ZestModalSize.standard,
      // A question with two answers, each said in full: nothing amber (3.4).
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.history,
      title: l10n.staleReconcileTitle,
      subtitle: days == null
          ? l10n.staleReconcileSubtitleNoDays
          : l10n.staleReconcileSubtitleDays(days),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.staleReconcileIntroBody,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13.5,
              height: 1.55,
              color: AppColors.v3TextSecondary.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (icon, label) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        // Neutral: colour in a dialog is for what it means
                        // (they were amber).
                        Icon(icon, size: 15, color: AppColors.v3TextSecondary),
                        const SizedBox(width: 10),
                        Text(
                          label,
                          style: TextStyle(
                            fontFamily: 'GeistSans',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.v3TextPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.staleReconcileExplainBody,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13,
              height: 1.5,
              color: AppColors.v3TextSecondary.withValues(alpha: 0.85),
            ),
          ),
          if (exported != null) ...[
            const SizedBox(height: 14),
            // Where it went, readable, copied in one tap; Show in folder is
            // the footer's side link (it was a button in the body).
            FileSavedBody(message: l10n.accountBackupExported, path: exported, showInFolder: false),
          ],
        ],
      ),
      // The side option: the backup first; once it is made, where it is.
      tertiaryKey: ValueKey(exported == null ? 'reconcile-export-first' : 'file-saved-show'),
      tertiaryAction: exported == null
          ? (label: l10n.staleReconcileExportBackupFirst, onPressed: () => _askPassword(true))
          : isDesktopPlatform
              ? (label: l10n.fileSavedShowInFolder, onPressed: () => unawaited(revealFileInFileManager(exported)))
              : null,
      secondaryAction: (
        label: l10n.staleReconcileUseCloudVersion,
        onPressed: () => Navigator.of(context).pop(StaleReconcileChoice.adoptCloud),
      ),
      primaryAction: (
        label: l10n.staleReconcileKeepMyItems,
        icon: null,
        onPressed: () => Navigator.of(context).pop(StaleReconcileChoice.mergeAnyway),
      ),
    );
  }
}
