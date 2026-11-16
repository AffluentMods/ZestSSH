import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/update_dialog.dart';

/// Checks for a newer release now, because the person asked (clicked the
/// version in the status bar, or "Check for updates" in About), and says
/// what it found: a newer version with an Update action (the update's
/// dialog, as the title bar's pill opens it), "this is the latest", or that
/// the check could not reach the site, or found a release not signed by
/// ZestSSH (ZS-1902).
Future<UpdateCheckOutcome> checkForUpdatesNow(
    BuildContext context, WidgetRef ref) async {
  final outcome = await ref.read(updateBannerProvider.notifier).checkNow();
  if (!context.mounted) return outcome;
  final l10n = AppLocalizations.of(context)!;
  switch (outcome) {
    case UpdateAvailable(:final info):
      showTopSnackBar(
        context,
        info.critical
            ? l10n.updateBannerImportantUpdate(info.version)
            : l10n.updateBannerVersionAvailable(info.version),
        isInfo: true,
        duration: const Duration(seconds: 8),
        actionLabel: l10n.updateBannerUpdateAction,
        onAction: () => openUpdate(context, ref, info),
      );
    case UpdateCheckUpToDate(:final current):
      showTopSnackBar(context, l10n.updateCheckUpToDate(current),
          isSuccess: true);
    case UpdateCheckFailed(refused: true):
      showTopSnackBar(
        context,
        ErrorCodes.withCode(l10n.appUpdateErrNotSigned, ErrorCodes.updateNotSigned),
        isError: true,
        details: 'The manifest at $kBuildUpdateManifestUrl names a newer version, and its signature is missing or does not verify with the release key.',
      );
    case UpdateCheckFailed():
      showTopSnackBar(context, l10n.updateCheckFailed, isError: true);
  }
  return outcome;
}

/// What "Update" does for [info]: the update's dialog where this copy
/// updates itself (a computer's build from the website), else the download
/// page.
Future<void> openUpdate(BuildContext context, WidgetRef ref, UpdateInfo info) async {
  if (ref.read(inAppUpdateSupportedProvider)) return showUpdateDialog(context, info);
  return openUpdateDownload(context, info.downloadUrl);
}

/// Opens a release's download page in the browser. Only an https link is
/// ever opened (the manifest is remote input), and it never throws into the
/// UI.
Future<void> openUpdateDownload(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    if (context.mounted) {
      final l10n = AppLocalizations.of(context)!;
      showTopSnackBar(context, l10n.desktopStatusDownloadPageError,
          isError: true, details: '$url, $e');
    }
  }
}
