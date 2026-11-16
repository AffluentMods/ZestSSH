// Where a line of words may end. A narrow pane wrapped "last used 2" over
// "hours ago" and "until 2:16" over "PM" (the design audit, 29 October
// 2026): words that are read together are kept on one line.

const _keep = ' ';

/// [text] with its spaces made non-breaking: a line never ends inside it
/// ("9:35 PM", "Your access: Manage").
String keepTogether(String text) => text.replaceAll(' ', _keep);

/// [text] made of parts joined by " · " ("Ed25519 · added Sep 1 · last used
/// 2 hours ago"), set so that a line ends only after a dot: each part reads
/// whole on its line.
String breakAtDots(String text) => keepTogether(text).replaceAll('$_keep·$_keep', '$_keep· ');

/// The most letters [noOrphan] keeps on one line: two short words fit any
/// line of text the app has, two long ones may not.
const _orphanPairMax = 24;

/// [text] with the last two words of each of its lines kept together, so
/// that a wrapped line never leaves one word alone under the rest ("at work
/// or" over "away", "are not" over "saved.": the design audit, 29 October
/// 2026). Every language gets it at once; a line with no space (Chinese,
/// Japanese), or whose last two words are too long to share any line, is left
/// as it is. Only for words to read: never for a command, a path or anything
/// to copy.
String noOrphan(String text) => text.split('\n').map(_noOrphanLine).join('\n');

String _noOrphanLine(String line) {
  final end = line.trimRight().length;
  if (end == 0) return line;
  final last = line.lastIndexOf(' ', end - 1);
  if (last <= 0) return line;
  final before = line.lastIndexOf(' ', last - 1);
  if (end - (before + 1) > _orphanPairMax) return line;
  return line.replaceRange(last, last + 1, _keep);
}
