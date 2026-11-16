import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

/// A detected URL in the terminal buffer.
class TerminalUrl {
  /// The absolute row in the buffer where this URL starts.
  final int row;

  /// The column where this URL starts (inclusive).
  final int startCol;

  /// The column where this URL ends (exclusive).
  final int endCol;

  /// The URL string.
  final String url;

  const TerminalUrl({
    required this.row,
    required this.startCol,
    required this.endCol,
    required this.url,
  });

  /// Returns true if the given cell position falls within this URL.
  bool containsCell(CellOffset offset) {
    return offset.y == row && offset.x >= startCol && offset.x < endCol;
  }
}

/// Scans terminal buffer lines for URLs.
///
/// Only detects http:// and https:// URLs. Runs lazily on visible lines only.
class UrlDetector {
  UrlDetector();

  // Regex matches http:// and https:// URLs, stopping at whitespace and
  // common enclosing characters. Strips trailing punctuation that is likely
  // not part of the URL.
  static final _urlPattern = RegExp(
    r'''https?://[^\s<>"')\]}]+''',
  );

  // Trailing characters that are commonly not part of a URL when they appear
  // at the very end (e.g. periods at end of sentence, commas in lists).
  static final _trailingPunctuation = RegExp(r'[.,;:!?)]+$');

  /// The cached list of detected URLs from the last scan.
  List<TerminalUrl> _urls = const [];

  /// The line range that was last scanned, used to avoid redundant work,
  /// with the lines it was (a program's full screen is another set of them)
  /// and the clock of their text ([BufferLine.textClock]): the same range of
  /// the same number of lines can hold other text.
  int _lastFirstLine = -1;
  int _lastLastLine = -1;
  int _lastBufferLength = -1;
  int _lastTextClock = -1;
  IndexAwareCircularBuffer<BufferLine>? _lastLines;

  /// Returns the list of URLs detected in the visible range.
  List<TerminalUrl> get urls => _urls;

  /// Scans the visible lines in [lines] from [firstLine] to [lastLine]
  /// (inclusive) for URLs. Results are cached and only recomputed when the
  /// visible range, the buffer length or any text changes.
  void scan(
    IndexAwareCircularBuffer<BufferLine> lines,
    int firstLine,
    int lastLine,
  ) {
    // Skip if this exact range of these lines was scanned and no text
    // changed since. (The range and the length alone say nothing of the
    // text: after `clear`, or once the scrollback is full, both stay as
    // they were while every row holds something else.)
    if (identical(lines, _lastLines) &&
        firstLine == _lastFirstLine &&
        lastLine == _lastLastLine &&
        lines.length == _lastBufferLength &&
        BufferLine.textClock == _lastTextClock) {
      return;
    }

    _lastLines = lines;
    _lastFirstLine = firstLine;
    _lastLastLine = lastLine;
    _lastBufferLength = lines.length;
    _lastTextClock = BufferLine.textClock;

    final result = <TerminalUrl>[];

    // A link can be longer than a row. Where it runs on, it is one link on
    // each of its rows: the rows are read as one text and the link is
    // underlined on every row it covers, each part opening the whole of it.
    // (Read row by row, only the part on the first row was a link, and a
    // click opened that part: a sign-in address cut off after
    // "response_ty".)
    var row = firstLine;
    // A link on screen whose start is in a row above it is read from there.
    var back = 0;
    while (row > 0 &&
        row < lines.length &&
        lines[row].isWrapped &&
        back < _maxRunRows) {
      row--;
      back++;
    }

    while (row <= lastLine) {
      if (row < 0 || row >= lines.length) {
        row++;
        continue;
      }

      // The rows of one run of text, and where each starts in it.
      final starts = <int>[];
      final rows = <int>[];
      final text = StringBuffer();
      var r = row;
      while (true) {
        starts.add(text.length);
        rows.add(r);
        text.write(lines[r].getText());
        final next = r + 1;
        if (next >= lines.length || rows.length >= _maxRunRows) break;
        if (lines[next].isWrapped ||
            _runsOn(text.toString(), lines[r], lines[next])) {
          r = next;
          continue;
        }
        break;
      }
      final joined = text.toString();
      row = r + 1;
      if (joined.isEmpty) continue;

      for (final match in _urlPattern.allMatches(joined)) {
        var url = match.group(0)!;

        // Strip trailing punctuation that is likely sentence-ending.
        url = url.replaceAll(_trailingPunctuation, '');

        // Balance parentheses: if URL has more closing than opening parens,
        // trim trailing close-parens (common with Wikipedia URLs in text).
        url = _balanceParentheses(url);

        if (url.length < 10) continue; // too short to be a real URL

        final start = match.start;
        final end = match.start + url.length;
        for (var i = 0; i < rows.length; i++) {
          final rowStart = starts[i];
          final rowEnd = i + 1 < rows.length ? starts[i + 1] : joined.length;
          final from = start > rowStart ? start : rowStart;
          final to = end < rowEnd ? end : rowEnd;
          if (from >= to) continue;
          result.add(TerminalUrl(
            row: rows[i],
            startCol: from - rowStart,
            endCol: to - rowStart,
            url: url,
          ));
        }
      }
    }

    _urls = result;
  }

