import 'dart:async';
import 'dart:math' as math;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/windows_eyedropper.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

// ── Colour-channel helpers ────────────────────────────────────────────────
// The modern `Color` component accessors (`.r/.g/.b` as 0..1 doubles) are the
// non-deprecated path, but for 0..255 integer channels the repo standard is
// `toARGB32()` + bit math (see custom_theme_builder.dart / zest_color_scheme).
int _red(Color c) => (c.toARGB32() >> 16) & 0xFF;
int _green(Color c) => (c.toARGB32() >> 8) & 0xFF;
int _blue(Color c) => c.toARGB32() & 0xFF;

/// ZestSSH colour picker.
///
/// A swatch row - an optional leading **None** swatch, the colour chosen when it
/// is not among the [presets], then the fixed [presets], then a trailing
/// "custom" entry - above a full custom-colour dialog
/// (S/V square + a VERTICAL hue slider + hex + editable R/G/B fields + a
/// "recent" row + a live "how it will look" preview + a Windows eyedropper).
///
/// Custom colours are ALWAYS opaque (`0xFF……`): there is no alpha channel.
/// `colorValue` stays an ARGB int downstream - just always fully opaque.
///
/// Selection affordance: the selected preset is drawn with a white ring, a soft
/// glow in its own colour and a contrast-checked ✓. When [noneSelected] is true
/// the None swatch wins and NO preset shows a ring.
class ZestColorPicker extends StatelessWidget {
  const ZestColorPicker({
    super.key,
    required this.presets,
    required this.selected,
    required this.onChanged,
    this.recentCustom = const [],
    this.allowCustom = true,
    this.allowNone = false,
    this.noneSelected = false,
    this.onNoneSelected,
  });

  /// The fixed palette shown as the swatch row. For a host, a group or a tag
  /// this is `AppColors.labelPalette`, never a list of its own.
  final List<Color> presets;

  /// Whether the trailing custom-colour (hue-wheel) entry is offered. Set false
  /// for callers that persist a palette INDEX rather than an arbitrary colour
  /// (e.g. connection colour labels), where a custom pick couldn't round-trip.
  final bool allowCustom;

  /// Whether a leading **None** swatch is rendered (dashed ring + slash glyph,
  /// no fill). Tapping it calls [onNoneSelected]. Off by default so existing
  /// callers are unaffected.
  final bool allowNone;

  /// When true the None swatch shows the selection ring and every preset's ring
  /// is suppressed (None wins).
  final bool noneSelected;

  /// Fired when the None swatch is tapped.
  final VoidCallback? onNoneSelected;

  /// The currently selected colour (gets the selection ring when it matches a
  /// preset by ARGB value - unless [noneSelected] is true).
  final Color selected;

  /// Fired when the user picks a preset OR commits a custom colour.
  final ValueChanged<Color> onChanged;

  /// Optional in-memory seed for the popover's "recent" row, merged ahead of
  /// (and deduped against) the values persisted in [SharedPreferences].
  final List<Color> recentCustom;

  // ── Recent-colour persistence ──────────────────────────────────────────
  /// SharedPreferences key. Value = a `List<String>`, each the decimal form of
  /// a `Color.toARGB32()` int (shared_preferences has no int-list API), newest
  /// first, deduped by ARGB, capped at [maxRecentColors].
  static const String recentColorsPrefsKey = 'zest_recent_custom_colors';

  /// Cap on the persisted "recent custom colours" ring.
  static const int maxRecentColors = 8;

  /// Whether an on-screen eyedropper is available on this platform. Real on
  /// Windows (see [WindowsEyedropper]); `false` elsewhere, where the "Pick"
  /// affordance is HIDDEN rather than a dead/no-op button.
  static bool get supportsEyedropper => WindowsEyedropper.isSupported;

  /// Load the persisted recent custom colours (newest first).
  static Future<List<Color>> loadRecentCustom() async {
    final prefs = await appPreferences();
    final raw = prefs.getStringList(recentColorsPrefsKey) ?? const <String>[];
    final out = <Color>[];
    for (final s in raw) {
      final v = int.tryParse(s);
      if (v != null) out.add(Color(v));
    }
    return out;
  }

