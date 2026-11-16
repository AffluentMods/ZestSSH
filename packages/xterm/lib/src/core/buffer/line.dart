import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/utils/circular_buffer.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

const _cellSize = 4;

const _cellForeground = 0;

const _cellBackground = 1;

const _cellAttributes = 2;

const _cellContent = 3;

/// Words a style run takes in [BufferLine._runs]: its first cell, then the
/// foreground, background and attributes every cell of the run has.
const _runSize = 4;

final _noCells = Uint32List(0);

/// One row of the terminal.
///
/// A row on the screen keeps four words a cell (foreground, background,
/// attributes, content) for every cell its capacity holds: 64, 128, 256 and
/// up, whatever it shows. A row that has scrolled into the scrollback is
/// [compact]ed: only the cells up to the last one that holds anything are
/// kept, and when the row's cells share their styles in runs (a plain log
/// line is one run, a coloured prompt a handful), the content word of each
/// cell alone, with the runs beside it. Every cell reads back exactly as it
/// was. Writing to a compacted row first gives it its full storage back.
///
/// Before, every row kept its full capacity for as long as it was in the
/// scrollback: 2,048 bytes a row at 80 columns, so a session whose 50,000
/// rows of scrollback had filled held about 100 MB, and ten such sessions a
/// gigabyte (found in a review before 4.0).
class BufferLine with IndexedItem {
  BufferLine(
    this._length, {
    this.isWrapped = false,
  }) : _data = Uint32List(_calcCapacity(_length) * _cellSize);

  int _length;

  /// The cells. Full storage ([_runs] null): four words a cell. Compacted
  /// with runs: one content word a cell, its style in [_runs]. Compacted
  /// without runs: four words a cell, only as many cells as are kept. A cell
  /// past the kept ones is empty: all of its words are 0.
  Uint32List _data;

  /// The style runs of a compacted row (see [_runSize]), or null.
  Uint32List? _runs;

  /// Whether this row is compacted (see [compact]).
  bool _compact = false;

  /// The storage of the row's cells, four words a cell. Gives a compacted
  /// row its full storage back first.
  Uint32List get data {
    if (_compact) _expand();
    return _data;
  }

  var isWrapped = false;

  int get length => _length;

  List<CellAnchor>? _anchorList;

  List<CellAnchor> get anchors => _anchorList ?? const <CellAnchor>[];

  /// Whether this row keeps only what it holds (see [compact]).
  bool get isCompact => _compact;

  /// Bytes the cells of this row take: its cell words and its style runs.
  int get storageBytes => _data.lengthInBytes + (_runs?.lengthInBytes ?? 0);

  /// The clock every line's text shares. It moves on whenever the text of a
  /// line changes and whenever a line is made, so a larger [textStamp] is a
  /// later change, on whichever line.
  static int get textClock => _textClock;
  static int _textClock = 0;

  /// When the text of this line last changed, by [textClock], or when the
  /// line was made if it never did. Colours and styles are not text, and
  /// writing what is there already is no change. What a selection goes by to
  /// know whether the text under it is still what was selected.
  int get textStamp => _textStamp;
  int _textStamp = ++_textClock;

  /// Marks the text of this line as changed now. For what the line cannot
  /// see itself: it is no longer on the screen that is shown.
  void touch() {
    _textStamp = ++_textClock;
  }

  /// Cells this row keeps: past them every cell is empty.
  int get _keptCells =>
      _runs == null ? _data.length ~/ _cellSize : _data.length;

