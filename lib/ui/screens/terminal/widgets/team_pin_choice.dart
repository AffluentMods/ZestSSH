import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';

/// In a host key prompt, for someone who may edit the host's Crate
/// (3.0): trust the key for everyone in it, on unless they turn it off.
/// Nothing when the prompt offers no pin.
class TeamPinChoice extends StatefulWidget {
  const TeamPinChoice({super.key, required this.verification});

  final HostKeyVerification verification;

  /// Whether [verification] offers pinning the key for the team.
  static bool offered(HostKeyVerification verification) {
    final pin = verification.teamPin;
    return pin != null && pin.mayChange && !pin.pinned;
  }

  @override
  State<TeamPinChoice> createState() => _TeamPinChoiceState();
}

class _TeamPinChoiceState extends State<TeamPinChoice> {
  @override
  Widget build(BuildContext context) {
    final pin = widget.verification.teamPin;
    if (pin == null || !TeamPinChoice.offered(widget.verification)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            key: const ValueKey('team-pin-choice'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: pin.forEveryone,
            onChanged: (v) => setState(() => pin.forEveryone = v ?? false),
            // An FTPS server's certificate (3.4) in its own words.
            title: Text(
                widget.verification.certificate
                    ? l10n.teamCertificateForEveryone(pin.crateName)
                    : l10n.teamHostKeyForEveryone(pin.crateName),
                style: const TextStyle(fontSize: 13)),
          ),
          Text(
            widget.verification.certificate ? l10n.teamCertificateForEveryoneNote : l10n.teamHostKeyForEveryoneNote,
            style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.v3TextSecondary),
          ),
        ],
      ),
    );
  }
}
