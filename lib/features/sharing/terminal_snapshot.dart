/// Session sharing (3.0): what a viewer who joins a live view part-way needs
/// to see exactly what the sharer sees: the terminal's screen as escape
/// sequences that rebuild it (text, colours, attributes, wide characters,
/// the cursor, the modes that change what keys send), with recent
/// scrollback before it on the main screen. Written into a terminal of the
/// same size, it reproduces the screen cell for cell.
library;

import 'package:xterm/xterm.dart';

/// At most this many lines of scrollback go before the screen.
const kSnapshotScrollback = 500;

/// [terminal]'s screen (and up to [scrollback] lines above it on the main
/// screen) as escape sequences for an empty terminal of the same size.
String terminalSnapshot(Terminal terminal, {int scrollback = kSnapshotScrollback}) {
  final out = StringBuffer();
  // A clean slate: reset attributes, origin mode off, main screen, the
  // whole of it scrolling, home, clear.
  out.write('\x1b[0m\x1b[?6l\x1b[?1049l\x1b[r\x1b[H\x1b[2J\x1b[3J');
  final buffer = terminal.buffer;
  final rows = terminal.viewHeight;
  final alt = terminal.isUsingAltBuffer;
  final pen = _Pen();

  if (alt) {
    out.write('\x1b[?1049h\x1b[r\x1b[H\x1b[2J');
    for (var y = 0; y < rows; y++) {
      out.write('\x1b[${y + 1};1H');
      _line(out, buffer.lines[buffer.scrollBack + y], pen, terminal.viewWidth);
    }
  } else {
    final last = buffer.height - 1;
    final first = (buffer.scrollBack - scrollback).clamp(0, buffer.height);
    for (var i = first; i <= last; i++) {
      // A row that wraps onto the next is written in full, so the next
      // carries on from its first column by itself.
      final wraps = i < last && buffer.lines[i + 1].isWrapped;
      _line(out, buffer.lines[i], pen, terminal.viewWidth, full: wraps);
      if (i < last && !wraps) out.write('\r\n');
    }
  }
  out.write('\x1b[0m');
  // The scroll region a program set (apt keeps its progress bar on the last
  // row with one above it; tmux its status line), so what it writes next
  // scrolls the same rows for the viewer as for the sharer.
  if (buffer.marginTop != 0 || buffer.marginBottom != rows - 1) {
    out.write('\x1b[${buffer.marginTop + 1};${buffer.marginBottom + 1}r');
  }
  // Origin mode, then the cursor where it is on the screen (counted from
  // the region's top while origin mode is on).
  final origin = terminal.originMode;
  if (origin) out.write('\x1b[?6h');
  out.write('\x1b[${buffer.cursorY - (origin ? buffer.marginTop : 0) + 1};${buffer.cursorX + 1}H');
  // Modes that change what the viewer's keys send or what is drawn.
  out.write(terminal.cursorKeysMode ? '\x1b[?1h' : '\x1b[?1l');
  out.write(terminal.appKeypadMode ? '\x1b=' : '\x1b>');
  out.write(terminal.bracketedPasteMode ? '\x1b[?2004h' : '\x1b[?2004l');
  out.write(terminal.autoWrapMode ? '\x1b[?7h' : '\x1b[?7l');
  out.write(terminal.cursorVisibleMode ? '\x1b[?25h' : '\x1b[?25l');
  return out.toString();
}

/// The pen (attributes and colours) last written, so a run of cells with the
/// same look writes its escape once.
class _Pen {
  int fg = 0;
  int bg = 0;
  int attrs = 0;
}

void _line(StringBuffer out, BufferLine line, _Pen pen, int width, {bool full = false}) {
  // Up to the last cell that shows anything: text, or a background colour.
  var end = line.length < width ? line.length : width;
  while (!full && end > 0 && line.getCodePoint(end - 1) == 0 && line.getBackground(end - 1) == 0 && line.getAttributes(end - 1) & CellAttr.inverse == 0) {
    end--;
  }
  var skip = 0;
  for (var x = 0; x < end; x++) {
    final width = line.getWidth(x);
    // The second half of a wide character is drawn with the first.
    if (width == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
    // Cells never written stay empty: moved over, not filled with spaces.
    // Not on a row wrapped from the one above: a cursor move there would
    // cancel the wrap the next character is waiting for.
    if (!line.isWrapped && line.getCodePoint(x) == 0 && line.getBackground(x) == 0 && line.getAttributes(x) == 0) {
      skip++;
      continue;
    }
    if (skip > 0) {
      out.write('\x1b[${skip}C');
      skip = 0;
    }
    final fg = line.getForeground(x);
    final bg = line.getBackground(x);
    final attrs = line.getAttributes(x);
    if (fg != pen.fg || bg != pen.bg || attrs != pen.attrs) {
      out.write(_sgr(fg, bg, attrs));
      pen
        ..fg = fg
        ..bg = bg
        ..attrs = attrs;
    }
    final cp = line.getCodePoint(x);
    out.writeCharCode(cp == 0 ? 0x20 : cp);
  }
}

String _sgr(int fg, int bg, int attrs) {
  final codes = <String>['0'];
  if (attrs & CellAttr.bold != 0) codes.add('1');
  if (attrs & CellAttr.faint != 0) codes.add('2');
  if (attrs & CellAttr.italic != 0) codes.add('3');
  if (attrs & CellAttr.underline != 0) codes.add('4');
  if (attrs & CellAttr.blink != 0) codes.add('5');
  if (attrs & CellAttr.inverse != 0) codes.add('7');
  if (attrs & CellAttr.invisible != 0) codes.add('8');
  if (attrs & CellAttr.strikethrough != 0) codes.add('9');
  codes.addAll(_color(fg, background: false));
  codes.addAll(_color(bg, background: true));
  return '\x1b[${codes.join(';')}m';
}

List<String> _color(int color, {required bool background}) {
  final value = color & CellColor.valueMask;
  switch (color & CellColor.typeMask) {
    case CellColor.named:
      if (value < 8) return ['${(background ? 40 : 30) + value}'];
      return ['${(background ? 100 : 90) + value - 8}'];
    case CellColor.palette:
      return [background ? '48' : '38', '5', '$value'];
    case CellColor.rgb:
      return [background ? '48' : '38', '2', '${(value >> 16) & 0xff}', '${(value >> 8) & 0xff}', '${value & 0xff}'];
    default:
      return const [];
  }
}
