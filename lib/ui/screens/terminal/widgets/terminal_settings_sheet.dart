import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Quick-access terminal settings, opened from the gear icon in the terminal
/// toolbar: the app's dialog (3.4), a phone's sheet, its settings taking effect
/// at once and Done in the footer (a sheet of its own before, with a line
/// across it).
class TerminalSettingsSheet extends ConsumerWidget {
  const TerminalSettingsSheet({super.key});

  static void show(BuildContext context) {
    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.settings2,
          title: AppLocalizations.of(ctx)!.terminalSettingsTitle,
          body: const TerminalSettingsSheet(),
          primaryKey: const ValueKey('terminal-settings-done'),
          primaryAction: (label: AppLocalizations.of(ctx)!.done, icon: null, onPressed: () => Navigator.of(ctx).pop()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontSize = ref.watch(terminalFontSizeProvider);
    final cursorStyle = ref.watch(cursorStyleProvider);
    final autoReconnect = ref.watch(autoReconnectEnabledProvider);
    final updater = ref.read(settingsUpdaterProvider);
    final l10n = AppLocalizations.of(context)!;

    // The shell's header is its title; no lines (the dialog rules, 3.4).
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Font Size ──
        BesideOrUnder(
          words: Text(l10n.terminalSettingsFontSize,
              style: const TextStyle(fontSize: 15)),
          control: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: AppLocalizations.of(context)!.shortcutNameZoomOut,
              icon: const Icon(LucideIcons.minus, size: 20),
              onPressed: fontSize > kTerminalFontSizeMin
                  ? () => updater.setTerminalFontSize(fontSize - 1)
                  : null,
              visualDensity: VisualDensity.compact,
            ),
            Container(
              width: 40,
              alignment: Alignment.center,
              child: Text(
                '${fontSize.round()}',
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: AppLocalizations.of(context)!.shortcutNameZoomIn,
              icon: const Icon(LucideIcons.plus, size: 20),
              onPressed: fontSize < kTerminalFontSizeMax
                  ? () => updater.setTerminalFontSize(fontSize + 1)
                  : null,
              visualDensity: VisualDensity.compact,
            ),
          ]),
        ),

        const SizedBox(height: 12),

        // ── Cursor Style ──
        BesideOrUnder(
          words: Text(l10n.terminalSettingsCursorStyle,
              style: const TextStyle(fontSize: 15)),
          control: SegmentedButton<TerminalCursorShape>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: TerminalCursorShape.block,
                label: Text('\u2588', style: TextStyle(fontSize: 16)),
              ),
              ButtonSegment(
                value: TerminalCursorShape.underline,
                label: Text('_', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              ButtonSegment(
                value: TerminalCursorShape.verticalBar,
                label: Text('|', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
            selected: {cursorStyle},
            onSelectionChanged: (selected) {
              updater.setTerminalCursorShape(selected.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.background
                    : AppColors.onSurfaceVariant,
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.brandOrange
                    : Colors.transparent,
              ),
            ),
          ),
        ),

        const SizedBox(height: 8),

        // ── Cursor Blink ──
        Row(
          children: [
            Expanded(
              child: Text(l10n.terminalSettingsCursorBlink,
                  style: const TextStyle(fontSize: 15)),
            ),
            ZestSwitch(value: ref.watch(cursorBlinkProvider), onChanged: (v) => updater.setCursorBlink(v)),
          ],
        ),

        const SizedBox(height: 16),

        // ── Auto Reconnect ──
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.terminalSettingsAutoReconnect,
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    l10n.terminalSettingsAutoReconnectDescription,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            ZestSwitch(value: autoReconnect, onChanged: (value) =>
                  updater.setAutoReconnectEnabled(value)),
          ],
        ),
        const SizedBox(height: 8),

        // ── Dangerous Command Protection ──
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.terminalSettingsCommandProtection,
                      style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    l10n.terminalSettingsCommandProtectionDescription,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            ZestSwitch(value: ref.watch(dangerousCommandProtectionProvider), onChanged: (value) =>
                  updater.setDangerousCommandProtection(value)),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
