"""Makes the app's copy of Nerd Fonts' Symbols Nerd Font Mono: the release's font with its
character map limited to Unicode's Private Use Area. Nothing else in the font changes: every glyph,
outline, metric and name stays as the release has it; only the code points outside the Private
Use Area stop pointing at their glyphs (the 14 characters below, and the release's entries for the
control codes U+0000, U+0008, U+0009, U+000D and U+001D, which a terminal never draws).

Why: the font is the terminal's last fallback (lib/theme/terminal_fonts.dart) for the powerline
separators and icons prompts draw from the Private Use Area. It also maps 14 ordinary characters
(power signs U+23FB to U+23FE and U+2B58, U+2630, U+2665, U+26A1, angle brackets U+276C to U+2771).
Flutter takes a listed fallback before the system's fonts, so with those mapped a prompt's
U+276F (Starship's and Pure's prompt sign) in Fira Code, Source Code Pro or the system's monospace
font, which lack it, would change from the system's own symbol font to this one. Limited to the
Private Use Area, the font draws only what no other font in the list means.

Usage (fontTools must be installed: pip install fonttools):

    python -I tool/nerd_font_pua_only.py <release SymbolsNerdFontMono-Regular.ttf> \\
        assets/fonts/SymbolsNerdFontMono-Regular.ttf

The release (v3.5.1) font's SHA-256 is fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749
(from NerdFontsSymbolsOnly.zip, SHA-256 fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc,
as the release's SHA-256.txt gives it). test/terminal/nerd_font_symbols_test.dart holds the
bundled file to the result.
"""
import hashlib
import sys

from fontTools.ttLib import TTFont

RELEASE_SHA256 = 'fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749'


def is_private_use(cp):
    return 0xE000 <= cp <= 0xF8FF or 0xF0000 <= cp <= 0xFFFFD or 0x100000 <= cp <= 0x10FFFD


def main(src, dst):
    with open(src, 'rb') as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != RELEASE_SHA256:
        sys.exit('not the v3.5.1 release font: SHA-256 %s' % digest)
    font = TTFont(src)
    removed = set()
    for table in font['cmap'].tables:
        for cp in [cp for cp in table.cmap if not is_private_use(cp)]:
            removed.add(cp)
            del table.cmap[cp]
    font.save(dst)
    print('removed', ' '.join('U+%04X' % cp for cp in sorted(removed)))
    with open(dst, 'rb') as f:
        print('wrote', dst, hashlib.sha256(f.read()).hexdigest())


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
