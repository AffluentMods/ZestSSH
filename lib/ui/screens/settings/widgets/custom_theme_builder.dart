import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_scheme_import.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/number_text.dart';

/// Whether we are running on a desktop OS.
bool get _isDesktop => isDesktopPlatform;

/// Opens the custom theme builder. Uses a full screen route on mobile
/// and a large dialog on desktop.
///
/// [existingId] / [existingTheme] / [existingName] are provided when editing.
Future<void> showCustomThemeBuilder(
  BuildContext context,
  WidgetRef ref, {
  String? existingId,
  TerminalTheme? existingTheme,
  String? existingName,
}) async {
  if (_isDesktop) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _CustomThemeBuilder(
              existingId: existingId,
              existingTheme: existingTheme,
              existingName: existingName,
            ),
          ),
        ),
      ),
    );
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _CustomThemeBuilder(
          existingId: existingId,
          existingTheme: existingTheme,
          existingName: existingName,
        ),
      ),
    );
  }
}

// ── Ordered list of colour keys for the editor ────────────────────

const _coreColorKeys = ['background', 'foreground', 'cursor', 'selection'];

const _ansiColorKeys = [
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
];

const _brightColorKeys = [
  'brightBlack',
  'brightRed',
  'brightGreen',
  'brightYellow',
  'brightBlue',
  'brightMagenta',
  'brightCyan',
  'brightWhite',
];

/// Keys whose colour is drawn as *text over the background* and therefore
/// needs a readability (contrast) check: the foreground plus every ANSI /
/// bright slot. Background / cursor / selection are chrome, not glyph ink,
/// so they are excluded.
const _contrastCheckedKeys = [
  'foreground',
  ..._ansiColorKeys,
  ..._brightColorKeys,
];

/// WCAG contrast-ratio cutoff below which a slot is flagged "low contrast".
///
/// 3.0 : 1 is the WCAG 2.x minimum for large text / UI components. It is
/// deliberately looser than the 4.5 : 1 body-text bar: terminal palettes
/// legitimately include a near-background "black" slot and muted greys, and
/// this is a WARNING (never a block), so a 3:1 floor flags genuinely
/// unreadable ink without drowning the user in noise.
const double _kContrastWarnThreshold = 3.0;

/// The hue (in degrees, 0-360) a named ANSI slot is *expected* to sit near.
/// Greys (black/white and their bright variants) have no meaningful hue and
/// are intentionally absent.
const Map<String, double> _expectedHues = {
  'red': 0,
  'green': 120,
  'yellow': 60,
  'blue': 240,
  'magenta': 300,
  'cyan': 180,
  'brightRed': 0,
  'brightGreen': 120,
  'brightYellow': 60,
  'brightBlue': 240,
  'brightMagenta': 300,
  'brightCyan': 180,
};

/// Degrees of hue drift tolerated before a slot is hinted as mis-named. Kept
/// wide (60°) so none of the built-in palettes false-positive (Gruvbox's
/// green-ish cyan is the closest, at ~57°).
const double _kHueMismatchThreshold = 60;

