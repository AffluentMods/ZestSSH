import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/themes.dart';

/// Palette index 15 is the theme's bright white (it drew as plain white, so
/// bright white text and backgrounds looked like ordinary white: upstream
/// xterm.dart d35ba2cc72); the other fifteen of the first sixteen keep their
/// colours.
void main() {
  test('index 15 is bright white, 7 plain white', () {
    const theme = TerminalThemes.defaultTheme;
    final palette = PaletteBuilder(theme).build();
    expect(palette[7], theme.white);
    expect(palette[15], theme.brightWhite);
    expect(palette[15], isNot(palette[7]));
    expect(palette[8], theme.brightBlack);
  });
}
