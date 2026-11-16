import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

/// A dialog (a sheet on a phone) that exposes a single saved connection as a QR
/// code + copyable `zestssh://share?d=…` URL.
///
/// This is the OUTBOUND side of the share flow - the receiver opens
/// the URL (or scans the QR) and goes through [IncomingShareDialog]
/// before anything writes to their database.
///
/// What's included in the share URL:
///   - Connection label, host, port
///   - Username, identity *hint* (label only, not the key material)
///   - Group hint
///   - Tag names
///   - Port forward rules (type / bind / remote / label)
///
/// What's NEVER included (the parser also rejects these on the way
/// back in, so even a deliberately crafted URL with these fields
/// would be discarded):
///   - Passwords
///   - Private keys, key passphrases
///   - Auth tokens
///   - JWTs / API keys
class ShareConnectionSheet extends ConsumerWidget {
  final String label;
  final String host;
  final int port;
  final String? user;
  final String? identityHint;
  final String? groupHint;
  final List<String> tags;
  final List<SharedForward> forwards;

  const ShareConnectionSheet({
    super.key,
    required this.label,
    required this.host,
    required this.port,
    this.user,
    this.identityHint,
    this.groupHint,
    this.tags = const [],
    this.forwards = const [],
  });

  static Future<void> show(
    BuildContext context, {
    required String label,
    required String host,
    required int port,
    String? user,
    String? identityHint,
    String? groupHint,
    List<String> tags = const [],
    List<SharedForward> forwards = const [],
  }) async {
    // The QR code and the link carry the REAL label, host and user by design
    // (this is an export): recording mode asks first, and the sheet opens
    // only once the user has turned the mode off (reveal gate, spec 5).
    if (!await confirmRevealWhileRecording(context)) return;
    if (!context.mounted) return;
    // A dialog on a computer, a sheet on a phone, as every other one (it was
    // a phone's bottom sheet on a computer too).
    return showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: ShareConnectionSheet(
        label: label,
        host: host,
        port: port,
        user: user,
        identityHint: identityHint,
        groupHint: groupHint,
        tags: tags,
        forwards: forwards,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final Uri shareUri;
    try {
      shareUri = ConnectionShareUrlService.buildShareUrl(
        label: label,
        host: host,
        port: port,
        user: user,
        identityHint: identityHint,
        groupHint: groupHint,
        tags: tags,
        forwards: forwards,
      );
    } catch (e) {
      // Failed round-trip validation - show a clear error instead
      // of a broken QR. Almost certainly means the connection has
      // a field that exceeds the spec's length limits.
      return _BuildError(message: e.toString());
    }

    final urlString = shareUri.toString();

    Future<void> copy() async {
      // The link holds the host as it is shared: it leaves the clipboard by
      // itself, as a secret does, and the person is told (found in a security
      // audit).
      await SecretClipboard.copy(urlString);
      if (context.mounted) {
        showTopSnackBar(context, clearsSoon(l10n, l10n.shareConnectionCopied), isSuccess: true);
      }
    }

    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.share2,
      title: l10n.shareConnectionShareTitle(Redactable.host(label).displayIn(ref)),
      subtitle: l10n.shareConnectionSubtitle,
      body: Column(
        key: const ValueKey('share-connection-body'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // QR
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: QrImageView(
                data: urlString,
                version: QrVersions.auto,
                size: 240,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                gapless: true,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF0A0A0A),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF0A0A0A),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // The link, to read or select; Copy link is the footer's button.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceRaisedAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: SelectableText(
              urlString,
              maxLines: 3,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: AppColors.v3TextSecondary,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // What's in / what's not
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceRaisedAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _includedRow(
                  icon: LucideIcons.check,
                  color: AppColors.success,
                  text: l10n.shareConnectionIncludedFields,
                ),
                const SizedBox(height: 6),
                _includedRow(
                  icon: LucideIcons.x,
                  color: AppColors.error,
                  text: l10n.shareConnectionExcludedFields,
                ),
              ],
            ),
          ),
        ],
      ),
      primaryAction: (label: l10n.shareConnectionCopyLink, icon: LucideIcons.copy, onPressed: copy),
      primaryKey: const ValueKey('share-connection-copy'),
      secondaryAction: (
        label: l10n.shareConnectionShareEllipsis,
        onPressed: () {
          Share.share(urlString, subject: l10n.shareConnectionShareSubject(label));
        },
      ),
      secondaryKey: const ValueKey('share-connection-share'),
    );
  }

  Widget _includedRow({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.v3TextSecondary,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _BuildError extends StatelessWidget {
  final String message;
  const _BuildError({required this.message});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.destructive,
      title: l10n.shareConnectionGenerateError,
      body: SelectableText(
        message,
        style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextSecondary),
      ),
      secondaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
