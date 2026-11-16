import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart';

/// A bottom sheet that lets the user quickly customise terminal
/// appearance (theme, font size) without leaving the home screen.
///
/// Shown from the "Customize Terminal" getting-started card.
class QuickCustomizeSheet extends ConsumerWidget {
  const QuickCustomizeSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final themeId = ref.watch(shownTerminalThemeIdProvider);
    final fontSize = ref.watch(terminalFontSizeProvider);
    final updater = ref.watch(settingsUpdaterProvider);

    final themeEntries = TerminalThemes.builtIn.entries.toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [

          // Title
          Text(
            l10n.settingsTerminalAppearance,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 20),

          // Theme selector - horizontal scrolling preview cards
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.settingsTerminalTheme,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: themeEntries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final entry = themeEntries[index];
                final id = entry.key;
                final theme = entry.value;
                final name = TerminalThemes.builtInNames[id] ?? id;
                final isSelected = id == themeId;
                return GestureDetector(
                  // Through the coordinator: with "Match terminal to app
                  // theme" on, its app theme follows, so the pick is shown.
                  onTap: () => ref.read(themeSyncCoordinatorProvider).setTerminalTheme(id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 100,
                    decoration: BoxDecoration(
                      color: theme.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.brandOrange
                            : AppColors.divider,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.foreground,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 20),

          // Font size slider
          Row(
            children: [
              Text(
                l10n.settingsFontSize,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${fontSize.toInt()}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accentInk,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ],
          ),
          Slider(
            value: clampTerminalFontSize(fontSize),
            min: kTerminalFontSizeMin,
            max: kTerminalFontSizeMax,
            divisions: (kTerminalFontSizeMax - kTerminalFontSizeMin).round(),
            activeColor: AppColors.brandOrange,
            onChanged: (v) => updater.setTerminalFontSize(v),
          ),

          const SizedBox(height: 8),

          // Done button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.done),
            ),
          ),
        ],
      ),
    );
  }
}
