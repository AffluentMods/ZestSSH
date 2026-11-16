import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

/// Terminal colour schemes, independent of the app theme.
///
/// Each theme provides all colour fields that the xterm [TerminalTheme]
/// expects. Free themes: Zest Night (the default since 3.0), Dark, Light,
/// AMOLED. Pro themes (gated in UI): Solarized Dark, Monokai, Dracula, Nord
/// and the rest.
///
/// Custom user-created themes are stored in SharedPreferences under the
/// key [_customThemesKey] as a JSON array.
abstract final class TerminalThemes {
  /// The app's own near-black, the default for anyone who has not picked a
  /// theme (3.0). [defaultDark] is the grey theme that was the default before.
  static const String zestNight = 'zest_night';

  /// What an unset or deleted choice falls back to.
  static const String defaultId = zestNight;

  static const String defaultDark = 'dark';
  static const String light = 'light';
  static const String amoled = 'amoled';
  static const String midnight = 'midnight';
  static const String catppuccinMocha = 'catppuccin_mocha';
  static const String solarizedDark = 'solarized_dark';
  static const String monokai = 'monokai';
  static const String dracula = 'dracula';
  static const String nord = 'nord';
  static const String gruvbox = 'gruvbox';
  static const String tokyoNight = 'tokyo_night';
  static const String cyberpunk = 'cyberpunk';
  static const String synthwave = 'synthwave';
  static const String ocean = 'ocean';
  static const String citrus = 'citrus';
  static const String oneDark = 'one_dark';
  static const String oneLight = 'one_light';
  static const String darcula = 'darcula';
  static const String intellijDark = 'intellij_dark';
  static const String intellijLight = 'intellij_light';

  /// SharedPreferences key for persisted custom themes.
  static const String _customThemesKey = 'custom_terminal_themes';

  /// All built-in themes, keyed by ID.
  static const Map<String, TerminalTheme> builtIn = {
    zestNight: _zestNightTheme,
    defaultDark: _darkTheme,
    light: _lightTheme,
    amoled: _amoledTheme,
    midnight: _midnightTheme,
    catppuccinMocha: _catppuccinMochaTheme,
    solarizedDark: _solarizedDarkTheme,
    monokai: _monokaiTheme,
    dracula: _draculaTheme,
    nord: _nordTheme,
    gruvbox: _gruvboxTheme,
    tokyoNight: _tokyoNightTheme,
    cyberpunk: _cyberpunkTheme,
    synthwave: _synthwaveTheme,
    ocean: _oceanTheme,
    citrus: _citrusTheme,
    oneDark: _oneDarkTheme,
    oneLight: _oneLightTheme,
    darcula: _darculaTheme,
    intellijDark: _intellijDarkTheme,
    intellijLight: _intellijLightTheme,
  };

  /// All available themes, keyed by ID (built-in + custom).
  ///
  /// Custom themes are populated after [loadCustomThemes] is called.
  static Map<String, TerminalTheme> get all => {
        ...builtIn,
        ..._customThemes,
      };

  /// Mutable registry for user-created themes.
  static final Map<String, TerminalTheme> _customThemes = {};

  /// Human-readable names for user-created themes.
  static final Map<String, String> _customThemeNames = {};

  /// Human-readable names for the settings UI (built-in + custom).
  static Map<String, String> get names => {
        ...builtInNames,
        ..._customThemeNames,
      };

  /// Human-readable names for built-in themes only.
  static const Map<String, String> builtInNames = {
    zestNight: 'Zest Night',
    defaultDark: 'Dark',
    light: 'Light',
    amoled: 'AMOLED Black',
    midnight: 'Midnight',
    catppuccinMocha: 'Catppuccin Mocha',
    solarizedDark: 'Solarized Dark',
    monokai: 'Monokai',
    dracula: 'Dracula',
    nord: 'Nord',
    gruvbox: 'Gruvbox',
    tokyoNight: 'Tokyo Night',
    cyberpunk: 'Cyberpunk',
    synthwave: 'Synthwave',
    ocean: 'Ocean',
    citrus: 'Citrus',
    oneDark: 'One Dark',
    oneLight: 'One Light',
    darcula: 'Darcula',
    intellijDark: 'IntelliJ Dark',
    intellijLight: 'IntelliJ Light',
  };

  /// IDs of themes available on the free tier: every built-in theme. A theme
  /// the person designs themselves is never one of these (custom themes stay
  /// with Squeezed).
  static final Set<String> freeThemeIds = Set.unmodifiable(builtIn.keys);

  /// Whether [id] is a user-created custom theme.
  static bool isCustomTheme(String id) => _customThemes.containsKey(id);

  /// All custom theme IDs, sorted.
  static List<String> get customThemeIds {
    final ids = _customThemes.keys.toList()..sort();
    return ids;
  }

