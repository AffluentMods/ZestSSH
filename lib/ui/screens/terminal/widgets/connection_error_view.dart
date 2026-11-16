import 'package:zestssh/features/screens/xprogram/x_program_install_text.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show Assertiveness;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart'
    show certificateFromOwnerOfferProvider, offlinePassOfferProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';

/// A line of connection text (a log line, a raw error, a failure summary) in
/// its recording-mode display form.
///
/// The free-text rule catches `user@host`, IP addresses, dotted names and
/// every REGISTERED host, but a session's own username and host also stand
/// alone in the connection log (`ssh_auth: Authenticating as deploy
/// (publicKey)`, `Resolving web-01...`, a Quick Connect target that was never
/// registered), and a bare word is not something the scan can recognise. This
/// masks those two explicitly, with the same rules the scan uses so the fakes
/// agree everywhere, then runs the scan over the rest. A `user@host` pair is
/// left to the scan on purpose, so it is masked once, not twice.
///
/// Pass-through while recording mode is off. Call it from a build that
/// watches [recordingModeProvider] so the text re-masks on a toggle.
String maskConnectionLine(String line, {String? host, String? username}) {
  if (!Redactor.instance.enabled || line.isEmpty) return line;
  var out = line;
  final user = username?.trim() ?? '';
  if (user.isNotEmpty) {
    out = _replaceBare(out, user, Redactable.username(user).display,
        notBefore: r'[A-Za-z0-9._-]', notAfter: r'[A-Za-z0-9._@-]');
  }
  final h = host?.trim() ?? '';
  if (h.isNotEmpty) {
    out = _replaceBare(out, h, Redactable.address(h).display,
        notBefore: r'[A-Za-z0-9.@-]', notAfter: r'[A-Za-z0-9.-]');
  }
  return Redactable.freeText(out).display;
}

/// Replace every standalone occurrence of [needle] in [text]: one that is
/// neither preceded by a character of [notBefore] nor followed by one of
/// [notAfter], so `db` never touches `db-primary.local` and `root` never
/// touches `rootfs`.
String _replaceBare(String text, String needle, String replacement,
    {required String notBefore, required String notAfter}) {
  if (!text.contains(needle)) return text;
  final re = RegExp('(?<!$notBefore)${RegExp.escape(needle)}(?!$notAfter)');
  return text.replaceAll(re, replacement);
}

/// The report of a connection that could not be made, for Copy details on
/// a phone and on a computer: what went wrong ([title], in the app's
/// language), the error, its kind and the connection's [log], every name and
/// address taken out (`ErrorReport.build`).
String connectionFailureReport({
  required String title,
  required String error,
  required String kind,
  List<String> log = const [],
  String where = 'Connecting to a host',
}) =>
    ErrorReport.build(
      what: title,
      where: where,
      error: error,
      details: ['Kind: $kind', ...log].join('\n'),
    );

/// Redesigned connection error screen with human-readable error messages,
/// connection details, contextual tips, and Retry / Edit Connection buttons.
class ConnectionErrorView extends ConsumerStatefulWidget {
  final String? errorMessage;
  final String connectionLabel;
  final String? connectionId;
  final List<String> connectionLog;
  final String? host;
  final int? port;
  final String? username;
  final VoidCallback onRetry;
  final VoidCallback onEditConnection;
  final VoidCallback onGoBack;

  const ConnectionErrorView({
    super.key,
    this.errorMessage,
    required this.connectionLabel,
    this.connectionId,
    this.connectionLog = const [],
    this.host,
    this.port,
    this.username,
    required this.onRetry,
    required this.onEditConnection,
    required this.onGoBack,
  });

  @override
  ConsumerState<ConnectionErrorView> createState() =>
      _ConnectionErrorViewState();
}

class _ConnectionErrorViewState extends ConsumerState<ConnectionErrorView> {
  /// The failure was said to a screen reader (once, when the view appears).
  bool _said = false;

