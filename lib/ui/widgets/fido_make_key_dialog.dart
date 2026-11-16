import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// What a new key on a security key is to be: Ed25519 or ECDSA P-256, and
/// whether the security key asks for its PIN at every use.
typedef FidoMakeChoice = ({bool ed25519, bool askPin});

/// Asks what kind of key to make on a security key (a phone or a tablet:
/// lib/services/fido/fido_signer.dart makes it). Null when cancelled.
Future<FidoMakeChoice?> showFidoMakeKeyDialog(BuildContext context) => showZestModal<FidoMakeChoice>(
      context: context,
      size: ZestModalSize.compact,
      child: const _FidoMakeKeyDialog(),
    );

class _FidoMakeKeyDialog extends StatefulWidget {
  const _FidoMakeKeyDialog();

  @override
  State<_FidoMakeKeyDialog> createState() => _FidoMakeKeyDialogState();
}

class _FidoMakeKeyDialogState extends State<_FidoMakeKeyDialog> {
  bool _ed25519 = true;
  bool _askPin = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final help = TextStyle(fontSize: 13, height: 1.4, color: ZestTokens.textSecondary);
    return ZestDialogShell(
      key: const ValueKey('fido-make-key'),
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.fidoMakeTitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.fidoMakeIntro, style: TextStyle(fontSize: 14, height: 1.45, color: ZestTokens.textPrimary)),
          const SizedBox(height: 16),
          Semantics(
            container: true,
            label: l10n.keyGenKeyType,
            child: SegmentedButton<bool>(
              key: const ValueKey('fido-make-kind'),
              showSelectedIcon: false,
              // (The kinds' names are the same in every language.)
              segments: const [
                ButtonSegment(value: true, label: Text('Ed25519')),
                ButtonSegment(value: false, label: Text('ECDSA P-256')),
              ],
              selected: {_ed25519},
              onSelectionChanged: (picked) => setState(() => _ed25519 = picked.first),
            ),
          ),
          const SizedBox(height: 8),
          Text(l10n.fidoMakeKindHelp, style: help),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            key: const ValueKey('fido-make-ask-pin'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.fidoMakeAskPin, style: TextStyle(fontSize: 15, color: ZestTokens.textPrimary)),
            subtitle: Text(l10n.fidoMakeAskPinHelp, style: help),
            value: _askPin,
            onChanged: (v) => setState(() => _askPin = v),
          ),
        ],
      ),
      primaryKey: const ValueKey('fido-make-go'),
      primaryAction: (
        label: l10n.create,
        icon: null,
        onPressed: () => Navigator.of(context).pop((ed25519: _ed25519, askPin: _askPin)),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
