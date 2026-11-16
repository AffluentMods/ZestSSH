/// The ready-made patterns of an alert's Simple mode (the Alerts page of a
/// computer, 3.0): what is commonly watched for in terminal output, so that
/// nobody needs to write a regular expression for it. A preset is only a
/// pattern and some example lines; what is saved is the pattern, as any
/// alert's is, matched with upper and lower case alike.
library;

/// One of Simple mode's choices.
enum AlertPreset {
  errors(r'\b(error|failed|fatal)\b', [
    'error: file not found',
    'Build FAILED in 3.2s',
    'fatal: not a git repository',
  ]),
  warnings(r'\bwarn(ing)?\b', [
    'warning: unused variable',
    'WARN disk 85% full',
  ]),
  buildFinished(r'build (succeeded|successful|finished|complete)', [
    'build succeeded',
    'build successful',
    'build finished',
    'build complete',
  ]),
  passwordPrompt(r'password[^:]*:\s*$', [
    'Password:',
    '[sudo] password for deploy:',
  ]),

  /// The person's own text, matched as it is written (no character of it
  /// has a meaning of its own).
  ownText('', []);

  const AlertPreset(this.pattern, this.examples);

  /// The pattern saved for it (none for [ownText], made from the text).
  final String pattern;

  /// Lines of output it matches, shown under it ("Matches lines like").
  final List<String> examples;

  /// The pattern of [text] as the person's own words: every character as
  /// itself.
  static String ownTextPattern(String text) => RegExp.escape(text.trim());

  /// The text a pattern made by [ownTextPattern] was made from, or null where
  /// [pattern] is anything else (it has a character with a meaning of its
  /// own that is not escaped).
  static String? ownTextOf(String pattern) {
    if (pattern.isEmpty) return null;
    final out = StringBuffer();
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == r'\') {
        if (i + 1 >= pattern.length) return null;
        final next = pattern[i + 1];
        if (!_special.contains(next)) return null;
        out.write(next);
        i++;
      } else {
        if (_special.contains(c)) return null;
        out.write(c);
      }
    }
    final text = out.toString();
    return ownTextPattern(text) == pattern ? text : null;
  }

  static const _special = r'\^$.|?*+()[]{}';

  /// Which choice [pattern] is: a preset's own pattern, the person's own text,
  /// or null where it is a regular expression of the person's (Regex mode).
  static AlertPreset? of(String pattern) {
    for (final p in values) {
      if (p != ownText && p.pattern == pattern) return p;
    }
    return ownTextOf(pattern) != null ? ownText : null;
  }
}
