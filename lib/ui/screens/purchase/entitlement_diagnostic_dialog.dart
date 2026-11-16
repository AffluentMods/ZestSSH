import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/entitlement_diagnostics.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// "Why does this say Free?" dialog.
///
/// Surfaces the last result from `PurchaseService.fetchWebEntitlements`
/// so we can SEE what the backend is returning. Critically:
///
/// - The raw bearer token is NEVER displayed or copied. Only the
///   length and source are surfaced.
/// - The JWT *payload* (firebase_uid, email) IS displayed - these
///   are identifiers, not auth material. Signature is stripped before
///   decoding.
/// - The "Copy to clipboard" button emits a sanitized markdown blob
///   that can be safely pasted into a support thread.
///
/// Trigger this from the upgrade screen via a small "Diagnostic" link.
class EntitlementDiagnosticDialog extends ConsumerStatefulWidget {
  const EntitlementDiagnosticDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: const EntitlementDiagnosticDialog(),
    );
  }

  @override
  ConsumerState<EntitlementDiagnosticDialog> createState() =>
      _EntitlementDiagnosticDialogState();
}

class _EntitlementDiagnosticDialogState
    extends ConsumerState<EntitlementDiagnosticDialog> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await ref.read(isProProvider.notifier).refresh();
      await ref.read(isCloudSyncProvider.notifier).refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _copySanitized() async {
    final l10n = AppLocalizations.of(context)!;
    final d = PurchaseService.lastDiagnostic;
    if (d == null) {
      showTopSnackBar(context, l10n.entitlementDiagnosticNoDiagnosticYet,
          isError: true);
      return;
    }
    // "Sanitized" means no bearer token; the blob still carries the account
    // email and ids, so it is a real value on the clipboard: reveal gate
    // (spec 5).
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: d.toShareableMarkdown()));
    if (!mounted) return;
    showTopSnackBar(context, l10n.entitlementDiagnosticCopiedSafe,
        isSuccess: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);
    final d = PurchaseService.lastDiagnostic;

    // In the app's dialog (the dialog rules, 3.4): its buttons in the footer,
    // the main one last (they stood across the bottom of a dialog of its own).
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.bug,
      title: l10n.entitlementDiagnosticTitle,
      subtitle: l10n.entitlementDiagnosticDescription,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section(l10n.entitlementDiagnosticLocalState, [
            _row('isPro', isPro ? 'true' : 'false'),
            _row('isCloudSync', isCloudSync ? 'true' : 'false'),
          ]),
          const SizedBox(height: 16),
          if (d == null)
            _section(l10n.entitlementDiagnosticBackendResponse, [
              _row(l10n.entitlementDiagnosticStatus, l10n.entitlementDiagnosticNotCalledYet),
            ])
          else
            ..._buildDiagnosticSections(d),
        ],
      ),
      secondaryAction: (label: l10n.entitlementDiagnosticCopySanitized, onPressed: _refreshing ? null : _copySanitized),
      primaryAction: (
        label: _refreshing ? l10n.entitlementDiagnosticRefreshing : l10n.entitlementDiagnosticRefreshNow,
        icon: LucideIcons.refreshCw,
        onPressed: _refreshing ? null : _refresh,
      ),
    );
  }

  List<Widget> _buildDiagnosticSections(EntitlementDiagnostic d) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _section(l10n.entitlementDiagnosticLastRequest, [
        _row(l10n.entitlementDiagnosticTime, _formatTime(d.at)),
        _row(l10n.entitlementDiagnosticEndpoint, d.endpoint, mono: true),
        _row(l10n.entitlementDiagnosticHttpStatus,
            d.httpStatus?.toString() ?? l10n.entitlementDiagnosticNoResponse),
        if (d.error != null) _row(l10n.error, d.error!),
      ]),
      const SizedBox(height: 16),
      _section(l10n.entitlementDiagnosticAuth, [
        _row(
          l10n.entitlementDiagnosticToken,
          d.tokenBytes == null
              ? l10n.entitlementDiagnosticTokenAbsent
              : l10n.entitlementDiagnosticTokenPresent(
                  d.tokenSource ?? "?", d.tokenBytes.toString()),
        ),
        // Recording mode: the uid and the email identify the account (name
        // rule, so a support thread can still say "same account as before");
        // the row id is a bare number with no shape worth keeping, so it
        // paints as bullets.
        _row(
          'firebase_uid',
          d.firebaseUid == null
              ? l10n.entitlementDiagnosticNotDecodable
              : Redactable.account(d.firebaseUid!).displayIn(ref),
          mono: true,
        ),
        _row(
          l10n.entitlementDiagnosticEmail,
          d.email == null
              ? l10n.entitlementDiagnosticEmailMissing
              : Redactable.account(d.email!).displayIn(ref),
        ),
        if (d.userId != null)
          _row(
            'userId',
            Redactable.password(d.userId.toString()).displayIn(ref),
          ),
      ]),
      const SizedBox(height: 16),
      _section(l10n.entitlementDiagnosticResponseBody, [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          // The body is whatever the backend echoed; the free-text rule
          // catches an email or an address embedded in it.
          child: SelectableText(
            d.responseBodySnippet.isEmpty
                ? l10n.entitlementDiagnosticEmpty
                : Redactable.freeText(d.responseBodySnippet).displayIn(ref),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: AppColors.v3TextPrimary,
              height: 1.4,
            ),
          ),
        ),
      ]),
    ];
  }

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: AppColors.v3TextTertiary,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _row(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.v3TextSecondary,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.v3TextPrimary,
                fontFamily: mono ? 'JetBrainsMono' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