  // ─── Custom theme persistence ──────────────────────────────────

  /// Loads custom themes from SharedPreferences into the runtime map.
  ///
  /// Call this once at app startup (after SharedPreferences is available).
  static Future<void> loadCustomThemes(SharedPreferences prefs) async {
    _customThemes.clear();
    _customThemeNames.clear();

    final raw = prefs.getString(_customThemesKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      for (final entry in list) {
        if (entry is! Map<String, dynamic>) continue;
        final id = entry['id'] as String?;
        final name = entry['name'] as String?;
        if (id == null || name == null) continue;

        final theme = _themeFromJson(entry);
        if (theme != null) {
          _customThemes[id] = theme;
          _customThemeNames[id] = name;
        }
      }
    } catch (_) {
      // Corrupt data - start fresh.
      _customThemes.clear();
      _customThemeNames.clear();
    }
  }

  /// Saves a custom theme (new or updated) and persists to SharedPreferences.
  ///
  /// If [id] is null a new ID is generated (custom_1, custom_2, ...).
  /// Returns the ID used.
  static Future<String> saveCustomTheme({
    required SharedPreferences prefs,
    required String name,
    required TerminalTheme theme,
    String? id,
  }) async {
    final themeId = id ?? _nextCustomId();
    _customThemes[themeId] = theme;
    _customThemeNames[themeId] = name;
    await _persist(prefs);
    return themeId;
  }

  /// Deletes a custom theme and persists the change.
  static Future<void> deleteCustomTheme({
    required SharedPreferences prefs,
    required String id,
  }) async {
    _customThemes.remove(id);
    _customThemeNames.remove(id);
    await _persist(prefs);
  }

  /// Generates the next available custom_N ID.
  static String _nextCustomId() {
    int maxNum = 0;
    for (final id in _customThemes.keys) {
      if (id.startsWith('custom_')) {
        final num = int.tryParse(id.substring(7));
        if (num != null && num > maxNum) maxNum = num;
      }
    }
    return 'custom_${maxNum + 1}';
  }

  /// Writes all custom themes to SharedPreferences as a JSON array.
  static Future<void> _persist(SharedPreferences prefs) async {
    final list = <Map<String, dynamic>>[];
    for (final entry in _customThemes.entries) {
      list.add({
        'id': entry.key,
        'name': _customThemeNames[entry.key] ?? entry.key,
        ..._themeToJson(entry.value),
      });
    }
    await prefs.setString(_customThemesKey, jsonEncode(list));
  }

  // ─── JSON serialisation helpers ────────────────────────────────