  /// Prepend [color] to the recent list (dedup by ARGB, cap [maxRecentColors])
  /// and persist. The colour is forced opaque before storing.
  static Future<void> addRecentCustom(Color color) async {
    final prefs = await appPreferences();
    final argb = 0xFF000000 | (color.toARGB32() & 0xFFFFFF);
    final existing =
        prefs.getStringList(recentColorsPrefsKey) ?? const <String>[];
    final ints = <int>[argb];
    for (final s in existing) {
      final v = int.tryParse(s);
      if (v != null && v != argb) ints.add(v);
    }
    final capped = ints
        .take(maxRecentColors)
        .map((v) => v.toString())
        .toList(growable: false);
    await prefs.setStringList(recentColorsPrefsKey, capped);
  }

  // ── Hex parse / format (static so they are unit-testable) ──────────────
  /// Parse a hex colour string. Accepts `#RGB`, `RGB`, `#RRGGBB` and `RRGGBB`
  /// only - case-insensitive, always opaque. There is no alpha form. Returns
  /// `null` for anything invalid - never throws.
  static Color? parseHex(String input) {
    var s = input.trim();
    if (s.startsWith('#')) s = s.substring(1);
    s = s.toUpperCase();
    if (s.isEmpty || !RegExp(r'^[0-9A-F]+$').hasMatch(s)) return null;
    switch (s.length) {
      case 3: // RGB shorthand - expand each nibble (F0A -> FF00AA).
        final r = s[0];
        final g = s[1];
        final b = s[2];
        return Color(int.parse('FF$r$r$g$g$b$b', radix: 16));
      case 6: // RRGGBB - opaque.
        return Color(int.parse('FF$s', radix: 16));
      default:
        return null;
    }
  }

