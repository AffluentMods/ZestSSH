import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes;
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/capped_file.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;
import 'package:zestssh/ui/widgets/setting_help.dart' show FoldedHelpTitle;

// ── Brand colour presets ──────────────────────────────────────────
// Swatch row offered by each brand picker (Primary / Secondary / Accent).
// The custom entry lets the user pick any RGB/hex value.

// Each colour once: the brand orange is the default primary and accent both
// (it was listed twice, two swatches of one colour).
const _brandPresets = <Color>[
  Color(0xFFFF7A1A), // orange (default primary and accent)
  Color(0xFF2196F3), // blue
  Color(0xFF4CAF50), // green
  Color(0xFF9C27B0), // purple
  Color(0xFFE91E63), // pink
  Color(0xFFF44336), // red
  Color(0xFF00BCD4), // cyan
  Color(0xFFFFC107), // amber
];

// ── UI font size scale ─────────────────────────────────────────────

enum UIFontScale {
  small('Small', 0.85),
  medium('Medium', 1.0),
  large('Large', 1.15);

  const UIFontScale(this.label, this.factor);
  final String label;
  final double factor;
}

// ══════════════════════════════════════════════════════════════════
//  Appearance Screen
// ══════════════════════════════════════════════════════════════════

/// The most of a file read as a theme: a theme is a few kilobytes.
const kMaxThemeFileBytes = 1024 * 1024;

class AppearanceScreen extends ConsumerStatefulWidget {
  const AppearanceScreen({super.key});