/// WCAG relative luminance of [c] (0 = black, 1 = white), from the sRGB
/// linearised channels. Alpha is ignored - terminal ink is opaque.
double _relativeLuminance(Color c) {
  final argb = c.toARGB32();
  double lin(int channel) {
    final v = channel / 255.0;
    return v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = lin((argb >> 16) & 0xFF);
  final g = lin((argb >> 8) & 0xFF);
  final b = lin(argb & 0xFF);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio between two colours (1.0 = identical, 21.0 = black on
/// white).
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Whether [color] is far enough from the hue its slot [key] is named for to
/// be worth a subtle "doesn't look like X" hint. Returns false for slots with
/// no expected hue, and for colours too grey/dark for a hue to be meaningful.
bool _hueLooksWrong(String key, Color color) {
  final expected = _expectedHues[key];
  if (expected == null) return false;
  final hsv = HSVColor.fromColor(color);
  // A near-grey or very dark colour has no reliable hue - don't cry wolf.
  if (hsv.saturation < 0.25 || hsv.value < 0.20) return false;
  var diff = (hsv.hue - expected).abs() % 360;
  if (diff > 180) diff = 360 - diff;
  return diff > _kHueMismatchThreshold;
}

// ─────────────────────────────────────────────────────────────────

/// Embeddable (docked) custom terminal-theme builder for the desktop Settings
/// right-hand pane.
///
/// Renders the same editor as [showCustomThemeBuilder] but WITHOUT the
/// Scaffold / AppBar / route chrome - it is meant to sit inside the docked
/// [ListEditorSplit] panel. Reports completion (save/cancel) through
/// [onClose] instead of `Navigator.pop`, mirroring how `SnippetEditor`'s
/// inline mode works.
class CustomTerminalThemeBuilder extends StatelessWidget {
  final String? existingId;
  final TerminalTheme? existingTheme;
  final String? existingName;

  /// Called when the editor is done (after a successful save) or cancelled.
  final VoidCallback onClose;

  const CustomTerminalThemeBuilder({
    super.key,
    this.existingId,
    this.existingTheme,
    this.existingName,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return _CustomThemeBuilder(
      existingId: existingId,
      existingTheme: existingTheme,
      existingName: existingName,
      onClose: onClose,
    );
  }
}

class _CustomThemeBuilder extends ConsumerStatefulWidget {
  final String? existingId;
  final TerminalTheme? existingTheme;
  final String? existingName;

  /// Inline/docked mode: when non-null the editor drops its Scaffold + AppBar
  /// chrome and reports completion through this callback instead of
  /// `Navigator.pop`. Null = the classic dialog / full-screen-route flow.
  final VoidCallback? onClose;

  const _CustomThemeBuilder({
    this.existingId,
    this.existingTheme,
    this.existingName,
    this.onClose,
  });

  bool get _embedded => onClose != null;

  @override
  ConsumerState<_CustomThemeBuilder> createState() =>
      _CustomThemeBuilderState();
}

class _CustomThemeBuilderState extends ConsumerState<_CustomThemeBuilder> {
  late final TextEditingController _nameController;
  late Map<String, Color> _colors;
  String? _selectedColorKey;

  /// Inline validation message for the name field. Null = valid. Rendered
  /// directly under the field (never a corner toast), and re-evaluated live
  /// against the controller's current text via [_onNameChanged].
  String? _nameError;

  /// Default colour map based on the Dark built-in theme.
  static Map<String, Color> get _defaultColors =>
      app_themes.TerminalThemes.colorMapFromTheme(
        app_themes.TerminalThemes.builtIn[app_themes.TerminalThemes.defaultDark]!,
      );

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.existingName ?? '',
    );
    // Drive both the live preview title and inline-error clearing from the
    // controller so every keystroke is reflected immediately.
    _nameController.addListener(_onNameChanged);

    if (widget.existingTheme != null) {
      _colors = app_themes.TerminalThemes.colorMapFromTheme(widget.existingTheme!);
    } else {
      _colors = _defaultColors;
    }
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    super.dispose();
  }

  /// Rebuild on every name keystroke (keeps the preview title live) and clear
  /// a stale "name required" error the moment the field is non-empty again.
  void _onNameChanged() {
    final clear = _nameError != null && _nameController.text.trim().isNotEmpty;
    setState(() {
      if (clear) _nameError = null;
    });
  }

  /// Localised human label for a colour key (e.g. `brightRed` → "Bright Red").
  String _colorLabel(AppLocalizations l10n, String key) {
    switch (key) {
      case 'background':
        return l10n.themeBuilderColorBackground;
      case 'foreground':
        return l10n.themeBuilderColorForeground;
      case 'cursor':
        return l10n.themeBuilderColorCursor;
      case 'selection':
        return l10n.themeBuilderColorSelection;
      case 'black':
        return l10n.themeBuilderColorBlack;
      case 'red':
        return l10n.themeBuilderColorRed;
      case 'green':
        return l10n.themeBuilderColorGreen;
      case 'yellow':
        return l10n.themeBuilderColorYellow;
      case 'blue':
        return l10n.themeBuilderColorBlue;
      case 'magenta':
        return l10n.themeBuilderColorMagenta;
      case 'cyan':
        return l10n.themeBuilderColorCyan;
      case 'white':
        return l10n.themeBuilderColorWhite;
      case 'brightBlack':
        return l10n.themeBuilderColorBrightBlack;
      case 'brightRed':
        return l10n.themeBuilderColorBrightRed;
      case 'brightGreen':
        return l10n.themeBuilderColorBrightGreen;
      case 'brightYellow':
        return l10n.themeBuilderColorBrightYellow;
      case 'brightBlue':
        return l10n.themeBuilderColorBrightBlue;
      case 'brightMagenta':
        return l10n.themeBuilderColorBrightMagenta;
      case 'brightCyan':
        return l10n.themeBuilderColorBrightCyan;
      case 'brightWhite':
        return l10n.themeBuilderColorBrightWhite;
      default:
        return key;
    }
  }

  /// Number of contrast-checked slots currently below the readability floor.
  int get _lowContrastCount {
    final bg = _colors['background']!;
    var count = 0;
    for (final key in _contrastCheckedKeys) {
      if (_contrastRatio(_colors[key]!, bg) < _kContrastWarnThreshold) count++;
    }
    return count;
  }

  TerminalTheme get _previewTheme => app_themes.TerminalThemes.themeFromColorMap(_colors);

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    // Validate the LIVE controller value, not a captured snapshot, so the
    // message always matches what's actually in the field.
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = l10n.themeBuilderNameRequired);
      return;
    }
    if (_nameError != null) {
      setState(() => _nameError = null);
    }

    final prefs = ref.read(sharedPreferencesProvider);
    final theme = _previewTheme;

    final savedId = await app_themes.TerminalThemes.saveCustomTheme(
      prefs: prefs,
      name: name,
      theme: theme,
      id: widget.existingId,
    );

    // Apply the theme immediately.
    if (mounted) {
      ref.read(settingsUpdaterProvider).setTerminalTheme(savedId);
      if (widget._embedded) {
        widget.onClose!();
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  /// Reset a single slot back to its value in the default (Dark) theme.
  void _resetSlot(String key) {
    final def = _defaultColors[key];
    if (def == null) return;
    setState(() => _colors[key] = def);
  }

  /// Reset the entire colour map to the default theme, after confirmation.
  Future<void> _resetAll() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      // An ordinary question inside the editor: nothing amber (3.4).
      tone: ZestDialogTone.neutral,
      title: l10n.themeBuilderResetAllTitle,
      body: l10n.themeBuilderResetAllBody,
      confirmLabel: l10n.themeBuilderResetAllConfirm,
      cancelLabel: l10n.cancel,
    );
    if (ok == true) {
      setState(() => _colors = _defaultColors);
    }
  }

  /// Import an ANSI palette from an iTerm2 / Windows Terminal / xrdb file into
  /// the live colour map (updates the preview immediately; Save persists it).
  ///
  /// The picker shows only those files on a computer.
  /// A phone's picker filters by a file type the system
  /// knows, and no system knows .itermcolors or .xrdb: there a filter would
  /// hide the very files this reads, so it shows every file. With [everyFile]
  /// (Any file, beside it) a computer's does too: a scheme can be in a file
  /// named `colors` or `.Xdefaults-host`, which no filter of endings lets through.
  Future<void> _importScheme({bool everyFile = false}) async {
    final l10n = AppLocalizations.of(context)!;
    final filter = _isDesktop && !everyFile;
    try {
      final picked = await FilePicker.platform.pickFiles(
        withData: true,
        type: filter ? FileType.custom : FileType.any,
        allowedExtensions: filter ? kTerminalSchemeFileExtensions : null,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.first;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) {
        _schemeSnack(l10n.customThemeBuilderCouldNotReadFile, isError: true);
        return;
      }
      // A scheme file is a few KB. Cap the input so a pathological or huge file
      // can't stall the regex parse on the UI isolate.
      if (bytes.length > 1024 * 1024) {
        _schemeSnack(l10n.customThemeBuilderFileTooLarge, isError: true);
        return;
      }
      final parsed =
          parseTerminalScheme(utf8.decode(bytes, allowMalformed: true));
      if (parsed == null) {
        _schemeSnack(
          l10n.customThemeBuilderNotRecognisedScheme,
          isError: true,
        );
        return;
      }
      setState(() => _colors = parsed);
      _schemeSnack(l10n.customThemeBuilderImportedPalette(file.name),
          isSuccess: true);
    } catch (e) {
      _schemeSnack(l10n.themeNotImported, isError: true, cause: e);
    }
  }

  void _schemeSnack(String message, {bool isError = false, bool isSuccess = false, Object? cause}) {
    if (!mounted) return;
    showTopSnackBar(context, message, isError: isError, isSuccess: isSuccess, details: cause == null ? null : '$cause');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = widget.existingId != null;

    // ── Docked (embedded) mode ─────────────────────────────────────
    // No Scaffold / AppBar / route: the enclosing docked panel supplies the
    // header + close button. The Reset-all / Save actions that lived in the
    // AppBar move into an inline action bar above the side-by-side layout.
    if (widget._embedded) {
      return Column(
        children: [
          _buildEmbeddedActionBar(l10n),
          Divider(height: 1, color: AppColors.divider),
          Expanded(child: _buildDesktopLayout()),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(isEditing
            ? l10n.themeBuilderEditTitle
            : l10n.themeBuilderCreateTitle),
        backgroundColor: AppColors.surface,
        actions: [
          TextButton.icon(
            onPressed: _resetAll,
            icon: Icon(
              LucideIcons.rotateCcw,
              size: 18,
              color: AppColors.onSurfaceVariant,
            ),
            label: Text(
              l10n.themeBuilderResetAll,
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
          _buildImportScheme(l10n),
          TextButton(
            onPressed: _save,
            child: Text(
              l10n.save,
              style: TextStyle(
                color: AppColors.accentInk,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: _isDesktop ? _buildDesktopLayout() : _buildMobileLayout(),
    );
  }

  // ── Import scheme, and which files it reads ─

  /// The button, and a "?" beside it that says which files it reads before
  /// the picker opens: on a phone a tap on it, on a computer the pointer too. A
  /// computer's filter goes by a file's ending, so beside it stands a way to pick
  /// from every file (a phone's picker shows them all as it is).
  Widget _buildImportScheme(AppLocalizations l10n) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: () => _importScheme(),
          icon: Icon(
            LucideIcons.download,
            size: 18,
            color: AppColors.onSurfaceVariant,
          ),
          label: Text(
            l10n.customThemeBuilderImportScheme,
            style: TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
        Tooltip(
          key: const ValueKey('import-scheme-help'),
          message: l10n.customThemeBuilderImportSchemeHelp,
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 8),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              LucideIcons.helpCircle,
              size: 15,
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ),
        if (_isDesktop)
          TextButton(
            key: const ValueKey('import-scheme-any-file'),
            onPressed: () => _importScheme(everyFile: true),
            child: Text(
              l10n.customThemeBuilderImportAnyFile,
              style: TextStyle(fontSize: 12.5, color: AppColors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  // ── Embedded action bar (replaces the AppBar actions when docked) ─

  Widget _buildEmbeddedActionBar(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _resetAll,
            icon: Icon(
              LucideIcons.rotateCcw,
              size: 18,
              color: AppColors.onSurfaceVariant,
            ),
            label: Text(
              l10n.themeBuilderResetAll,
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 4),
          _buildImportScheme(l10n),
          const Spacer(),
          FilledButton.icon(
            onPressed: _save,
            icon: Icon(
              widget.existingId != null ? LucideIcons.check : LucideIcons.plus,
              size: 18,
            ),
            label: Text(l10n.save),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              foregroundColor: AppColors.onBrand(AppColors.brandOrange),
            ),
          ),
        ],
      ),
    );
  }

  // ── Desktop: side-by-side preview + editor ─────────────────────

  Widget _buildDesktopLayout() {
    return Row(
      children: [
        // Left: Preview
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildNameField(),
                const SizedBox(height: 16),
                Expanded(child: _buildPreview()),
              ],
            ),
          ),
        ),
        VerticalDivider(width: 1, color: AppColors.divider),
        // Right: Color editor
        Expanded(
          flex: 5,
          child: _buildColorEditor(),
        ),
      ],
    );
  }

  // ── Mobile: vertically stacked ─────────────────────────────────

  Widget _buildMobileLayout() {
    return Column(
      children: [
        // Theme name
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _buildNameField(),
        ),
        // Preview
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: 160,
            child: _buildPreview(),
          ),
        ),
        Divider(height: 1, color: AppColors.divider),
        // Colour editor
        Expanded(child: _buildColorEditor()),
      ],
    );
  }

  // ── Shared widgets ─────────────────────────────────────────────

  Widget _buildNameField() {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      controller: _nameController,
      style: TextStyle(color: AppColors.onSurface),
      // Inline validation lives here, adjacent to the field - `errorText`
      // renders the message directly beneath it (never a corner toast) and
      // turns the border red. Cleared live from [_onNameChanged].
      decoration: InputDecoration(
        labelText: l10n.themeBuilderNameLabel,
        labelStyle: TextStyle(color: AppColors.onSurfaceVariant),
        hintText: l10n.themeBuilderNameHint,
        hintStyle: TextStyle(color: AppColors.onSurfaceDim),
        errorText: _nameError,
        errorStyle: TextStyle(color: AppColors.error),
        filled: true,
        fillColor: AppColors.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.brandOrange),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.error, width: 1.5),
        ),
      ),
    );
  }

  // ── Live preview ───────────────────────────────────────────────

  Widget _buildPreview() {
    final l10n = AppLocalizations.of(context)!;
    final theme = _previewTheme;
    final name = _nameController.text.trim();
    return Container(
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Terminal title bar - the theme name lives here so renaming is
          // reflected in the preview live. The traffic-light dots reuse the
          // red/yellow/green ANSI slots, so they update live too.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.foreground.withValues(alpha: 0.12),
                ),
              ),
            ),
            child: Row(
              children: [
                _previewDot(theme.red),
                _previewDot(theme.yellow),
                _previewDot(theme.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name.isEmpty ? l10n.themeBuilderPreviewUntitled : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: theme.foreground
                          .withValues(alpha: name.isEmpty ? 0.4 : 0.78),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: DefaultTextStyle(
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: theme.foreground,
                  height: 1.4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Prompt - the command is shown "selected" to preview the
                    // selection colour live.
                    _richLine([
                      _span('user', theme.green),
                      _span('@', theme.foreground),
                      _span('server', theme.cyan),
                      _span(':', theme.foreground),
                      _span('~', theme.blue),
                      _span('\$ ', theme.foreground),
                      TextSpan(
                        text: 'ls -la',
                        style: TextStyle(
                          color: theme.foreground,
                          backgroundColor: theme.selection,
                        ),
                      ),
                    ]),
              const SizedBox(height: 2),
              // Directory listing
              _richLine([
                _span('drwxr-xr-x  ', theme.foreground),
                _span('Documents/', theme.blue),
              ]),
              _richLine([
                _span('-rw-r--r--  ', theme.foreground),
                _span('config.yaml', theme.green),
              ]),
              _richLine([
                _span('-rwxr-xr-x  ', theme.foreground),
                _span('deploy.sh', theme.red),
              ]),
              const SizedBox(height: 4),
              // Git status
              _richLine([
                _span('user', theme.green),
                _span('@', theme.foreground),
                _span('server', theme.cyan),
                _span(':', theme.foreground),
                _span('~', theme.blue),
                _span('\$ ', theme.foreground),
                _span('git status', theme.foreground),
              ]),
              _richLine([
                _span('On branch ', theme.foreground),
                _span('main', theme.magenta),
              ]),
              _richLine([
                _span('  modified:   ', theme.yellow),
                _span('src/app.dart', theme.foreground),
              ]),
              _richLine([
                _span('  new file:   ', theme.green),
                _span('README.md', theme.foreground),
              ]),
              _richLine([
                _span('  deleted:    ', theme.red),
                _span('old_config.json', theme.foreground),
              ]),
              const SizedBox(height: 4),
              // Cursor simulation
              _richLine([
                _span('user', theme.green),
                _span('@', theme.foreground),
                _span('server', theme.cyan),
                _span(':', theme.foreground),
                _span('~', theme.blue),
                _span('\$ ', theme.foreground),
                // Cursor block
                WidgetSpan(
                  child: Container(
                    width: 8,
                    height: 14,
                    color: theme.cursor,
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              // ANSI colour swatch row
              Row(
                children: [
                  ..._ansiColorKeys.map((k) => _swatch(_colors[k]!)),
                ],
              ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        ..._brightColorKeys
                            .map((k) => _swatch(_colors[k]!)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewDot(Color c) {
    return Container(
      width: 9,
      height: 9,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
      ),
    );
  }

  Widget _swatch(Color c) {
    return Container(
      width: 16,
      height: 12,
      margin: const EdgeInsets.only(right: 2),
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _richLine(List<InlineSpan> spans) {
    return Text.rich(TextSpan(children: spans));
  }

  InlineSpan _span(String text, Color color) {
    return TextSpan(text: text, style: TextStyle(color: color));
  }

  // ── Colour editor (scrollable list of swatches + selected picker) ─

  Widget _buildColorEditor() {
    final l10n = AppLocalizations.of(context)!;
    final lowContrast = _lowContrastCount;
    return Column(
      children: [
        if (lowContrast > 0) _contrastSummary(l10n, lowContrast),
        // Section: Core colours
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _sectionLabel(l10n.themeBuilderSectionCore),
              ..._coreColorKeys.map(_colorTile),
              _sectionLabel(l10n.themeBuilderSectionAnsi),
              ..._ansiColorKeys.map(_colorTile),
              _sectionLabel(l10n.themeBuilderSectionBright),
              ..._brightColorKeys.map(_colorTile),
            ],
          ),
        ),
        // Inline colour picker for the selected key
        if (_selectedColorKey != null) ...[
          Divider(height: 1, color: AppColors.divider),
          _HsvColorPicker(
            key: ValueKey(_selectedColorKey),
            initialColor: _colors[_selectedColorKey!]!,
            onColorChanged: (c) {
              setState(() {
                _colors[_selectedColorKey!] = c;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.accentInk,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  /// Subtle banner summarising how many slots read poorly on the background.
  Widget _contrastSummary(AppLocalizations l10n, int count) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle,
              size: 16, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.themeBuilderContrastSummary(count),
              style: TextStyle(
                fontSize: 12,
                color: AppColors.warning,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _colorTile(String key) {
    final l10n = AppLocalizations.of(context)!;
    final color = _colors[key]!;
    final label = _colorLabel(l10n, key);
    final isSelected = _selectedColorKey == key;
    final defaultColor = _defaultColors[key];
    final isModified =
        defaultColor != null && defaultColor.toARGB32() != color.toARGB32();

    // Contrast (only for foreground + ANSI/bright, drawn over the background).
    final bg = _colors['background']!;
    final checksContrast = _contrastCheckedKeys.contains(key);
    final ratio = checksContrast ? _contrastRatio(color, bg) : null;
    final lowContrast = ratio != null && ratio < _kContrastWarnThreshold;

    // Optional mis-named-hue hint (e.g. a blue-ish "green" slot).
    final hueWrong = _hueLooksWrong(key, color);

    return ListTile(
      dense: true,
      selected: isSelected,
      selectedTileColor: AppColors.surfaceContainerHigh,
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? AppColors.brandOrange : AppColors.divider,
            width: isSelected ? 2 : 1,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: AppColors.onSurface),
            ),
          ),
          if (lowContrast) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.themeBuilderLowContrastTooltip(
                  formatDecimal(ratio, l10n: l10n)),
              child: Icon(LucideIcons.alertTriangle,
                  size: 15, color: AppColors.warning),
            ),
          ],
          if (hueWrong) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.themeBuilderHueMismatchTooltip(label),
              child: Icon(LucideIcons.helpCircle,
                  size: 15, color: AppColors.onSurfaceDim),
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: AppColors.onSurfaceDim,
            ),
          ),
          // Per-slot reset - only when the slot differs from its default.
          if (isModified)
            IconButton(
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              color: AppColors.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: l10n.themeBuilderResetSlotTooltip,
              onPressed: () => _resetSlot(key),
            )
          else
            const SizedBox(width: 32),
        ],
      ),
      onTap: () {
        setState(() {
          _selectedColorKey = isSelected ? null : key;
        });
      },
    );
  }
}

// ─── HSV colour picker widget ────────────────────────────────────

class _HsvColorPicker extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;

  const _HsvColorPicker({
    super.key,
    required this.initialColor,
    required this.onColorChanged,
  });

  @override
  State<_HsvColorPicker> createState() => _HsvColorPickerState();
}

class _HsvColorPickerState extends State<_HsvColorPicker> {
  late HSVColor _hsv;
  late TextEditingController _hexController;
  bool _internalHexUpdate = false;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexController = TextEditingController(text: _hexString);
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String get _hexString =>
      _hsv.toColor().toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  void _updateColor(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _internalHexUpdate = true;
      _hexController.text = _hexString;
      _internalHexUpdate = false;
    });
    widget.onColorChanged(_hsv.toColor());
  }

  void _onHexSubmitted(String text) {
    if (_internalHexUpdate) return;
    final cleaned = text.replaceAll('#', '').trim();
    if (cleaned.length == 6) {
      final value = int.tryParse('FF$cleaned', radix: 16);
      if (value != null) {
        _updateColor(HSVColor.fromColor(Color(value)));
      }
    } else if (cleaned.length == 8) {
      final value = int.tryParse(cleaned, radix: 16);
      if (value != null) {
        _updateColor(HSVColor.fromColor(Color(value)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceDark,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Hue slider
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Text('H', style: TextStyle(
                  color: AppColors.onSurfaceDim, fontSize: 11)),
              ),
              Expanded(child: _buildHueSlider()),
            ],
          ),
          const SizedBox(height: 8),
          // Saturation slider
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Text('S', style: TextStyle(
                  color: AppColors.onSurfaceDim, fontSize: 11)),
              ),
              Expanded(child: _buildSaturationSlider()),
            ],
          ),
          const SizedBox(height: 8),
          // Value slider
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Text('V', style: TextStyle(
                  color: AppColors.onSurfaceDim, fontSize: 11)),
              ),
              Expanded(child: _buildValueSlider()),
            ],
          ),
          const SizedBox(height: 8),
          // Alpha slider (for selection colour transparency)
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Text('A', style: TextStyle(
                  color: AppColors.onSurfaceDim, fontSize: 11)),
              ),
              Expanded(child: _buildAlphaSlider()),
            ],
          ),
          const SizedBox(height: 12),
          // Hex input + colour preview swatch
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.divider),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _hexController,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 13,
                    color: AppColors.onSurface,
                  ),
                  decoration: InputDecoration(
                    prefixText: '#',
                    prefixStyle: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13,
                      color: AppColors.onSurfaceDim,
                    ),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    filled: true,
                    fillColor: AppColors.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide:
                          BorderSide(color: AppColors.brandOrange),
                    ),
                  ),
                  onSubmitted: _onHexSubmitted,
                  onChanged: _onHexSubmitted,
                ),
              ),
              const SizedBox(width: 8),
              // Quick swatches
              ..._quickSwatches.map((c) => GestureDetector(
                    onTap: () => _updateColor(HSVColor.fromColor(c)),
                    child: Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(
                        color: c,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: _hsv.toColor().toARGB32() == c.toARGB32()
                              ? AppColors.brandOrange
                              : AppColors.divider,
                        ),
                      ),
                    ),
                  )),
            ],
          ),
        ],
      ),
    );
  }

  // Quick-access swatch colours.
  static final _quickSwatches = <Color>[
    const Color(0xFF000000),
    const Color(0xFFFFFFFF),
    AppColors.orange,
    const Color(0xFFFF0000),
    const Color(0xFF00FF00),
    const Color(0xFF0000FF),
    const Color(0xFFFFFF00),
    const Color(0xFFFF00FF),
    const Color(0xFF00FFFF),
  ];

  Widget _buildHueSlider() {
    return _GradientSlider(
      value: _hsv.hue / 360,
      gradient: const LinearGradient(colors: [
        Color(0xFFFF0000),
        Color(0xFFFFFF00),
        Color(0xFF00FF00),
        Color(0xFF00FFFF),
        Color(0xFF0000FF),
        Color(0xFFFF00FF),
        Color(0xFFFF0000),
      ]),
      onChanged: (v) {
        _updateColor(_hsv.withHue(v * 360));
      },
    );
  }

  Widget _buildSaturationSlider() {
    final left = _hsv.withSaturation(0).toColor();
    final right = _hsv.withSaturation(1).toColor();
    return _GradientSlider(
      value: _hsv.saturation,
      gradient: LinearGradient(colors: [left, right]),
      onChanged: (v) {
        _updateColor(_hsv.withSaturation(v));
      },
    );
  }

  Widget _buildValueSlider() {
    final left = _hsv.withValue(0).toColor();
    final right = _hsv.withValue(1).toColor();
    return _GradientSlider(
      value: _hsv.value,
      gradient: LinearGradient(colors: [left, right]),
      onChanged: (v) {
        _updateColor(_hsv.withValue(v));
      },
    );
  }

  Widget _buildAlphaSlider() {
    final baseColor = _hsv.toColor();
    return _GradientSlider(
      value: baseColor.a,
      gradient: LinearGradient(colors: [
        baseColor.withAlpha(0),
        baseColor.withAlpha(255)],
      ),
      onChanged: (v) {
        final c = _hsv.toColor().withAlpha((v * 255).round());
        setState(() {
          _hsv = HSVColor.fromColor(c);
          _internalHexUpdate = true;
          _hexController.text = _hexString;
          _internalHexUpdate = false;
        });
        widget.onColorChanged(c);
      },
    );
  }
}