  /// Converts a [Color] to a hex string like "FF1E1E1E".
  static String _colorToHex(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();

  /// Parses a hex string ("FF1E1E1E") back to a [Color].
  static Color _hexToColor(String hex) => Color(int.parse(hex, radix: 16));

  static Map<String, String> _themeToJson(TerminalTheme t) => {
        'cursor': _colorToHex(t.cursor),
        'selection': _colorToHex(t.selection),
        'foreground': _colorToHex(t.foreground),
        'background': _colorToHex(t.background),
        'black': _colorToHex(t.black),
        'red': _colorToHex(t.red),
        'green': _colorToHex(t.green),
        'yellow': _colorToHex(t.yellow),
        'blue': _colorToHex(t.blue),
        'magenta': _colorToHex(t.magenta),
        'cyan': _colorToHex(t.cyan),
        'white': _colorToHex(t.white),
        'brightBlack': _colorToHex(t.brightBlack),
        'brightRed': _colorToHex(t.brightRed),
        'brightGreen': _colorToHex(t.brightGreen),
        'brightYellow': _colorToHex(t.brightYellow),
        'brightBlue': _colorToHex(t.brightBlue),
        'brightMagenta': _colorToHex(t.brightMagenta),
        'brightCyan': _colorToHex(t.brightCyan),
        'brightWhite': _colorToHex(t.brightWhite),
      };

  static TerminalTheme? _themeFromJson(Map<String, dynamic> json) {
    try {
      return TerminalTheme(
        cursor: _hexToColor(json['cursor'] as String),
        selection: _hexToColor(json['selection'] as String),
        foreground: _hexToColor(json['foreground'] as String),
        background: _hexToColor(json['background'] as String),
        black: _hexToColor(json['black'] as String),
        red: _hexToColor(json['red'] as String),
        green: _hexToColor(json['green'] as String),
        yellow: _hexToColor(json['yellow'] as String),
        blue: _hexToColor(json['blue'] as String),
        magenta: _hexToColor(json['magenta'] as String),
        cyan: _hexToColor(json['cyan'] as String),
        white: _hexToColor(json['white'] as String),
        brightBlack: _hexToColor(json['brightBlack'] as String),
        brightRed: _hexToColor(json['brightRed'] as String),
        brightGreen: _hexToColor(json['brightGreen'] as String),
        brightYellow: _hexToColor(json['brightYellow'] as String),
        brightBlue: _hexToColor(json['brightBlue'] as String),
        brightMagenta: _hexToColor(json['brightMagenta'] as String),
        brightCyan: _hexToColor(json['brightCyan'] as String),
        brightWhite: _hexToColor(json['brightWhite'] as String),
        searchHitBackground: const Color(0x80E8A020),
        searchHitBackgroundCurrent: const Color(0xFFE8A020),
        searchHitForeground: const Color(0xFF000000),
      );
    } catch (_) {
      return null;
    }
  }

  /// Creates a [TerminalTheme] from a colour map (used by the theme builder).
  static TerminalTheme themeFromColorMap(Map<String, Color> colors) {
    return TerminalTheme(
      cursor: colors['cursor']!,
      selection: colors['selection']!,
      foreground: colors['foreground']!,
      background: colors['background']!,
      black: colors['black']!,
      red: colors['red']!,
      green: colors['green']!,
      yellow: colors['yellow']!,
      blue: colors['blue']!,
      magenta: colors['magenta']!,
      cyan: colors['cyan']!,
      white: colors['white']!,
      brightBlack: colors['brightBlack']!,
      brightRed: colors['brightRed']!,
      brightGreen: colors['brightGreen']!,
      brightYellow: colors['brightYellow']!,
      brightBlue: colors['brightBlue']!,
      brightMagenta: colors['brightMagenta']!,
      brightCyan: colors['brightCyan']!,
      brightWhite: colors['brightWhite']!,
      searchHitBackground: const Color(0x80E8A020),
      searchHitBackgroundCurrent: const Color(0xFFE8A020),
      searchHitForeground: const Color(0xFF000000),
    );
  }

  /// Extracts the editable colour map from a [TerminalTheme].
  static Map<String, Color> colorMapFromTheme(TerminalTheme t) => {
        'cursor': t.cursor,
        'selection': t.selection,
        'foreground': t.foreground,
        'background': t.background,
        'black': t.black,
        'red': t.red,
        'green': t.green,
        'yellow': t.yellow,
        'blue': t.blue,
        'magenta': t.magenta,
        'cyan': t.cyan,
        'white': t.white,
        'brightBlack': t.brightBlack,
        'brightRed': t.brightRed,
        'brightGreen': t.brightGreen,
        'brightYellow': t.brightYellow,
        'brightBlue': t.brightBlue,
        'brightMagenta': t.brightMagenta,
        'brightCyan': t.brightCyan,
        'brightWhite': t.brightWhite,
      };

  // ─── Zest Night (default since 3.0) ──────────────────────────────
  // The app's near-black under warm text, so a session reads as part of the
  // window rather than a grey box inside it. The cursor is the brand orange
  // (retinted to a custom primary when themes are synced); the ANSI colours
  // are the app's status palette, lifted for text on black.
  static const _zestNightTheme = TerminalTheme(
    cursor: Color(0xFFFF7A1A),
    selection: Color(0x4DFF7A1A),
    foreground: Color(0xFFD6D1C4),
    background: Color(0xFF0A0A0B),
    black: Color(0xFF26262A),
    red: Color(0xFFF0736B),
    green: Color(0xFF7FC08A),
    yellow: Color(0xFFE6C14A),
    blue: Color(0xFF83A8D8),
    magenta: Color(0xFFC792EA),
    cyan: Color(0xFF6CC5C0),
    white: Color(0xFFD6D1C4),
    brightBlack: Color(0xFF6D6B65),
    brightRed: Color(0xFFFF8F87),
    brightGreen: Color(0xFFA0D8A8),
    brightYellow: Color(0xFFF2D675),
    brightBlue: Color(0xFFA5C2EA),
    brightMagenta: Color(0xFFD9B2F2),
    brightCyan: Color(0xFF93DDD7),
    brightWhite: Color(0xFFF2EEE6),
    searchHitBackground: Color(0x80E6C14A),
    searchHitBackgroundCurrent: Color(0xFFE6C14A),
    searchHitForeground: Color(0xFF0A0A0B),
  );

  // ─── Dark (the default before 3.0) ───────────────────────────────
  static const _darkTheme = TerminalTheme(
    cursor: Color(0xFFE8600A),
    selection: Color(0x80E8600A),
    foreground: Color(0xFFD4D4D4),
    background: Color(0xFF1E1E1E),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF0DBC79),
    yellow: Color(0xFFE5E510),
    blue: Color(0xFF2472C8),
    magenta: Color(0xFFBC3FBC),
    cyan: Color(0xFF11A8CD),
    white: Color(0xFFE5E5E5),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFF14C4C),
    brightGreen: Color(0xFF23D18B),
    brightYellow: Color(0xFFF5F543),
    brightBlue: Color(0xFF3B8EEA),
    brightMagenta: Color(0xFFD670D6),
    brightCyan: Color(0xFF29B8DB),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80E8A020),
    searchHitBackgroundCurrent: Color(0xFFE8A020),
    searchHitForeground: Color(0xFF000000),
  );

  // ─── Light ───────────────────────────────────────────────────────
  static const _lightTheme = TerminalTheme(
    cursor: Color(0xFFE8600A),
    selection: Color(0x40E8600A),
    foreground: Color(0xFF333333),
    background: Color(0xFFF5F5F5),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF008000),
    yellow: Color(0xFF795E25),
    blue: Color(0xFF0451A5),
    magenta: Color(0xFFBC05BC),
    cyan: Color(0xFF0598BC),
    white: Color(0xFFA5A5A5),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFCD3131),
    brightGreen: Color(0xFF14CE14),
    brightYellow: Color(0xFFB5BA00),
    brightBlue: Color(0xFF0451A5),
    brightMagenta: Color(0xFFBC05BC),
    brightCyan: Color(0xFF0598BC),
    brightWhite: Color(0xFFA5A5A5),
    searchHitBackground: Color(0x80E8A020),
    searchHitBackgroundCurrent: Color(0xFFE8A020),
    searchHitForeground: Color(0xFF000000),
  );

  // ─── AMOLED Black ────────────────────────────────────────────────
  static const _amoledTheme = TerminalTheme(
    cursor: Color(0xFFE8600A),
    selection: Color(0x80E8600A),
    foreground: Color(0xFFD4D4D4),
    background: Color(0xFF000000),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF0DBC79),
    yellow: Color(0xFFE5E510),
    blue: Color(0xFF2472C8),
    magenta: Color(0xFFBC3FBC),
    cyan: Color(0xFF11A8CD),
    white: Color(0xFFE5E5E5),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFF14C4C),
    brightGreen: Color(0xFF23D18B),
    brightYellow: Color(0xFFF5F543),
    brightBlue: Color(0xFF3B8EEA),
    brightMagenta: Color(0xFFD670D6),
    brightCyan: Color(0xFF29B8DB),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80E8A020),
    searchHitBackgroundCurrent: Color(0xFFE8A020),
    searchHitForeground: Color(0xFF000000),
  );

  // ─── Solarized Dark ─────────────────────────────────────────────
  static const _solarizedDarkTheme = TerminalTheme(
    cursor: Color(0xFF839496),
    selection: Color(0x40268BD2),
    foreground: Color(0xFF839496),
    background: Color(0xFF002B36),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF586E75),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF586E75),
    brightYellow: Color(0xFF657B83),
    brightBlue: Color(0xFF839496),
    brightMagenta: Color(0xFF6C71C4),
    brightCyan: Color(0xFF93A1A1),
    brightWhite: Color(0xFFFDF6E3),
    searchHitBackground: Color(0x80B58900),
    searchHitBackgroundCurrent: Color(0xFFB58900),
    searchHitForeground: Color(0xFF002B36),
  );

  // ─── Monokai ─────────────────────────────────────────────────────
  static const _monokaiTheme = TerminalTheme(
    cursor: Color(0xFFF8F8F0),
    selection: Color(0x4049483E),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF272822),
    black: Color(0xFF272822),
    red: Color(0xFFF92672),
    green: Color(0xFFA6E22E),
    yellow: Color(0xFFF4BF75),
    blue: Color(0xFF66D9EF),
    magenta: Color(0xFFAE81FF),
    cyan: Color(0xFFA1EFE4),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF75715E),
    brightRed: Color(0xFFF92672),
    brightGreen: Color(0xFFA6E22E),
    brightYellow: Color(0xFFF4BF75),
    brightBlue: Color(0xFF66D9EF),
    brightMagenta: Color(0xFFAE81FF),
    brightCyan: Color(0xFFA1EFE4),
    brightWhite: Color(0xFFF9F8F5),
    searchHitBackground: Color(0x80F4BF75),
    searchHitBackgroundCurrent: Color(0xFFF4BF75),
    searchHitForeground: Color(0xFF272822),
  );

  // ─── Dracula ─────────────────────────────────────────────────────
  static const _draculaTheme = TerminalTheme(
    cursor: Color(0xFFF8F8F2),
    selection: Color(0x4044475A),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF282A36),
    black: Color(0xFF21222C),
    red: Color(0xFFFF5555),
    green: Color(0xFF50FA7B),
    yellow: Color(0xFFF1FA8C),
    blue: Color(0xFFBD93F9),
    magenta: Color(0xFFFF79C6),
    cyan: Color(0xFF8BE9FD),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF6272A4),
    brightRed: Color(0xFFFF6E6E),
    brightGreen: Color(0xFF69FF94),
    brightYellow: Color(0xFFFFFFA5),
    brightBlue: Color(0xFFD6ACFF),
    brightMagenta: Color(0xFFFF92DF),
    brightCyan: Color(0xFFA4FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80F1FA8C),
    searchHitBackgroundCurrent: Color(0xFFF1FA8C),
    searchHitForeground: Color(0xFF282A36),
  );

  // ─── Nord ────────────────────────────────────────────────────────
  static const _nordTheme = TerminalTheme(
    cursor: Color(0xFFD8DEE9),
    selection: Color(0x404C566A),
    foreground: Color(0xFFD8DEE9),
    background: Color(0xFF2E3440),
    black: Color(0xFF3B4252),
    red: Color(0xFFBF616A),
    green: Color(0xFFA3BE8C),
    yellow: Color(0xFFEBCB8B),
    blue: Color(0xFF81A1C1),
    magenta: Color(0xFFB48EAD),
    cyan: Color(0xFF88C0D0),
    white: Color(0xFFE5E9F0),
    brightBlack: Color(0xFF4C566A),
    brightRed: Color(0xFFBF616A),
    brightGreen: Color(0xFFA3BE8C),
    brightYellow: Color(0xFFEBCB8B),
    brightBlue: Color(0xFF81A1C1),
    brightMagenta: Color(0xFFB48EAD),
    brightCyan: Color(0xFF8FBCBB),
    brightWhite: Color(0xFFECEFF4),
    searchHitBackground: Color(0x80EBCB8B),
    searchHitBackgroundCurrent: Color(0xFFEBCB8B),
    searchHitForeground: Color(0xFF2E3440),
  );

  // ─── Gruvbox ──────────────────────────────────────────────────
  static const _gruvboxTheme = TerminalTheme(
    cursor: Color(0xFFEBDBB2),
    selection: Color(0x40FE8019),
    foreground: Color(0xFFEBDBB2),
    background: Color(0xFF282828),
    black: Color(0xFF282828),
    red: Color(0xFFCC241D),
    green: Color(0xFF98971A),
    yellow: Color(0xFFD79921),
    blue: Color(0xFF458588),
    magenta: Color(0xFFB16286),
    cyan: Color(0xFF689D6A),
    white: Color(0xFFA89984),
    brightBlack: Color(0xFF928374),
    brightRed: Color(0xFFFB4934),
    brightGreen: Color(0xFFB8BB26),
    brightYellow: Color(0xFFFABD2F),
    brightBlue: Color(0xFF83A598),
    brightMagenta: Color(0xFFD3869B),
    brightCyan: Color(0xFF8EC07C),
    brightWhite: Color(0xFFEBDBB2),
    searchHitBackground: Color(0x80D79921),
    searchHitBackgroundCurrent: Color(0xFFD79921),
    searchHitForeground: Color(0xFF282828),
  );

  // ─── Tokyo Night ──────────────────────────────────────────────
  static const _tokyoNightTheme = TerminalTheme(
    cursor: Color(0xFFC0CAF5),
    selection: Color(0x40364A82),
    foreground: Color(0xFFC0CAF5),
    background: Color(0xFF1A1B26),
    black: Color(0xFF15161E),
    red: Color(0xFFF7768E),
    green: Color(0xFF9ECE6A),
    yellow: Color(0xFFE0AF68),
    blue: Color(0xFF7AA2F7),
    magenta: Color(0xFFBB9AF7),
    cyan: Color(0xFF7DCFFF),
    white: Color(0xFFA9B1D6),
    brightBlack: Color(0xFF414868),
    brightRed: Color(0xFFF7768E),
    brightGreen: Color(0xFF9ECE6A),
    brightYellow: Color(0xFFE0AF68),
    brightBlue: Color(0xFF7AA2F7),
    brightMagenta: Color(0xFFBB9AF7),
    brightCyan: Color(0xFF7DCFFF),
    brightWhite: Color(0xFFC0CAF5),
    searchHitBackground: Color(0x80E0AF68),
    searchHitBackgroundCurrent: Color(0xFFE0AF68),
    searchHitForeground: Color(0xFF1A1B26),
  );

  // ─── Cyberpunk ────────────────────────────────────────────────
  static const _cyberpunkTheme = TerminalTheme(
    cursor: Color(0xFF00FF41),
    selection: Color(0x40FF00FF),
    foreground: Color(0xFF00FF41),
    background: Color(0xFF0D0208),
    black: Color(0xFF0D0208),
    red: Color(0xFFFF003C),
    green: Color(0xFF00FF41),
    yellow: Color(0xFFFFD300),
    blue: Color(0xFF00D4FF),
    magenta: Color(0xFFFF00FF),
    cyan: Color(0xFF00FFFF),
    white: Color(0xFFD0D0D0),
    brightBlack: Color(0xFF333333),
    brightRed: Color(0xFFFF4466),
    brightGreen: Color(0xFF33FF66),
    brightYellow: Color(0xFFFFE033),
    brightBlue: Color(0xFF33DDFF),
    brightMagenta: Color(0xFFFF33FF),
    brightCyan: Color(0xFF33FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80FFD300),
    searchHitBackgroundCurrent: Color(0xFFFFD300),
    searchHitForeground: Color(0xFF0D0208),
  );

  // ─── Synthwave ────────────────────────────────────────────────
  static const _synthwaveTheme = TerminalTheme(
    cursor: Color(0xFFFF7EDB),
    selection: Color(0x40FF7EDB),
    foreground: Color(0xFFF0E4FC),
    background: Color(0xFF2B213A),
    black: Color(0xFF1E1530),
    red: Color(0xFFFE4450),
    green: Color(0xFF72F1B8),
    yellow: Color(0xFFFEDE5D),
    blue: Color(0xFF36F9F6),
    magenta: Color(0xFFFF7EDB),
    cyan: Color(0xFF36F9F6),
    white: Color(0xFFF0E4FC),
    brightBlack: Color(0xFF403353),
    brightRed: Color(0xFFFE4450),
    brightGreen: Color(0xFF72F1B8),
    brightYellow: Color(0xFFFEDE5D),
    brightBlue: Color(0xFF36F9F6),
    brightMagenta: Color(0xFFFF7EDB),
    brightCyan: Color(0xFF36F9F6),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80FEDE5D),
    searchHitBackgroundCurrent: Color(0xFFFEDE5D),
    searchHitForeground: Color(0xFF2B213A),
  );

  // ─── Ocean ────────────────────────────────────────────────────
  static const _oceanTheme = TerminalTheme(
    cursor: Color(0xFF6CB6FF),
    selection: Color(0x40316DCA),
    foreground: Color(0xFFADBEC9),
    background: Color(0xFF0D1117),
    black: Color(0xFF0D1117),
    red: Color(0xFFFF7B72),
    green: Color(0xFF7EE787),
    yellow: Color(0xFFD29922),
    blue: Color(0xFF6CB6FF),
    magenta: Color(0xFFA371F7),
    cyan: Color(0xFF56D4DD),
    white: Color(0xFFADBEC9),
    brightBlack: Color(0xFF484F58),
    brightRed: Color(0xFFFF9B8A),
    brightGreen: Color(0xFF9BF1A0),
    brightYellow: Color(0xFFE3B341),
    brightBlue: Color(0xFF8DCCFF),
    brightMagenta: Color(0xFFBC8CFF),
    brightCyan: Color(0xFF76E3EA),
    brightWhite: Color(0xFFE6EDF3),
    searchHitBackground: Color(0x80D29922),
    searchHitBackgroundCurrent: Color(0xFFD29922),
    searchHitForeground: Color(0xFF0D1117),
  );

  // ─── Citrus (ZestSSH brand) ───────────────────────────────────
  static const _citrusTheme = TerminalTheme(
    cursor: Color(0xFFE8600A),
    selection: Color(0x40E8600A),
    foreground: Color(0xFFFFF0E0),
    background: Color(0xFF1A1008),
    black: Color(0xFF1A1008),
    red: Color(0xFFFF5D3A),
    green: Color(0xFF8CC63F),
    yellow: Color(0xFFFFB830),
    blue: Color(0xFF3DA5D9),
    magenta: Color(0xFFE85DAE),
    cyan: Color(0xFF5BC9B8),
    white: Color(0xFFE8DCC8),
    brightBlack: Color(0xFF5A4D3A),
    brightRed: Color(0xFFFF7F5C),
    brightGreen: Color(0xFFA8D956),
    brightYellow: Color(0xFFFFCC55),
    brightBlue: Color(0xFF5BBAE8),
    brightMagenta: Color(0xFFFF7DC4),
    brightCyan: Color(0xFF7DDDD0),
    brightWhite: Color(0xFFFFF5E8),
    searchHitBackground: Color(0x80FFB830),
    searchHitBackgroundCurrent: Color(0xFFFFB830),
    searchHitForeground: Color(0xFF1A1008),
  );

  // ─── Midnight ────────────────────────────────────────────────────
  // The Midnight app theme's terminal: its navy, its sky blue caret, and its
  // status colours for the ANSI ones. It had none, so "Match terminal to app
  // theme" had nothing to match.
  static const _midnightTheme = TerminalTheme(
    cursor: Color(0xFF5B9CF5),
    selection: Color(0x405B9CF5),
    foreground: Color(0xFFDDE3F0),
    background: Color(0xFF0B1021),
    black: Color(0xFF222C4A),
    red: Color(0xFFE85B6E),
    green: Color(0xFF4EC07A),
    yellow: Color(0xFFE5A840),
    blue: Color(0xFF5B9CF5),
    magenta: Color(0xFFB48CF2),
    cyan: Color(0xFF4FC3D9),
    white: Color(0xFFC2CADC),
    brightBlack: Color(0xFF6C7B9E),
    brightRed: Color(0xFFFF8090),
    brightGreen: Color(0xFF74DA9B),
    brightYellow: Color(0xFFF5C468),
    brightBlue: Color(0xFF82B6FF),
    brightMagenta: Color(0xFFCBAAFF),
    brightCyan: Color(0xFF7ADCEE),
    brightWhite: Color(0xFFF2F5FB),
    searchHitBackground: Color(0x80E5A840),
    searchHitBackgroundCurrent: Color(0xFFE5A840),
    searchHitForeground: Color(0xFF0B1021),
  );

  // ─── Catppuccin Mocha ────────────────────────────────────────────
  // The Catppuccin project's own Mocha palette for terminals
  // (https://catppuccin.com/palette), for the app theme of that name.
  static const _catppuccinMochaTheme = TerminalTheme(
    cursor: Color(0xFFF5E0DC),
    selection: Color(0x66585B70),
    foreground: Color(0xFFCDD6F4),
    background: Color(0xFF1E1E2E),
    black: Color(0xFF45475A),
    red: Color(0xFFF38BA8),
    green: Color(0xFFA6E3A1),
    yellow: Color(0xFFF9E2AF),
    blue: Color(0xFF89B4FA),
    magenta: Color(0xFFF5C2E7),
    cyan: Color(0xFF94E2D5),
    white: Color(0xFFBAC2DE),
    brightBlack: Color(0xFF585B70),
    brightRed: Color(0xFFF38BA8),
    brightGreen: Color(0xFFA6E3A1),
    brightYellow: Color(0xFFF9E2AF),
    brightBlue: Color(0xFF89B4FA),
    brightMagenta: Color(0xFFF5C2E7),
    brightCyan: Color(0xFF94E2D5),
    brightWhite: Color(0xFFA6ADC8),
    searchHitBackground: Color(0x80F9E2AF),
    searchHitBackgroundCurrent: Color(0xFFF9E2AF),
    searchHitForeground: Color(0xFF1E1E2E),
  );

  // ─── One Dark ────────────────────────────────────────────────────
  // Atom's One Dark, as the "Atom One Dark" terminal scheme of the
  // iTerm2-Color-Schemes collection has it, on the editor's own background
  // (#282C34) with Atom's blue caret.
  static const _oneDarkTheme = TerminalTheme(
    cursor: Color(0xFF528BFF),
    selection: Color(0x40ABB2BF),
    foreground: Color(0xFFABB2BF),
    background: Color(0xFF282C34),
    black: Color(0xFF21252B),
    red: Color(0xFFE06C75),
    green: Color(0xFF98C379),
    yellow: Color(0xFFE5C07B),
    blue: Color(0xFF61AFEF),
    magenta: Color(0xFFC678DD),
    cyan: Color(0xFF56B6C2),
    white: Color(0xFFABB2BF),
    brightBlack: Color(0xFF767676),
    brightRed: Color(0xFFE06C75),
    brightGreen: Color(0xFF98C379),
    brightYellow: Color(0xFFE5C07B),
    brightBlue: Color(0xFF61AFEF),
    brightMagenta: Color(0xFFC678DD),
    brightCyan: Color(0xFF56B6C2),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80E5C07B),
    searchHitBackgroundCurrent: Color(0xFFE5C07B),
    searchHitForeground: Color(0xFF282C34),
  );

  // ─── One Light ───────────────────────────────────────────────────
  // Atom's One Light, as the "Atom One Light" terminal scheme has it. That
  // scheme repeats green for cyan and black for bright black; those two are
  // the cyan and the comment grey of Atom's own One Light syntax colours.
  static const _oneLightTheme = TerminalTheme(
    cursor: Color(0xFF526FFF),
    selection: Color(0x402F5AF3),
    foreground: Color(0xFF2A2C33),
    background: Color(0xFFF9F9F9),
    black: Color(0xFF000000),
    red: Color(0xFFDE3E35),
    green: Color(0xFF3F953A),
    yellow: Color(0xFFD2B67C),
    blue: Color(0xFF2F5AF3),
    magenta: Color(0xFF950095),
    cyan: Color(0xFF0184BC),
    white: Color(0xFFBBBBBB),
    brightBlack: Color(0xFFA0A1A7),
    brightRed: Color(0xFFDE3E35),
    brightGreen: Color(0xFF3F953A),
    brightYellow: Color(0xFFD2B67C),
    brightBlue: Color(0xFF2F5AF3),
    brightMagenta: Color(0xFFA00095),
    brightCyan: Color(0xFF0184BC),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80D2B67C),
    searchHitBackgroundCurrent: Color(0xFFD2B67C),
    searchHitForeground: Color(0xFF2A2C33),
  );

  // ─── Darcula ─────────────────────────────────────────────────────
  // The JetBrains IDEs' classic dark scheme, in the console colours of the
  // IDE's own Darcula scheme: its sixteen colours, on the editor's
  // background (#2B2B2B) with the console's text (#BBBBBB). (It had the
  // colours of a community terminal scheme of that name, which are not the
  // IDE's.) Its black is black and its white a grey, as in the IDE.
  static const _darculaTheme = TerminalTheme(
    cursor: Color(0xFFBBBBBB),
    selection: Color(0x802F65CA),
    foreground: Color(0xFFBBBBBB),
    background: Color(0xFF2B2B2B),
    black: Color(0xFF000000),
    red: Color(0xFFF0524F),
    green: Color(0xFF5C962C),
    yellow: Color(0xFFA68A0D),
    blue: Color(0xFF3993D4),
    magenta: Color(0xFFA771BF),
    cyan: Color(0xFF00A3A3),
    white: Color(0xFF808080),
    brightBlack: Color(0xFF595959),
    brightRed: Color(0xFFFF4050),
    brightGreen: Color(0xFF4FC414),
    brightYellow: Color(0xFFE5BF00),
    brightBlue: Color(0xFF1FB0FF),
    brightMagenta: Color(0xFFED7EED),
    brightCyan: Color(0xFF00E5E5),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80A68A0D),
    searchHitBackgroundCurrent: Color(0xFFE5BF00),
    searchHitForeground: Color(0xFF2B2B2B),
  );

  // ─── IntelliJ Dark ───────────────────────────────────────────────
  // The dark scheme of the JetBrains IDEs' current interface: its editor's
  // background (#1E1F22), text (#BCBEC4) and caret (#CED0D6), with the
  // sixteen console colours it takes from Darcula.
  static const _intellijDarkTheme = TerminalTheme(
    cursor: Color(0xFFCED0D6),
    selection: Color(0x80375FAD),
    foreground: Color(0xFFBCBEC4),
    background: Color(0xFF1E1F22),
    black: Color(0xFF000000),
    red: Color(0xFFF0524F),
    green: Color(0xFF5C962C),
    yellow: Color(0xFFA68A0D),
    blue: Color(0xFF3993D4),
    magenta: Color(0xFFA771BF),
    cyan: Color(0xFF00A3A3),
    white: Color(0xFF808080),
    brightBlack: Color(0xFF595959),
    brightRed: Color(0xFFFF4050),
    brightGreen: Color(0xFF4FC414),
    brightYellow: Color(0xFFE5BF00),
    brightBlue: Color(0xFF1FB0FF),
    brightMagenta: Color(0xFFED7EED),
    brightCyan: Color(0xFF00E5E5),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0x80A68A0D),
    searchHitBackgroundCurrent: Color(0xFFE5BF00),
    searchHitForeground: Color(0xFF1E1F22),
  );

  // ─── IntelliJ Light ──────────────────────────────────────────────
  // The light scheme of the JetBrains IDEs: white, the editor's text
  // (#080808) and selection (#A6D2FF), and the sixteen console colours of
  // the IDE's default scheme.
  static const _intellijLightTheme = TerminalTheme(
    cursor: Color(0xFF000000),
    selection: Color(0xB3A6D2FF),
    foreground: Color(0xFF080808),
    background: Color(0xFFFFFFFF),
    black: Color(0xFF000000),
    red: Color(0xFFCE0505),
    green: Color(0xFF067D17),
    yellow: Color(0xFFB28C00),
    blue: Color(0xFF063FDB),
    magenta: Color(0xFFB309B3),
    cyan: Color(0xFF028E8E),
    white: Color(0xFF929292),
    brightBlack: Color(0xFF656565),
    brightRed: Color(0xFFFF1616),
    brightGreen: Color(0xFF16B42C),
    brightYellow: Color(0xFFECC32C),
    brightBlue: Color(0xFF2D61F0),
    brightMagenta: Color(0xFFE617E6),
    brightCyan: Color(0xFF15C1C1),
    brightWhite: Color(0xFFC9C9C9),
    searchHitBackground: Color(0x80ECC32C),
    searchHitBackgroundCurrent: Color(0xFFECC32C),
    searchHitForeground: Color(0xFF080808),
  );
}
