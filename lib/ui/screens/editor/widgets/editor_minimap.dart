import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/editor/editor_language.dart';
import 'package:zestssh/ui/screens/editor/editor_look.dart';

/// The file editor's minimap (3.4: off by
/// default, a switch in the editor's menu on computers, never on phones): a
/// narrow drawing of the whole file at the right of the code, each line a
/// thin bar in its colours (never real text drawn tiny), with the part the
/// code shows as a box. A click or a drag on it scrolls the code; the wheel
/// over it scrolls the code too.
///
/// It stays cheap on a file at the size cap: a file with more lines than it
/// has room for is drawn from a sample of its lines (one per row), each line
/// is read only as far as the drawing is wide, and the lines are drawn again
/// only when the text changes (the box, in a layer of its own, follows the
/// scrolling).
class EditorMinimap extends StatefulWidget {
  const EditorMinimap({
    super.key,
    required this.controller,
    required this.scroller,
    required this.look,
    required this.language,
  });

  /// How wide it is (96 pixels).
  static const double width = 96;

  final CodeLineEditingController controller;

  /// The code's own vertical scrolling ([CodeScrollController.verticalScroller]).
  final ScrollController scroller;
  final EditorLook look;
  final EditorLanguage language;

  @override
  State<EditorMinimap> createState() => _EditorMinimapState();
}

class _EditorMinimapState extends State<EditorMinimap> {
  /// The file's lines, told only when they change (the controller also
  /// speaks for a caret moved, which leaves the drawing as it is).
  late final ValueNotifier<CodeLines> _lines = ValueNotifier(widget.controller.codeLines);

