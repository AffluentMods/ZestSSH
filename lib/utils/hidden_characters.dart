import 'package:flutter/widgets.dart' show StringCharacters;

/// How [character] (a code point) is shown in a question that shows what will
/// run: as itself, unless that is not what it would look like. A control
/// character is named (`\n`, `\e`, `\x07`), and what draws other text wrongly or
/// draws nothing is given by its number (a backslash, u and its hex): the C1 controls, the
/// direction marks, overrides and isolates (an unended right-to-left override
/// draws the rest of the line backwards), and the invisible ones.
String visibleCharacter(int character) {
  switch (character) {
    case 0x0a:
      return r'\n';
    case 0x0d:
      return r'\r';
    case 0x09:
      return r'\t';
    case 0x1b:
      return r'\e';
    case 0x00:
      return r'\0';
  }
  if (character < 0x20 || character == 0x7f) {
    return '\\x${character.toRadixString(16).padLeft(2, '0')}';
  }
  if (_hides(character)) {
    final hex = character.toRadixString(16);
    return character > 0xffff ? '\\u{$hex}' : '\\u${hex.padLeft(4, '0')}';
  }
  return String.fromCharCode(character);
}

bool _hides(int rune) =>
    (rune >= 0x80 && rune <= 0x9f) || // the C1 controls
    rune == 0x00ad || // soft hyphen
    rune == 0x034f || // combining grapheme joiner
    rune == 0x061c || // Arabic letter mark
    (rune >= 0x180b && rune <= 0x180f) || // Mongolian selectors, vowel separator
    (rune >= 0x200b && rune <= 0x200f) || // zero-width, LRM, RLM
    (rune >= 0x2028 && rune <= 0x202e) || // line and paragraph separators, embeddings, overrides
    (rune >= 0x2060 && rune <= 0x206f) || // word joiner, invisible operators, isolates
    rune == 0xfeff || // zero-width no-break space
    (rune >= 0xfff9 && rune <= 0xfffb) || // interlinear annotation
    (rune >= 0xe0000 && rune <= 0xe007f); // tag characters

/// [text] with everything in it showing as what it is ([visibleCharacter]), for
/// every place a command is shown for a person to decide on it: drawn as they
/// are, such characters can make a command read other than it runs. With
/// [keepLines], line breaks and tabs stay as they are, for text read on lines
/// of its own.
String visibleCommand(String text, {bool keepLines = false}) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (keepLines && (rune == 0x0a || rune == 0x09)) {
      out.writeCharCode(rune);
    } else {
      out.write(visibleCharacter(rune));
    }
  }
  return out.toString();
}

/// [text] with every character that hides or reorders what it says shown
/// ([visibleCharacter]); a line break and a tab stay as they are.
String withHiddenCharactersShown(String text) => visibleCommand(text, keepLines: true);

/// [command] for a question before it runs, short: at most [max] characters, cut
/// between them (a cut by units could halve an emoji), and made visible.
String commandForQuestion(String command, {int max = 120, bool keepLines = false}) {
  // (Counted as far as it may be cut, and no further: it may be a whole clipboard.)
  final letters = command.characters;
  final fits = command.length <= max || letters.take(max).string.length == command.length;
  return visibleCommand(
    fits ? command : '${letters.take(max - 1)}…',
    keepLines: keepLines,
  );
}

/// The most of a command a question draws, which is more than anyone reads in its
/// box and a long way from a whole clipboard: a megabyte with no space in it took
/// 17 seconds to lay out, with the window standing still.
const int kMaxCommandShown = 1 << 16;