  /// Canonical hex string for [c]: always `#RRGGBB` (alpha ignored).
  static String hexOf(Color c) {
    final rgb = (c.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    return '#$rgb';
  }

  /// The custom colour: in the dialog's place where this picker is in one (a
  /// snippet category's, a host icon's), which comes back as it was (rule 4
  /// of the dialog rules, 3.4: no dialog over a dialog); a dialog of its own
  /// on a page. (It was a popover of its own over its dialog.)
  void _openCustom(BuildContext context) {
    unawaited(
      showZestInPlace<void>(
        context: context,
        size: ZestModalSize.compact,
        builder: (_) => _ZestCustomColorDialog(
          initial: selected,
          recentSeed: recentCustom,
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selectedArgb = selected.toARGB32();
    final showPresetRing = !noneSelected;
    // A colour not on the list (a host's from before there was one list, a
    // custom pick) shows as it is, picked. Tapping it does nothing: a saved
    // colour is only ever replaced by someone choosing another.
    final offList = showPresetRing &&
        selectedArgb >>> 24 != 0 &&
        !presets.any((c) => c.toARGB32() == selectedArgb);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (allowNone)
          _NoneSwatch(
            tooltip: l10n.none,
            selected: noneSelected,
            onTap: onNoneSelected ?? () {},
          ),
        if (offList)
          KeyedSubtree(
            key: const ValueKey('zest-color-picker-current'),
            child: _PresetSwatch(color: selected, selected: true, onTap: () {}),
          ),
        for (final c in presets)
          _PresetSwatch(
            color: c,
            selected: showPresetRing && c.toARGB32() == selectedArgb,
            onTap: () => onChanged(c),
          ),
        if (allowCustom)
          _CustomEntry(
            tooltip: l10n.zestColorPickerCustom,
            onTap: () => _openCustom(context),
          ),
      ],
    );
  }
}

/// Full hue wheel used for the custom-entry conic gradient and the hue slider.
final List<Color> _hueWheel = [
  for (var h = 0; h <= 360; h += 30)
    HSVColor.fromAHSV(1, (h % 360).toDouble(), 1, 1).toColor(),
];

/// What a screen reader calls [c]: the palette's colours by name, any other
/// by its code (4.0, the accessibility pass: a swatch was an unnamed tap).
String colorSpokenName(Color c, AppLocalizations l10n) {
  final argb = c.toARGB32() | 0xFF000000;
  return switch (argb) {
    0xFFEF4444 => l10n.themeBuilderColorRed,
    0xFFF59E0B || 0xFFEAB308 => l10n.themeBuilderColorYellow,
    0xFFFF7A1A => l10n.a11yColorOrange,
    0xFF10B981 => l10n.themeBuilderColorGreen,
    0xFF3B82F6 => l10n.themeBuilderColorBlue,
    0xFFA855F7 => l10n.a11yColorPurple,
    0xFFEC4899 => l10n.a11yColorPink,
    0xFF14B8A6 => l10n.a11yColorTeal,
    _ => l10n.a11yColorHex(ZestColorPicker.hexOf(c)),
  };
}

const double _swatchSize = 28;
const double _swatchGap = 2;
const double _swatchRing = 2;
const double _swatchOuter = _swatchSize + 2 * (_swatchGap + _swatchRing);

/// A single preset swatch. When [selected], the swatch pops: a white ring, a
/// soft glow in its own colour, and a contrast-checked ✓ - so the chosen colour
/// reads at a glance. Layout footprint is constant so selecting never reflows.
class _PresetSwatch extends StatelessWidget {
  const _PresetSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // White reads on most swatches, but a light swatch (yellow) needs a dark ✓.
    final checkColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.light
            ? Colors.black
            : Colors.white;
    // Chosen: a ring in the text's colour with a gap, the same for every
    // colour and every theme (a white ring and a glow in the swatch's own
    // colour vanished on light ones and looked different on each).
    final dot = Container(
      width: selected ? _swatchSize - 6 : _swatchSize,
      height: selected ? _swatchSize - 6 : _swatchSize,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: selected ? Icon(LucideIcons.check, size: 13, color: checkColor) : null,
    );
    final swatch = Container(
      key: selected ? const ValueKey('zest-color-picker-selected') : null,
      width: _swatchSize,
      height: _swatchSize,
      alignment: Alignment.center,
      decoration: selected
          ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ZestTokens.textPrimary, width: 1.5))
          : null,
      child: dot,
    );
    // Named and said as picked or not, reached with Tab (Enter picks it); a
    // finger's 48 where the controls are touch sized.
    return ZestPressable(
      onTap: onTap,
      semanticLabel: colorSpokenName(color, AppLocalizations.of(context)!),
      selected: selected,
      excludeChildSemantics: true,
      borderRadius: _swatchOuter / 2,
      child: SizedBox(
        width: _swatchOuter,
        height: _swatchOuter,
        child: Center(child: swatch),
      ),
    );
  }
}

