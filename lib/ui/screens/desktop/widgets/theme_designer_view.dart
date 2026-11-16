import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart' show shownTerminalThemeIdProvider;
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_color_scheme.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/ui/screens/settings/widgets/custom_theme_builder.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart' show themeDeleteQuestionBody;
import 'package:zestssh/utils/around_value.dart';
import 'package:zestssh/utils/number_text.dart';

// ══════════════════════════════════════════════════════════════════
// Editable token model
// ══════════════════════════════════════════════════════════════════
//
// The designer edits a SUBSET of a full [ZestColorScheme]. Every field it
// does NOT expose (info, hover, secondary, accent, and the derived chrome
// tokens) is carried through untouched, so editing a built-in preserves the
// parts you didn't touch instead of resetting them to a generic default -
// the bug the previous flat-15-token model had, where saving Dracula quietly
// reset its info/selection/hover to defaults.

class _SchemeToken {
  const _SchemeToken({
    required this.key,
    required this.label,
    required this.description,
    required this.read,
    required this.write,
  });

  /// Stable, internal identifier used to match validation findings back to the
  /// row they flag. Never shown to the user (the display label is localized).
  final String key;

  /// Localized display label, resolved against the active [AppLocalizations].
  final String Function(AppLocalizations l10n) label;

  /// Localized one-line description, resolved against [AppLocalizations].
  final String Function(AppLocalizations l10n) description;

  /// Pull this token's colour out of a scheme.
  final Color Function(ZestColorScheme cs) read;

  /// Return a new scheme with this token set to [value]. May touch more than
  /// one field (e.g. Accent also recomputes on-accent + focus + selection).
  final ZestColorScheme Function(ZestColorScheme cs, Color value) write;
}

/// Text / glyph colour on a filled accent, computed so a USER-chosen accent
/// stays legible: near-black above ~0.45 relative luminance, near-white below.
/// A pale-yellow and a deep-navy accent both get a readable button label.
/// The "On accent" token: as the app derives it (ZestColors.onFill), the
/// more readable of white and near-black (a luminance cut-off gave the
/// default orange white, 2.6:1).
Color _onAccentFor(Color accent) => ZestColors.onFill(accent);

/// Sunken (recessed input) surface, a step below [cs] surface. Mirrors the
/// derivation in ZestTheme.toThemeData and AppColors.applyTheme so the preview
/// and the derived-row swatch match what the app actually renders.
Color _sunkenOf(ZestColorScheme cs) {
  final hsl = HSLColor.fromColor(cs.surface);
  final isDark = cs.background.computeLuminance() < 0.4;
  return hsl
      .withLightness((hsl.lightness + (isDark ? -0.025 : -0.03)).clamp(0.0, 1.0))
      .toColor();
}

// Closures can't be const, so these are top-level finals.

final List<_SchemeToken> _surfaceTokens = [
  _SchemeToken(
    key: 'background',
    label: (l10n) => l10n.themeDesignTokenBackground,
    description: (l10n) => l10n.themeDesignTokenBackgroundDesc,
    read: (cs) => cs.background,
    write: (cs, v) => cs.copyWith(background: v),
  ),
  _SchemeToken(
    key: 'surface',
    label: (l10n) => l10n.themeDesignTokenSurface,
    description: (l10n) => l10n.themeDesignTokenSurfaceDesc,
    read: (cs) => cs.surface,
    write: (cs, v) => cs.copyWith(surface: v),
  ),
  _SchemeToken(
    key: 'elevated',
    label: (l10n) => l10n.themeDesignTokenElevated,
    description: (l10n) => l10n.themeDesignTokenElevatedDesc,
    read: (cs) => cs.surfaceElevated,
    write: (cs, v) => cs.copyWith(surfaceElevated: v),
  ),
];

final List<_SchemeToken> _textTokens = [
  _SchemeToken(
    key: 'textPrimary',
    label: (l10n) => l10n.themeDesignTokenTextPrimary,
    description: (l10n) => l10n.themeDesignTokenTextPrimaryDesc,
    read: (cs) => cs.onSurface,
    write: (cs, v) => cs.copyWith(onSurface: v, onBackground: v),
  ),
  _SchemeToken(
    key: 'textSecondary',
    label: (l10n) => l10n.themeDesignTokenTextSecondary,
    description: (l10n) => l10n.themeDesignTokenTextSecondaryDesc,
    read: (cs) => cs.onSurfaceMuted,
    write: (cs, v) => cs.copyWith(onSurfaceMuted: v, onBackgroundMuted: v),
  ),
  _SchemeToken(
    key: 'textSubtle',
    label: (l10n) => l10n.themeDesignTokenTextSubtle,
    description: (l10n) => l10n.themeDesignTokenTextSubtleDesc,
    read: (cs) => cs.onBackgroundSubtle,
    write: (cs, v) => cs.copyWith(onBackgroundSubtle: v),
  ),
];

final List<_SchemeToken> _borderTokens = [
  _SchemeToken(
    key: 'border',
    label: (l10n) => l10n.themeDesignTokenBorder,
    description: (l10n) => l10n.themeDesignTokenBorderDesc,
    read: (cs) => cs.border,
    write: (cs, v) => cs.copyWith(border: v),
  ),
  _SchemeToken(
    key: 'divider',
    label: (l10n) => l10n.themeDesignTokenDivider,
    description: (l10n) => l10n.themeDesignTokenDividerDesc,
    read: (cs) => cs.divider,
    write: (cs, v) => cs.copyWith(divider: v),
  ),
];

final List<_SchemeToken> _accentTokens = [
  _SchemeToken(
    key: 'accent',
    label: (l10n) => l10n.themeDesignTokenAccent,
    description: (l10n) => l10n.themeDesignTokenAccentDesc,
    read: (cs) => cs.primary,
    write: (cs, v) => cs.copyWith(
      primary: v,
      // On-accent is computed, never authored - a user-chosen accent must
      // keep its button label readable.
      onPrimary: _onAccentFor(v),
      focus: v,
      selected: v.withValues(alpha: 0.15),
    ),
  ),
  _SchemeToken(
    key: 'accentHover',
    label: (l10n) => l10n.themeDesignTokenAccentHover,
    description: (l10n) => l10n.themeDesignTokenAccentHoverDesc,
    read: (cs) => cs.primaryHover,
    write: (cs, v) => cs.copyWith(primaryHover: v),
  ),
];

final List<_SchemeToken> _statusTokens = [
  _SchemeToken(
    key: 'success',
    label: (l10n) => l10n.themeDesignTokenSuccess,
    description: (l10n) => l10n.themeDesignTokenSuccessDesc,
    read: (cs) => cs.success,
    write: (cs, v) => cs.copyWith(success: v),
  ),
  _SchemeToken(
    key: 'warning',
    label: (l10n) => l10n.themeDesignTokenWarning,
    description: (l10n) => l10n.themeDesignTokenWarningDesc,
    read: (cs) => cs.warning,
    write: (cs, v) => cs.copyWith(warning: v),
  ),
  _SchemeToken(
    key: 'error',
    label: (l10n) => l10n.themeDesignTokenError,
    description: (l10n) => l10n.themeDesignTokenErrorDesc,
    read: (cs) => cs.error,
    write: (cs, v) => cs.copyWith(error: v),
  ),
];

