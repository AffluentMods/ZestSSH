import 'dart:ui';
import 'package:flutter/painting.dart';

import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy + _cellSize.height - 1),
          Offset(offset.dx + _cellSize.width, offset.dy + _cellSize.height - 1),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy),
          Offset(offset.dx, offset.dy + _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;

    if (!_textStyle.enableLigatures) {
      // Legacy per-cell paint - byte-identical to before the ligature feature.
      for (var i = 0; i < line.length; i++) {
        line.getCellData(i, cellData);

        final charWidth = cellData.content >> CellContent.widthShift;
        final cellOffset = offset.translate(i * cellWidth, 0);

        paintCell(canvas, cellOffset, cellData);

        if (charWidth == 2) {
          i++;
        }
      }
      return;
    }

    _paintLineLigated(canvas, offset, line, cellData, cellWidth);
  }

  /// Ligature paint path (opt-in). Backgrounds stay per-cell; FOREGROUND glyphs
  /// are batched into contiguous runs that share style and are printable ASCII
  /// (0x21..0x7E) + single-width, so OpenType calt/liga combine `!=`/`->`/`=>`
  /// across the cell boundary. Everything else - spaces, blanks, wide/CJK cells,
  /// or a style change - flushes the run and falls back to the exact per-cell
  /// [paintCellForeground] (which also keeps the space-underline workaround and
  /// non-monospace fallback glyphs correct). Restricting runs to ASCII avoids
  /// the fallback-advance drift that would push a run off the character grid.
  void _paintLineLigated(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    CellData cellData,
    double cellWidth,
  ) {
    const styleMask = CellFlags.bold |
        CellFlags.italic |
        CellFlags.underline |
        CellFlags.inverse |
        CellFlags.faint;

    final runChars = <int>[];
    var runStartCol = 0;
    var runFg = 0;
    var runBg = 0;
    var runStyleFlags = 0;

    void flushRun() {
      if (runChars.isEmpty) return;
      final runStr = String.fromCharCodes(runChars);

      var color = runStyleFlags & CellFlags.inverse == 0
          ? resolveForegroundColor(runFg)
          : resolveBackgroundColor(runBg);
      if (runStyleFlags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: runStyleFlags & CellFlags.bold != 0,
        italic: runStyleFlags & CellFlags.italic != 0,
        underline: runStyleFlags & CellFlags.underline != 0,
      );

      final key = Object.hash(runStr, color, runStyleFlags, _textScaler);
      var paragraph = _paragraphCache.getLayoutFromCache(key);
      paragraph ??= _paragraphCache.performAndCacheLayout(
        runStr,
        style,
        _textScaler,
        key,
      );
      canvas.drawParagraph(
        paragraph,
        offset.translate(runStartCol * cellWidth, 0),
      );
      runChars.clear();
    }

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final charCode = cellData.content & CellContent.codepointMask;
      final cellOffset = offset.translate(i * cellWidth, 0);

      // Background is always per-cell (backgrounds never ligate).
      paintCellBackground(canvas, cellOffset, cellData);

      final batchable = charWidth == 1 && charCode >= 0x21 && charCode <= 0x7E;
      if (batchable) {
        final fg = cellData.foreground;
        final bg = cellData.background;
        final sf = cellData.flags & styleMask;
        if (runChars.isNotEmpty &&
            (fg != runFg || bg != runBg || sf != runStyleFlags)) {
          flushRun();
        }
        if (runChars.isEmpty) {
          runStartCol = i;
          runFg = fg;
          runBg = bg;
          runStyleFlags = sf;
        }
        runChars.add(charCode);
      } else {
        flushRun();
        paintCellForeground(canvas, cellOffset, cellData);
        if (charWidth == 2) {
          i++;
        }
      }
    }
    flushRun();
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;

      var color = cellFlags & CellFlags.inverse == 0
          ? resolveForegroundColor(cellData.foreground)
          : resolveBackgroundColor(cellData.background);

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    if (_isPrivateUse(charCode) &&
        cellData.content >> CellContent.widthShift == 1 &&
        _paintFitted(canvas, offset, paragraph, charCode)) {
      return;
    }
    canvas.drawParagraph(paragraph, offset);
  }

  /// Nerd Font icons and powerline separators are Private Use Area code
  /// points (U+E000 to U+F8FF, and planes 15 and 16), one cell each. Most come
  /// from a fallback font whose glyphs are one em wide (the app's Symbols Nerd
  /// Font Mono), wider than a cell (0.6 em in JetBrains Mono): drawn as they
  /// are they would cover the next cell. Such a glyph is drawn to fit its
  /// cell, as a font patched as a "Nerd Font Mono" draws it: a powerline
  /// separator stretched over the whole cell, so a prompt's coloured segments
  /// meet it with no gap above or below, and any other icon scaled down whole
  /// and centred in the cell. A glyph no wider than the cell (a terminal
  /// font's own powerline arrows) is drawn as before. Returns whether it drew.
  bool _paintFitted(
    Canvas canvas,
    Offset offset,
    Paragraph paragraph,
    int charCode,
  ) {
    final advance = paragraph.maxIntrinsicWidth;
    final cellWidth = _cellSize.width;
    if (advance <= cellWidth + 0.5) return false;

    // The glyph's font box, its ascent above the baseline to its descent
    // below, as the font that drew it has them (a tight box is the run's own
    // font's, not the line's). Symbols Nerd Font Mono's ascent and descent
    // are its em, the square its glyphs are drawn in.
    final boxes = paragraph.getBoxesForRange(
      0,
      charCode > 0xFFFF ? 2 : 1,
      boxHeightStyle: BoxHeightStyle.tight,
    );
    if (boxes.isEmpty) return false;
    final top = boxes.first.top;
    final height = boxes.first.bottom - top;
    if (height <= 0) return false;

    canvas.save();
    if (_isPowerlineSeparator(charCode)) {
      canvas.translate(offset.dx, offset.dy);
      canvas.scale(cellWidth / advance, _cellSize.height / height);
      canvas.translate(0, -top);
    } else {
      final scale = cellWidth / advance;
      canvas.translate(offset.dx, offset.dy + _cellSize.height / 2);
      canvas.scale(scale, scale);
      canvas.translate(0, -(top + height / 2));
    }
    canvas.drawParagraph(paragraph, Offset.zero);
    canvas.restore();
    return true;
  }

  @pragma('vm:prefer-inline')
  static bool _isPrivateUse(int c) =>
      (c >= 0xE000 && c <= 0xF8FF) || c >= 0xF0000;

  /// The powerline separators that join a prompt's segments: triangles,
  /// half circles and slants (U+E0B0 to U+E0BF), flames and pixels (U+E0C0 to
  /// U+E0C7), trapezoids (U+E0D2, U+E0D4) and inverted triangles (U+E0D6,
  /// U+E0D7). The branch, line and lock signs (U+E0A0 to U+E0A3) and the
  /// waveform, honeycomb and blocks are icons, scaled whole.
  static bool _isPowerlineSeparator(int c) =>
      (c >= 0xE0B0 && c <= 0xE0C7) ||
      c == 0xE0D2 ||
      c == 0xE0D4 ||
      c == 0xE0D6 ||
      c == 0xE0D7;

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
