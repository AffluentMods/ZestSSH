import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/line_breaks.dart';

/// Words read together stay on one line: a narrow pane wrapped "last used 2"
/// over "hours ago" and "until 2:16" over "PM" (found in a design
/// review).
void main() {
  test('keepTogether: no space a line may end at', () {
    expect(keepTogether('9:35 PM'), '9:35 PM');
    expect(keepTogether('Your access: Manage'), 'Your access: Manage');
    expect(keepTogether('none'), 'none');
  });

  test('breakAtDots: a line may end only after a dot', () {
    expect(
      breakAtDots('Ed25519 · added Sep 1 · last used 2 hours ago'),
      'Ed25519 · added Sep 1 · last used 2 hours ago',
    );
    expect(breakAtDots('4 hosts'), '4 hosts');
  });

  testWidgets('drawn narrow, the parts wrap whole, at the dots', (tester) async {
    final text = breakAtDots('Ed25519 · added Sep 1 · last used 2 hours ago');
    // The test font draws every letter 10 wide: room for 34 a line, where
    // plain spaces ended the first line at "last used" and put "2 hours ago"
    // on the second.
    final painter = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 340);
    final first = painter.getLineBoundary(const TextPosition(offset: 0));
    final second = painter.getLineBoundary(TextPosition(offset: first.end));
    painter.dispose();
    // The first line ends after the second dot, not inside "last used 2 hours
    // ago", which has the second line whole.
    expect(text.substring(first.start, first.end).trimRight(), 'Ed25519 · added Sep 1 ·');
    expect(text.substring(second.start, second.end), 'last used 2 hours ago');
  });

  test('noOrphan: the last two words of each line kept together, where they fit any line', () {
    // ("away" and "saved." were alone on their last lines, found in a design
    // review.)
    expect(noOrphan('Reach hosts differently at home, at work or away'),
        'Reach hosts differently at home, at work or\u00A0away');
    expect(noOrphan('Recording is off. New commands are not saved.'), 'Recording is off. New commands are not\u00A0saved.');
    expect(noOrphan('Off.\nrm -rf runs without asking.'), 'Off.\nrm -rf runs without\u00A0asking.', reason: 'each line');
    expect(noOrphan('ends here '), 'ends\u00A0here ', reason: 'a space after the words is kept');
    // Nothing to keep together: one word, no space (Chinese, Japanese), or
    // two words too long to share a narrow line.
    for (final same in ['none', '', '\n', '记录已关闭。新命令不会被保存。', 'Verbindungseinstellungen gespeichert.']) {
      expect(noOrphan(same), same);
    }
  });

  testWidgets('noOrphan, drawn narrow: the last line holds two words', (tester) async {
    // The test font draws every letter 10 wide: room for 12 a line, where
    // plain spaces left "saved." alone on the last.
    String lastLine(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 120);
      final line = painter.getLineBoundary(TextPosition(offset: text.length - 1));
      painter.dispose();
      return text.substring(line.start, line.end);
    }

    expect(lastLine('are not saved.'), 'saved.');
    expect(lastLine(noOrphan('are not saved.')), 'not\u00A0saved.');
  });
}
