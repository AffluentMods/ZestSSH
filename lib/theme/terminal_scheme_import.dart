import 'dart:convert';

import 'package:flutter/material.dart';

/// The file types [parseTerminalScheme] reads, for a file picker's filter:
/// JSON (Windows Terminal, VS Code), iTerm2's own, and X resources by the
/// names those files go by (both spellings: Linux's filter minds the case).
const List<String> kTerminalSchemeFileExtensions = [
  'json',
  'itermcolors',
  'xrdb',
  'Xresources',
  'xresources',
  'Xdefaults',
  'xdefaults',
];

/// Parses a terminal colour scheme exported from another emulator into the
/// 20-key colour map the custom terminal-theme builder uses
/// (`background`, `foreground`, `cursor`, `selection`, the 8 ANSI colours, and
/// the 8 bright variants).
///
/// Supported formats, auto-detected from the file contents:
///   * Windows Terminal / VS Code JSON scheme fragments
///   * iTerm2 `.itermcolors` (XML plist)
///   * xrdb / X resources (`*.color0:` style)
///
/// Returns null if the content matches none of them. No external packages are
/// used - each parser is deliberately tolerant and best-effort, because these
/// files come from many tools and hand edits.
Map<String, Color>? parseTerminalScheme(String content) {
  final trimmed = content.trimLeft();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    final m = _parseWindowsTerminal(content);
    if (m != null) return m;
  }
  if (content.contains('Ansi 0 Color') || content.contains('<plist')) {
    final m = _parseIterm(content);
    if (m != null) return m;
  }
  return _parseXrdb(content);
}

/// The ordered keys the builder expects. Import always returns exactly these.
const List<String> _schemeKeys = [
  'background', 'foreground', 'cursor', 'selection', //
  'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white', //
  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', //
  'brightBlue', 'brightMagenta', 'brightCyan', 'brightWhite', //
];

// ── Windows Terminal / VS Code JSON ────────────────────────────────

Map<String, Color>? _parseWindowsTerminal(String content) {
  try {
    final decoded = jsonDecode(content);
    // A VS Code themes array or a WT settings object: dig for the first object
    // that carries the tell-tale ANSI keys.
    final obj = _findSchemeObject(decoded);
    if (obj == null) return null;

    Color? c(String key) {
      final v = obj[key];
      return v is String ? _hex(v) : null;
    }

    final bg = c('background');
    final fg = c('foreground');
    final black = c('black');
    // Windows Terminal names magenta "purple".
    final magenta = c('magenta') ?? c('purple');
    if (bg == null || fg == null || black == null || magenta == null) {
      return null;
    }

    return {
      'background': bg,
      'foreground': fg,
      'cursor': c('cursorColor') ?? c('cursor') ?? fg,
      'selection':
          c('selectionBackground') ?? c('selection') ?? _blend(fg, bg, 0.3),
      'black': black,
      'red': c('red') ?? black,
      'green': c('green') ?? black,
      'yellow': c('yellow') ?? black,
      'blue': c('blue') ?? black,
      'magenta': magenta,
      'cyan': c('cyan') ?? black,
      'white': c('white') ?? fg,
      'brightBlack': c('brightBlack') ?? black,
      'brightRed': c('brightRed') ?? c('red') ?? black,
      'brightGreen': c('brightGreen') ?? c('green') ?? black,
      'brightYellow': c('brightYellow') ?? c('yellow') ?? black,
      'brightBlue': c('brightBlue') ?? c('blue') ?? black,
      'brightMagenta': c('brightPurple') ?? c('brightMagenta') ?? magenta,
      'brightCyan': c('brightCyan') ?? c('cyan') ?? black,
      'brightWhite': c('brightWhite') ?? c('white') ?? fg,
    };
  } catch (_) {
    return null;
  }
}

/// Find the first map holding ANSI colour keys, whether the JSON is the scheme
/// object itself, a `{schemes:[...]}` wrapper, or a VS Code themes array.
Map<String, dynamic>? _findSchemeObject(dynamic node) {
  if (node is Map<String, dynamic>) {
    if (node.containsKey('black') &&
        (node.containsKey('background') || node.containsKey('foreground'))) {
      return node;
    }
    // Some VS Code exports nest under "colors" with "terminal.ansiBlack" keys.
    for (final v in node.values) {
      final found = _findSchemeObject(v);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final v in node) {
      final found = _findSchemeObject(v);
      if (found != null) return found;
    }
  }
  return null;
}

// ── iTerm2 .itermcolors (XML plist) ────────────────────────────────

