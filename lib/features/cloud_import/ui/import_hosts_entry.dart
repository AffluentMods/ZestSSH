import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/cloud_import/cloud_import_writer.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_view.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart' show openImportFile;
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/connection/share_link_add.dart';
import 'package:zestssh/ui/screens/desktop/dialogs/get_connected_dialogs.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

/// Opens "Import hosts" (3.0) and then what was chosen: a file it found the
/// kind of, the SSH config, PuTTY or CSV file import, a host shared as a
/// `.zest` file or as a share link, or the outcome of a cloud import.
/// [chooseFile]: it opens at Import a file's question, which file.
Future<void> openImportHosts(BuildContext context, {bool chooseFile = false}) async {
  final result = await showImportHostsDialog(context, chooseFile: chooseFile);
  if (result == null || !context.mounted) return;
  switch (result) {
    case ImportFromFile(:final file, :final kind):
      await openImportFile(context, file, kind);
    case ImportFromSshConfig():
      if (zestUsesSheets(context)) {
        await context.push(Routes.sshConfigImport);
      } else {
        final o = await showDesktopSshConfigImport(context);
        if (o != null && context.mounted) toastImportOutcome(context, added: o.imported, failedLimit: o.failedLimit);
      }
    case ImportTermiusGuide():
      await showTermiusGuide(context);
    case ImportFromPutty():
      await context.push(Routes.puttyImport);
    case ImportFromCsv(:final kind):
      await openCsvImport(context, kind: kind);
    case ImportAskForSource():
      await context.push(Routes.report, extra: FeedbackType.suggestion);
    case ImportFromZest():
      await importHostShareFile(context);
    case ImportFromShareLink(:final reading):
      // The link on the clipboard, or one pasted now; then the confirmation
      // every share link has, as an opened link's (the app's deep links).
      final link = reading ?? await showPasteShareLink(context);
      if (link == null || !link.ok || !context.mounted) return;
      await addShareLinkHost(context, link.share!, link.uri!);
    case ImportedFromCloud(:final account, :final outcome, :final keptError):
      await showCloudImportOutcome(context, account, outcome);
      if (keptError != null && context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        await ZestDialogShell.showModal<void>(
          context,
          size: ZestModalSize.compact,
          // What it means, in its amber sentence (3.4).
          tone: ZestDialogTone.warning,
          icon: LucideIcons.alertTriangle,
          title: l10n.cloudImpNotKeptTitle,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZestCallout(l10n.cloudImpNotKeptBody),
              Align(alignment: Alignment.centerRight, child: CopyDetailsButton(detail: keptError, label: l10n.desktopShellCopyDetails)),
            ],
          ),
          primaryAction: (label: l10n.close, icon: null, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
        );
      }
  }
}

/// Opens the CSV file import (3.0), and then says what it did as a cloud
/// import's outcome is said, the file's name for the account's.
Future<void> openCsvImport(BuildContext context, {HostFileKind kind = HostFileKind.csv, CsvPicked? picked}) async {
  final result = await showCsvImport(context, kind: kind, picked: picked);
  if (result == null || !context.mounted) return;
  await showCloudImportOutcome(context, result.fileName, result.asCloudOutcome);
}

/// Says what a cloud import did; hosts that could not be written are listed
/// with their details to copy.
Future<void> showCloudImportOutcome(BuildContext context, String account, CloudImportOutcome outcome) async {
  final l10n = AppLocalizations.of(context)!;
  final done = outcome.added + outcome.linked + outcome.updated;
  if (outcome.failures.isEmpty) {
    showTopSnackBar(
      context,
      outcome.gone > 0 ? '${l10n.cloudImpDone(account, done)} ${l10n.cloudImpMarkedGone(outcome.gone)}' : l10n.cloudImpDone(account, done),
      isSuccess: true,
    );
    return;
  }
  final details = [for (final f in outcome.failures) '${f.name}: ${f.error}'].join('\n');
  await ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.compact,
    // A list of what failed, said plainly: nothing amber (3.4).
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.alertTriangle,
    title: l10n.cloudImpSomeFailed(outcome.failures.length),
    subtitle: l10n.cloudImpDone(account, done),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in outcome.failures.take(8))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${f.name}: ${f.error.contains('orchard-access') ? l10n.cloudImpRefusedByCrate : l10n.cloudImpNotWritten}',
              style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary),
            ),
          ),
        if (outcome.failures.length > 8)
          Text(l10n.cloudImpAndMore(outcome.failures.length - 8), style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
        Align(alignment: Alignment.centerRight, child: CopyDetailsButton(detail: details, label: l10n.desktopShellCopyDetails)),
      ],
    ),
    primaryAction: (label: l10n.close, icon: null, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
  );
}

/// Where termius-export lives (a free, open-source tool; not ours).
const kTermiusExportUrl = 'https://github.com/y01and3/termius-export';

/// Moving from Termius: it has no export, so the guide
/// points to termius-export, which writes an SSH config file, and opens the
/// SSH config import to choose it. Nothing here reads Termius's own data.
Future<void> showTermiusGuide(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  Widget para(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: TextStyle(fontSize: 13, height: 1.55, color: ZestTokens.textSecondary)),
      );
  final choose = await ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.info,
    icon: LucideIcons.arrowRightLeft,
    title: l10n.termiusGuideTitle,
    body: Column(
      key: const ValueKey('termius-guide'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        para(l10n.termiusGuideNoExport),
        para(l10n.termiusGuideRun),
        para(l10n.termiusGuideDelete),
      ],
    ),
    primaryAction: (
      label: l10n.termiusGuideChoose,
      icon: LucideIcons.fileUp,
      onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
    ),
    secondaryAction: (
      label: l10n.termiusGuideOpen,
      onPressed: () => launchUrl(Uri.parse(kTermiusExportUrl), mode: LaunchMode.externalApplication),
    ),
  );
  if (choose != true || !context.mounted) return;
  if (zestUsesSheets(context)) {
    await context.push(Routes.sshConfigImport, extra: true);
    return;
  }
  final o = await showDesktopSshConfigImport(context, pickFile: true);
  if (o != null && context.mounted) toastImportOutcome(context, added: o.imported, failedLimit: o.failedLimit);
}