/// Leading "None" swatch: a dashed ring outline with a diagonal slash and no
/// fill. Shows the selection ring when [selected].
class _NoneSwatch extends StatelessWidget {
  const _NoneSwatch({
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: ZestPressable(
        key: const ValueKey('zest-color-picker-none'),
        onTap: onTap,
        semanticLabel: tooltip,
        selected: selected,
        excludeChildSemantics: true,
        borderRadius: _swatchOuter / 2,
        child: CustomPaint(
          size: const Size(_swatchOuter, _swatchOuter),
          painter: _NoneSwatchPainter(
            selected: selected,
            ring: ZestTokens.textSecondary,
            selectionRing: ZestTokens.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Rightmost "custom" entry: a conic hue wheel with a centered `+`.
class _CustomEntry extends StatelessWidget {
  const _CustomEntry({required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Pressed in a finger's 48 where the controls are touch sized, as the
    // swatches beside it are (it sat in a box of its swatch's 36, which held
    // the pressable to 36).
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: ZestPressable(
        onTap: onTap,
        semanticLabel: tooltip,
        excludeChildSemantics: true,
        borderRadius: _swatchOuter / 2,
        child: SizedBox(
          width: _swatchOuter,
          height: _swatchOuter,
          child: Center(
            child: Container(
              key: const ValueKey('zest-color-picker-custom-entry'),
              width: _swatchSize,
              height: _swatchSize,
              // Neutral: a plus in a ring (a rainbow wheel shouted louder
              // than every colour beside it).
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ZestTokens.borderStrong, width: 1.5),
              ),
              child: Center(
                child: Icon(LucideIcons.plus, size: 14, color: ZestTokens.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Custom-colour dialog
// ══════════════════════════════════════════════════════════════════════════

/// The full custom-colour editor, in the app's dialog ([ZestDialogShell]).
///
/// Commit model: **Apply** (the main button, in the footer) commits - fires
/// [onChanged], adds the colour to "recent", closes. **Cancel** (and a click
/// outside, and Esc) reverts with no change. Enter = Apply. Live edits only
/// mutate local working state until commit. The Windows eyedropper is the
/// footer's side link (it was a button in the body).
class _ZestCustomColorDialog extends StatefulWidget {
  const _ZestCustomColorDialog({
    required this.initial,
    required this.recentSeed,
    required this.onChanged,
  });

  final Color initial;
  final List<Color> recentSeed;
  final ValueChanged<Color> onChanged;

  @override
  State<_ZestCustomColorDialog> createState() =>
      _ZestCustomColorDialogState();
}

class _ZestCustomColorDialogState extends State<_ZestCustomColorDialog> {
  /// The editor's keys (Escape, Enter): it takes the keyboard as it opens.
  final _keys = FocusNode(debugLabel: 'zest-custom-colour');

  // Working state is stored as HSV so dragging value/saturation to an extreme
  // never loses the hue (which a Color round-trip would). Always opaque.
  late double _hue; // 0..360
  late double _sat; // 0..1
  late double _val; // 0..1

  /// The opaque colour the popover opened with - the "Current" comparison half.
  late final Color _openedWith;

  late final TextEditingController _hexController;
  late final FocusNode _hexFocus;
  String _lastValidHex = '';
  bool _hexError = false;

  List<Color> _recents = const [];
  bool _closed = false;

  // ── Eyedropper (Windows) ────────────────────────────────────────────────
  WindowsEyedropper? _eyedropper;
  Timer? _sampleTimer;
  bool _sampling = false;
  Color? _preSampleColor;

  Color get _currentColor => HSVColor.fromAHSV(
        1,
        _hue % 360,
        _sat.clamp(0.0, 1.0),
        _val.clamp(0.0, 1.0),
      ).toColor();

  @override
  void initState() {
    super.initState();
    _openedWith = Color(0xFF000000 | (widget.initial.toARGB32() & 0xFFFFFF));
    final hsv = HSVColor.fromColor(_openedWith);
    _hue = hsv.hue;
    _sat = hsv.saturation;
    _val = hsv.value;
    _lastValidHex = ZestColorPicker.hexOf(_openedWith);
    _hexController = TextEditingController(text: _lastValidHex);
    _hexFocus = FocusNode();
    _hexFocus.addListener(_onHexFocusChange);
    _recents = List<Color>.from(widget.recentSeed);
    unawaited(_loadRecents());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_keys.hasFocus) _keys.requestFocus();
    });
  }

  @override
  void dispose() {
    _stopSampling(apply: false, silent: true);
    _hexFocus.removeListener(_onHexFocusChange);
    _hexFocus.dispose();
    _hexController.dispose();
    _keys.dispose();
    super.dispose();
  }

  Future<void> _loadRecents() async {
    final loaded = await ZestColorPicker.loadRecentCustom();
    if (!mounted) return;
    final seen = <int>{};
    final merged = <Color>[];
    for (final c in [...loaded, ...widget.recentSeed]) {
      if (seen.add(c.toARGB32())) merged.add(c);
      if (merged.length >= ZestColorPicker.maxRecentColors) break;
    }
    setState(() => _recents = merged);
  }

  // ── Commit / revert ────────────────────────────────────────────────────
  void _commit() {
    if (_closed) return;
    _stopSampling(apply: false, silent: true);
    _closed = true;
    final c = _currentColor;
    unawaited(ZestColorPicker.addRecentCustom(c));
    widget.onChanged(c);
    zestDialogPop(context);
  }

  void _revert() {
    if (_closed) return;
    _stopSampling(apply: false, silent: true);
    _closed = true;
    zestDialogPop(context);
  }

  /// Esc: cancel an in-progress sample, else Cancel the dialog.
  void _onEscape() {
    if (_sampling) {
      _stopSampling(apply: false);
    } else {
      _revert();
    }
  }

  /// Enter: commit an in-progress sample, else Apply the dialog.
  void _onEnter() {
    if (_sampling) {
      _stopSampling(apply: true);
    } else {
      _commit();
    }
  }

  /// Click outside the dialog while sampling: the user clicked a pixel, which
  /// is the colour. (Not sampling, a click outside is Cancel, as a dialog's.)
  void _onOutsideTap() {
    if (_sampling) _stopSampling(apply: true);
  }

  // ── Eyedropper control ──────────────────────────────────────────────────
  void _togglePick() {
    if (_sampling) {
      _stopSampling(apply: true);
      return;
    }
    if (!WindowsEyedropper.isSupported) return;
    _preSampleColor = _currentColor;
    final ed = _eyedropper = WindowsEyedropper();
    _sampleTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final c = ed.sample();
      if (c != null && mounted) _setFromColor(c, keepHue: true);
    });
    setState(() => _sampling = true);
  }

  void _stopSampling({required bool apply, bool silent = false}) {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    final ed = _eyedropper;
    _eyedropper = null;
    ed?.dispose();
    final restore = _preSampleColor;
    _preSampleColor = null;
    if (!_sampling) return;
    if (!apply && restore != null && !silent) {
      _setFromColor(restore, keepHue: true);
    }
    if (silent) {
      _sampling = false;
    } else if (mounted) {
      setState(() => _sampling = false);
    } else {
      _sampling = false;
    }
  }

  // ── Mutators ───────────────────────────────────────────────────────────
  /// Sync the hex field + last-valid marker after an internal (non-hex) edit.
  void _afterInternalChange() {
    _lastValidHex = ZestColorPicker.hexOf(_currentColor);
    if (!_hexFocus.hasFocus) _hexController.text = _lastValidHex;
    if (_hexError) _hexError = false;
  }

  void _setSV(double s, double v) {
    setState(() {
      _sat = s.clamp(0.0, 1.0);
      _val = v.clamp(0.0, 1.0);
      _afterInternalChange();
    });
  }

  void _setHue(double fraction) {
    setState(() {
      _hue = (fraction.clamp(0.0, 1.0)) * 360;
      _afterInternalChange();
    });
  }

  void _setChannel(int index, int value) {
    final c = _currentColor;
    var r = _red(c), g = _green(c), b = _blue(c);
    final vv = value.clamp(0, 255);
    if (index == 0) {
      r = vv;
    } else if (index == 1) {
      g = vv;
    } else {
      b = vv;
    }
    _setFromColor(Color.fromARGB(255, r, g, b), keepHue: true);
  }

  /// Adopt [c] into working state (always opaque). [keepHue] preserves the
  /// current hue when the incoming colour is achromatic (so typing a grey
  /// doesn't snap hue to red).
  void _setFromColor(
    Color c, {
    bool syncController = true,
    bool keepHue = false,
  }) {
    final opaque = Color(0xFF000000 | (c.toARGB32() & 0xFFFFFF));
    final hsv = HSVColor.fromColor(opaque);
    setState(() {
      if (!(keepHue && hsv.saturation == 0)) _hue = hsv.hue;
      _sat = hsv.saturation;
      _val = hsv.value;
      _hexError = false;
    });
    _lastValidHex = ZestColorPicker.hexOf(_currentColor);
    if (syncController && !_hexFocus.hasFocus) {
      _hexController.text = _lastValidHex;
    }
  }

  void _onHexChanged(String text) {
    final parsed = ZestColorPicker.parseHex(text);
    if (parsed != null) {
      _setFromColor(parsed, syncController: false, keepHue: true);
    } else {
      setState(() => _hexError = text.trim().isNotEmpty);
    }
  }

  void _onHexFocusChange() {
    if (_hexFocus.hasFocus || !mounted) return;
    // On blur: revert an invalid value to the last valid one; normalise a
    // valid one to canonical form. Never throw.
    final parsed = ZestColorPicker.parseHex(_hexController.text);
    setState(() {
      _hexController.text = parsed == null
          ? _lastValidHex
          : ZestColorPicker.hexOf(_currentColor);
      _hexError = false;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = _currentColor;

    const svSize = 156.0;

    final shell = ZestDialogShell(
      key: const ValueKey('zest-custom-colour'),
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.palette,
      title: l10n.zestColorPickerCustomTitle,
      onClose: _revert,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top: SV square · vertical hue · New/Current ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: svSize,
                height: svSize,
                child: GestureDetector(
                  onPanDown: (d) => _handleSV(d.localPosition, const Size(svSize, svSize)),
                  onPanUpdate: (d) => _handleSV(d.localPosition, const Size(svSize, svSize)),
                  child: CustomPaint(
                    size: const Size(svSize, svSize),
                    painter: _SVSquarePainter(
                      hue: _hue % 360,
                      sat: _sat,
                      val: _val,
                      border: ZestTokens.border,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _VerticalHueSlider(
                width: 20,
                height: svSize,
                hue: _hue,
                onChanged: _setHue,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CompareSwatch(
                  working: color,
                  current: _openedWith,
                  onRevertToCurrent: () => _setFromColor(_openedWith),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ── HEX · R · G · B ──────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: _hexColumn(l10n)),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _ChannelField(label: 'R', value: _red(color), onChanged: (v) => _setChannel(0, v)),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 2,
                child: _ChannelField(label: 'G', value: _green(color), onChanged: (v) => _setChannel(1, v)),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 2,
                child: _ChannelField(label: 'B', value: _blue(color), onChanged: (v) => _setChannel(2, v)),
              ),
            ],
          ),
          if (_recents.isNotEmpty) ...[
            const SizedBox(height: 16),
            _sectionLabel(l10n.zestColorPickerRecent),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _recents)
                  GestureDetector(
                    onTap: () => _setFromColor(c),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: ZestTokens.border),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          // ── Live preview ─────────────────────────────────
          _sectionLabel(l10n.zestColorPickerPreviewTitle),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _CardPreview(accent: color)),
              const SizedBox(width: 10),
              Expanded(child: _DrawerPreview(accent: color)),
            ],
          ),
        ],
      ),
      // The eyedropper (Windows): a side option, the footer's link; hidden
      // where there is none rather than a button that does nothing.
      tertiaryKey: const ValueKey('zest-color-picker-eyedropper'),
      tertiaryAction: WindowsEyedropper.isSupported
          ? (label: _sampling ? l10n.zestColorPickerSampling : l10n.zestColorPickerFromScreen, onPressed: _togglePick)
          : null,
      secondaryAction: (label: l10n.cancel, onPressed: _revert),
      primaryKey: const ValueKey('zest-color-picker-apply'),
      primaryAction: (label: l10n.settingsApply, icon: null, onPressed: _commit),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
        const SingleActivator(LogicalKeyboardKey.enter): _onEnter,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _onEnter,
      },
      child: Focus(
        focusNode: _keys,
        child: Stack(
          children: [
            // While sampling, a click anywhere outside the dialog is the
            // pixel picked (the dialog's own area takes its clicks).
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_sampling,
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _onOutsideTap),
              ),
            ),
            shell,
          ],
        ),
      ),
    );
  }

  Widget _hexColumn(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.zestColorPickerHex),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey('zest-color-picker-hex-field'),
          controller: _hexController,
          focusNode: _hexFocus,
          onChanged: _onHexChanged,
          onSubmitted: (_) => _commit(),
          style: TextStyle(
            color: ZestTokens.textPrimary,
            fontFamily: 'JetBrainsMono',
            fontSize: 13,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: ZestTokens.surfaceSunken,
            errorText: _hexError ? l10n.zestColorPickerInvalidHex : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: ZestTokens.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: ZestTokens.textSecondary),
            ),
          ),
        ),
      ],
    );
  }

  void _handleSV(Offset pos, Size size) {
    _setSV(pos.dx / size.width, 1 - pos.dy / size.height);
  }
}

