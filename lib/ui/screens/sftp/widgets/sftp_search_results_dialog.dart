import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Runs a recursive remote name-search and lets the user jump to a hit.
///
/// Opens immediately with a spinner, streams to a flat, actionable result list
/// (name only, one level of scope, results as a flat list you can
/// act on; not a filter syntax). Returns the chosen [SftpEntry], or null if
/// dismissed. The search is cancelled when the dialog closes.
class SftpSearchResultsDialog extends StatefulWidget {
  const SftpSearchResultsDialog({
    super.key,
    required this.service,
    required this.root,
    required this.query,
  });

  final SftpService service;
  final String root;
  final String query;

  static Future<SftpEntry?> show(
    BuildContext context, {
    required SftpService service,
    required String root,
    required String query,
  }) {
    return showZestModal<SftpEntry>(
      context: context,
      size: ZestModalSize.standard,
      child: SftpSearchResultsDialog(
        service: service,
        root: root,
        query: query,
      ),
    );
  }

  @override
  State<SftpSearchResultsDialog> createState() =>
      _SftpSearchResultsDialogState();
}

class _SftpSearchResultsDialogState extends State<SftpSearchResultsDialog> {
  List<SftpEntry>? _results;
  Object? _error;
  StackTrace? _errorStack;
  bool _cancelled = false;

  static const int _maxResults = 500;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _run() async {
    try {
      final res = await widget.service.searchRecursive(
        widget.root,
        widget.query,
        maxResults: _maxResults,
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() => _results = res);
    } catch (e, stack) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _errorStack = stack;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final l10n = AppLocalizations.of(context)!;
    // The shell (the dialog rules of 3.4): what was searched and where in its
    // head, the hits as a list (a tap on one goes there), Cancel in the
    // footer.
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.search,
      title: l10n.sftpSearchTitle(widget.query),
      subtitle: l10n.sftpSearchUnder(widget.root),
      bodyScrolls: false,
      body: _buildBody(l10n, results),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }

  Widget _buildBody(AppLocalizations l10n, List<SftpEntry>? results) {
    if (_error != null) {
      // Why, in the app's language, with its report (it was the raw error in
      // a sentence).
      final said = sftpErrorMessage(_error!, op: SftpOp.list);
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.sftpSearchStopped(said),
                key: const ValueKey('sftp-search-failed'),
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            ErrorDetailsPanel(
              report: ErrorReport.build(what: said, where: 'Files: searching subfolders', error: _error, stack: _errorStack),
            ),
          ],
        ),
      );
    }
    if (results == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.v3TextSecondary)),
            const SizedBox(height: 14),
            Text(l10n.sftpSearchingSubfolders,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(l10n.sftpNoMatchesFound,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
      );
    }
    final capped = results.length >= _maxResults;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: results.length,
            itemBuilder: (context, i) {
              final e = results[i];
              return InkWell(
                onTap: () => Navigator.of(context).pop(e),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 7),
                  child: Row(
                    children: [
                      Icon(
                        e.isSymlink
                            ? LucideIcons.link
                            : e.isDirectory
                                ? LucideIcons.folder
                                : LucideIcons.file,
                        size: 15,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.name,
                                style: TextStyle(
                                    fontSize: 13, color: AppColors.onSurface),
                                overflow: TextOverflow.ellipsis),
                            Text(
                              e.path,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'JetBrainsMono',
                                color: AppColors.textSecondary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(LucideIcons.arrowUpRight, size: 13,
                          color: AppColors.textSecondary),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
          child: Row(
            children: [
              Text(
                capped
                    ? l10n.sftpSearchCapped(_maxResults)
                    : l10n.sftpMatchCount(results.length),
                style: TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