  /// Where a drag took hold of the box, from its top; null while none.
  double? _grab;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onCode);
  }

  @override
  void didUpdateWidget(EditorMinimap old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onCode);
      widget.controller.addListener(_onCode);
      _onCode();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onCode);
    _lines.dispose();
    super.dispose();
  }

  void _onCode() {
    final lines = widget.controller.codeLines;
    if (!identical(lines, _lines.value)) _lines.value = lines;
  }

  MinimapGeometry _geometry(double height) => MinimapGeometry.of(
        lineCount: _lines.value.length,
        height: height,
        scroller: widget.scroller,
      );

  void _press(double y, double height) {
    final g = _geometry(height);
    if (!g.canScroll) return;
    // Taken by the box: it moves with the pointer from where it was held.
    // Elsewhere: the box comes to the pointer, centred on it.
    _grab = y >= g.boxTop && y <= g.boxTop + g.boxHeight ? y - g.boxTop : g.boxHeight / 2;
    _scrollTo(g, y);
  }

  void _drag(double y, double height) {
    if (_grab == null) return;
    _scrollTo(_geometry(height), y);
  }

  void _scrollTo(MinimapGeometry g, double y) {
    widget.scroller.jumpTo(g.pixelsForBoxTop(y - (_grab ?? 0)));
  }

  void _wheel(PointerScrollEvent e) {
    if (!widget.scroller.hasClients) return;
    final p = widget.scroller.position;
    widget.scroller.jumpTo((p.pixels + e.scrollDelta.dy).clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final look = widget.look;
    final colours = MinimapColours.of(look);
    return Semantics(
      label: AppLocalizations.of(context)!.editorMinimapLabel,
      child: Container(
        key: const ValueKey('editor-minimap'),
        width: EditorMinimap.width,
        decoration: BoxDecoration(
          color: look.background,
          border: Border(left: BorderSide(color: look.foreground.withValues(alpha: 0.07))),
        ),
        child: LayoutBuilder(builder: (context, c) {
          final height = c.maxHeight;
          return Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) _wheel(e);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Down at once, a click as much as a drag's start.
              onVerticalDragDown: (d) => _press(d.localPosition.dy, height),
              onVerticalDragUpdate: (d) => _drag(d.localPosition.dy, height),
              onVerticalDragEnd: (_) => _grab = null,
              onVerticalDragCancel: () => _grab = null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: MinimapLinesPainter(
                        lines: _lines,
                        colours: colours,
                        comments: MinimapComments.of(widget.language),
                      ),
                    ),
                  ),
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: MinimapBoxPainter(
                        lines: _lines,
                        scroller: widget.scroller,
                        fill: look.foreground.withValues(alpha: 0.07),
                        edge: look.foreground.withValues(alpha: 0.14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Where the lines and the box stand in a minimap [height] pixels tall.
@visibleForTesting
class MinimapGeometry {
  MinimapGeometry._({
    required this.rows,
    required this.rowHeight,
    required this.drawnHeight,
    required this.boxTop,
    required this.boxHeight,
    required this.total,
    required this.viewport,
    required this.maxScroll,
  });

  /// Each line's room while every line fits: a 2 pixel bar and a pixel apart
  /// (3 pixels a line).
  static const double fullRow = 3;

  /// Room left at the top and the bottom.
  static const double inset = 8;

  /// With no [scroller], where the lines stand only.
  factory MinimapGeometry.of({required int lineCount, required double height, ScrollController? scroller}) {
    final room = math.max(0.0, height - inset * 2);
    final n = math.max(1, lineCount);
    final int rows;
    final double rowHeight;
    if (n * fullRow <= room) {
      rows = n;
      rowHeight = fullRow;
    } else {
      // More lines than room: a sample of them, at most one per pixel.
      rows = math.max(1, math.min(n, room.floor()));
      rowHeight = room / rows;
    }
    final drawn = rows * rowHeight;
    var viewport = 0.0, maxScroll = 0.0, pixels = 0.0;
    if (scroller != null &&
        scroller.hasClients &&
        scroller.position.hasContentDimensions &&
        scroller.position.hasViewportDimension) {
      final p = scroller.position;
      viewport = p.viewportDimension;
      maxScroll = math.max(0.0, p.maxScrollExtent);
      pixels = p.pixels.clamp(0.0, maxScroll);
    }
    final total = viewport + maxScroll;
    final boxTop = total <= 0 ? 0.0 : pixels / total * drawn;
    final boxHeight = total <= 0 ? drawn : math.max(6.0, viewport / total * drawn);
    return MinimapGeometry._(
      rows: rows,
      rowHeight: rowHeight,
      drawnHeight: drawn,
      boxTop: inset + boxTop,
      boxHeight: math.min(boxHeight, drawn),
      total: total,
      viewport: viewport,
      maxScroll: maxScroll,
    );
  }

  /// How many lines are drawn, and each one's room.
  final int rows;
  final double rowHeight;

  /// How tall the drawing of the lines is.
  final double drawnHeight;

  /// The box of the part the code shows.
  final double boxTop;
  final double boxHeight;

  /// The code's whole height, what it shows of it, and how far it scrolls.
  final double total;
  final double viewport;
  final double maxScroll;

  bool get canScroll => maxScroll > 0 && drawnHeight > 0;

  /// The code's scroll offset that puts the box's top at [top].
  double pixelsForBoxTop(double top) {
    if (!canScroll) return 0;
    return ((top - inset) / drawnHeight * total).clamp(0.0, maxScroll);
  }

  /// The line drawn in [row] of [lineCount].
  int lineOfRow(int row, int lineCount) => rows >= lineCount ? row : (row * lineCount / rows).floor();
}

/// The colours a minimap draws in, from the editor's look.
@visibleForTesting
class MinimapColours {
  const MinimapColours({
    required this.text,
    required this.punctuation,
    required this.keyword,
    required this.key,
    required this.string,
    required this.number,
    required this.comment,
    required this.addition,
    required this.deletion,
    required this.meta,
  });

  factory MinimapColours.of(EditorLook look) {
    Color s(String name) => (look.syntax[name]?.color ?? look.foreground).withValues(alpha: 0.75);
    return MinimapColours(
      text: look.foreground.withValues(alpha: 0.45),
      punctuation: look.foreground.withValues(alpha: 0.3),
      keyword: s('keyword'),
      key: s('attribute'),
      string: s('string'),
      number: s('number'),
      comment: s('comment'),
      addition: s('addition'),
      deletion: s('deletion'),
      meta: s('meta'),
    );
  }

  final Color text;
  final Color punctuation;
  final Color keyword;
  final Color key;
  final Color string;
  final Color number;
  final Color comment;
  final Color addition;
  final Color deletion;
  final Color meta;

  List<Color> get _all => [text, punctuation, keyword, key, string, number, comment, addition, deletion, meta];

  @override
  bool operator ==(Object other) => other is MinimapColours && listEquals(other._all, _all);

  @override
  int get hashCode => Object.hashAll(_all);
}

/// How a kind of file starts a comment that runs to the end of the line.
@visibleForTesting
class MinimapComments {
  const MinimapComments(this.starts, {this.coloured = true, this.diff = false});

  static MinimapComments of(EditorLanguage language) => switch (language) {
        EditorLanguage.plainText => const MinimapComments([], coloured: false),
        EditorLanguage.diff => const MinimapComments([], diff: true),
        EditorLanguage.json => const MinimapComments([]),
        EditorLanguage.ini || EditorLanguage.systemd => const MinimapComments(['#', ';']),
        EditorLanguage.javascript ||
        EditorLanguage.typescript ||
        EditorLanguage.go ||
        EditorLanguage.rust ||
        EditorLanguage.css =>
          const MinimapComments(['//', '/*', '*']),
        EditorLanguage.php => const MinimapComments(['//', '#', '/*', '*']),
        EditorLanguage.sql || EditorLanguage.lua => const MinimapComments(['--']),
        EditorLanguage.html || EditorLanguage.xml || EditorLanguage.markdown => const MinimapComments(['<!--']),
        _ => const MinimapComments(['#']),
      };

  /// What starts a comment ('*' only where a line starts with it, inside a
  /// block comment).
  final List<String> starts;

  /// Whether the file is coloured at all (plain text is not).
  final bool coloured;

  /// A diff: its lines coloured by what they add or take away.
  final bool diff;
}

enum _Kind { text, punctuation, keyword, key, string, number, comment, addition, deletion, meta }

/// The lines, each a bar per word in its colours.
@visibleForTesting
class MinimapLinesPainter extends CustomPainter {
  MinimapLinesPainter({required this.lines, required this.colours, required this.comments}) : super(repaint: lines);

  final ValueListenable<CodeLines> lines;
  final MinimapColours colours;
  final MinimapComments comments;

  /// The pixels a character takes, and the room at the left and the right.
  static const double charWidth = 1.25;
  static const double left = 8;
  static const double right = 8;

  /// How many lines the last paint drew, for the tests.
  @visibleForTesting
  int paintedRows = 0;

  @override
  void paint(Canvas canvas, Size size) {
    final codeLines = lines.value;
    final count = codeLines.length;
    paintedRows = 0;
    if (count == 0) return;
    final g = MinimapGeometry.of(lineCount: count, height: size.height);
    final maxCols = ((size.width - left - right) / charWidth).floor();
    if (maxCols <= 0) return;
    final barHeight = math.max(1.0, g.rowHeight * 2 / 3);
    final paths = <_Kind, Path>{};
    void bar(_Kind kind, int from, int to, double top) {
      final x = left + from * charWidth;
      final w = (math.min(to, maxCols) - from) * charWidth;
      if (w <= 0) return;
      (paths[kind] ??= Path()).addRect(Rect.fromLTWH(x, top, w, barHeight));
    }

    // The lines are read in order, a block at a time: looking each one up
    // from the start would cost the whole file again for every row.
    final segments = codeLines.segments;
    var segment = 0, segmentStart = 0;
    for (var row = 0; row < g.rows; row++) {
      final index = g.lineOfRow(row, count);
      while (segment < segments.length && index >= segmentStart + segments[segment].length) {
        segmentStart += segments[segment].length;
        segment++;
      }
      if (segment >= segments.length) break;
      final text = segments[segment][index - segmentStart].text;
      final top = MinimapGeometry.inset + row * g.rowHeight;
      _paintLine(text, maxCols, (kind, from, to) => bar(kind, from, to, top));
      paintedRows++;
    }
    for (final e in paths.entries) {
      canvas.drawPath(e.value, Paint()..color = _colour(e.key));
    }
  }

  Color _colour(_Kind kind) => switch (kind) {
        _Kind.text => colours.text,
        _Kind.punctuation => colours.punctuation,
        _Kind.keyword => colours.keyword,
        _Kind.key => colours.key,
        _Kind.string => colours.string,
        _Kind.number => colours.number,
        _Kind.comment => colours.comment,
        _Kind.addition => colours.addition,
        _Kind.deletion => colours.deletion,
        _Kind.meta => colours.meta,
      };

  /// Reads [text] as far as [maxCols] columns (a tab is 4) and hands out
  /// its words as runs of columns, each with its kind.
  void _paintLine(String text, int maxCols, void Function(_Kind kind, int from, int to) run) {
    // Its columns, as drawn: a tab moves to the next stop.
    final cols = <int>[];
    final chars = <int>[];
    var col = 0;
    for (var i = 0; i < text.length && col < maxCols; i++) {
      final c = text.codeUnitAt(i);
      cols.add(col);
      chars.add(c);
      col += c == 0x09 ? 4 - col % 4 : 1;
    }
    if (chars.isEmpty) return;
    var first = 0;
    while (first < chars.length && _space(chars[first])) {
      first++;
    }
    if (first >= chars.length) return;

    // A line of a kind of its own, whole: a comment, a diff's line.
    _Kind? whole;
    if (!comments.coloured) {
      whole = _Kind.text;
    } else if (comments.diff) {
      whole = switch (chars[first]) {
        0x2B => _Kind.addition, // +
        0x2D => _Kind.deletion, // -
        0x40 => _Kind.meta, // @
        _ => _Kind.text,
      };
    } else if (_startsComment(chars, first, lineStart: true)) {
      whole = _Kind.comment;
    }
    if (whole != null) {
      _words(chars, cols, first, chars.length, (from, to) => run(whole!, from, to));
      return;
    }

    // Else word by word: the line's first word as a key or a keyword,
    // strings, numbers, a comment to the end of the line, the rest as text.
    // A line that opens a block (ends in { or :) starts with a keyword.
    final last = _lastNonSpace(chars);
    final opener = last == 0x7B || last == 0x3A;
    var i = first;
    var firstWord = true;
    while (i < chars.length) {
      final c = chars[i];
      if (_space(c)) {
        i++;
        continue;
      }
      if (_startsComment(chars, i, lineStart: false)) {
        _words(chars, cols, i, chars.length, (from, to) => run(_Kind.comment, from, to));
        return;
      }
      var end = i + 1;
      _Kind kind;
      if (c == 0x22 || c == 0x27 || c == 0x60) {
        // A string, to its closing quote.
        while (end < chars.length && chars[end] != c) {
          end++;
        }
        if (end < chars.length) end++;
        kind = _Kind.string;
      } else {
        while (end < chars.length && !_space(chars[end]) && chars[end] != 0x22 && chars[end] != 0x27) {
          end++;
        }
        if (_digit(c)) {
          kind = _Kind.number;
        } else if (!_wordy(chars, i, end)) {
          kind = _Kind.punctuation;
        } else if (firstWord) {
          kind = opener ? _Kind.keyword : _Kind.key;
        } else {
          kind = _Kind.text;
        }
      }
      firstWord = false;
      // A string's own spaces stay in its bar; elsewhere words stand apart.
      run(kind, cols[i], end < cols.length ? cols[end] : _endCol(chars, cols));
      i = end;
    }
  }

  static int _endCol(List<int> chars, List<int> cols) => cols.last + (chars.last == 0x09 ? 4 - cols.last % 4 : 1);

  /// Hands out the words of [chars] from [from] to [to].
  static void _words(List<int> chars, List<int> cols, int from, int to, void Function(int from, int to) word) {
    var i = from;
    while (i < to) {
      while (i < to && _space(chars[i])) {
        i++;
      }
      if (i >= to) return;
      var end = i;
      while (end < to && !_space(chars[end])) {
        end++;
      }
      word(cols[i], end < cols.length ? cols[end] : _endCol(chars, cols));
      i = end;
    }
  }

  bool _startsComment(List<int> chars, int at, {required bool lineStart}) {
    for (final s in comments.starts) {
      if (s == '*' && !lineStart) continue;
      if (s == '#' && !lineStart && at > 0 && !_space(chars[at - 1])) continue;
      if (at + s.length > chars.length) continue;
      var match = true;
      for (var k = 0; k < s.length; k++) {
        if (chars[at + k] != s.codeUnitAt(k)) {
          match = false;
          break;
        }
      }
      // '*' alone, or '*/', inside a block comment; never '*p' in C.
      if (match && s == '*' && at + 1 < chars.length && !_space(chars[at + 1]) && chars[at + 1] != 0x2F) match = false;
      if (match) return true;
    }
    return false;
  }

  static int? _lastNonSpace(List<int> chars) {
    for (var i = chars.length - 1; i >= 0; i--) {
      if (!_space(chars[i])) return chars[i];
    }
    return null;
  }

  static bool _space(int c) => c == 0x20 || c == 0x09 || c == 0x0D;
  static bool _digit(int c) => c >= 0x30 && c <= 0x39;
  static bool _wordy(List<int> chars, int from, int to) {
    for (var i = from; i < to; i++) {
      final c = chars[i];
      if (_digit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F) return true;
    }
    return false;
  }

  @override
  bool shouldRepaint(MinimapLinesPainter old) =>
      old.lines != lines || old.colours != colours || old.comments != comments;
}

/// The box of the part the code shows, which follows the scrolling.
@visibleForTesting
class MinimapBoxPainter extends CustomPainter {
  MinimapBoxPainter({required this.lines, required this.scroller, required this.fill, required this.edge})
      : super(repaint: Listenable.merge([scroller, lines]));

  final ValueListenable<CodeLines> lines;
  final ScrollController scroller;
  final Color fill;
  final Color edge;

  /// Where the last paint put the box, for the tests.
  @visibleForTesting
  Rect? painted;

  @override
  void paint(Canvas canvas, Size size) {
    final g = MinimapGeometry.of(lineCount: lines.value.length, height: size.height, scroller: scroller);
    final rect = Rect.fromLTWH(0, g.boxTop, size.width, g.boxHeight);
    painted = rect;
    canvas.drawRect(rect, Paint()..color = fill);
    final line = Paint()..color = edge;
    canvas.drawRect(Rect.fromLTWH(0, rect.top, size.width, 1), line);
    canvas.drawRect(Rect.fromLTWH(0, rect.bottom - 1, size.width, 1), line);
  }

  @override
  bool shouldRepaint(MinimapBoxPainter old) => true;
}
