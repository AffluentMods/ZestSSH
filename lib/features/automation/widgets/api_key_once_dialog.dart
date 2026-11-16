import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

/// Shows a key just made, once: the only place an automation API key is ever
/// shown in full (show-once, only a hash kept).
/// [secret] is the key [AutomationKeysNotifier.createKey] returned beside
/// [apiKey]; it is not stored, so once this closes it cannot be shown again.
///
/// Every screen that makes a key opens this: the phone's API keys, the
/// computer's Automation, API keys tab, and the automation wizard.
Future<void> showApiKeyOnceDialog(
  BuildContext context, {
  required AutomationApiKey apiKey,
  required String secret,
}) =>
    showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      // Closed by Done only, once the key is said to be saved.
      barrierDismissible: false,
      onDismissAttempt: () async => false,
      child: ApiKeyOnceDialog(apiKey: apiKey, secret: secret),
    );

/// The dialog [showApiKeyOnceDialog] opens. It closes only once the person
/// says the key is saved.
class ApiKeyOnceDialog extends StatefulWidget {
  const ApiKeyOnceDialog({super.key, required this.apiKey, required this.secret});

  final AutomationApiKey apiKey;
  final String secret;

  @override
  State<ApiKeyOnceDialog> createState() => _ApiKeyOnceDialogState();
}

class _ApiKeyOnceDialogState extends State<ApiKeyOnceDialog> {
  bool _confirmedSaved = false;

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context)!;
    // A secret goes to the clipboard: reveal gate (spec 5).
    if (!await confirmRevealWhileRecording(context)) return;
    if (!mounted) return;
    // Cleared after 45s, as every secret copied is (SecretClipboard), the
    // dialog closed or not.
    await SecretClipboard.copy(widget.secret);
    if (!mounted) return;
    showTopSnackBar(context, l10n.triggersViewApiKeyCopiedClears);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The app's dialog (3.4): the key and its copy icon in the body, Done in
    // the footer, off until the key is said to be saved.
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.triggersViewSaveKeyTitle,
      maxWidth: 520,
      // Closed by Done only.
      onClose: _confirmedSaved ? () => Navigator.of(context).pop() : () {},
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.triggersViewSaveKeyExplainer,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.v3TextSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            widget.apiKey.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.v3TextPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Row(
              children: [
                Expanded(
                  // Recording mode: the key paints as bullets with a Reveal
                  // icon that runs the reveal gate (spec 5). The gate turns
                  // the mode off, and this rebuilds with the real key.
                  child: Consumer(
                    builder: (context, ref, _) {
                      final recording = ref.watch(recordingModeProvider);
                      final style = TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.v3TextPrimary,
                      );
                      if (!recording) {
                        return SelectableText(
                          widget.secret,
                          key: const ValueKey('api-key-once-secret'),
                          style: style,
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: Text(Redactor.passwordMask, style: style)),
                          // An icon on the key, as its copy is (no button in
                          // the body).
                          IconButton(
                            key: const ValueKey('api-key-once-reveal'),
                            icon: const Icon(LucideIcons.eye, size: 16),
                            tooltip: l10n.recModeRevealAction,
                            color: AppColors.v3TextSecondary,
                            onPressed: () => confirmRevealWhileRecording(context),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                IconButton(
                  key: const ValueKey('api-key-once-copy'),
                  icon: const Icon(LucideIcons.copy, size: 16),
                  tooltip: l10n.triggersViewCopyToClipboard,
                  color: AppColors.v3TextSecondary,
                  onPressed: _copy,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          CheckboxListTile(
            key: const ValueKey('api-key-once-saved'),
            dense: true,
            value: _confirmedSaved,
            onChanged: (v) => setState(() => _confirmedSaved = v ?? false),
            title: Text(
              l10n.triggersViewConfirmSavedKey,
              style: const TextStyle(fontSize: 12.5),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
      primaryKey: const ValueKey('api-key-once-done'),
      primaryAction: (
        label: l10n.done,
        icon: null,
        onPressed: _confirmedSaved ? () => Navigator.of(context).pop() : null,
      ),
    );
  }
}
