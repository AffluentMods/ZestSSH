import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/os_icon.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Shows a dialog with detailed session information.
///
/// Displays host, user, port, how long it has been connected and the
/// detected OS, in the app's language, with the host's name, its address and
/// the user masked in recording mode (3.0: a plain dialog in
/// English, which showed them as they are while recording).
class SessionInfoDialog {
  SessionInfoDialog._();

  static Future<void> show(
    BuildContext context, {
    required String? host,
    required String? username,
    required int? port,
    required DateTime? connectedAt,
    required OsKind? detectedOs,
    required String? connectionLabel,
  }) =>
      showZestModal<void>(
        context: context,
        size: ZestModalSize.compact,
        child: _SessionInfo(
          host: host,
          username: username,
          port: port,
          connectedAt: connectedAt,
          detectedOs: detectedOs,
          connectionLabel: connectionLabel,
        ),
      );

  /// How long [duration] is, in the shared compact length of the app's
  /// language: days and hours, hours and minutes, minutes and seconds, or
  /// seconds; unknown when there is none.
  static String durationText(AppLocalizations l10n, Duration? duration) {
    if (duration == null) return l10n.homeUnknown;
    return durationWords(l10n, duration, seconds: true);
  }
}

class _SessionInfo extends ConsumerWidget {
  const _SessionInfo({
    required this.host,
    required this.username,
    required this.port,
    required this.connectedAt,
    required this.detectedOs,
    required this.connectionLabel,
  });

  final String? host;
  final String? username;
  final int? port;
  final DateTime? connectedAt;
  final OsKind? detectedOs;
  final String? connectionLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final label = connectionLabel;
    final host = this.host;
    final username = this.username;
    final os = detectedOs;
    final connectedAt = this.connectedAt;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.info,
      icon: LucideIcons.info,
      title: label == null || label.isEmpty ? l10n.sessionDetailsTitle : Redactable.host(label).displayIn(ref),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _InfoRow(
            icon: LucideIcons.server,
            label: l10n.sessionDetailsHostname,
            value: host == null ? l10n.homeUnknown : Redactable.address(host).displayIn(ref),
          ),
          _InfoRow(
            icon: LucideIcons.user,
            label: l10n.sessionDetailsUsername,
            value: username == null ? l10n.homeUnknown : Redactable.username(username).displayIn(ref),
          ),
          _InfoRow(
            icon: LucideIcons.hash,
            label: l10n.sessionDetailsPort,
            value: '${port ?? 22}',
          ),
          _InfoRow(
            icon: LucideIcons.timer,
            label: l10n.sessionInfoConnectedFor,
            value: SessionInfoDialog.durationText(
              l10n,
              connectedAt == null ? null : DateTime.now().difference(connectedAt),
            ),
          ),
          if (os != null && os != OsKind.unknown) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                OsIconWidget(kind: os, size: 16),
                const SizedBox(width: 10),
                Text(
                  l10n.sessionDetailsOs,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  OsIconWidget.labelForOs(os),
                  style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      primaryAction: (label: l10n.close, icon: null, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 12),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'JetBrainsMono',
              ),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