/// Every editable token in group order - used for dirty detection and reset.
final List<_SchemeToken> _allTokens = [
  ..._surfaceTokens,
  ..._textTokens,
  ..._borderTokens,
  ..._accentTokens,
  ..._statusTokens,
];

/// WCAG contrast ratio between two opaque colours (1.0 .. 21.0).
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// A validation finding. [blocking] issues (colour collisions) prevent saving;
/// warnings are advisory. [labels] are the row labels to flag inline.
class _ThemeIssue {
  const _ThemeIssue(this.labels, this.message, {this.blocking = false});
  final List<String> labels;
  final String message;
  final bool blocking;
}

// ══════════════════════════════════════════════════════════════════
// ThemeDesignerView
// ══════════════════════════════════════════════════════════════════
//
// A thin editor over the REAL app-theme system. Selecting a theme here applies
// it live (via [themeUpdaterProvider]) AND loads it for editing; the built-in
// list is [BuiltInThemes.all] (the same themes the Appearance dropdown offers),
// and Save-as-new / Import register a [customAppThemesProvider] theme. There is
// no private theme set or private prefs any more.

class ThemeDesignerView extends ConsumerStatefulWidget {
  const ThemeDesignerView({super.key, this.initialTab = 0, this.onClose});

  /// 0 = App tab, 1 = Terminal tab. Appearance opens on App; the Terminal
  /// "Open theme designer" button opens on Terminal.
  final int initialTab;

  /// Closes the enclosing docked panel (used by the embedded terminal builder
  /// after a save). Null outside the dock.
  final VoidCallback? onClose;

  @override
  ConsumerState<ThemeDesignerView> createState() => _ThemeDesignerViewState();
}

class _ThemeDesignerViewState extends ConsumerState<ThemeDesignerView> {
  /// The scheme currently in the editor. Seeded from the active theme,
  /// reseeded whenever a theme is selected, mutated as tokens are edited.
  late ZestColorScheme _working;

  /// Identity of the theme the working copy was seeded from - drives the
  /// "Editing" badge (name + built-in/custom + unsaved marker).
  late String _baseId;
  late String _baseName;

  /// True once the working copy diverges from its base theme.
  bool _dirty = false;

