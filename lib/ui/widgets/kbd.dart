import 'package:flutter/material.dart';
import 'package:zestssh/theme/app_colors.dart';

/// A keyboard shortcut badge widget.
///
/// Renders a subtle rounded rectangle with monospace text, used to display
/// keyboard shortcuts like "Ctrl+K" or "F11" in the UI.
///
/// ```dart
/// Kbd('Ctrl+K')
/// Kbd('F11')
/// ```
class Kbd extends StatelessWidget {
  /// The shortcut text to display, e.g. "Ctrl+K", "Ctrl+Shift+P".
  final String shortcut;

  const Kbd(this.shortcut, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: Text(
        shortcut,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'JetBrainsMono',
          color: AppColors.onSurfaceVariant,
        ),
      ),
    );
  }
}