// ─── Custom gradient slider track ────────────────────────────────

class _GradientSlider extends StatelessWidget {
  final double value;
  final LinearGradient gradient;
  final ValueChanged<double> onChanged;

  const _GradientSlider({
    required this.value,
    required this.gradient,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        const height = 28.0;
        const trackHeight = 14.0;
        const thumbRadius = 8.0;

        return GestureDetector(
          onPanDown: (d) => _update(d.localPosition.dx, width),
          onPanUpdate: (d) => _update(d.localPosition.dx, width),
          child: SizedBox(
            width: width,
            height: height,
            child: CustomPaint(
              painter: _GradientTrackPainter(
                gradient: gradient,
                trackHeight: trackHeight,
                thumbPosition: value,
                thumbRadius: thumbRadius,
              ),
            ),
          ),
        );
      },
    );
  }

  void _update(double dx, double width) {
    final clamped = dx.clamp(0.0, width) / width;
    onChanged(clamped);
  }
}

class _GradientTrackPainter extends CustomPainter {
  final LinearGradient gradient;
  final double trackHeight;
  final double thumbPosition;
  final double thumbRadius;

  _GradientTrackPainter({
    required this.gradient,
    required this.trackHeight,
    required this.thumbPosition,
    required this.thumbRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackRect = Rect.fromLTWH(
      0,
      (size.height - trackHeight) / 2,
      size.width,
      trackHeight,
    );
    final trackRRect =
        RRect.fromRectAndRadius(trackRect, const Radius.circular(7));

    // Checkerboard background (for alpha visibility)
    final checkerPaint = Paint()..color = Colors.white;
    canvas.drawRRect(trackRRect, checkerPaint);
    final darkPaint = Paint()..color = const Color(0xFFCCCCCC);
    const sq = 4.0;
    canvas.save();
    canvas.clipRRect(trackRRect);
    for (var y = trackRect.top; y < trackRect.bottom; y += sq) {
      for (var x = trackRect.left; x < trackRect.right; x += sq) {
        final ix = ((x - trackRect.left) / sq).floor();
        final iy = ((y - trackRect.top) / sq).floor();
        if ((ix + iy) % 2 == 1) {
          canvas.drawRect(Rect.fromLTWH(x, y, sq, sq), darkPaint);
        }
      }
    }
    canvas.restore();

    // Gradient
    final gradientPaint = Paint()
      ..shader = gradient.createShader(trackRect);
    canvas.drawRRect(trackRRect, gradientPaint);

    // Border
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0x33FFFFFF);
    canvas.drawRRect(trackRRect, borderPaint);

    // Thumb
    final thumbX = thumbPosition.clamp(0.0, 1.0) * size.width;
    final thumbCenter = Offset(thumbX, size.height / 2);
    canvas.drawCircle(
      thumbCenter,
      thumbRadius + 1,
      Paint()..color = Colors.black54,
    );
    canvas.drawCircle(
      thumbCenter,
      thumbRadius,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      thumbCenter,
      thumbRadius - 2,
      Paint()
        ..color = gradient.colors[
            (thumbPosition * (gradient.colors.length - 1)).round().clamp(
                  0,
                  gradient.colors.length - 1,
                )],
    );
  }

  @override
  bool shouldRepaint(_GradientTrackPainter old) =>
      old.thumbPosition != thumbPosition || old.gradient != gradient;
}