  /// 0 = App tab, 1 = Terminal tab.
  late int _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    final active = ref.read(appThemeProvider);
    _baseId = active.id;
    _baseName = active.name;
    _working = active.colorScheme;
  }

  bool get _baseIsBuiltIn => BuiltInThemes.contains(_baseId);

  // ── Selection ───────────────────────────────────────────────────

  /// Apply [theme] as the live app theme AND load it into the editor. Free
  /// users hit the paywall on a Pro-only built-in (custom themes are the
  /// user's own, so they're always selectable).
  Future<void> _selectTheme(ZestTheme theme) async {
    final isBuiltIn = BuiltInThemes.contains(theme.id);
    final isPro = ref.read(isProProvider);
    if (isBuiltIn && !isPro && !kFreeAppThemeIds.contains(theme.id)) {
      PricingModal.show(context);
      return;
    }
    final updater = ref.read(themeUpdaterProvider);
    // An explicit pick is a manual choice: turn off follow-system, otherwise
    // the OS brightness silently overrides the selection and it looks dead.
    await updater.setFollowSystemTheme(false);
    // Route through the sync coordinator so "Match terminal to app theme"
    // (when on) also flips the paired terminal palette.
    await ref.read(themeSyncCoordinatorProvider).setAppTheme(theme.id);
    if (!mounted) return;
    setState(() {
      _baseId = theme.id;
      _baseName = theme.name;
      _working = theme.colorScheme;
      _dirty = false;
    });
  }

  // ── Editing ─────────────────────────────────────────────────────

  void _applyToken(_SchemeToken token, String hex) {
    setState(() {
      _working = token.write(_working, _hexToColor(hex));
      _dirty = _differsFromBase();
    });
  }

  /// The scheme of the theme the working copy was seeded from (built-in or
  /// custom), or null if that theme no longer exists.
  ZestColorScheme? _baseScheme() {
    return _baseIsBuiltIn
        ? BuiltInThemes.getById(_baseId).colorScheme
        : ref.read(customAppThemesProvider)[_baseId]?.colorScheme;
  }

  /// True when any editable token differs from the base theme.
  bool _differsFromBase() {
    final base = _baseScheme();
    if (base == null) return true;
    for (final t in _allTokens) {
      if (t.read(_working).toARGB32() != t.read(base).toARGB32()) return true;
    }
    return false;
  }

  /// Revert edits back to the base theme's shipped colours.
  void _reset() {
    final base = _baseScheme();
    if (base == null) return;
    setState(() {
      _working = base;
      _dirty = false;
    });
  }

  /// Revert a single token to the base theme's value (per-row reset).
  void _resetToken(_SchemeToken token) {
    final base = _baseScheme();
    if (base == null) return;
    setState(() {
      _working = token.write(_working, token.read(base));
      _dirty = _differsFromBase();
    });
  }

  // ── Validation ──────────────────────────────────────────────────

  /// Structural checks on the working scheme. Collisions BLOCK saving (two
  /// tokens sharing a value renders a border invisible); contrast and ladder
  /// findings are advisory warnings.
  List<_ThemeIssue> _validate(ZestColorScheme cs, AppLocalizations l10n) {
    final issues = <_ThemeIssue>[];
    final isDark = cs.background.computeLuminance() < 0.4;

    bool same(Color a, Color b) => a.toARGB32() == b.toARGB32();
    // keyA/keyB are the stable row identifiers (used to flag the right row);
    // nameA/nameB are the localized display names shown in the message.
    void collide(
        String keyA, String nameA, Color ca, String keyB, String nameB, Color cb) {
      if (same(ca, cb)) {
        issues.add(_ThemeIssue(
            [keyA, keyB], l10n.themeDesignCollision(nameA, nameB),
            blocking: true));
      }
    }

    collide('surface', l10n.themeDesignTokenSurface, cs.surface, 'divider',
        l10n.themeDesignTokenDivider, cs.divider);
    collide('elevated', l10n.themeDesignTokenElevated, cs.surfaceElevated,
        'border', l10n.themeDesignTokenBorder, cs.border);
    collide('background', l10n.themeDesignTokenBackground, cs.background,
        'surface', l10n.themeDesignTokenSurface, cs.surface);
    collide('surface', l10n.themeDesignTokenSurface, cs.surface, 'elevated',
        l10n.themeDesignTokenElevated, cs.surfaceElevated);

    void contrast(String key, String name, Color fg, double min) {
      final r = _contrastRatio(fg, cs.surface);
      if (r < min) {
        issues.add(_ThemeIssue(
          [key],
          l10n.themeDesignContrastWarning(
              name, formatDecimal(r, l10n: l10n), formatDecimal(min, l10n: l10n)),
        ));
      }
    }

    contrast('textPrimary', l10n.themeDesignTokenTextPrimary, cs.onSurface, 4.5);
    contrast(
        'textSecondary', l10n.themeDesignTokenTextSecondary, cs.onSurfaceMuted, 3.0);
    contrast('accent', l10n.themeDesignTokenAccent, cs.primary, 3.0);

    final bgL = cs.background.computeLuminance();
    final sfL = cs.surface.computeLuminance();
    final elL = cs.surfaceElevated.computeLuminance();
    if (isDark) {
      if (sfL < bgL) {
        issues.add(_ThemeIssue(
            ['surface'], l10n.themeDesignSurfaceLighterThanBackground));
      }
      if (elL < sfL) {
        issues.add(_ThemeIssue(
            ['elevated'], l10n.themeDesignElevatedLighterThanSurface));
      }
    } else {
      if (sfL > bgL) {
        issues.add(_ThemeIssue(
            ['surface'], l10n.themeDesignSurfaceDarkerThanBackground));
      }
      if (elL > sfL) {
        issues.add(_ThemeIssue(
            ['elevated'], l10n.themeDesignElevatedDarkerThanSurface));
      }
    }
    return issues;
  }

  // ── Save as new ─────────────────────────────────────────────────

  /// Update the custom theme being edited IN PLACE (same id + name). Only
  /// offered when the base is a custom theme, built-ins are immutable. This is
  /// the "overwrite what I'm editing" path.
  Future<void> _saveInPlace() async {
    if (_baseIsBuiltIn) return;
    final l10n = AppLocalizations.of(context)!;
    if (!ref.read(isProProvider)) {
      PricingModal.show(context);
      return;
    }
    if (_validate(_working, l10n).any((i) => i.blocking)) {
      _showSnack(l10n.themeDesignFixCollisionsBeforeSaving);
      return;
    }
    final scheme = await _persist(_baseId, _baseName);
    if (!mounted) return;
    setState(() {
      _working = scheme;
      _dirty = false;
    });
    _showSnack(l10n.themeDesignSavedNamed(_baseName));
  }

  /// Snapshot the working scheme under a name and select it. A NEW name creates
  /// a theme; a name matching an existing custom OVERWRITES it. Pro-gated: free
  /// users see the upgrade modal.
  Future<void> _saveAsNewTheme() async {
    final l10n = AppLocalizations.of(context)!;
    if (!ref.read(isProProvider)) {
      PricingModal.show(context);
      return;
    }
    if (_validate(_working, l10n).any((i) => i.blocking)) {
      _showSnack(l10n.themeDesignFixCollisionsBeforeSaving);
      return;
    }
    final customs = ref.read(customAppThemesProvider);
    final result = await showZestModal<String>(
      context: context,
      size: ZestModalSize.compact,
      child: _SaveThemeDialog(
        initialName: _suggestName(),
        reservedNames: {...BuiltInThemes.names.values},
        customNames: {for (final t in customs.values) t.name},
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    // A name matching an existing custom overwrites it (reuse its id); a fresh
    // name mints a new one.
    String? overwriteId;
    for (final t in customs.values) {
      if (t.name.toLowerCase() == result.toLowerCase()) {
        overwriteId = t.id;
        break;
      }
    }
    final id =
        overwriteId ?? ref.read(customAppThemesProvider.notifier).nextId();
    final scheme = await _persist(id, result);
    if (!mounted) return;
    setState(() {
      _baseId = id;
      _baseName = result;
      _working = scheme;
      _dirty = false;
    });
    _showSnack(overwriteId != null
        ? l10n.themeDesignUpdatedThemeNamed(result)
        : l10n.themeDesignSavedAndAppliedNamed(result));
  }

  /// Build a [ZestTheme] from the working scheme under [id]/[name], persist it
  /// as a custom theme and apply it (turning off follow-system). Shared by the
  /// in-place Save and the Save-as-new / overwrite paths. Returns the scheme so
  /// the caller can fold it into a single setState.
  Future<ZestColorScheme> _persist(String id, String name) async {
    final scheme = _working.copyWith(
      id: id,
      name: name,
      isDark: _working.background.computeLuminance() < 0.4,
    );
    final theme = ZestTheme(
      id: id,
      name: name,
      brightness: scheme.isDark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
    );
    await ref.read(customAppThemesProvider.notifier).save(theme);
    await ref.read(themeUpdaterProvider).setFollowSystemTheme(false);
    await ref.read(themeSyncCoordinatorProvider).setAppTheme(id);
    return scheme;
  }

  /// Default suggestion for the save-as dialog: "[base] custom", de-duplicated.
  String _suggestName() {
    final taken = <String>{
      ...BuiltInThemes.names.values.map((n) => n.toLowerCase()),
      ...ref
          .read(customAppThemesProvider)
          .values
          .map((t) => t.name.toLowerCase()),
    };
    // From a built-in, suggest "<name> custom"; from a custom, "<name> copy".
    final root = _baseIsBuiltIn ? '$_baseName custom' : '$_baseName copy';
    if (!taken.contains(root.toLowerCase())) return root;
    var i = 2;
    while (taken.contains('$root $i'.toLowerCase())) {
      i++;
    }
    return '$root $i';
  }

  // ── Delete custom ───────────────────────────────────────────────

  Future<void> _deleteCustomTheme(ZestTheme theme) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.themeDesignDeleteThemeTitle(theme.name),
      body: themeDeleteQuestionBody(l10n),
      confirmLabel: l10n.themeDesignDeleteTheme,
    );
    if (confirmed != true || !mounted) return;
    await ref.read(customAppThemesProvider.notifier).delete(theme.id);
    if (!mounted) return;
    // If the deleted theme was live, fall back to the default theme.
    if (ref.read(appThemeIdProvider) == theme.id) {
      await ref.read(themeUpdaterProvider).setAppTheme(kDefaultAppThemeId);
    }
    // If we were editing it, reseed the editor from the default theme.
    if (_baseId == theme.id) {
      final fallback = BuiltInThemes.getById(kDefaultAppThemeId);
      setState(() {
        _baseId = fallback.id;
        _baseName = fallback.name;
        _working = fallback.colorScheme;
        _dirty = false;
      });
    }
  }

  // ── Import / Export ─────────────────────────────────────────────

  /// Import a `.zestheme` app-theme file (the same envelope [_exportTheme]
  /// writes and the Appearance importer accepts), register it and apply it.
  Future<void> _importTheme() async {
    final l10n = AppLocalizations.of(context)!;
    if (!ref.read(isProProvider)) {
      PricingModal.show(context);
      return;
    }
    try {
      // Only the files this reads, as Import scheme beside it: the designer
      // is a computer's alone, whose
      // pickers filter by any file type.
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: l10n.themeDesignImportTheme,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const ['zestheme', 'json'],
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.first;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        _showSnack(l10n.themeDesignCouldNotReadFile);
        return;
      }
      // A theme file is a few KB. Cap the input so a pathological or huge file
      // can't stall the parse on the UI isolate.
      if (bytes.length > 1024 * 1024) {
        _showSnack(l10n.themeDesignFileTooLarge);
        return;
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        _showSnack(l10n.themeDesignNotAZestTheme);
        return;
      }
      if (decoded['type'] != 'app') {
        _showSnack(l10n.themeDesignLooksLikeTerminalTheme);
        return;
      }
      final colors = decoded['colors'];
      if (colors is! Map<String, dynamic>) {
        _showSnack(l10n.themeDesignMissingColours);
        return;
      }
      final parsed = ZestColorScheme.fromJson(colors);
      if (parsed == null) {
        _showSnack(l10n.themeDesignCorruptOrNewer);
        return;
      }
      final id = ref.read(customAppThemesProvider.notifier).nextId();
      // SECURITY: the name is untrusted. Strip control + bidirectional
      // characters (log-injection / RTL-spoofing) before it becomes a UI
      // label, matching the typed-name rules and the imported-settings claim.
      var name = _stripUnsafe((decoded['name'] as String?) ?? '').trim();
      if (name.isEmpty) name = l10n.themeDesignImportedThemeName;
      if (name.length > 32) name = name.substring(0, 32);
      final scheme = parsed.copyWith(id: id, name: name);
      final theme = ZestTheme(
        id: id,
        name: name,
        brightness: scheme.isDark ? Brightness.dark : Brightness.light,
        colorScheme: scheme,
      );
      await ref.read(customAppThemesProvider.notifier).save(theme);
      await ref.read(themeUpdaterProvider).setFollowSystemTheme(false);
      await ref.read(themeSyncCoordinatorProvider).setAppTheme(id);
      if (!mounted) return;
      setState(() {
        _baseId = id;
        _baseName = name;
        _working = scheme;
        _dirty = false;
      });
      _showSnack(l10n.themeDesignImportedAndAppliedNamed(name));
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context, l10n.themeNotImported, isError: true, details: '$e');
    }
  }

  /// Serialize the working colours to a `.zestheme` file. The envelope
  /// round-trips back through [_importTheme] and the Appearance importer.
  Future<void> _exportTheme() async {
    final l10n = AppLocalizations.of(context)!;
    final scheme = _working.copyWith(name: _baseName);
    final export = <String, dynamic>{
      'name': _baseName,
      'type': 'app',
      'app': 'ZestSSH',
      'version': 1,
      'colors': scheme.toJson(),
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(export);
    final safeName =
        _baseName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_').toLowerCase();

    final isMobile = Platform.isAndroid || Platform.isIOS;
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: l10n.themeDesignExportTheme,
        fileName: '$safeName.zestheme',
        bytes: isMobile ? utf8.encode(jsonStr) : null,
      );
      if (path == null) return;
      if (!isMobile) {
        await File(path).writeAsString(jsonStr);
      }
      if (!mounted) return;
      _showSnack(l10n.themeDesignExportedNamed(_baseName));
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context, l10n.appearanceThemeNotExported, isError: true, details: '$e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          width: 360,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DesignerTabs(
          index: _tab,
          onChanged: (i) => setState(() => _tab = i),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              _buildAppTab(context),
              // The terminal palette editor, embedded as the second tab, so
              // there is one designer with two tabs instead of two docks.
              CustomTerminalThemeBuilder(onClose: widget.onClose ?? () {}),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAppTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The active-chip highlight follows the LIVE app theme id, so a selection
    // made from the Appearance dropdown is reflected here too.
    final activeId = ref.watch(appThemeIdProvider);
    final customs = ref.watch(customAppThemesProvider);

    // Live validation of the working scheme. Collisions block Save; the rest
    // are advisory. Build a key->worst-issue map so each row can flag itself.
    final issues = _validate(_working, l10n);
    final hasBlocking = issues.any((i) => i.blocking);
    final rowIssues = <String, _ThemeIssue>{};
    for (final issue in issues) {
      for (final label in issue.labels) {
        final existing = rowIssues[label];
        if (existing == null || (!existing.blocking && issue.blocking)) {
          rowIssues[label] = issue;
        }
      }
    }
    final base = _baseScheme();

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        // Scrollable on its own: the designer is hosted in the right-hand
        // docked panel of desktop Settings, which hands it a BOUNDED height.
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          children: [
            // ── Header ──────────────────────────────────────
            // The docked panel chrome already titles this "Theme Designer",
            // so the body opens straight into the editing badge (one title,
            // not two).
            _EditingBadge(
              name: _baseName,
              isBuiltIn: _baseIsBuiltIn,
              dirty: _dirty,
            ),
            const SizedBox(height: 16),
            _SectionLabel(label: l10n.themeDesignLivePreview),
            const SizedBox(height: 10),
            _ThemePreview(scheme: _working, terminal: _previewTerminal()),
            const SizedBox(height: 16),
            const _ThemeNote(),
            if (issues.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ValidationBanner(issues: issues, hasBlocking: hasBlocking),
            ],
            const SizedBox(height: 8),

            // ── Colour sections ─────────────────────────────
            _group(l10n.themeDesignSectionSurfaces, _surfaceTokens, rowIssues, base),
            _DerivedRow(
              label: l10n.themeDesignDerivedSunken,
              color: _sunkenOf(_working),
              rule: l10n.themeDesignDerivedSunkenRule,
            ),
            _group(l10n.themeDesignSectionText, _textTokens, rowIssues, base),
            _group(l10n.themeDesignSectionBorders, _borderTokens, rowIssues, base),
            _group(l10n.themeDesignSectionAccent, _accentTokens, rowIssues, base),
            _DerivedRow(
              label: l10n.themeDesignDerivedOnAccent,
              color: _onAccentFor(_working.primary),
              rule: l10n.themeDesignDerivedOnAccentRule,
            ),
            _group(l10n.themeDesignSectionStatus, _statusTokens, rowIssues, base),

            // ── Built-in themes ─────────────────────────────
            const SizedBox(height: 28),
            _SectionLabel(label: l10n.themeDesignBuiltInThemes),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in BuiltInThemes.all)
                  _ThemeChip(
                    theme: t,
                    isActive: t.id == activeId,
                    onTap: () => _selectTheme(t),
                  ),
              ],
            ),

            // ── User-saved themes ───────────────────────────
            if (customs.isNotEmpty) ...[
              const SizedBox(height: 24),
              _SectionLabel(label: l10n.themeDesignMyThemes),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in customs.values)
                    _ThemeChip(
                      theme: t,
                      isActive: t.id == activeId,
                      onTap: () => _selectTheme(t),
                      onDelete: () => _deleteCustomTheme(t),
                    ),
                ],
              ),
            ],

            // ── Bottom actions ──────────────────────────────
            const SizedBox(height: 28),
            Divider(height: 1, color: AppColors.v3BorderSubtle),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _BottomActionButton(
                  label: l10n.themeDesignReset,
                  icon: LucideIcons.rotateCcw,
                  onPressed: _reset,
                ),
                _BottomActionButton(
                  label: l10n.themeDesignImportEllipsis,
                  icon: LucideIcons.upload,
                  onPressed: _importTheme,
                ),
                _BottomActionButton(
                  label: l10n.themeDesignExportEllipsis,
                  icon: LucideIcons.download,
                  onPressed: _exportTheme,
                ),
                // Editing a custom theme, offer "Save" (overwrite in place) as
                // the primary action; built-ins can only be saved as a copy.
                if (!_baseIsBuiltIn)
                  _BottomActionButton(
                    label: l10n.save,
                    icon: LucideIcons.save,
                    accent: true,
                    onPressed: _saveInPlace,
                  ),
                _BottomActionButton(
                  label: l10n.themeDesignSaveAsNewTheme,
                  icon: LucideIcons.copy,
                  accent: _baseIsBuiltIn,
                  onPressed: _saveAsNewTheme,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The terminal that would go with the theme in the editor: its pair while
  /// the terminal is matched to the app theme, otherwise the one in use.
  TerminalTheme _previewTerminal() {
    final pair = ref.watch(themesSyncedProvider) ? kAppToTerminalThemeId[_baseId] : null;
    final id = pair ?? ref.watch(shownTerminalThemeIdProvider);
    return TerminalThemes.all[id] ?? TerminalThemes.all[TerminalThemes.defaultId]!;
  }

  Widget _group(
    String label,
    List<_SchemeToken> tokens,
    Map<String, _ThemeIssue> rowIssues,
    ZestColorScheme? base,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        _SectionLabel(label: label),
        const SizedBox(height: 4),
        for (final t in tokens)
          _ColorRow(
            token: t,
            color: t.read(_working),
            issue: rowIssues[t.key],
            onChanged: (hex) => _applyToken(t, hex),
            onReset: (base != null &&
                    t.read(_working).toARGB32() != t.read(base).toARGB32())
                ? () => _resetToken(t)
                : null,
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Designer tab bar (App / Terminal)
// ══════════════════════════════════════════════════════════════════

class _DesignerTabs extends StatelessWidget {
  const _DesignerTabs({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.v3Background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.v3BorderSubtle),
        ),
        child: Row(
          children: [
            _segment(l10n.themeDesignTabApp, 0),
            _segment(l10n.themeDesignTabTerminal, 1),
          ],
        ),
      ),
    );
  }

  Widget _segment(String label, int i) {
    final active = index == i;
    return Expanded(
      // The hand, as everything clickable shows it (without it the switch
      // looked like a label).
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('theme-designer-tab-$i'),
          onTap: () => onChanged(i),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? AppColors.v3Surface : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border:
                  active ? Border.all(color: AppColors.v3BorderSubtle) : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                color: active
                    ? AppColors.v3AccentInk
                    : AppColors.v3TextSecondary,
                fontSize: 13,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Section label (shared style: 2px accent tick + rule)
// ══════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 2,
          height: 11,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.v3AccentPrimary,
                AppColors.v3AccentPrimary.withValues(alpha: 0.55),
              ],
            ),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: AppColors.v3TextTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: AppColors.v3BorderSubtle)),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// "Editing: <name>" badge
