import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// A link longer than a row is one link on every row it covers, and a click
/// on any of its rows opens the whole of it. Read row by row, only the part
/// on the first row was a link: a sign-in address printed by a program was
/// cut off at the end of its first row.

void main() {
  const link =
      'https://login.example/oauth/authorize?code=true&client_id=demo-1234&response_type=code&scope=profile';

  List<TerminalUrl> scan(Terminal terminal) {
    final detector = UrlDetector();
    final lines = terminal.buffer.lines;
    detector.scan(lines, 0, lines.length - 1);
    return detector.urls;
  }

  Terminal terminalOf(int width) {
    final terminal = Terminal(maxLines: 100);
    terminal.resize(width, 12);
    return terminal;
  }

  test(
    'a link the terminal wraps onto more rows is the whole link on each of them',
    () {
      final terminal = terminalOf(40);
      terminal.write('Sign in:\r\n$link\r\nDone\r\n');
      final urls = scan(terminal);
      // 101 characters on rows of 40: three rows.
      expect(urls.map((u) => u.row), [1, 2, 3]);
      expect(urls.map((u) => u.url).toSet(), {link});
      expect(urls.map((u) => (u.startCol, u.endCol)), [
        (0, 40),
        (0, 40),
        (0, link.length - 80),
      ]);
    },
  );

  test(
    'a link a program breaks into full rows itself is read on into the next row',
    () {
      final terminal = terminalOf(40);
      // As a program that lays its own text out writes it: a new line at
      // every full row.
      final rows = [
        for (var i = 0; i < link.length; i += 40)
          link.substring(i, i + 40 > link.length ? link.length : i + 40),
      ];
      terminal.write(
        ' Browser did not open? Use the address below\r\n\r\n${rows.join('\r\n')}\r\n\r\n Press Enter\r\n',
      );
      final urls = scan(terminal);
      expect(urls, hasLength(rows.length));
      expect(urls.map((u) => u.url).toSet(), {link});
    },
  );

  test(
    'a row that is not full, or a link that ends before the row does, is not read on',
    () {
      final terminal = terminalOf(40);
      terminal.write(
        'see https://docs.example/start here\r\nhttps://other.example/page\r\n',
      );
      // The first link ends mid-row: the next row's link is its own.
      expect(scan(terminal).map((u) => u.url), [
        'https://docs.example/start',
        'https://other.example/page',
      ]);

      final full = terminalOf(30);
      // A full row whose link ends there, and a next row that starts with a
      // space: not one link.
      // 'open ' and the link fill the 30 columns exactly.
      full.write('open https://docs.example/abcd\r\n then press Enter\r\n');
      expect(scan(full).map((u) => u.url), ['https://docs.example/abcd']);
    },
  );

  test(
    'a link whose start scrolled above the rows on screen is still read whole',
    () {
      final terminal = terminalOf(40);
      terminal.write('$link\r\n');
      final detector = UrlDetector();
      // Only its last row is on screen.
      detector.scan(terminal.buffer.lines, 2, 2);
      expect(detector.getUrlAt(const CellOffset(3, 2))?.url, link);
    },
  );
}
