import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/l10n/list_names.dart';

/// The terminal's fonts ([FontPicker]): the app's dialog (3.4), a phone's
/// sheet, a row per font with a dot radio and its preview in its own type (a
/// tap picks it and closes), Close in the footer. (It was a Material dialog of
/// its own on a computer and a sheet of its own on a phone, the font in use
/// on an orange tile.)
Future<void> showFontPicker(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        key: const ValueKey('font-picker'),
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.type,
        title: l10n.fontPickerTitle,
        // Every font draws Nerd Font icons (4.0): said where the font is picked.
        subtitle: l10n.settingsTerminalFontNerdIcons,
        body: const FontPicker(),
        secondaryAction: (label: l10n.close, onPressed: () => Navigator.pop(ctx)),
      ),
    ),
  );
}

/// The terminal's fonts with live previews, the body of [showFontPicker].
///
/// Each option renders its preview text using the actual bundled font
/// so users can see real differences between typefaces.
class FontPicker extends ConsumerWidget {
  const FontPicker({super.key});

  /// Preview text per font - shows font name @ affluentlabs prompt.
  static String _previewText(TerminalFontFamily font) {
    final name = font.fontFamily.toLowerCase();
    return '$name@affluentlabs:~\$';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFont = ref.watch(terminalFontFamilyProvider);
    final updater = ref.watch(settingsUpdaterProvider);
    final l10n = AppLocalizations.of(context)!;

    // One font is picked, so a dot radio on each, the one the dialogs have;
    // a check is for where several can be picked (this was a check in a
    // circle). The one in use in bold,
    // with no tile of colour: colour is for what a dialog means.
    return RadioGroup<TerminalFontFamily>(
      groupValue: currentFont,
      onChanged: (font) {
        if (font == null) return;
        updater.setTerminalFontFamily(font);
        Navigator.pop(context);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final font in TerminalFontFamily.values)
            ListTile(
              key: ValueKey('font-picker-${font.name}'),
              contentPadding: const EdgeInsets.only(right: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              leading: Radio<TerminalFontFamily>(value: font),
              title: Text(
                font.nameIn(l10n),
                style: TextStyle(
                  fontWeight: font == currentFont ? FontWeight.w700 : FontWeight.w500,
                  color: AppColors.v3TextPrimary,
                ),
              ),
              subtitle: Text(
                _previewText(font),
                style: TextStyle(
                  fontFamily: font.fontFamily,
                  fontSize: 14,
                  height: 1.4,
                  color: AppColors.v3TextSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                updater.setTerminalFontFamily(font);
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }
}