// ══════════════════════════════════════════════════════════════════

class _EditingBadge extends StatelessWidget {
  const _EditingBadge({
    required this.name,
    required this.isBuiltIn,
    required this.dirty,
  });

  final String name;
  final bool isBuiltIn;
  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (before, after) = aroundValue(l10n.themeDesignEditingName(aroundValueMarker));
    return Row(
      children: [
        if (before.isNotEmpty)
          Text(
            before,
            style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 13),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.v3Surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Text(
            name,
            style: TextStyle(
              color: AppColors.v3TextPrimary,
              fontSize: 12,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ),
        if (after.isNotEmpty)
          Text(
            after,
            style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 13),
          ),
        const SizedBox(width: 8),
        Text(
          isBuiltIn ? l10n.themeDesignBuiltInLower : l10n.themeDesignCustomLower,
          style: TextStyle(color: AppColors.v3TextTertiary, fontSize: 12),
        ),
        if (dirty) ...[
          const SizedBox(width: 12),
          Icon(LucideIcons.pencil, size: 11, color: AppColors.v3AccentInk),
          const SizedBox(width: 5),
          Text(
            l10n.themeDesignUnsavedEdits,
            style: TextStyle(color: AppColors.v3AccentInk, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// "Terminal colours are separate" note
// ══════════════════════════════════════════════════════════════════

class _ThemeNote extends StatelessWidget {
  const _ThemeNote();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.info, size: 13, color: AppColors.v3TextTertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l10n.themeDesignChromeNote,
            style: TextStyle(color: AppColors.v3TextTertiary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Validation banner
// ══════════════════════════════════════════════════════════════════

class _ValidationBanner extends StatelessWidget {
  const _ValidationBanner({required this.issues, required this.hasBlocking});

  final List<_ThemeIssue> issues;
  final bool hasBlocking;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = hasBlocking ? AppColors.v3Error : AppColors.v3Warning;
    final blockingCount = issues.where((i) => i.blocking).length;
    final warnCount = issues.length - blockingCount;
    final headline = hasBlocking
        ? l10n.themeDesignCollisionCount(blockingCount)
        : l10n.themeDesignWarningCount(warnCount);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasBlocking
                    ? LucideIcons.alertCircle
                    : LucideIcons.alertTriangle,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 8),
              Text(
                headline,
                style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 4),
              child: Text(
                '• ${issue.message}',
                style: TextStyle(
                  color: AppColors.v3TextSecondary,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Live preview - the app's window, small, in the working scheme's colours
// ══════════════════════════════════════════════════════════════════

/// The window a theme makes: its title bar with tabs, the side rail, a session
/// with the terminal that goes with the theme, and the status bar. Every colour
/// that can be edited here shows, where the app uses it. (It was a card and a
/// search box that stood for nothing in the
/// app.)
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.scheme, required this.terminal});

  final ZestColorScheme scheme;

  /// The terminal colours that go with this app theme.
  final TerminalTheme terminal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = scheme;
    return Container(
      key: const ValueKey('theme-preview'),
      height: 268,
      decoration: BoxDecoration(
        color: cs.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: DefaultTextStyle(
        style: TextStyle(fontFamily: 'GeistSans', fontSize: 11, color: cs.onSurface),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleBar(l10n),
            Container(height: 1, color: cs.divider),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _rail(l10n),
                  Container(width: 1, color: cs.divider),
                  Expanded(child: _session(l10n)),
                ],
              ),
            ),
            Container(height: 1, color: cs.divider),
            _statusBar(l10n),
          ],
        ),
      ),
    );
  }

  /// The space, two session tabs (the one in front marked in the accent) and
  /// the search, as the top of the window has them.
  Widget _titleBar(AppLocalizations l10n) {
    final cs = scheme;
    return SizedBox(
      height: 34,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cs.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.user, size: 11, color: cs.primary),
                  const SizedBox(width: 5),
                  Text(l10n.treeSelectorPersonal, style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _tab('web-01', active: true, dot: cs.success),
            const SizedBox(width: 4),
            _tab('db-primary', dot: cs.warning),
            const Spacer(),
            Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(6)),
              child: Text(
                l10n.hostsNewHost,
                style: TextStyle(color: cs.onPrimary, fontSize: 10.5, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              height: 22,
              width: 92,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(
                color: _sunkenOf(cs),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cs.border),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.search, size: 10, color: cs.onBackgroundSubtle),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      l10n.commonSearch,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onBackgroundSubtle, fontSize: 10.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab(String name, {bool active = false, required Color dot}) {
    final cs = scheme;
    return Container(
      height: 22,
      padding: const EdgeInsets.only(left: 2, right: 8),
      decoration: BoxDecoration(
        color: active ? cs.surfaceElevated : cs.surface,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: active ? cs.primary : cs.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 2, height: 14, color: active ? cs.primary : cs.divider),
          const SizedBox(width: 6),
          _dot(dot),
          const SizedBox(width: 5),
          Text(name, style: TextStyle(color: active ? cs.onSurface : cs.onSurfaceMuted, fontSize: 10.5)),
        ],
      ),
    );
  }

  /// The side rail: where you are in the accent, the rest in the quieter text.
  Widget _rail(AppLocalizations l10n) {
    final cs = scheme;
    Widget row(IconData icon, String name, {bool active = false}) => Container(
          height: 24,
          margin: const EdgeInsets.only(bottom: 3),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: active ? cs.primary.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(icon, size: 12, color: active ? cs.primary : cs.onSurfaceMuted),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? cs.primary : cs.onSurfaceMuted,
                  ),
                ),
              ),
            ],
          ),
        );
    return SizedBox(
      width: 118,
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(LucideIcons.server, l10n.narrowSidebarHosts, active: true),
            row(LucideIcons.key, l10n.narrowSidebarKeys),
            row(LucideIcons.braces, l10n.narrowSidebarSnippets),
            row(LucideIcons.bellRing, l10n.narrowSidebarTriggers),
            row(LucideIcons.history, l10n.narrowSidebarHistory),
          ],
        ),
      ),
    );
  }

  /// A session: its head with the state and a button in the accent, and the
  /// terminal in the colours that go with the theme.
  Widget _session(AppLocalizations l10n) {
    final cs = scheme;
    final t = terminal;
    TextSpan span(String text, Color color) => TextSpan(text: text, style: TextStyle(color: color));
    final prompt = <InlineSpan>[
      span('deploy@web-01', t.green),
      span(':', t.foreground),
      span('~', t.blue),
      span(r'$ ', t.foreground),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 30,
          color: cs.surface,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Text('web-01', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    _dot(cs.success),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        l10n.sessionInfoStatusConnected,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cs.onSurfaceMuted, fontSize: 10.5),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), border: Border.all(color: cs.border)),
                child: Text(l10n.pillSftp, style: TextStyle(color: cs.onSurfaceMuted, fontSize: 10.5)),
              ),
            ],
          ),
        ),
        Container(height: 1, color: cs.divider),
        Expanded(
          child: Container(
            key: const ValueKey('theme-preview-terminal'),
            color: t.background,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: DefaultTextStyle(
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, height: 1.45, color: t.foreground),
              maxLines: 1,
              overflow: TextOverflow.clip,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(TextSpan(children: [...prompt, span('ls', t.foreground)])),
                  Text.rich(TextSpan(children: [
                    span('app/  ', t.blue),
                    span('deploy.sh  ', t.green),
                    span('notes.txt  ', t.foreground),
                    span('logs -> /var/log', t.cyan),
                  ])),
                  Text.rich(TextSpan(children: [...prompt, span('git status -s', t.foreground)])),
                  Text.rich(TextSpan(children: [
                    span(' M ', t.yellow),
                    span('src/app.dart  ', t.foreground),
                    span('D ', t.red),
                    span('old.conf  ', t.foreground),
                    span('?? ', t.magenta),
                    span('todo', t.foreground),
                  ])),
                  Text.rich(TextSpan(children: [
                    ...prompt,
                    TextSpan(
                      text: 'tail -f app.log',
                      style: TextStyle(color: t.foreground, backgroundColor: t.selection),
                    ),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Container(width: 6, height: 12, color: t.cursor),
                    ),
                  ])),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The status bar, in the quietest text.
  Widget _statusBar(AppLocalizations l10n) {
    final cs = scheme;
    return SizedBox(
      height: 22,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.desktopStatusActiveSessions(2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onBackgroundSubtle, fontSize: 10),
              ),
            ),
            _dot(cs.error),
            const SizedBox(width: 4),
            _dot(cs.warning),
            const SizedBox(width: 4),
            _dot(cs.success),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );
}

