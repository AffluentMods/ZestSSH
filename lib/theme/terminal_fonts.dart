/// The fonts a terminal falls back to for a character its own font does not
/// have.
library;

/// Nerd Fonts' "Symbols Only" font, bundled: Symbols Nerd Font Mono from the
/// Nerd Fonts v3.5.1 release, its character map limited to the Private Use
/// Area (tool/nerd_font_pua_only.py; licences in third_party/symbols-nerd-font).
///
/// Prompts and tools such as Starship, oh-my-posh, Powerlevel10k, eza, lsd and
/// lazygit draw powerline separators and file icons with code points in
/// Unicode's Private Use Area (U+E000 to U+F8FF, and from U+F0000 for Material
/// Design's icons). None of the terminal fonts the app has is a Nerd Font, so
/// these were boxes. In [kTerminalFontFallback] they draw in every terminal
/// font on every platform: Flutter looks a character up in the listed
/// families before it asks the system. As the font answers for the Private
/// Use Area alone, every other character is drawn as it was.
///
/// The Mono font's glyphs are one em wide, wider than a terminal cell: the
/// terminal draws such a glyph to fit its one cell (xterm's
/// TerminalPainter.paintCellForeground).
const String kNerdFontSymbolsFamily = 'SymbolsNerdFontMono';

/// What every terminal falls back to, in order, after the font picked in
/// Settings: the CJK and emoji fonts a system may have, the generic
/// monospace and sans-serif, then the bundled Nerd Font symbols. A terminal
/// font's own powerline arrows (JetBrains Mono, Fira Code, Source Code Pro
/// and Hack have U+E0A0 to U+E0B3) are still drawn from that font.
const List<String> kTerminalFontFallback = [
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
  kNerdFontSymbolsFamily,
];