/// Section / field label (uppercased, tracked).
Widget _sectionLabel(String text) => Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: ZestTokens.textTertiary,
      ),
    );

/// "New" (top) over "Current" (bottom) comparison swatch with small labels.
class _CompareSwatch extends StatelessWidget {
  const _CompareSwatch({
    required this.working,
    required this.current,
    this.onRevertToCurrent,
  });

  final Color working;
  final Color current;

  /// Tapping the "Current" (bottom) half reverts the working colour to it.
  final VoidCallback? onRevertToCurrent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Stretched: the two halves take the column's width (they had none, so
    // only their border showed, a line).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tinyLabel(l10n.zestColorPickerNew),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 54,
            decoration: BoxDecoration(
              border: Border.all(color: ZestTokens.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: ColoredBox(color: working)),
                Expanded(
                  child: GestureDetector(
                    onTap: onRevertToCurrent,
                    child: ColoredBox(color: current),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 3),
        _tinyLabel(l10n.zestColorPickerCurrent),
      ],
    );
  }
}

Widget _tinyLabel(String text) => Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: ZestTokens.textTertiary,
      ),
    );

/// "On a card" preview: a card with a LEFT ACCENT BAR (the colour label
/// channel), a placeholder icon, a label and a healthy status dot.
class _CardPreview extends StatelessWidget {
  const _CardPreview({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.border),
        ),
        child: Row(
          children: [
            Container(width: 4, height: double.infinity, color: accent),
            const SizedBox(width: 10),
            Icon(LucideIcons.server, size: 16,
                color: ZestTokens.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppLocalizations.of(context)!.zestColorPickerOnCard,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ZestTokens.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _dot(ZestTokens.statusHealthy),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

/// "In the drawer" preview: a dark row faintly tinted by the colour, with a
/// LEFT BAR in the colour, a label and a neutral dot.
class _DrawerPreview extends StatelessWidget {
  const _DrawerPreview({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    final tint = Color.alphaBlend(
      accent.withValues(alpha: 0.12),
      ZestTokens.surfaceSunken,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.border),
        ),
        child: Row(
          children: [
            Container(width: 4, height: double.infinity, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                AppLocalizations.of(context)!.zestColorPickerInDrawer,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ZestTokens.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _dot(ZestTokens.textTertiary),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

Widget _dot(Color color) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

/// Vertical rainbow hue slider with a horizontal thumb. Maps drag-y → 0..1
/// fraction → hue.
class _VerticalHueSlider extends StatelessWidget {
  const _VerticalHueSlider({
    required this.width,
    required this.height,
    required this.hue,
    required this.onChanged,
  });

  final double width;
  final double height;
  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    void handle(Offset p) => onChanged((p.dy / height).clamp(0.0, 1.0));
    return SizedBox(
      width: width,
      height: height,
      child: GestureDetector(
        onPanDown: (d) => handle(d.localPosition),
        onPanUpdate: (d) => handle(d.localPosition),
        child: CustomPaint(
          size: Size(width, height),
          painter: _HueBarPainter(
            fraction: (hue % 360) / 360,
            border: ZestTokens.border,
          ),
        ),
      ),
    );
  }
}

/// Editable 0-255 channel field. Live-updates on typing; clamps out-of-range;
/// ArrowUp/Down nudge ±1 (±10 with Shift) as a bonus.
class _ChannelField extends StatefulWidget {
  const _ChannelField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_ChannelField> createState() => _ChannelFieldState();
}

class _ChannelFieldState extends State<_ChannelField> {
  late final TextEditingController _controller;
  late final FocusNode _node;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _node = FocusNode(onKeyEvent: _onKey);
    _node.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(_ChannelField old) {
    super.didUpdateWidget(old);
    // Reflect external changes (SV drag, hex entry, recents) unless the user is
    // actively editing this field.
    if (widget.value != old.value && !_node.hasFocus) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    _node.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    final f = _node.hasFocus;
    if (!f) {
      // Normalise on blur to the committed value.
      _controller.text = widget.value.toString();
    }
    setState(() => _focused = f);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final step = HardwareKeyboard.instance.isShiftPressed ? 10 : 1;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _bump(step);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _bump(-step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _bump(int delta) {
    final nv = (widget.value + delta).clamp(0, 255);
    _controller.text = nv.toString();
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    widget.onChanged(nv);
  }

  void _onChanged(String text) {
    if (text.isEmpty) return; // mid-edit; don't snap to 0.
    final v = int.tryParse(text);
    if (v == null) return;
    final cv = v.clamp(0, 255);
    if (cv != v) {
      _controller.text = cv.toString();
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    }
    widget.onChanged(cv);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(widget.label),
        const SizedBox(height: 6),
        TextField(
          controller: _controller,
          focusNode: _node,
          onChanged: _onChanged,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ZestTokens.textPrimary,
            fontFamily: 'JetBrainsMono',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: ZestTokens.surfaceSunken,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: ZestTokens.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: _focused
                    ? ZestTokens.textSecondary
                    : ZestTokens.border,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Painters ───────────────────────────────────────────────────────────────

/// None swatch: dashed ring + diagonal slash, plus an outer selection ring.
class _NoneSwatchPainter extends CustomPainter {
  _NoneSwatchPainter({
    required this.selected,
    required this.ring,
    required this.selectionRing,
  });

  final bool selected;
  final Color ring;
  final Color selectionRing;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = _swatchSize / 2 - 1; // dashed-ring radius

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = ring;

    // Dashed circle (arc segments).
    const dashes = 16;
    const sweep = (2 * math.pi) / dashes;
    final arcRect = Rect.fromCircle(center: center, radius: r);
    for (var i = 0; i < dashes; i += 2) {
      canvas.drawArc(arcRect, i * sweep, sweep * 0.62, false, ringPaint);
    }

    // Diagonal slash (bottom-left → top-right).
    final off = r * 0.6;
    canvas.drawLine(
      center + Offset(-off, off),
      center + Offset(off, -off),
      ringPaint,
    );

    if (selected) {
      canvas.drawCircle(
        center,
        _swatchSize / 2 + _swatchGap + _swatchRing / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = selectionRing,
      );
    }
  }

  @override
  bool shouldRepaint(_NoneSwatchPainter old) =>
      old.selected != selected || old.ring != ring;
}

/// Saturation (x) × Value (y) square for the current [hue].
class _SVSquarePainter extends CustomPainter {
  _SVSquarePainter({
    required this.hue,
    required this.sat,
    required this.val,
    required this.border,
  });

  final double hue;
  final double sat;
  final double val;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(rrect);

    final hueColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    // White → hue, left to right.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    // Transparent → black, top to bottom.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );
    canvas.restore();

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = border,
    );

    final thumb = Offset(sat * size.width, (1 - val) * size.height);
    canvas.drawCircle(
      thumb,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawCircle(
      thumb,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_SVSquarePainter old) =>
      old.hue != hue || old.sat != sat || old.val != val;
}

/// Vertical full-spectrum hue bar with a horizontal thumb at [fraction]
/// (0 = top, 1 = bottom).
class _HueBarPainter extends CustomPainter {
  _HueBarPainter({required this.fraction, required this.border});

  final double fraction;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.width / 2),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: _hueWheel,
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = border,
    );

    final y = fraction.clamp(0.0, 1.0) * size.height;
    final outer = RRect.fromRectAndRadius(
      Rect.fromLTWH(-2, y - 4, size.width + 4, 8),
      const Radius.circular(4),
    );
    canvas.drawRRect(outer, Paint()..color = Colors.black54);
    final inner = RRect.fromRectAndRadius(
      Rect.fromLTWH(-1, y - 3, size.width + 2, 6),
      const Radius.circular(3),
    );
    canvas.drawRRect(inner, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_HueBarPainter old) => old.fraction != fraction;
}
