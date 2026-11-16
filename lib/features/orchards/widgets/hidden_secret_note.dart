import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Where a password or private key would be, for an Orchard key this
/// account reaches at Connect (3.0): it is used to connect, and
/// never shown, copied, exported or changed here.
class HiddenSecretNote extends StatelessWidget {
  const HiddenSecretNote({super.key, required this.text, this.action});

  final String text;

  /// Shows them after the person confirms it is them (a Crate that asks
  /// again); null where they stay hidden.
  final ({String label, VoidCallback onPressed})? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.eyeOff, size: 15, color: AppColors.v3TextSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary)),
          ),
          if (action case final a?)
            TextButton.icon(
              key: const ValueKey('secret-show'),
              onPressed: a.onPressed,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              icon: const Icon(LucideIcons.fingerprint, size: 14),
              label: Text(a.label),
            ),
        ],
      ),
    );
  }
}
