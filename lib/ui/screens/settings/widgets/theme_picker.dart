import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes;
import 'package:zestssh/ui/screens/settings/widgets/custom_theme_builder.dart';

/// The terminal's themes ([ThemePicker]): the app's dialog (3.4) on a
/// computer and its sheet on a phone, a tile per theme (a tap picks it and closes),
/// Create custom theme the footer's side link and Close beside it. (It was a
/// Material dialog of its own on a computer and a sheet of its own on a
/// phone, with its button under the tiles.)
Future<void> showThemePicker(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final isPro = ref.read(isProProvider);
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        key: const ValueKey('theme-picker'),
        size: ZestModalSize.standard,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.palette,
        title: l10n.themePickerTitle,
        body: const ThemePicker(),
        tertiaryKey: const ValueKey('theme-picker-create'),
        tertiaryAction: (
          label: isPro ? l10n.themePickerCreateCustomTheme : l10n.themePickerCreateCustomThemePro,
          onPressed: () {
            Navigator.pop(ctx);
            if (!isPro) {
              context.push(Routes.upgrade);
              return;
            }
            showCustomThemeBuilder(context, ref);
          },
        ),
        secondaryAction: (label: l10n.close, onPressed: () => Navigator.pop(ctx)),
      ),
    ),
  );
}

/// A grid of terminal theme previews, the body of [showThemePicker].
///
/// Free themes are always selectable. Pro themes show a lock icon
/// and navigate to the upgrade screen when tapped by free users.
///
/// Custom user-created themes appear in a separate section at the bottom
/// with edit / delete actions.
class ThemePicker extends ConsumerWidget {
  const ThemePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final currentId = ref.watch(shownTerminalThemeIdProvider);
    final updater = ref.watch(settingsUpdaterProvider);
    final isPro = ref.watch(isProProvider);
    final customIds = app_themes.TerminalThemes.customThemeIds;

    final builtInEntries = app_themes.TerminalThemes.builtIn.entries.toList();

    // Total items = built-in + optional custom header + custom themes
    //             + "Create Custom" button
    final hasCustom = customIds.isNotEmpty;

    // Grids that take the room they need: the dialog's body scrolls.
    Widget grid(List<Widget> tiles) => GridView.count(
          crossAxisCount: 3,
          childAspectRatio: 100 / 80,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: tiles,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Built-in themes grid ────────────────────────
        grid([
          for (final entry in builtInEntries)
            _ThemeTile(
              id: entry.key,
              theme: entry.value,
              name: app_themes.TerminalThemes.builtInNames[entry.key] ?? entry.key,
              isSelected: entry.key == currentId,
              isFree: app_themes.TerminalThemes.freeThemeIds.contains(entry.key),
              isPro: isPro,
              isCustom: false,
              onSelect: () {
                // Through the coordinator: with "Match terminal to app
                // theme" on, its app theme follows, so the pick is the
                // terminal shown.
                ref.read(themeSyncCoordinatorProvider).setTerminalTheme(entry.key);
                Navigator.pop(context);
              },
              onLocked: () {
                Navigator.pop(context);
                context.push(Routes.upgrade);
              },
            ),
        ]),

        // ── Custom themes ────────────────────────────────
        if (hasCustom) ...[
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: Text(
              l10n.themePickerCustomThemes,
              style: TextStyle(
                color: AppColors.v3TextSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          grid([
            for (final id in customIds)
              if (app_themes.TerminalThemes.all[id] case final theme?)
                _ThemeTile(
                  id: id,
                  theme: theme,
                  name: app_themes.TerminalThemes.names[id] ?? id,
                  isSelected: id == currentId,
                  isFree: true, // custom themes are always usable
                  isPro: isPro,
                  isCustom: true,
                  onSelect: () {
                    ref.read(themeSyncCoordinatorProvider).setTerminalTheme(id);
                    Navigator.pop(context);
                  },
                  onEdit: () {
                    Navigator.pop(context);
                    showCustomThemeBuilder(
                      context,
                      ref,
                      existingId: id,
                      existingTheme: theme,
                      existingName: app_themes.TerminalThemes.names[id] ?? id,
                    );
                  },
                  onDelete: () async {
                    final name = app_themes.TerminalThemes.names[id] ?? id;
                    final confirm = await ZestConfirmDialog.show(
                      context,
                      tone: ZestDialogTone.destructive,
                      title: l10n.themePickerDeleteTheme,
                      body: l10n.themePickerDeleteConfirm(name),
                      confirmLabel: l10n.delete,
                    );
                    if (confirm != true) return;
                    if (!context.mounted) return;

                    final prefs = ref.read(sharedPreferencesProvider);
                    await app_themes.TerminalThemes.deleteCustomTheme(
                      prefs: prefs,
                      id: id,
                    );
                    // If the deleted theme was active, fall back.
                    if (currentId == id) {
                      updater.setTerminalTheme(app_themes.TerminalThemes.defaultId);
                    }
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
          ]),
        ],
      ],
    );
  }
}

// ── Individual theme preview tile ────────────────────────────────

class _ThemeTile extends StatelessWidget {
  final String id;
  final TerminalTheme theme;
  final String name;
  final bool isSelected;
  final bool isFree;
  final bool isPro;
  final bool isCustom;
  final VoidCallback onSelect;
  final VoidCallback? onLocked;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _ThemeTile({
    required this.id,
    required this.theme,
    required this.name,
    required this.isSelected,
    required this.isFree,
    required this.isPro,
    required this.isCustom,
    required this.onSelect,
    this.onLocked,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isLocked = !isFree && !isPro;

    return GestureDetector(
      onTap: () {
        if (isLocked) {
          onLocked?.call();
          return;
        }
        onSelect();
      },
      onLongPress: isCustom
          ? () => _showCustomActions(context)
          : null,
      child: Opacity(
        opacity: isLocked ? 0.6 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: theme.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  isSelected ? AppColors.brandOrange : Colors.transparent,
              width: 2,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '\$ ls -la',
                style: TextStyle(
                  color: theme.foreground,
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                ),
              ),
              Text(
                'drwxr-xr-x',
                style: TextStyle(
                  color: theme.green,
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        color: theme.foreground,
                        fontSize: 10,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isLocked)
                    Icon(LucideIcons.lock, size: 12, color: theme.yellow)
                  else if (isCustom)
                    Icon(LucideIcons.brush, size: 12, color: theme.cyan)
                  else if (!isFree)
                    Icon(LucideIcons.sparkles, size: 12, color: theme.yellow),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCustomActions(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(LucideIcons.pencil, color: AppColors.accentInk),
              title: Text(l10n.themePickerEditNamed(name)),
              onTap: () {
                Navigator.pop(ctx);
                onEdit?.call();
              },
            ),
            ListTile(
              leading: Icon(LucideIcons.trash2, color: AppColors.error),
              title: Text(l10n.themePickerDeleteNamed(name)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete?.call();
              },
            ),
          ],
        ),
      ),
    );
  }
}