  /// The most rows one run of text is read across, so a screen of one
  /// unbroken line costs no more than this.
  static const _maxRunRows = 64;

  /// What a link may hold: none of what [_urlPattern] stops at.
  static final _linkCharacter = RegExp(r'''[^\s<>"')\]}]''');

  /// Whether a link at the end of [line] (whose run so far is [text]) runs
  /// on into [next], a row the terminal did not mark as its continuation.
  /// A program that lays its own text out (a sign-in address printed by a
  /// full-screen program, for one) breaks a long line into rows itself, with
  /// a new line where the row is full. Such a row is read on into the next
  /// when it is full to its last cell, a link runs to its very end, and the
  /// next row starts with something a link holds.
  static bool _runsOn(String text, BufferLine line, BufferLine next) {
    final rowText = line.getText();
    if (rowText.length < line.length) return false;
    final nextText = next.getText();
    if (nextText.isEmpty || !_linkCharacter.hasMatch(nextText[0])) return false;
    if (!_linkCharacter.hasMatch(rowText[rowText.length - 1])) return false;
    final last = _urlPattern.allMatches(text).lastOrNull;
    return last != null && last.end == text.length;
  }

  /// Looks at the range last scanned again when [lines] are other lines or
  /// their text changed since: what [getUrlAt] answers is then of the text
  /// as it is, not as it was when it was last painted.
  void rescanIfStale(IndexAwareCircularBuffer<BufferLine> lines) {
    if (_lastFirstLine < 0) return;
    scan(lines, _lastFirstLine, _lastLastLine);
  }

  /// Returns the URL at the given cell position, or null if none.
  TerminalUrl? getUrlAt(CellOffset offset) {
    for (final url in _urls) {
      if (url.containsCell(offset)) {
        return url;
      }
    }
    return null;
  }

  /// Invalidates the cache, forcing a rescan on the next call to [scan].
  void invalidate() {
    _lastFirstLine = -1;
    _lastLastLine = -1;
    _lastBufferLength = -1;
    _lastTextClock = -1;
    _lastLines = null;
    _urls = const [];
  }

  /// Balances parentheses in a URL string. If there are more closing parens
  /// than opening parens, trailing close-parens are removed one at a time.
  static String _balanceParentheses(String url) {
    var openCount = 0;
    var closeCount = 0;
    for (final c in url.codeUnits) {
      if (c == 0x28) openCount++; // '('
      if (c == 0x29) closeCount++; // ')'
    }
    while (closeCount > openCount && url.endsWith(')')) {
      url = url.substring(0, url.length - 1);
      closeCount--;
    }
    return url;
  }
}