  /// Keeps only what the row holds: the cells up to the last one that holds
  /// anything (a character, a colour or a style), and, when it is smaller,
  /// each cell's content word with the style runs beside it. Nothing a
  /// reader of the row sees changes, its text stamp included. For a row that
  /// has left the screen: one that is written to again gets its full
  /// storage back first.
  void compact() {
    if (_compact) return;
    final data = _data;
    var used = data.length ~/ _cellSize;
    while (used > 0) {
      final o = (used - 1) * _cellSize;
      if ((data[o] | data[o + 1] | data[o + 2] | data[o + 3]) != 0) break;
      used--;
    }

    var runCount = 0;
    for (var i = 0; i < used; i++) {
      final o = i * _cellSize;
      if (i == 0 ||
          data[o + _cellForeground] != data[o - _cellSize + _cellForeground] ||
          data[o + _cellBackground] != data[o - _cellSize + _cellBackground] ||
          data[o + _cellAttributes] != data[o - _cellSize + _cellAttributes]) {
        runCount++;
      }
    }

    if (used + runCount * _runSize < used * _cellSize) {
      final content = Uint32List(used);
      final runs = Uint32List(runCount * _runSize);
      var r = 0;
      for (var i = 0; i < used; i++) {
        final o = i * _cellSize;
        content[i] = data[o + _cellContent];
        if (i == 0 ||
            data[o + _cellForeground] != data[o - _cellSize + _cellForeground] ||
            data[o + _cellBackground] != data[o - _cellSize + _cellBackground] ||
            data[o + _cellAttributes] != data[o - _cellSize + _cellAttributes]) {
          runs[r] = i;
          runs[r + 1] = data[o + _cellForeground];
          runs[r + 2] = data[o + _cellBackground];
          runs[r + 3] = data[o + _cellAttributes];
          r += _runSize;
        }
      }
      _data = content;
      _runs = runs;
      _compact = true;
    } else if (used * _cellSize < data.length) {
      _data = used == 0
          ? _noCells
          : Uint32List.fromList(Uint32List.sublistView(data, 0, used * _cellSize));
      _compact = true;
    }
  }

  /// Gives a compacted row its full storage back, every cell as it was.
  void _expand() {
    final kept = _keptCells;
    final full = Uint32List(_calcCapacity(max(_length, kept)) * _cellSize);
    final runs = _runs;
    if (runs == null) {
      full.setRange(0, _data.length, _data);
    } else {
      var r = 0;
      for (var i = 0; i < kept; i++) {
        while (r + _runSize < runs.length && runs[r + _runSize] <= i) {
          r += _runSize;
        }
        final o = i * _cellSize;
        full[o + _cellForeground] = runs[r + 1];
        full[o + _cellBackground] = runs[r + 2];
        full[o + _cellAttributes] = runs[r + 3];
        full[o + _cellContent] = _data[i];
      }
    }
    _data = full;
    _runs = null;
    _compact = false;
  }

  /// Where the style run of [index] starts in [_runs]: the last run that
  /// starts at or before it.
  int _runAt(Uint32List runs, int index) {
    var lo = 0;
    var hi = runs.length ~/ _runSize - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (runs[mid * _runSize] <= index) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo * _runSize;
  }

  /// Word [field] of the cell at [index] of a compacted row.
  int _compactWord(int index, int field) {
    final runs = _runs;
    if (runs == null) {
      final o = index * _cellSize + field;
      return o < _data.length ? _data[o] : 0;
    }
    if (index >= _data.length) return 0;
    if (field == _cellContent) return _data[index];
    return runs[_runAt(runs, index) + 1 + field];
  }

  /// Word [field] of the cell at [index].
  @pragma('vm:prefer-inline')
  int _word(int index, int field) {
    if (_compact) return _compactWord(index, field);
    return _data[index * _cellSize + field];
  }

  /// Writes the character of a cell (with its width), and notes the change
  /// when it is one.
  void _setContentAt(int at, int content) {
    if (_compact) _expand();
    if (_data[at] == content) return;
    _data[at] = content;
    _textStamp = ++_textClock;
  }

  int getForeground(int index) {
    return _word(index, _cellForeground);
  }

  int getBackground(int index) {
    return _word(index, _cellBackground);
  }

  int getAttributes(int index) {
    return _word(index, _cellAttributes);
  }

  int getContent(int index) {
    return _word(index, _cellContent);
  }

  int getCodePoint(int index) {
    return _word(index, _cellContent) & CellContent.codepointMask;
  }

