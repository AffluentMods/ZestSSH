import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Real full-screen programs, replayed. Each fixture is what vim, nano or
/// less actually sent to a terminal of a fixed size while it was scrolled one
/// step at a time (recorded with TERM=xterm-256color, which is what the app
/// announces), and after every step the program was told to repaint the
/// whole screen. A repaint draws the same screen from scratch, so the screen
/// the emulator shows after the step itself (drawn with scroll regions,
/// inserted and deleted lines) must equal the screen after the repaint, cell
/// for cell and colour for colour. And every row must still be able to hold
/// a selection (highlighting broke in
/// vim and nano after a scroll).
///
/// Fixtures: test/terminal/fixtures/*.json, made by tool/terminal/capture.py.

class _Capture {
  _Capture(this.name, this.rows, this.cols, this.segments);

  final String name;
  final int rows;
  final int cols;
  final List<({String label, String kind, List<int> data})> segments;

  static _Capture load(File file) {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return _Capture(
      json['name'] as String,
      json['rows'] as int,
      json['cols'] as int,
      [
        for (final s in json['segments'] as List)
          (
            label: s['label'] as String,
            kind: s['kind'] as String,
            data: base64Decode(s['data'] as String),
          ),
      ],
    );
  }
}

/// What one cell looks like: the character, the colour behind it, and (when
/// there is something to draw) the colour and style it is drawn in. An empty
/// cell and a space look the same.
String _look(BufferLine line, int x) {
  final code = line.getCodePoint(x);
  final flags = line.getAttributes(x);
  final inverse = flags & CellAttr.inverse != 0;
  final fg = line.getForeground(x);
  final bg = line.getBackground(x);
  final behind = inverse ? 'f$fg' : 'b$bg';
  final blank = code == 0 || code == 0x20;
  final marks = flags & (CellAttr.underline | CellAttr.strikethrough);
  if (blank && marks == 0) return ' |$behind';
  final ink = inverse ? 'b$bg' : 'f$fg';
  return '${String.fromCharCode(code == 0 ? 0x20 : code)}|$behind|$ink|'
      '${flags & ~CellAttr.inverse}';
}

List<List<String>> _screenOf(Terminal t) => [
      for (var y = 0; y < t.viewHeight; y++)
        [
          for (var x = 0; x < t.viewWidth; x++)
            _look(t.buffer.lines[t.buffer.scrollBack + y], x),
        ],
    ];

String _text(Terminal t, int y) =>
    t.buffer.lines[t.buffer.scrollBack + y].getText().trimRight();

/// Rows whose content is a message of the moment, which a repaint is allowed
/// to change: vim's command line and less's prompt (the last row), and nano's
/// status bar (third from the bottom).
Set<int> _messageRows(_Capture c) {
  if (c.name.startsWith('nano')) return {c.rows - 3};
  return {c.rows - 1};
}

void main() {
  final dir = Directory(Platform.environment['ZEST_REPLAY_DIR'] ??
      'test/terminal/fixtures');
  final files = dir.existsSync()
      ? (dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  test('there are recorded sessions to replay', () {
    expect(files, isNotEmpty, reason: 'no fixtures in ${dir.path}');
  });

  for (final file in files) {
    final capture = _Capture.load(file);
    test('${capture.name}: every step looks like its repaint, and every row '
        'can be selected', () {
      final t = Terminal(maxLines: 2000);
      t.resize(capture.cols, capture.rows);
      final problems = <String>[];
      List<List<String>>? afterStep;
      List<String>? textAfterStep;
      for (final segment in capture.segments) {
        t.write(utf8.decode(segment.data, allowMalformed: true));

        // Every row on screen is in the buffer and knows where.
        for (var y = 0; y < t.viewHeight; y++) {
          final line = t.buffer.lines[t.buffer.scrollBack + y];
          if (!line.attached || line.index != t.buffer.scrollBack + y) {
            problems.add('${segment.label} (${segment.kind}): row $y '
                '"${_text(t, y)}" cannot hold a selection');
          }
        }

        if (segment.kind == 'step') {
          afterStep = _screenOf(t);
          textAfterStep = [for (var y = 0; y < t.viewHeight; y++) _text(t, y)];
          continue;
        }
        // A repaint: compare with the screen the step left.
        final repainted = _screenOf(t);
        final before = afterStep!;
        for (var y = 0; y < repainted.length; y++) {
          if (_messageRows(capture).contains(y)) continue;
          for (var x = 0; x < repainted[y].length; x++) {
            if (before[y][x] == repainted[y][x]) continue;
            problems.add('${segment.label}: row $y col $x was '
                '[${before[y][x]}] and repaints as [${repainted[y][x]}]\n'
                '    step:    "${textAfterStep![y]}"\n'
                '    repaint: "${_text(t, y)}"');
            break; // one difference per row is enough to name it
          }
        }
      }
      expect(problems, isEmpty, reason: problems.take(40).join('\n'));
    });
  }
}
