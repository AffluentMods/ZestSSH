import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart';
import 'package:zestssh/features/screens/xprogram/x_program_install_text.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' as session;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart'
    show connectionFailureReport, maskConnectionLine;
import 'package:zestssh/utils/host_address.dart';

/// What a computer says when a connection could not be made (3.0):
/// what went wrong and what to try, in the app's language (the
/// words the phone's screen for it has: [ConnectionError.translate]), the
/// host, Try again, and the report of the failure behind Copy details
/// (scrubbed, with the connection's log). It was a plain dialog whose
/// headline said "Could not connect to host:port" in English, and whose
/// Copy details copied the raw details: the host, the user and the log,
/// once recording mode was turned off for it.
class ConnectionFailedDialog extends ConsumerWidget {
  const ConnectionFailedDialog({super.key, required this.error, this.onRetry});

  final session.ConnectionError error;

  /// Connects again; no button when null.
  final VoidCallback? onRetry;

  /// The report of [error], which is shown as [shown]: what went wrong, the
  /// error, its kind and the connection's log, every name and address taken
  /// out. The kind is the one the failure is shown as, as in the report of
  /// every other screen of a failed connection ("refused", "authFailed").
  /// (It was what the program calls the type of what was thrown.)
  static String reportOf(session.ConnectionError error, ConnectionError shown) => connectionFailureReport(
        title: shown.title,
        error: error.errorMessage,
        kind: shown.type.name,
        log: error.connectionLog,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Recording mode: the host and the user are masked on screen (the
    // description of a refused sign-in names them).
    ref.watch(recordingModeProvider);
    final friendly = ConnectionError.translate(
      error.errorMessage,
      host: error.host,
      port: error.port,
      username: error.username,
    );
    String masked(String text) => maskConnectionLine(text, host: error.host, username: error.username);
    final label = error.connectionLabel;
    // A login that could get no team certificate, where an owner can sign
    // one directly: offered from here.
    final offer = ref.watch(session.certificateFromOwnerOfferProvider)[error.connectionId];
    // A host whose Crate is closed on this device by its offline limit: an
    // owner can sign a pass for it, asked for from here.
    final pass = ref.watch(session.offlinePassOfferProvider)[error.connectionId];
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.destructive,
      // The failure is red; trying again is not a danger: the accent.
      primaryBrand: true,
      icon: LucideIcons.alertCircle,
      title: friendly.title,
      subtitle: label == null ? masked(hostWithPort(error.host, error.port)) : Redactable.host(label).display,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FailureDescription(
            masked(friendly.description),
            textKey: const ValueKey('connection-failed-description'),
            style: TextStyle(fontSize: 14, color: AppColors.v3TextPrimary, height: 1.45),
          ),
          if (friendly.tip != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const ValueKey('connection-failed-tip'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceChip,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.v3BorderSubtle),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.lightbulb, size: 16, color: ZestTokens.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      masked(friendly.tip!),
                      style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          ErrorDetailsPanel(report: reportOf(error, friendly)),
        ],
      ),
      primaryAction: onRetry == null
          ? null
          : (
              label: l10n.retry,
              icon: LucideIcons.rotateCw,
              onPressed: () {
                Navigator.of(context).pop();
                onRetry!();
              },
            ),
      secondaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop()),
      tertiaryAction: offer != null
          ? (
              label: l10n.certHandButton,
              onPressed: () {
                // This dialog goes, and the other opens in its place.
                final navigator = Navigator.of(context);
                navigator.pop();
                showCertFromOwner(navigator.context, orchardId: offer.orchardId, crateId: offer.crateId);
              },
            )
          : pass != null
              ? (
                  label: l10n.passAskButton,
                  onPressed: () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    showPassFromOwner(navigator.context, orchardId: pass.orchardId, crateId: pass.crateId);
                  },
                )
              : null,
    );
  }
}