  int getWidth(int index) {
    return _word(index, _cellContent) >> CellContent.widthShift;
  }

  void getCellData(int index, CellData cellData) {
    if (_compact) {
      cellData.foreground = _compactWord(index, _cellForeground);
      cellData.background = _compactWord(index, _cellBackground);
      cellData.flags = _compactWord(index, _cellAttributes);
      cellData.content = _compactWord(index, _cellContent);
      return;
    }
    final offset = index * _cellSize;
    cellData.foreground = _data[offset + _cellForeground];
    cellData.background = _data[offset + _cellBackground];
    cellData.flags = _data[offset + _cellAttributes];
    cellData.content = _data[offset + _cellContent];
  }

  CellData createCellData(int index) {
    if (_compact) _expand();
    final cellData = CellData.empty();
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = cellData.foreground;
    _data[offset + _cellBackground] = cellData.background;
    _data[offset + _cellAttributes] = cellData.flags;
    _setContentAt(offset + _cellContent, cellData.content);
    return cellData;
  }

  void setForeground(int index, int value) {
    if (_compact) _expand();
    _data[index * _cellSize + _cellForeground] = value;
  }

  void setBackground(int index, int value) {
    if (_compact) _expand();
    _data[index * _cellSize + _cellBackground] = value;
  }

  void setAttributes(int index, int value) {
    if (_compact) _expand();
    _data[index * _cellSize + _cellAttributes] = value;
  }

  void setContent(int index, int value) {
    _setContentAt(index * _cellSize + _cellContent, value);
  }

  void setCodePoint(int index, int char) {
    final width = unicodeV11.wcwidth(char);
    setContent(index, char | (width << CellContent.widthShift));
  }