  @override
  Widget build(BuildContext context) {
    // Every identifying string below is composed here, so the view itself
    // must rebuild when recording mode flips for them to re-mask.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    final l10n = AppLocalizations.of(context)!;
    final host = widget.host;
    final username = widget.username;
    // The translator embeds the host and the username in its prose, where a
    // bare label is nothing the free-text scan can recognise: hand it the
    // display forms, which are the real values while the mode is off.
    final hostShown = host == null ? null : Redactable.address(host).display;
    final userShown =
        username == null ? null : Redactable.username(username).display;
    final error = ConnectionError.translate(
      widget.errorMessage ?? l10n.connectionErrorUnknownError,
      host: hostShown,
      port: widget.port,
      username: userShown,
    );
    String mask(String text) =>
        maskConnectionLine(text, host: host, username: username);

    // Said when it appears, its host and what went wrong (4.0 accessibility
    // pass: a screen reader heard nothing, the terminal it was in simply
    // gone).
    if (!_said) {
      _said = true;
      final said = [
        if (widget.connectionLabel.isNotEmpty) Redactable.host(widget.connectionLabel).display,
        mask(error.title),
      ].join(': ');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) zestAnnounce(context, said, assertiveness: Assertiveness.assertive);
      });
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Connection info header
            if (widget.connectionLabel.isNotEmpty) ...[
              RedactedText(
                Redactable.host(widget.connectionLabel),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              if (hostShown != null)
                Text(
                  '${userShown != null ? '$userShown@' : ''}'
                  '$hostShown:${widget.port ?? 22}',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'JetBrainsMono',
                    color: AppColors.onSurfaceDim,
                  ),
                ),
              const SizedBox(height: 20),
            ],

            // What went wrong, as a computer's window for it says it: the
            // error's red chip (3.0 UI: it was an orange triangle here and
            // a red chip there).
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: ZestTokens.statusCritical.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: ZestTokens.statusCritical.withValues(alpha: 0.35)),
              ),
              child: ExcludeSemantics(child: Icon(LucideIcons.alertCircle, size: 26, color: ZestTokens.statusCritical)),
            ),
            const SizedBox(height: 20),

            // Human-readable error title: the view's heading.
            Semantics(
              header: true,
              child: Text(
                mask(error.title),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: ZestTokens.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Description
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FailureDescription(
                mask(error.description),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: ZestTokens.textSecondary,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Contextual tip
            if (error.tip != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceChip,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ZestTokens.borderSubtle),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.lightbulb, size: 16, color: ZestTokens.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        mask(error.tip!),
                        style: TextStyle(
                          fontSize: 13,
                          color: ZestTokens.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 24),

            // Retry is the one main action; Edit, and what an owner can
            // sign directly, are neutral (the theme's buttons: 44 high on a
            // phone).
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: widget.onRetry,
                    icon: const Icon(LucideIcons.rotateCw, size: 16),
                    label: Text(l10n.retry),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.onEditConnection,
                    icon: const Icon(LucideIcons.pencil, size: 16),
                    label: Text(l10n.edit),
                  ),
                ),
              ],
            ),
            // A login that could get no team certificate, where an owner
            // can sign one directly.
            if (ref.watch(certificateFromOwnerOfferProvider)[widget.connectionId] case final offer?) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('connection-error-certificate-from-owner'),
                  onPressed: () => showCertFromOwner(context, orchardId: offer.orchardId, crateId: offer.crateId),
                  icon: const Icon(LucideIcons.qrCode, size: 16),
                  label: Text(l10n.certHandButton),
                ),
              ),
            ],
            // A host whose Crate is closed on this device by its offline
            // limit: an owner can sign a pass for it.
            if (ref.watch(offlinePassOfferProvider)[widget.connectionId] case final pass?) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('connection-error-offline-pass'),
                  onPressed: () => showPassFromOwner(context, orchardId: pass.orchardId, crateId: pass.crateId),
                  icon: const Icon(LucideIcons.qrCode, size: 16),
                  label: Text(l10n.passAskButton),
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: widget.onGoBack,
              icon: const Icon(LucideIcons.arrowLeft, size: 16),
              label: Text(l10n.connectionErrorGoBack),
              style: TextButton.styleFrom(
                foregroundColor: ZestTokens.textSecondary,
              ),
            ),
            const SizedBox(height: 16),

            // What stands behind it, to read or copy: the report of the
            // failure, scrubbed (3.0: the raw error and the log
            // stood behind a gesture no keyboard reached, with nothing to
            // copy them by, and the log could not be selected).
            ErrorDetailsPanel(
              report: connectionFailureReport(
                title: error.title,
                error: error.rawError,
                kind: error.type.name,
                log: widget.connectionLog,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
