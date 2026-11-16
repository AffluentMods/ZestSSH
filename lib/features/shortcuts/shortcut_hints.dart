import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Platform-correct label for the modal-cancel key (Esc).
///
/// Esc / Enter are deliberately NOT user-rebindable (rebinding them would
/// break basic modal interaction), but their footer hints are still routed
/// through [formatShortcutKey] so a dialog footer reads identically to
/// every other shortcut surface in the app - one formatter, everywhere.
String shortcutEscLabel({TargetPlatform? platform}) => formatShortcutKey(
      ShortcutKey(keyId: LogicalKeyboardKey.escape.keyId),
      platform: platform,
    );

/// Platform-correct label for the modal-confirm key (Enter).
String shortcutEnterLabel({TargetPlatform? platform}) => formatShortcutKey(
      ShortcutKey(keyId: LogicalKeyboardKey.enter.keyId),
      platform: platform,
    );

/// A single dim mono key-hint chip (e.g. `Esc`, `Ctrl+1`), matching the
/// footer / keycap styling used across the desktop chrome.
class ShortcutHintChip extends StatelessWidget {
  const ShortcutHintChip(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.v3BorderSubtle, width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontFamily: 'JetBrainsMono',
          color: AppColors.v3TextTertiary,
        ),
      ),
    );
  }
}

/// Reusable dialog-footer hint row: an `Esc` chip and an `Enter` chip,
/// both sourced from the shortcut registry's formatter.
///
/// Drop this into any dialog footer (save / edit dialogs, confirmations)
/// so the Esc / Enter hints stay consistent app-wide and follow the host
/// platform's modifier conventions without each dialog hardcoding them.
class DialogFooterHints extends StatelessWidget {
  const DialogFooterHints({
    super.key,
    this.showEsc = true,
    this.showEnter = true,
  });

  final bool showEsc;
  final bool showEnter;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showEsc) ShortcutHintChip(shortcutEscLabel()),
        if (showEsc && showEnter) const SizedBox(width: 6),
        if (showEnter) ShortcutHintChip(shortcutEnterLabel()),
      ],
    );
  }
}