// ══════════════════════════════════════════════════════════════════
// Color Row
// ══════════════════════════════════════════════════════════════════

class _ColorRow extends StatefulWidget {
  const _ColorRow({
    required this.token,
    required this.color,
    required this.onChanged,
    this.issue,
    this.onReset,
  });

  final _SchemeToken token;
  final Color color;
  final ValueChanged<String> onChanged;

  /// Validation finding for this row, if any (collision or warning).
  final _ThemeIssue? issue;

  /// Non-null when this token differs from the base theme, revert on tap.
  final VoidCallback? onReset;

  @override
  State<_ColorRow> createState() => _ColorRowState();
}

class _ColorRowState extends State<_ColorRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hex = _colorToHex(widget.color);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _showHexEditDialog(context, hex),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.v3Surface : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              // Label
              SizedBox(
                width: 130,
                child: Text(
                  widget.token.label(l10n),
                  style: TextStyle(
                    color: AppColors.v3TextPrimary,
                    fontSize: 14,
                  ),
                ),
              ),
              // Color swatch
              _ColorSwatch(color: widget.color),
              const SizedBox(width: 10),
              // Hex value
              SizedBox(
                width: 80,
                child: Text(
                  hex,
                  style: TextStyle(
                    color: AppColors.v3TextSecondary,
                    fontSize: 12,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Description
              Expanded(
                child: Text(
                  widget.token.description(l10n),
                  style: TextStyle(
                    color: AppColors.v3TextTertiary,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Validation badge (collision = error, else warning)
              if (widget.issue != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: widget.issue!.message,
                  child: Icon(
                    widget.issue!.blocking
                        ? LucideIcons.alertCircle
                        : LucideIcons.alertTriangle,
                    size: 14,
                    color: widget.issue!.blocking
                        ? AppColors.v3Error
                        : AppColors.v3Warning,
                  ),
                ),
              ],
              // Per-row reset on hover (only when changed from the base theme)
              if (_hovered && widget.onReset != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: l10n.themeDesignResetColour,
                  child: GestureDetector(
                    onTap: widget.onReset,
                    child: Icon(LucideIcons.rotateCcw,
                        size: 13, color: AppColors.v3TextTertiary),
                  ),
                ),
              ],
              // Edit icon on hover
              if (_hovered) ...[
                const SizedBox(width: 4),
                Icon(LucideIcons.pencil,
                    size: 14, color: AppColors.v3TextTertiary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showHexEditDialog(BuildContext context, String hex) {
    final l10n = AppLocalizations.of(context)!;
    showZestModal<String>(
      context: context,
      size: ZestModalSize.compact,
      child: _HexEditDialog(
        label: widget.token.label(l10n),
        initialHex: hex,
      ),
    ).then((result) {
      if (result != null) {
        widget.onChanged(result);
      }
    });
  }
}

// ══════════════════════════════════════════════════════════════════
// Derived (read-only) row - a computed token shown with its rule
// ══════════════════════════════════════════════════════════════════

class _DerivedRow extends StatelessWidget {
  const _DerivedRow({
    required this.label,
    required this.color,
    required this.rule,
  });

  final String label;
  final Color color;
  final String rule;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Opacity(
      opacity: 0.72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 130,
              child: Text(
                label,
                style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 14),
              ),
            ),
            _ColorSwatch(color: color),
            const SizedBox(width: 10),
            SizedBox(
              width: 80,
              child: Text(
                _colorToHex(color),
                style: TextStyle(
                  color: AppColors.v3TextTertiary,
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                rule,
                style: TextStyle(color: AppColors.v3TextTertiary, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Tooltip(
              message: l10n.themeDesignDerivedTooltip,
              child: Icon(LucideIcons.lock,
                  size: 12, color: AppColors.v3TextTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Color swatch circle
// ══════════════════════════════════════════════════════════════════

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.v3BorderDefault,
          width: 1,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Hex edit dialog
// ══════════════════════════════════════════════════════════════════

class _HexEditDialog extends StatefulWidget {
  const _HexEditDialog({
    required this.label,
    required this.initialHex,
  });

  final String label;
  final String initialHex;

  @override
  State<_HexEditDialog> createState() => _HexEditDialogState();
}

class _HexEditDialogState extends State<_HexEditDialog> {
  late final TextEditingController _hexController;
  String? _errorText;

  // ── HSV state ──────────────────────────────────────────────────
  // We drive the SV square + hue slider off these so dragging
  // either control updates the preview / hex field continuously.
  late HSVColor _hsv;

  // SV-square + hue-slider sizing.  The SV square is a 2D plane
  // - saturation on X, value on Y (inverted: top = bright).  The
  // hue slider runs the rainbow horizontally below.
  static const double _svWidth = 320;
  static const double _svHeight = 200;
  static const double _hueHeight = 18;

  @override
  void initState() {
    super.initState();
    _hexController = TextEditingController(text: widget.initialHex);
    _hsv = HSVColor.fromColor(_hexToColor(widget.initialHex));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  bool _isValidHex(String value) {
    final hex = value.startsWith('#') ? value.substring(1) : value;
    if (hex.length != 6) return false;
    return RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(hex);
  }

  String _normalizeHex(String value) {
    var hex = value.trim();
    if (!hex.startsWith('#')) hex = '#$hex';
    return hex.toUpperCase();
  }

  /// Currently-selected color, recomputed from HSV every build.
  Color get _color => _hsv.toColor();

  /// Hex string (#RRGGBB) for the current HSV value - used as the
  /// authoritative output.
  String get _currentHex {
    final c = _color;
    return '#${c.r.toInt().toRadixString(16).padLeft(2, '0')}'
        '${c.g.toInt().toRadixString(16).padLeft(2, '0')}'
        '${c.b.toInt().toRadixString(16).padLeft(2, '0')}'.toUpperCase();
  }

  void _setHsv(HSVColor v, {bool syncHexField = true}) {
    setState(() {
      _hsv = v;
      _errorText = null;
      if (syncHexField) {
        _hexController.text = _currentHex;
      }
    });
  }

  void _onSvPan(Offset localPos) {
    final s = (localPos.dx / _svWidth).clamp(0.0, 1.0);
    final v = 1 - (localPos.dy / _svHeight).clamp(0.0, 1.0);
    _setHsv(_hsv.withSaturation(s).withValue(v));
  }

  void _onHuePan(double localX) {
    final h = (localX / _svWidth).clamp(0.0, 1.0) * 360;
    _setHsv(_hsv.withHue(h));
  }

  void _onHexChanged(String raw) {
    if (_isValidHex(raw)) {
      // User typed a valid hex - sync the HSV state without clobbering
      // their typed text.
      _setHsv(HSVColor.fromColor(_hexToColor(raw)), syncHexField: false);
    } else {
      // Just clear the error chip if they're mid-edit.
      if (_errorText != null) setState(() => _errorText = null);
    }
  }

  void _apply() {
    final raw = _hexController.text.trim();
    if (_isValidHex(raw)) {
      Navigator.of(context).pop(_normalizeHex(raw));
    } else {
      final l10n = AppLocalizations.of(context)!;
      setState(() => _errorText = l10n.themeDesignInvalidHex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pureHue =
        HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();

    // The app's dialog (3.4): its title the header's, Cancel and Apply in the
    // footer.
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.pipette,
      title: l10n.themeDesignEditLabel(widget.label),
      maxWidth: _svWidth + 44 + 8,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── 2D saturation × value square ────────────────────
          GestureDetector(
            onPanStart: (d) => _onSvPan(d.localPosition),
            onPanUpdate: (d) => _onSvPan(d.localPosition),
            onTapDown: (d) => _onSvPan(d.localPosition),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: _svWidth,
                height: _svHeight,
                child: Stack(
                  children: [
                    // Hue → white horizontal gradient
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Colors.white, pureHue],
                        ),
                      ),
                    ),
                    // Black bottom overlay (value)
                    Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                    // Marker
                    Positioned(
                      left: _hsv.saturation * _svWidth - 8,
                      top: (1 - _hsv.value) * _svHeight - 8,
                      child: IgnorePointer(
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 3,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ── Hue slider (rainbow strip) ──────────────────────
          GestureDetector(
            onPanStart: (d) => _onHuePan(d.localPosition.dx),
            onPanUpdate: (d) => _onHuePan(d.localPosition.dx),
            onTapDown: (d) => _onHuePan(d.localPosition.dx),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_hueHeight / 2),
              child: SizedBox(
                width: _svWidth,
                height: _hueHeight,
                child: Stack(
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0xFFFF0000), // 0°  red
                            Color(0xFFFFFF00), // 60° yellow
                            Color(0xFF00FF00), // 120° green
                            Color(0xFF00FFFF), // 180° cyan
                            Color(0xFF0000FF), // 240° blue
                            Color(0xFFFF00FF), // 300° magenta
                            Color(0xFFFF0000), // 360° red
                          ],
                        ),
                      ),
                      child: SizedBox.expand(),
                    ),
                    // Marker
                    Positioned(
                      left: (_hsv.hue / 360) * _svWidth - 6,
                      top: -1,
                      child: IgnorePointer(
                        child: Container(
                          width: 12,
                          height: _hueHeight + 2,
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            border: Border.all(
                                color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 3,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Hex input + live swatch ─────────────────────────
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hexController,
                  style: TextStyle(
                    color: AppColors.v3TextPrimary,
                    fontSize: 14,
                    fontFamily: 'JetBrainsMono',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                        RegExp(r'[#0-9A-Fa-f]')),
                    LengthLimitingTextInputFormatter(7),
                  ],
                  decoration: InputDecoration(
                    prefixText: '# ',
                    prefixStyle: TextStyle(
                      color: AppColors.v3TextSecondary,
                      fontFamily: 'JetBrainsMono',
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 12),
                    filled: true,
                    fillColor: AppColors.v3Surface,
                    errorText: _errorText,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(
                          color: AppColors.v3BorderDefault),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(
                          color: AppColors.v3BorderDefault),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(
                          color: AppColors.v3AccentPrimary),
                    ),
                  ),
                  onChanged: _onHexChanged,
                  onSubmitted: (_) => _apply(),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _color,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: AppColors.v3BorderDefault, width: 1),
                ),
              ),
            ],
          ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      primaryKey: const ValueKey('theme-hex-apply'),
      primaryAction: (label: l10n.themeDesignApply, icon: null, onPressed: _apply),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Theme chip (built-in + custom selector)
// ══════════════════════════════════════════════════════════════════

class _ThemeChip extends StatefulWidget {
  const _ThemeChip({
    required this.theme,
    required this.isActive,
    required this.onTap,
    this.onDelete,
  });

  final ZestTheme theme;
  final bool isActive;
  final VoidCallback onTap;

  /// When non-null, an X appears on hover (custom themes only).
  final VoidCallback? onDelete;

  @override
  State<_ThemeChip> createState() => _ThemeChipState();
}

class _ThemeChipState extends State<_ThemeChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = widget.theme.colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.v3Surface : AppColors.v3Background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.isActive
                  ? AppColors.v3AccentPrimary
                  : AppColors.v3BorderSubtle,
              width: widget.isActive ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Mini colour preview: background / surface / accent
              Container(
                width: 32,
                height: 18,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                      color: AppColors.v3BorderDefault, width: 0.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2.5),
                  child: Row(
                    children: [
                      Expanded(child: Container(color: cs.background)),
                      Expanded(child: Container(color: cs.surface)),
                      Expanded(child: Container(color: cs.primary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.theme.name,
                style: TextStyle(
                  color: widget.isActive
                      ? AppColors.v3AccentInk
                      : AppColors.v3TextPrimary,
                  fontSize: 13,
                  fontWeight:
                      widget.isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (widget.isActive) ...[
                const SizedBox(width: 6),
                Icon(LucideIcons.check,
                    size: 14, color: AppColors.v3AccentInk),
              ],
              // Always-visible delete affordance on custom chips (built-ins
              // pass no onDelete), so removing a saved theme is discoverable
              // rather than hover-only.
              if (widget.onDelete != null) ...[
                const SizedBox(width: 7),
                Tooltip(message: AppLocalizations.of(context)!.delete, child: GestureDetector(
                  onTap: widget.onDelete,
                  behavior: HitTestBehavior.opaque,
                  child: Icon(LucideIcons.x,
                      size: 13,
                      color: _hovered
                          ? AppColors.v3TextSecondary
                          : AppColors.v3TextTertiary),
                )),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Bottom action buttons
// ══════════════════════════════════════════════════════════════════

class _BottomActionButton extends StatefulWidget {
  const _BottomActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.accent = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool accent;

  @override
  State<_BottomActionButton> createState() => _BottomActionButtonState();
}

class _BottomActionButtonState extends State<_BottomActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final textColor =
        widget.accent ? AppColors.v3AccentInk : AppColors.v3TextPrimary;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered
                ? (widget.accent
                    ? AppColors.v3AccentPrimary.withValues(alpha: 0.12)
                    : AppColors.v3Surface)
                : AppColors.v3Background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: widget.accent
                  ? AppColors.v3AccentPrimary.withValues(alpha: 0.4)
                  : AppColors.v3BorderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: textColor),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Save Theme Dialog
// ══════════════════════════════════════════════════════════════════

class _SaveThemeDialog extends StatefulWidget {
  const _SaveThemeDialog({
    required this.initialName,
    required this.reservedNames,
    required this.customNames,
  });

  /// Pre-populated text field value.
  final String initialName;

  /// Built-in theme names - reusing one is blocked with an inline error.
  final Set<String> reservedNames;

  /// Existing custom theme names - reusing one OVERWRITES that theme.
  final Set<String> customNames;

  @override
  State<_SaveThemeDialog> createState() => _SaveThemeDialogState();
}

class _SaveThemeDialogState extends State<_SaveThemeDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName)
      ..selection =
          TextSelection(baseOffset: 0, extentOffset: widget.initialName.length);
    // Rebuild on every keystroke so the button label / subtitle tracks whether
    // the name is new or an overwrite, and a stale error clears as you type.
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {
        if (_errorText != null) _errorText = null;
      });

  bool get _isReserved {
    final lower = _controller.text.trim().toLowerCase();
    return widget.reservedNames.any((n) => n.toLowerCase() == lower);
  }

  /// The existing custom name (original casing) this would overwrite, else null.
  String? get _overwriteTarget {
    final lower = _controller.text.trim().toLowerCase();
    for (final n in widget.customNames) {
      if (n.toLowerCase() == lower) return n;
    }
    return null;
  }

  void _apply() {
    final l10n = AppLocalizations.of(context)!;
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorText = l10n.themeDesignNameEmpty);
      return;
    }
    if (raw.length > 32) {
      setState(() => _errorText = l10n.themeDesignNameTooLong);
      return;
    }
    // SECURITY: theme names land in a JSON-encoded SharedPreferences map AND
    // get used as section labels in the UI. Restricting to letters / digits /
    // spaces / dashes / underscores rules out JSON-key collisions
    // (`__proto__`), line-break log injection, and control-char rendering.
    if (!RegExp(r'^[A-Za-z0-9 _\-]{1,32}$').hasMatch(raw)) {
      setState(() => _errorText = l10n.themeDesignNameInvalidChars);
      return;
    }
    // A built-in name is reserved; a custom-name match is allowed and treated
    // as an overwrite by the caller.
    if (_isReserved) {
      setState(() => _errorText = l10n.themeDesignNameReserved(raw));
      return;
    }
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final overwrite = _overwriteTarget;
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.palette,
      title: l10n.themeDesignSaveTheme,
      subtitle: overwrite != null
          ? l10n.themeDesignOverwriteSubtitle(overwrite)
          : l10n.themeDesignSaveNewSubtitle,
      maxWidth: 460,
      maxHeight: 380,
      secondaryAction: (
        label: l10n.cancel,
        onPressed: () => Navigator.of(context).pop(),
      ),
      primaryAction: (
        label: overwrite != null ? l10n.themeDesignOverwrite : l10n.themeDesignSaveTheme,
        icon: overwrite != null ? LucideIcons.save : LucideIcons.check,
        onPressed: _apply,
      ),
      body: ZestTextField(
        controller: _controller,
        label: l10n.themeDesignThemeName,
        hintText: l10n.themeDesignThemeNameHint,
        onSubmit: _apply,
        maxLength: 32,
        errorText: _errorText,
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Utilities
// ══════════════════════════════════════════════════════════════════

/// Parse a hex string like '#FF7A1A' or 'FF7A1A' into a [Color].
/// Strip control and bidirectional characters from an untrusted theme name so
/// an imported name cannot spoof or inject when shown as a UI label.
String _stripUnsafe(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r < 0x20 ||
        r == 0x7F ||
        (r >= 0x202A && r <= 0x202E) ||
        (r >= 0x2066 && r <= 0x2069)) {
      continue;
    }
    buf.writeCharCode(r);
  }
  return buf.toString();
}

Color _hexToColor(String hex) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) {
    final value = int.tryParse(h, radix: 16);
    if (value != null) return Color(0xFF000000 | value);
  }
  return Colors.grey;
}

/// Format a [Color] as a `#RRGGBB` hex string (alpha dropped).
String _colorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