  void setCell(int index, int char, int witdh, CursorStyle style) {
    if (_compact) _expand();
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = style.foreground;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] = style.attrs;
    _setContentAt(offset + _cellContent, char | (witdh << CellContent.widthShift));
  }

  void setCellData(int index, CellData cellData) {
    if (_compact) _expand();
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = cellData.foreground;
    _data[offset + _cellBackground] = cellData.background;
    _data[offset + _cellAttributes] = cellData.flags;
    _setContentAt(offset + _cellContent, cellData.content);
  }

  void eraseCell(int index, CursorStyle style) {
    if (_compact) _expand();
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = style.foreground;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] = style.attrs;
    _setContentAt(offset + _cellContent, 0);
  }

  /// Gives every cell of the line [background] and leaves the rest of each
  /// cell alone. For a row that scrolls in under a background colour.
  void fillBackground(int background) {
    if (_compact) _expand();
    for (var i = 0; i < _length; i++) {
      _data[i * _cellSize + _cellBackground] = background;
    }
  }

  void resetCell(int index) {
    if (_compact) _expand();
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = 0;
    _data[offset + _cellBackground] = 0;
    _data[offset + _cellAttributes] = 0;
    _setContentAt(offset + _cellContent, 0);
  }

  /// Erase cells whose index satisfies [start] <= index < [end]. Erased cells
  /// are filled with [style].
  void eraseRange(int start, int end, CursorStyle style) {
    // Nothing to erase. (At the first column the look at `end - 1` below was
    // a look at no cell: it threw, and one code stopped the session's screen.)
    if (end <= start) return;

    // reset cell one to the left if start is second cell of a wide char
    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    // reset cell one to the right if end is second cell of a wide char
    if (end < _length && getWidth(end - 1) == 2) {
      eraseCell(end - 1, style);
    }

    end = min(end, _length);
    for (var i = start; i < end; i++) {
      eraseCell(i, style);
    }
  }

  /// Remove [count] cells starting at [start]. Cells that are empty after the
  /// removal are filled with [style].
  void removeCells(int start, int count, [CursorStyle? style]) {
    assert(start >= 0 && start < _length);
    assert(count >= 0 && start + count <= _length);

    if (_compact) _expand();

    style ??= CursorStyle.empty;

    // What is left of the line moves over: its text is not what it was.
    if (count > 0) touch();

    if (start + count < _length) {
      final moveStart = start * _cellSize;
      final moveEnd = (_length - count) * _cellSize;
      final moveOffset = count * _cellSize;
      for (var i = moveStart; i < moveEnd; i++) {
        _data[i] = _data[i + moveOffset];
      }
    }

    for (var i = _length - count; i < _length; i++) {
      eraseCell(i, style);
    }

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    // Update anchors, remove anchors that are inside the removed range.
    final anchors = this.anchors;
    for (var i = 0; i < anchors.length; i++) {
      final anchor = anchors[i];
      if (anchor.x >= start) {
        if (anchor.x < start + count) {
          anchor.dispose();
        } else {
          anchor.reposition(anchor.x - count);
        }
      }
    }
  }

  /// Inserts [count] cells at [start]. New cells are initialized with [style].
  void insertCells(int start, int count, [CursorStyle? style]) {
    if (_compact) _expand();

    style ??= CursorStyle.empty;

    // The rest of the line moves over: its text is not what it was.
    if (count > 0) touch();

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    if (start + count < _length) {
      final moveStart = start * _cellSize;
      final moveEnd = (_length - count) * _cellSize;
      final moveOffset = count * _cellSize;
      for (var i = moveEnd - 1; i >= moveStart; i--) {
        _data[i + moveOffset] = _data[i];
      }
    }

    final end = min(start + count, _length);
    for (var i = start; i < end; i++) {
      eraseCell(i, style);
    }

    if (getWidth(_length - 1) == 2) {
      eraseCell(_length - 1, style);
    }

    // Update anchors, move anchors that are after the inserted range.
    final anchors = this.anchors;
    for (var i = 0; i < anchors.length; i++) {
      final anchor = anchors[i];
      if (anchor.x >= start + count) {
        anchor.reposition(anchor.x + count);

        // Remove anchors that are now outside the buffer.
        if (anchor.x >= _length) {
          anchor.dispose();
        }
      }
    }
  }

  void resize(int length) {
    assert(length >= 0);

    if (length == _length) {
      return;
    }

    // A compacted row needs no storage for a new length: the cells it does
    // not keep are empty, and it gets full storage back when it is written.
    if (length > _length && !_compact) {
      final newBufferSize = _calcCapacity(length) * _cellSize;

      if (newBufferSize > _data.length) {
        final newBuffer = Uint32List(newBufferSize);
        newBuffer.setRange(0, _data.length, _data);
        _data = newBuffer;
      }
    }

    // Cells cut off the end: when one of them held a character, the text of
    // the line is not what it was.
    for (var i = length; i < _length; i++) {
      if (getContent(i) != 0) {
        touch();
        break;
      }
    }

    _length = length;

    final anchors = this.anchors;
    for (var i = 0; i < anchors.length; i++) {
      final anchor = anchors[i];
      if (anchor.x > _length) {
        anchor.reposition(_length);
      }
    }
  }

  /// Returns the offset of the last cell that has content from the start of
  /// the line.
  int getTrimmedLength([int? cols]) {
    final maxCols = _compact ? _keptCells : _data.length ~/ _cellSize;

    if (cols == null || cols > maxCols) {
      cols = maxCols;
    }

    if (cols <= 0) {
      return 0;
    }

    for (var i = cols - 1; i >= 0; i--) {
      var codePoint = getCodePoint(i);

      if (codePoint != 0) {
        // we are at the last cell in this line that has content.
        // the length of this line is the index of this cell + 1
        // the only exception is that if that last cell is wider
        // than 1 then we have to add the diff
        final lastCellWidth = getWidth(i);
        return i + lastCellWidth;
      }
    }
    return 0;
  }

  /// Copies [len] cells from [src] starting at [srcCol] to [dstCol] at this
  /// line.
  void copyFrom(BufferLine src, int srcCol, int dstCol, int len) {
    resize(dstCol + len);
    if (_compact) _expand();

    var dstOffset = dstCol * _cellSize;

    if (!src._compact) {
      var srcOffset = srcCol * _cellSize;
      for (var i = 0; i < len * _cellSize; i++) {
        _data[dstOffset++] = src._data[srcOffset++];
      }
    } else {
      // A compacted row is read cell by cell (see [compact]).
      for (var i = 0; i < len; i++) {
        final at = srcCol + i;
        _data[dstOffset++] = src._compactWord(at, _cellForeground);
        _data[dstOffset++] = src._compactWord(at, _cellBackground);
        _data[dstOffset++] = src._compactWord(at, _cellAttributes);
        _data[dstOffset++] = src._compactWord(at, _cellContent);
      }
    }
    if (len > 0) touch();
  }

  static int _calcCapacity(int length) {
    assert(length >= 0);

    var capacity = 64;

    if (length < 256) {
      while (capacity < length) {
        capacity *= 2;
      }
    } else {
      capacity = 256;
      while (capacity < length) {
        capacity += 32;
      }
    }

    return capacity;
  }

  /// The text of the cells from [from] up to (not including) [to].
  ///
  /// A cell nothing was written to reads as a space when something is written
  /// after it on the line. A full-screen program does not write the blanks of
  /// an indented line: it moves the cursor over them (vim sends cursor
  /// forward, nano addresses the column). Leaving those cells out, as this
  /// used to, made copied text lose its indentation (` 14if x:` for
  /// ` 14        if x:`) and put everything that maps a text position to a
  /// column (search matches, trigger highlights, links) in the wrong place on
  /// such a row. Cells after the last written one are not text, so a line
  /// never ends in padding.
  String getText([int? from, int? to]) {
    if (from == null || from < 0) {
      from = 0;
    }

    if (to == null || to > _length) {
      to = _length;
    }

    // One past the last cell that holds a character.
    var written = _length;
    while (written > 0 && getCodePoint(written - 1) == 0) {
      written--;
    }
    final stop = min(to, written);

    final builder = StringBuffer();
    for (var i = from; i < stop; i++) {
      final codePoint = getCodePoint(i);
      if (codePoint == 0) {
        // The right half of a wide character is not a cell of its own.
        if (i > 0 && getWidth(i - 1) == 2) continue;
        builder.writeCharCode(0x20);
        continue;
      }
      if (i + getWidth(i) <= to) {
        builder.writeCharCode(codePoint);
      }
    }

    return builder.toString();
  }

  CellAnchor createAnchor(int offset) {
    final anchor = CellAnchor(offset, owner: this);
    (_anchorList ??= <CellAnchor>[]).add(anchor);
    return anchor;
  }

  void dispose() {
    final anchors = _anchorList;
    if (anchors == null) return;
    for (final anchor in anchors.toList()) {
      anchor.dispose();
    }
  }

  @override
  String toString() {
    return getText();
  }
}

/// A handle to a cell in a [BufferLine] that can be used to track the location
/// of the cell. Anchors are guaranteed to be stable, retaining their relative
/// position to each other after mutations to the buffer.
class CellAnchor {
  CellAnchor(int offset, {BufferLine? owner})
      : _offset = offset,
        _owner = owner;

  int _offset;

  int get x {
    return _offset;
  }

  int get y {
    assert(attached);
    return _owner!.index;
  }

  CellOffset get offset {
    assert(attached);
    return CellOffset(_offset, _owner!.index);
  }

  BufferLine? _owner;

  BufferLine? get line => _owner;

  bool get attached => _owner?.attached ?? false;

  void reparent(BufferLine owner, int offset) {
    _owner?._anchorList?.remove(this);
    _owner = owner;
    (owner._anchorList ??= <CellAnchor>[]).add(this);
    _offset = offset;
  }

  void reposition(int offset) {
    _offset = offset;
  }

  void dispose() {
    _owner?._anchorList?.remove(this);
    _owner = null;
  }

  @override
  String toString() {
    if (attached) {
      return 'CellAnchor($x, $y)';
    } else {
      return 'CellAnchor($x, detached)';
    }
  }
}