  @override
  ConsumerState<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends ConsumerState<AppearanceScreen> {
  // ── Helpers ─────────────────────────────────────────────────────

  // As many to a row as keep each name whole: about 110 wide each at the
  // text size the app is drawn at (larger with the text), two to four. A
  // phone has three (four cut them to "Catppuccin M..."), two at a large
  // text size.
  int get _gridColumns {
    final width = MediaQuery.sizeOf(context).width.clamp(0.0, 680.0);
    final perCard = 110 * MediaQuery.textScalerOf(context).scale(13) / 13;
    return ((width - 32 + 10) / (perCard + 10)).floor().clamp(2, 4);
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ResponsiveScaffold(
      title: l10n.appearanceAppearance,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // The two rows over the themes in one card, in the one settings
          // row of the phone (each was a box of its own, in another look).
          SettingsSection(
            title: null,
            child: Column(children: [_buildSyncToggle(), _buildTerminalLink()]),
          ),
          const SizedBox(height: 8),
          _buildAppThemeSection(),
          const SizedBox(height: 24),
          _buildTerminalThemeSection(),
          const SizedBox(height: 24),
          _buildAccentColorSection(),
          const SizedBox(height: 24),
          _buildTypographySection(),
          const SizedBox(height: 24),
          _buildSystemSection(),
          const SizedBox(height: 24),
          _buildCustomThemesSection(),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  0. Theme Sync Toggle
  // ══════════════════════════════════════════════════════════════

  /// Toggle for "apply theme to entire app". When ON (default), picking an
  /// app theme also flips the terminal theme to its paired equivalent (and
  /// vice-versa). When OFF, the two pickers act independently.
  Widget _buildSyncToggle() {
    final l10n = AppLocalizations.of(context)!;
    final synced = ref.watch(themesSyncedProvider);
    return SwitchListTile(
      key: const ValueKey('appearance-sync-themes'),
      value: synced,
      onChanged: (v) =>
          ref.read(themeSyncCoordinatorProvider).setSyncEnabled(v),
      title: FoldedHelpTitle(setting: l10n.appearanceApplyThemeToEntireApp, help: l10n.appearanceApplyThemeToEntireAppSubtitle),
      secondary: PhoneIconTile(
        synced ? LucideIcons.link : LucideIcons.unlink,
        color: synced ? null : AppColors.textSecondary,
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  0b. Terminal drill-down
  // ══════════════════════════════════════════════════════════════

  /// Terminal now lives UNDER Appearance (matching the desktop change where
  /// Terminal is a sub-group of Appearance): a single row that drills into the
  /// dedicated [TerminalSettingsScreen].
  Widget _buildTerminalLink() {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      key: const ValueKey('appearance-terminal'),
      leading: const PhoneIconTile(LucideIcons.terminal),
      // The page's own name and what it holds (4.0: Terminal and SSH).
      title: Text(l10n.settingsPageTerminalSsh),
      subtitle: Text(l10n.settingsPageTerminalSshDesc),
      trailing: const Icon(LucideIcons.chevronRight),
      onTap: () => context.push(Routes.terminalSettings),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  1. App Theme
  // ══════════════════════════════════════════════════════════════

  Widget _buildAppThemeSection() {
    final l10n = AppLocalizations.of(context)!;
    final currentThemeId = ref.watch(appThemeIdProvider);
    final synced = ref.watch(themesSyncedProvider);
    // The themes a person made or imported come after the built-in ones,
    // as a computer lists them (a phone listed the built-in ones alone, so
    // one made with the brand colours or imported could not be picked
    // again).
    final themes = [...BuiltInThemes.all, ...ref.watch(customAppThemesProvider).values];

    return _Section(
      title: synced ? l10n.appearanceTheme : l10n.appearanceAppTheme,
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: _ThemeGrid(
          crossAxisCount: _gridColumns,
          textScaler: MediaQuery.textScalerOf(context),
        ),
        itemCount: themes.length,
        itemBuilder: (context, index) {
          final theme = themes[index];
          final isSelected = theme.id == currentThemeId;
          return _AppThemeCard(
            key: ValueKey('appearance-app-theme-${theme.id}'),
            theme: theme,
            name: _appThemeName(theme, l10n),
            isSelected: isSelected,
            onTap: () {
              // Always go through the coordinator so the sync toggle is
              // honoured automatically.
              ref
                  .read(themeSyncCoordinatorProvider)
                  .setAppTheme(theme.id);
            },
          );
        },
      ),
    );
  }

  /// The name a theme is shown by: the one the brand colours make is named
  /// after them, in the person's language (it is saved as 'Custom').
  String _appThemeName(ZestTheme theme, AppLocalizations l10n) =>
      theme.id == kCustomBrandThemeId ? l10n.zestAppearanceBrandColors : theme.name;

  // ══════════════════════════════════════════════════════════════
  //  2. Terminal Theme
  // ══════════════════════════════════════════════════════════════

  Widget _buildTerminalThemeSection() {
    final l10n = AppLocalizations.of(context)!;
    final currentThemeId = ref.watch(shownTerminalThemeIdProvider);
    final synced = ref.watch(themesSyncedProvider);
    final allThemes = app_themes.TerminalThemes.all;
    final themeIds = allThemes.keys.toList();

    // When synced, this section becomes "Terminal Extras" - i.e. only the
    // terminal-only themes that don't pair with an app theme. Picking one
    // sets the terminal independently and leaves the app chrome alone.
    final visibleIds = synced
        ? themeIds.where((id) => !terminalThemeHasAppSibling(id)).toList()
        : themeIds;

    if (visibleIds.isEmpty) return const SizedBox.shrink();

    return _Section(
      title: synced
          ? l10n.appearanceTerminalOnlyThemes
          : l10n.appearanceTerminalTheme,
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: _ThemeGrid(
          crossAxisCount: _gridColumns,
          textScaler: MediaQuery.textScalerOf(context),
        ),
        itemCount: visibleIds.length,
        itemBuilder: (context, index) {
          final id = visibleIds[index];
          final theme = allThemes[id]!;
          final name = app_themes.TerminalThemes.names[id] ?? id;
          final isSelected = id == currentThemeId;
          return _TerminalThemeCard(
            themeId: id,
            theme: theme,
            name: name,
            isSelected: isSelected,
            onTap: () {
              // Always go through the coordinator so the sync toggle is
              // honoured automatically.
              ref
                  .read(themeSyncCoordinatorProvider)
                  .setTerminalTheme(id);
            },
          );
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  3. Accent Color
  // ══════════════════════════════════════════════════════════════

  Widget _buildAccentColorSection() {
    final l10n = AppLocalizations.of(context)!;
    // Reflect the ACTIVE resolved scheme so the pickers show the live values
    // (a built-in theme, or the user's custom_brand override).
    final scheme = ref.watch(appThemeProvider).colorScheme;
    final updater = ref.read(themeUpdaterProvider);

    return _Section(
      title: l10n.zestAppearanceBrandColors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _brandColorRow(
            label: l10n.zestAppearancePrimary,
            help: l10n.zestAppearancePrimaryHelp,
            selected: scheme.primary,
            onChanged: (c) => updater.setBrandColors(primary: c),
          ),
          const SizedBox(height: 20),
          _brandColorRow(
            label: l10n.zestAppearanceSecondary,
            help: l10n.zestAppearanceSecondaryHelp,
            selected: scheme.effectiveSecondary,
            onChanged: (c) => updater.setBrandColors(secondary: c),
          ),
          const SizedBox(height: 20),
          _brandColorRow(
            label: l10n.zestAppearanceAccent,
            help: l10n.zestAppearanceAccentHelp,
            selected: scheme.effectiveAccent,
            onChanged: (c) => updater.setBrandColors(accent: c),
          ),
        ],
      ),
    );
  }

  /// One labelled brand-colour row: title, one-line helper, and a full
  /// [ZestColorPicker] (presets + custom RGB/hex). Persists + hot-applies via
  /// [ThemeUpdater.setBrandColors].
  Widget _brandColorRow({
    required String label,
    required String help,
    required Color selected,
    required ValueChanged<Color> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        const SizedBox(height: 2),
        Text(
          help,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 10),
        ZestColorPicker(
          presets: _brandPresets,
          selected: selected,
          onChanged: onChanged,
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  4. Typography
  // ══════════════════════════════════════════════════════════════

  /// The terminal's font and its size are set on the Terminal page alone;
  /// here one row, saying what they are, opens that page.
  /// Both pages had the two rows, so the phone's settings
  /// search found each twice, "Terminal font" and "Font" (a design
  /// audit).
  Widget _buildTypographySection() {
    final l10n = AppLocalizations.of(context)!;
    final fontFamily = ref.watch(terminalFontFamilyProvider);
    final fontSize = ref.watch(terminalFontSizeProvider);

    return _Section(
      title: l10n.appearanceTypography,
      child: ListTile(
        key: const ValueKey('appearance-terminal-font'),
        contentPadding: EdgeInsets.zero,
        leading: const PhoneIconTile(LucideIcons.type),
        title: Text(l10n.appearanceTerminalFontAndSize),
        subtitle: Text(l10n.appearanceTerminalFontAndSizeValue(fontFamily.nameIn(l10n), fontSize.toInt())),
        trailing: const Icon(LucideIcons.chevronRight),
        onTap: () => context.push(Routes.terminalSettings),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  5. System
  // ══════════════════════════════════════════════════════════════

  Widget _buildSystemSection() {
    final l10n = AppLocalizations.of(context)!;
    final followSystem = ref.watch(followSystemThemeProvider);

    return _Section(
      title: l10n.appearanceSystem,
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: FoldedHelpTitle(setting: l10n.appearanceFollowSystemTheme, help: l10n.appearanceFollowSystemThemeSubtitle),
            value: followSystem,
            onChanged: (v) {
              ref.read(themeUpdaterProvider).setFollowSystemTheme(v);
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _resetToDefaults,
              icon: const Icon(LucideIcons.rotateCcw, size: 18),
              label: Text(l10n.appearanceResetToDefaults),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _resetToDefaults() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      // An ordinary question: nothing amber (3.4).
      tone: ZestDialogTone.neutral,
      title: l10n.appearanceResetAppearanceTitle,
      body: l10n.appearanceResetAppearanceContent,
      confirmLabel: l10n.appearanceReset,
    );
    if (confirmed == true && mounted) _doReset();
  }

  void _doReset() {
    final themeUpdater = ref.read(themeUpdaterProvider);
    final settingsUpdater = ref.read(settingsUpdaterProvider);
    final syncCoordinator = ref.read(themeSyncCoordinatorProvider);

    themeUpdater.setAppTheme(kDefaultAppThemeId);
    themeUpdater.setFollowSystemTheme(false);
    themeUpdater.setCustomAccentColor(null);
    // Drop the custom primary/secondary/accent override, if any.
    themeUpdater.clearBrandColors();
    // The terminal theme a new install has (it put Default Dark in its
    // place, which is not the default).
    settingsUpdater.setTerminalTheme(app_themes.TerminalThemes.defaultId);
    settingsUpdater.setTerminalFontFamily(TerminalFontFamily.jetBrainsMono);
    settingsUpdater.setTerminalFontSize(14);
    // Restore the default "synced" behaviour.
    syncCoordinator.setSyncEnabled(true);

    showTopSnackBar(context, AppLocalizations.of(context)!.appearanceResetSnack);
  }

  // ══════════════════════════════════════════════════════════════
  //  6. Custom Themes (Pro)
  // ══════════════════════════════════════════════════════════════

  Widget _buildCustomThemesSection() {
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final appCustoms = ref.watch(customAppThemesProvider).values.toList();
    final terminalCustomIds = app_themes.TerminalThemes.customThemeIds;

    return _Section(
      title: l10n.appearanceCustomThemes,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.appearanceCustomThemesSubtitle,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          // The two side by side where they fit, the second under the first
          // where they do not (on a phone 360 wide they ran off its edge, in
          // English too).
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: isPro ? _importTheme : () => _showProGate(context),
                icon: Icon(
                  isPro ? LucideIcons.upload : LucideIcons.lock,
                  size: 18,
                ),
                label: Text(l10n.appearanceImportTheme),
              ),
              OutlinedButton.icon(
                onPressed: _exportCurrentTheme,
                icon: const Icon(LucideIcons.download, size: 18),
                label: Text(l10n.appearanceExportCurrent),
              ),
            ],
          ),
          // The themes made or imported on this device, of both kinds, each
          // with its kind and a way to delete it (a phone listed its terminal
          // themes alone, and deleted one at a tap, without asking).
          if (appCustoms.isNotEmpty || terminalCustomIds.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              l10n.appearanceSavedThemes,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            for (final theme in appCustoms)
              ListTile(
                key: ValueKey('appearance-saved-app-${theme.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text(_appThemeName(theme, l10n)),
                subtitle: Text(l10n.appearanceAppTheme),
                leading: const PhoneIconTile(LucideIcons.palette, size: 20),
                trailing: IconButton(
                  tooltip: l10n.themeDesignDeleteTheme,
                  icon: const Icon(LucideIcons.trash2, size: 20),
                  onPressed: () => _deleteCustomAppTheme(theme),
                ),
              ),
            for (final id in terminalCustomIds)
              ListTile(
                key: ValueKey('appearance-saved-terminal-$id'),
                contentPadding: EdgeInsets.zero,
                title: Text(app_themes.TerminalThemes.names[id] ?? id),
                subtitle: Text(l10n.appearanceTerminalTheme),
                leading: const PhoneIconTile(LucideIcons.terminal, size: 20),
                trailing: IconButton(
                  tooltip: l10n.themePickerDeleteTheme,
                  icon: const Icon(LucideIcons.trash2, size: 20),
                  onPressed: () => _deleteCustomTheme(id),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _showProGate(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(
      context,
      l10n.appearanceCustomThemesRequirePro,
      actionLabel: l10n.appearanceUpgrade,
      // The way to Squeezed, as every notice of a paid part gives it (its
      // Upgrade did nothing).
      onAction: () {
        if (context.mounted) context.push(Routes.upgrade);
      },
    );
  }

  Future<void> _importTheme() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      // A file chosen can be anything, of any size: read to a theme's size at most.
      final bytes = await readFileCapped(file.path!, kMaxThemeFileBytes);
      if (bytes == null) {
        if (mounted) showTopSnackBar(context, l10n.csvImpTooLarge(1), isError: true);
        return;
      }
      final json = await importJsonAway(bytes) as Map<String, dynamic>;

      final name = json['name'] as String?;
      final type = json['type'] as String?;
      final colors = json['colors'] as Map<String, dynamic>?;

      if (name == null || type == null || colors == null) {
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.appearanceInvalidZesthemeFile,
          );
        }
        return;
      }

      if (type == 'terminal') {
        // Parse as terminal theme
        final termTheme = _parseTerminalThemeColors(colors);
        if (termTheme == null) {
          if (mounted) {
            showTopSnackBar(
                context, l10n.appearanceCouldNotParseTerminalColors);
          }
          return;
        }
        final prefs = ref.read(sharedPreferencesProvider);
        await app_themes.TerminalThemes.saveCustomTheme(
          prefs: prefs,
          name: name,
          theme: termTheme,
        );
        if (mounted) {
          setState(() {}); // Refresh to show the new theme
          showTopSnackBar(
              context, l10n.appearanceImportedTerminalTheme(name));
        }
      } else if (type == 'app') {
        // App (chrome) themes are stored as JSON-persisted ZestThemes under
        // customAppThemesProvider - the same slot the Theme Designer's
        // "Save as new theme" writes to - so an imported app theme resolves
        // through appThemeProvider exactly like a locally-created one.
        final scheme = ZestColorScheme.fromJson(colors);
        if (scheme == null) {
          if (mounted) {
            showTopSnackBar(context, l10n.appearanceCouldNotParseAppColors);
          }
          return;
        }
        // Mint a fresh local id so an import can never silently overwrite an
        // existing custom theme (or collide with a built-in id). Keep the
        // human-readable name from the file.
        final notifier = ref.read(customAppThemesProvider.notifier);
        final newId = notifier.nextId();
        final imported = scheme.copyWith(id: newId, name: name);
        final theme = ZestTheme(
          id: newId,
          name: name,
          brightness: imported.isDark ? Brightness.dark : Brightness.light,
          colorScheme: imported,
        );
        await notifier.save(theme);
        // Apply immediately, routed through the coordinator so the sync
        // toggle is honoured (a custom id has no terminal sibling, so this
        // just switches the app chrome).
        await ref.read(themeSyncCoordinatorProvider).setAppTheme(newId);
        if (mounted) {
          setState(() {});
          showTopSnackBar(
            context,
            l10n.appearanceImportedAppTheme(name),
            isSuccess: true,
          );
        }
      } else {
        if (mounted) {
          showTopSnackBar(context, l10n.appearanceUnknownThemeType(type));
        }
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.themeNotImported, isError: true, details: '$e');
      }
    }
  }

  TerminalTheme? _parseTerminalThemeColors(Map<String, dynamic> colors) {
    try {
      Color parse(String key) => parseThemeHex(colors[key] as String) ?? (throw FormatException(key));

      return TerminalTheme(
        cursor: parse('cursor'),
        selection: parse('selection'),
        foreground: parse('foreground'),
        background: parse('background'),
        black: parse('black'),
        red: parse('red'),
        green: parse('green'),
        yellow: parse('yellow'),
        blue: parse('blue'),
        magenta: parse('magenta'),
        cyan: parse('cyan'),
        white: parse('white'),
        brightBlack: parse('brightBlack'),
        brightRed: parse('brightRed'),
        brightGreen: parse('brightGreen'),
        brightYellow: parse('brightYellow'),
        brightBlue: parse('brightBlue'),
        brightMagenta: parse('brightMagenta'),
        brightCyan: parse('brightCyan'),
        brightWhite: parse('brightWhite'),
        searchHitBackground: const Color(0x80E8A020),
        searchHitBackgroundCurrent: const Color(0xFFE8A020),
        searchHitForeground: const Color(0xFF000000),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _exportCurrentTheme() async {
    final l10n = AppLocalizations.of(context)!;
    final terminalId = ref.read(terminalThemeIdProvider);
    final termTheme = app_themes.TerminalThemes.all[terminalId];
    if (termTheme == null) return;

    final name = app_themes.TerminalThemes.names[terminalId] ?? terminalId;

    String colorHex(Color c) =>
        (c.toARGB32() & 0x00FFFFFF)
            .toRadixString(16)
            .padLeft(6, '0')
            .toUpperCase();

    final export = {
      'name': name,
      'type': 'terminal',
      'colors': {
        'cursor': colorHex(termTheme.cursor),
        'selection': colorHex(termTheme.selection),
        'foreground': colorHex(termTheme.foreground),
        'background': colorHex(termTheme.background),
        'black': colorHex(termTheme.black),
        'red': colorHex(termTheme.red),
        'green': colorHex(termTheme.green),
        'yellow': colorHex(termTheme.yellow),
        'blue': colorHex(termTheme.blue),
        'magenta': colorHex(termTheme.magenta),
        'cyan': colorHex(termTheme.cyan),
        'white': colorHex(termTheme.white),
        'brightBlack': colorHex(termTheme.brightBlack),
        'brightRed': colorHex(termTheme.brightRed),
        'brightGreen': colorHex(termTheme.brightGreen),
        'brightYellow': colorHex(termTheme.brightYellow),
        'brightBlue': colorHex(termTheme.brightBlue),
        'brightMagenta': colorHex(termTheme.brightMagenta),
        'brightCyan': colorHex(termTheme.brightCyan),
        'brightWhite': colorHex(termTheme.brightWhite),
      },
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(export);

    try {
      final fileName =
          '${name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_').toLowerCase()}.zestheme';
      // Written into a folder of its own, and deleted with it once the sheet
      // has closed (it was written straight into the folder of temporary
      // files and left there).
      await ConnectionShareService.shareFiles(
        {fileName: utf8.encode(jsonStr)},
        subject: l10n.appearanceExportShareSubject(name),
      );
    } catch (e) {
      // In the app's words, with what was thrown to copy (it said "Export
      // failed:" and the error as it was thrown).
      if (mounted) {
        showTopSnackBar(context, l10n.appearanceThemeNotExported, isError: true, details: '$e');
      }
    }
  }

  Future<void> _deleteCustomTheme(String id) async {
    final l10n = AppLocalizations.of(context)!;
    // Asked first, as the theme picker asks (a tap deleted it).
    final sure = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.themePickerDeleteTheme,
      body: l10n.themePickerDeleteConfirm(app_themes.TerminalThemes.names[id] ?? id),
      confirmLabel: l10n.delete,
    );
    if (sure != true || !mounted) return;
    final prefs = ref.read(sharedPreferencesProvider);
    final currentId = ref.read(terminalThemeIdProvider);

    await app_themes.TerminalThemes.deleteCustomTheme(prefs: prefs, id: id);

    // The theme in use deleted: the one a new install has, as the theme
    // picker does (it put Default Dark in its place).
    if (currentId == id) {
      await ref.read(settingsUpdaterProvider).setTerminalTheme(app_themes.TerminalThemes.defaultId);
    }

    if (mounted) setState(() {}); // Refresh list
  }

  /// An app theme made or imported, deleted after asking, as a computer
  /// deletes one; the one in use gives way to the theme a new install has
  /// (Graphite), as the question says ([themeDeleteQuestionBody]).
  Future<void> _deleteCustomAppTheme(ZestTheme theme) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.themeDesignDeleteThemeTitle(_appThemeName(theme, l10n)),
      body: themeDeleteQuestionBody(l10n),
      confirmLabel: l10n.themeDesignDeleteTheme,
    );
    if (confirmed != true || !mounted) return;
    await ref.read(customAppThemesProvider.notifier).delete(theme.id);
    // The one in use gives way to the theme a new install has.
    if (ref.read(appThemeIdProvider) == theme.id) {
      await ref.read(themeUpdaterProvider).setAppTheme(kDefaultAppThemeId);
    }
  }
}

// ══════════════════════════════════════════════════════════════════
//  Shared layout widgets
// ══════════════════════════════════════════════════════════════════

/// Section wrapper with a styled header.
class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  // The 3.0 look every phone settings page shares (widgets/settings_section.dart).
  @override
  Widget build(BuildContext context) => SettingsSection(title: title, card: false, child: child);
}

// ══════════════════════════════════════════════════════════════════
//  Theme grid
// ══════════════════════════════════════════════════════════════════

/// Theme cards in a grid: each as tall as its width makes it at the text
/// size the app is drawn at, and taller by as much as its name grows at a
/// larger one, so the picture above the name keeps its size (at twice the
/// size it ran out of its card, found 17 October 2026).
class _ThemeGrid extends SliverGridDelegateWithFixedCrossAxisCount {
  const _ThemeGrid({required super.crossAxisCount, required this.textScaler})
      : super(crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.85);

  final TextScaler textScaler;

  /// The room under the picture for a card's name: two lines of 13 at the
  /// text size the app is drawn at, and its padding.
  double get _nameRoom => 2 * textScaler.scale(13) * 1.3 + 14;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = (constraints.crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1)) / crossAxisCount;
    final height = width * 0.72 + _nameRoom;
    return SliverGridRegularTileLayout(
      crossAxisCount: crossAxisCount,
      mainAxisStride: height + mainAxisSpacing,
      crossAxisStride: width + crossAxisSpacing,
      childMainAxisExtent: height,
      childCrossAxisExtent: width,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(covariant _ThemeGrid oldDelegate) =>
      super.shouldRelayout(oldDelegate) || oldDelegate.textScaler != textScaler;
}

// ══════════════════════════════════════════════════════════════════
//  App Theme Card
// ══════════════════════════════════════════════════════════════════

class _AppThemeCard extends StatelessWidget {
  final ZestTheme theme;
  final String name;
  final bool isSelected;
  final VoidCallback onTap;

  const _AppThemeCard({
    super.key,
    required this.theme,
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.brandOrange : AppColors.divider,
            width: isSelected ? 2 : 1,
          ),
          color: AppColors.surface,
        ),
        child: Column(
          children: [
            // Mini preview
            Expanded(
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(11)),
                child: Stack(
                  children: [
                    // Background
                    Container(color: cs.background),
                    // Surface card preview
                    Positioned(
                      left: 6,
                      top: 6,
                      right: 6,
                      bottom: 12,
                      child: Container(
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Simulated title bar
                            Container(
                              height: 4,
                              width: 30,
                              decoration: BoxDecoration(
                                color: cs.primary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              height: 3,
                              width: 20,
                              decoration: BoxDecoration(
                                color: cs.onSurfaceMuted,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Selected checkmark
                    if (isSelected)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: AppColors.brandOrange,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            LucideIcons.check,
                            size: 14,
                            color: AppColors.onBrand(AppColors.brandOrange),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Name
            SizedBox(
              height: 2 * MediaQuery.textScalerOf(context).scale(13) * 1.3 + 14,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                child: Center(
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected
                          ? AppColors.accentInk
                          : AppColors.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
//  Terminal Theme Card
// ══════════════════════════════════════════════════════════════════

class _TerminalThemeCard extends StatelessWidget {
  final String themeId;
  final TerminalTheme theme;
  final String name;
  final bool isSelected;
  final VoidCallback onTap;

  const _TerminalThemeCard({
    required this.themeId,
    required this.theme,
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.brandOrange : AppColors.divider,
            width: isSelected ? 2 : 1,
          ),
          color: AppColors.surface,
        ),
        child: Column(
          children: [
            // Mini terminal preview
            Expanded(
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(11)),
                child: Stack(
                  children: [
                    // A picture of a terminal: its sample lines keep their size whatever
                    // the text size (at 1.5 times they ran out of the card).
                    MediaQuery.withNoTextScaling(child: Container(
                      color: theme.background,
                      padding: const EdgeInsets.all(6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _termLine('\$ ', theme.green, 'ls -la',
                              theme.foreground),
                          const SizedBox(height: 2),
                          _termLine('> ', theme.cyan, 'main.dart',
                              theme.yellow),
                          const SizedBox(height: 2),
                          _termLine('', theme.red, 'error',
                              theme.foreground),
                        ],
                      ),
                    )),
                    if (isSelected)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: AppColors.brandOrange,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            LucideIcons.check,
                            size: 14,
                            color: AppColors.onBrand(AppColors.brandOrange),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Name
            SizedBox(
              height: 2 * MediaQuery.textScalerOf(context).scale(13) * 1.3 + 14,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                child: Center(
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected
                          ? AppColors.accentInk
                          : AppColors.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _termLine(
      String prefix, Color prefixColor, String text, Color textColor) {
    return Row(
      children: [
        Text(
          prefix,
          style: TextStyle(
            fontSize: 8,
            fontFamily: 'JetBrainsMono',
            color: prefixColor,
            height: 1.2,
          ),
        ),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 8,
              fontFamily: 'JetBrainsMono',
              color: textColor,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// What the question before a custom app theme is deleted says: that the
/// theme in use gives way to the one a new install has, by its name. It said
/// "Default Dark", a theme there is none of (it falls back to Graphite).
String themeDeleteQuestionBody(AppLocalizations l10n) =>
    l10n.themeDeleteFallsBackTo(BuiltInThemes.getById(kDefaultAppThemeId).name);

/// A colour of a .zestheme file: "#" and 3, 4, 6 or 8 hex digits (or the
/// digits alone), as CSS writes them: RGB, RGBA, RRGGBB or RRGGBBAA, each
/// digit of the short forms doubled. Null for anything else. ("#fff" was
/// read as 0xFFF, a dark blue, and an alpha in 8 digits was dropped.)
Color? parseThemeHex(String text) {
  var hex = text.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
  if (hex.length == 3 || hex.length == 4) hex = [for (final c in hex.split('')) '$c$c'].join();
  if (hex.length == 6) hex = '${hex}ff';
  if (hex.length != 8) return null;
  final rgba = int.parse(hex, radix: 16);
  // RRGGBBAA to AARRGGBB, as Color takes it.
  return Color(((rgba & 0xFF) << 24) | (rgba >> 8));
}