Map<String, Color>? _parseIterm(String content) {
  // Each colour is a <key>NAME</key><dict>...Red/Green/Blue Component...</dict>.
  final blockRe = RegExp(
    r'<key>([^<]+)</key>\s*<dict>(.*?)</dict>',
    dotAll: true,
  );
  double? comp(String body, String name) {
    final m = RegExp(
      '<key>$name Component</key>\\s*<real>([-0-9.eE+]+)</real>',
    ).firstMatch(body);
    if (m == null) return null;
    return double.tryParse(m.group(1)!);
  }

  final out = <String, Color>{};
  for (final block in blockRe.allMatches(content)) {
    final name = block.group(1)!.trim();
    final body = block.group(2)!;
    final r = comp(body, 'Red');
    final g = comp(body, 'Green');
    final b = comp(body, 'Blue');
    if (r == null || g == null || b == null) continue;
    final color = Color.fromARGB(
      255,
      (r.clamp(0.0, 1.0) * 255).round(),
      (g.clamp(0.0, 1.0) * 255).round(),
      (b.clamp(0.0, 1.0) * 255).round(),
    );
    final key = _itermKey(name);
    if (key != null) out[key] = color;
  }

  if (!out.containsKey('background') ||
      !out.containsKey('foreground') ||
      !out.containsKey('black')) {
    return null;
  }
  return _fill(out);
}

String? _itermKey(String name) {
  const ansi = [
    'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white', //
  ];
  final ansiMatch = RegExp(r'^Ansi (\d+) Color$').firstMatch(name);
  if (ansiMatch != null) {
    final n = int.parse(ansiMatch.group(1)!);
    if (n >= 0 && n < 8) return ansi[n];
    if (n >= 8 && n < 16) {
      final base = ansi[n - 8];
      return 'bright${base[0].toUpperCase()}${base.substring(1)}';
    }
    return null;
  }
  switch (name) {
    case 'Foreground Color':
      return 'foreground';
    case 'Background Color':
      return 'background';
    case 'Cursor Color':
      return 'cursor';
    case 'Selection Color':
      return 'selection';
    default:
      return null;
  }
}

// ── xrdb / X resources ─────────────────────────────────────────────

Map<String, Color>? _parseXrdb(String content) {
  final out = <String, Color>{};
  final lineRe = RegExp(
    r'(?:^|[.*])(foreground|background|cursorColor|colorBG|colorFG|color(\d+))\s*:\s*(#?[0-9A-Fa-f]{6})',
    multiLine: true,
  );
  const ansi = [
    'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white', //
  ];
  for (final m in lineRe.allMatches(content)) {
    final name = m.group(1)!;
    final numStr = m.group(2);
    final hex = _hex(m.group(3)!);
    if (hex == null) continue;
    if (numStr != null) {
      final n = int.parse(numStr);
      if (n >= 0 && n < 8) {
        out[ansi[n]] = hex;
      } else if (n >= 8 && n < 16) {
        final base = ansi[n - 8];
        out['bright${base[0].toUpperCase()}${base.substring(1)}'] = hex;
      }
    } else if (name == 'foreground' || name == 'colorFG') {
      out['foreground'] = hex;
    } else if (name == 'background' || name == 'colorBG') {
      out['background'] = hex;
    } else if (name == 'cursorColor') {
      out['cursor'] = hex;
    }
  }

  if (!out.containsKey('background') ||
      !out.containsKey('foreground') ||
      !out.containsKey('black')) {
    return null;
  }
  return _fill(out);
}

// ── Shared helpers ─────────────────────────────────────────────────

/// Backfill any missing key so the builder always gets all 20, deriving
/// sensible fallbacks from what was present.
Map<String, Color> _fill(Map<String, Color> partial) {
  final fg = partial['foreground'] ?? const Color(0xFFD6D3CA);
  final bg = partial['background'] ?? const Color(0xFF0B0B0D);
  final out = <String, Color>{};
  for (final key in _schemeKeys) {
    var c = partial[key];
    if (c == null) {
      if (key == 'cursor') {
        c = fg;
      } else if (key == 'selection') {
        c = _blend(fg, bg, 0.3);
      } else if (key.startsWith('bright')) {
        // Fall back a bright slot to its normal sibling.
        final base = key.substring(6);
        final normal = '${base[0].toLowerCase()}${base.substring(1)}';
        c = partial[normal] ?? fg;
      } else {
        c = fg;
      }
    }
    out[key] = c;
  }
  return out;
}

/// Parse `#RRGGBB`, `RRGGBB`, or `0xRRGGBB` into an opaque [Color].
Color? _hex(String raw) {
  var h = raw.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
  if (h.length == 8) h = h.substring(2); // drop a leading alpha byte
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Mix [a] toward [b] by [t] (0..1). Used for a fallback selection colour.
Color _blend(Color a, Color b, double t) {
  return Color.lerp(a, b, t) ?? a;
}
