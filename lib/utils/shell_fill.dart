// Putting a value into a shell command someone wrote, with regard to where in
// the command it lands. Wrapping every value in single quotes is right for one
// that stands alone, and wrong for one inside quotes the command already has:
// `grep '${P}' log` with `foo; touch x; echo` became `grep ''foo; touch x;
// echo'' log`, which ran touch, and `echo "${P}"` with `$(touch x)` left the
// $(...) live, from a value a link or another app can give (found 30 October
// 2026 in an independent review). So the command is read as a POSIX shell reads
// it, as far as where a value lands depends on it, and each value is written the
// way that place takes it, so that it arrives as it is and is never read as part
// of the command.
//
// What no filling can help: a command that runs its own argument (eval, sh -c,
// ssh host, awk's system()) runs a value given to it, and the first word of a
// command names the program to run. And these are a POSIX shell's rules: a host
// whose login shell is fish, PowerShell or cmd.exe has others.

/// POSIX-shell single-quote escaping for a single argument.
///
/// Wraps the input in single quotes so shell metacharacters lose
/// their meaning. Embedded single quotes are escaped via the
/// canonical `'\''` close-and-reopen trick. Treats every input as
/// untrusted - pass `''` for empty strings, never bare-empty.
///
/// Examples:
///   `foo`            → `'foo'`
///   `foo bar`        → `'foo bar'`
///   `foo; rm /`      → `'foo; rm /'` (literal, no command split)
///   `it's`           → `'it'\''s'`
///   ``               → `''`
String shellEscapeArg(String value) {
  if (value.isEmpty) return "''";
  // Wrap in single quotes; replace any single quote inside with
  // the standard ''\'' sequence so it stays a single token.
  final escaped = value.replaceAll("'", r"'\''");
  return "'$escaped'";
}

/// [template] with each placeholder [values] has a value for replaced by that
/// value, in one pass over the template: what a value holds is never read for
/// placeholders of its own. A placeholder with no value is left as it is.
///
/// [values] is keyed by the name for `${NAME}`, `${NAME:-default}` and
/// `${NAME:secret}`, and by `[a,b]` for the lists `$[a,b]` and `${[a,b]}`. With
/// [doubleBraces], automation's own `{{name}}` too.
String fillPlaceholders(String template, Map<String, String> values, {bool doubleBraces = false}) {
  if (values.isEmpty) return template;
  final edits = _Walk(template, values, doubleBraces).edits();
  if (edits.isEmpty) return template;
  final out = StringBuffer();
  var at = 0;
  for (final e in edits) {
    out.write(template.substring(at, e.start));
    out.write(e.text);
    at = e.end;
  }
  out.write(template.substring(at));
  return out.toString();
}

/// Every way [fillPlaceholders] can write [value] in a command. What keeps a
/// value out of a log looks for it as it was typed, and `a$b` in double quotes
/// stands there as `a\$b`.
Set<String> filledForms(String value) => {
      value,
      value.replaceAll("'", r"'\''"),
      _backslashed(value, _liveInDoubleQuotes),
      _backslashed(value, _liveInHereDocument),
      _inAnsiC(value),
    };

final _placeholder = RegExp(
  r'\{\{(\w+)\}\}' // {{name}}
  r'|\$\{\[([^\]]*)\]\}' // ${[a,b]}
  r'|\$\[([^\]]*)\]' // $[a,b]
  r'|\$\{(\w+)(?::-[^}]*)?(?::(?:secret|password))?\}', // ${NAME}, ${NAME:-x}, ${NAME:secret}
);

final _aWord = RegExp(r'\w+');
final _leadingTabs = RegExp(r'^\t+');

/// What a double-quoted string keeps live.
final _liveInDoubleQuotes = RegExp(r'[\\"$`]');

/// The same in a `${...}` of the shell's own, whose `}` a value must not end it
/// with, and which reads a double quote as one even in a here-document.
final _liveInParameter = RegExp(r'[\\"$`}]');

/// What a here-document with an unquoted delimiter keeps live. (A double quote
/// is an ordinary character in it, and a backslash before one stays.)
final _liveInHereDocument = RegExp(r'[\\$`]');

/// What a backtick's inside loses one backslash from before it is read.
final _liveInBackticks = RegExp(r'[\\$`]');

/// What arithmetic has no use for: in `$(( ))` a single quote quotes nothing, and
/// `a[$(cmd)]` runs cmd when bash works the sum out, however it was escaped on
/// the way in. A value there is a number, a name or a sum.
final _notArithmetic = RegExp(r'[^\w +\-*/%<>=!&|^~?:,]');

/// The words after which the next word is a command again.
const _commandNext = {'then', 'do', 'else', 'elif', 'if', 'while', 'until', 'time'};

String _backslashed(String value, RegExp live) => value.replaceAllMapped(live, (m) => '\\${m[0]}');

/// A value inside `$'...'`, where a backslash is live and `\'` does not close it
/// for bash, and does for a shell that does not have `$'...'`. Written by number,
/// it has neither character in it to read either way.
String _inAnsiC(String value) => value.replaceAll(r'\', r'\x5c').replaceAll("'", r'\x27');

class _Edit {
  const _Edit(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

/// A here-document, from its `<<` on: the word that ends it, and how it is read.
class _HereDoc {
  const _HereDoc(this.word, {required this.stripsTabs, required this.literal});
  final String word;

  /// `<<-`: a line's leading tabs do not count.
  final bool stripsTabs;

  /// Its word was quoted: nothing in it is live.
  final bool literal;

  bool endsAt(String line) => (stripsTabs ? line.replaceFirst(_leadingTabs, '') : line) == word;
}

enum _In {
  /// Commands: the template itself, and a `$(...)`. (A backtick's inside is a
  /// walk of its own.)
  commands,
  singleQuotes,
  ansiCQuotes,
  doubleQuotes,

  /// A `${...}` of the shell's own: its inside takes the quoting of where it
  /// stands.
  parameter,
  arithmetic,
  comment,
  hereDocument,
}

class _Frame {
  _Frame(this.kind, {this.closesAtParen = false, this.dollar = false, this.hereDoc, this.lineStart = 0, this.editsAtLine = 0});

  final _In kind;

  /// A `$(...)`, whose own `)` ends it.
  final bool closesAtParen;

  /// Arithmetic: a `$((`, not a `((`.
  final bool dollar;

  /// How many of the frame's own parentheses are open.
  int parens = 0;

  /// For each `case` open, how many parentheses were open at it: a `)` at that
  /// depth ends a pattern, and closes nothing.
  final cases = <int>[];

  /// At the start of a word (a `#` starts a comment there).
  bool wordStart = true;

  /// The next word is a command (where `case` and `esac` mean what they say).
  bool commandNext = true;

  final _HereDoc? hereDoc;
  int lineStart;
  int editsAtLine;

  void wordGoes() {
    wordStart = false;
    commandNext = false;
  }

  void commandStarts() {
    wordStart = true;
    commandNext = true;
  }
}

class _Walk {
  _Walk(this.text, this.values, this.doubleBraces);

  final String text;
  final Map<String, String> values;
  final bool doubleBraces;

  final _edits = <_Edit>[];
  final _stack = <_Frame>[_Frame(_In.commands)];
  final _hereDocsPending = <_HereDoc>[];
  var _i = 0;

  /// Where a `$` of the shell's own ended: a value right there has `$'` before it.
  var _afterDollar = -1;

  List<_Edit> edits() {
    while (_i < text.length) {
      final f = _stack.last;
      if (f.kind == _In.hereDocument && _hereDocEndsHere(f)) continue;
      if (_fillHere()) continue;
      switch (f.kind) {
        case _In.commands:
          _inCommands(f);
        case _In.singleQuotes:
          if (text[_i] == "'") _stack.removeLast();
          _i++;
        case _In.ansiCQuotes:
          _inAnsiCQuotes();
        case _In.doubleQuotes:
          _inDoubleQuotes();
        case _In.parameter:
          _inParameter();
        case _In.arithmetic:
          _inArithmetic(f);
        case _In.comment:
          // (The line's end is the commands' own.)
          if (text[_i] == '\n') {
            _stack.removeLast();
          } else {
            _i++;
          }
        case _In.hereDocument:
          _inHereDocument(f);
      }
    }
    // A here-document with no end of its own, or none yet on its last line: a
    // value there can still end it, and leave a line of its own to run.
    for (final f in _stack.reversed) {
      if (f.kind != _In.hereDocument) continue;
      _i = text.length;
      _hereDocLineEnds(f);
      break;
    }
    return _edits;
  }

  /// The value of a placeholder standing here, written as this place takes it.
  bool _fillHere() {
    final c = text[_i];
    if (c != r'$' && !(doubleBraces && c == '{')) return false;
    final m = _placeholder.matchAsPrefix(text, _i);
    if (m == null) return false;
    final key = m[1] ?? (m[2] != null ? '[${m[2]}]' : (m[3] != null ? '[${m[3]}]' : m[4]));
    final value = key == null ? null : values[key];
    if (value == null) return false;
    _edits.add(_Edit(_i, m.end, _written(value)));
    _i = m.end;
    _stack.last.wordGoes();
    return true;
  }

  /// [value] as the place the walk stands in takes it.
  String _written(String value) {
    var inParameter = false;
    for (final f in _stack.reversed) {
      switch (f.kind) {
        case _In.parameter:
          inParameter = true;
          continue;
        case _In.commands:
          // `$${P}` is a `$` and a quote: bash reads that as `$'...'`.
          return _i == _afterDollar ? "'${_inAnsiC(value)}'" : shellEscapeArg(value);
        case _In.comment:
          // One line, or what follows its line break runs. Quoted as well: a
          // shell at a prompt need not take `#` for a comment (zsh does not).
          return shellEscapeArg(value.replaceAll(RegExp(r'[\r\n]'), ' '));
        case _In.singleQuotes:
          return value.replaceAll("'", r"'\''");
        case _In.ansiCQuotes:
          return _inAnsiC(value);
        case _In.doubleQuotes:
          return _backslashed(value, inParameter ? _liveInParameter : _liveInDoubleQuotes);
        case _In.arithmetic:
          return value.replaceAll(_notArithmetic, '');
        case _In.hereDocument:
          if (f.hereDoc!.literal) return value;
          return _backslashed(value, inParameter ? _liveInParameter : _liveInHereDocument);
      }
    }
    return shellEscapeArg(value);
  }

  void _inCommands(_Frame f) {
    final c = text[_i];
    if (c == r'\') {
      // What follows is not read: `\${P}` is the text `${P}`.
      _i += 2;
      f.wordGoes();
    } else if (c == "'" || c == '"') {
      f.wordGoes();
      _stack.add(_Frame(c == "'" ? _In.singleQuotes : _In.doubleQuotes));
      _i++;
    } else if (text.startsWith(r"$'", _i)) {
      f.wordGoes();
      _stack.add(_Frame(_In.ansiCQuotes));
      _i += 2;
    } else if (c == r'$' || c == '`') {
      f.wordGoes();
      _expansion();
    } else if (c == '#' && f.wordStart) {
      _stack.add(_Frame(_In.comment));
      _i++;
    } else if (c == '\n') {
      _i++;
      f.commandStarts();
      _hereDocsStart();
    } else if (c == ' ' || c == '\t' || c == '\r') {
      _i++;
      f.wordStart = true;
    } else if (c == ';' || c == '&' || c == '|') {
      _i++;
      f.commandStarts();
    } else if (c == '(') {
      if (f.wordStart && f.commandNext && text.startsWith('((', _i)) {
        f.wordGoes();
        _stack.add(_Frame(_In.arithmetic));
        _i += 2;
      } else {
        f.parens++;
        _i++;
        f.commandStarts();
      }
    } else if (c == ')') {
      _i++;
      if (f.cases.isNotEmpty && f.parens == f.cases.last) {
        f.commandStarts();
      } else if (f.parens > 0) {
        f.parens--;
        f.commandStarts();
      } else if (f.closesAtParen) {
        _stack.removeLast();
      }
    } else if (text.startsWith('<<', _i)) {
      _hereDocOperator(f);
    } else if (f.wordStart && _aWord.matchAsPrefix(text, _i) != null) {
      _word(f);
    } else {
      _i++;
      f.wordStart = false;
      if (c != '{' && c != '!') f.commandNext = false;
    }
  }

  /// A word: `case` and `esac` matter, where they are the words themselves, at
  /// the place of a command. The `)` of a case's pattern closes nothing.
  void _word(_Frame f) {
    final end = _aWord.matchAsPrefix(text, _i)!.end;
    final word = text.substring(_i, end);
    final whole = end == text.length || ' \t\r\n;&|()'.contains(text[end]);
    _i = end;
    f.wordStart = false;
    if (!f.commandNext || !whole) {
      f.commandNext = false;
    } else if (word == 'case') {
      f.cases.add(f.parens);
      f.commandNext = false;
    } else if (word == 'esac' && f.cases.isNotEmpty) {
      f.cases.removeLast();
      f.commandNext = false;
    } else if (!_commandNext.contains(word)) {
      f.commandNext = false;
    }
  }

  /// A `$` or a backtick where they are live.
  void _expansion() {
    if (text[_i] == '`') {
      _backtick();
    } else if (text.startsWith(r'$((', _i)) {
      _stack.add(_Frame(_In.arithmetic, dollar: true));
      _i += 3;
    } else if (text.startsWith(r'$(', _i)) {
      _stack.add(_Frame(_In.commands, closesAtParen: true));
      _i += 2;
    } else if (text.startsWith(r'${', _i)) {
      _stack.add(_Frame(_In.parameter));
      _i += 2;
    } else {
      _i++;
      _afterDollar = _i;
    }
  }

  /// A backtick's inside is a command of its own, once one backslash has gone
  /// from before each `\`, `$` and backtick, and the shell looks for its closing
  /// backtick before it reads any quote. So it is walked as that command, and a
  /// value in it has a backslash more before those three, at every depth: a
  /// backtick in a single-quoted value closed the substitution all the same.
  void _backtick() {
    final inside = StringBuffer();
    // Where each character of [inside] is in the template, and where it ends.
    final at = <int>[];
    var j = _i + 1;
    while (j < text.length && text[j] != '`') {
      at.add(j);
      if (text[j] == r'\' && j + 1 < text.length && _liveInBackticks.hasMatch(text[j + 1])) {
        inside.write(text[j + 1]);
        j += 2;
      } else {
        inside.write(text[j]);
        j++;
      }
    }
    at.add(j);
    for (final e in _Walk(inside.toString(), values, doubleBraces).edits()) {
      _edits.add(_Edit(at[e.start], at[e.end], _backslashed(e.text, _liveInBackticks)));
    }
    _i = j + 1;
  }

  void _inAnsiCQuotes() {
    final c = text[_i];
    if (c == r'\') {
      _i += 2;
    } else {
      if (c == "'") _stack.removeLast();
      _i++;
    }
  }

  void _inDoubleQuotes() {
    final c = text[_i];
    if (c == r'\') {
      _i += 2;
    } else if (c == r'$' || c == '`') {
      _expansion();
    } else {
      if (c == '"') _stack.removeLast();
      _i++;
    }
  }

  /// Whether what stands around the `${...}` on top is quoted: there a single
  /// quote is an ordinary character.
  bool get _parameterQuoted {
    for (final f in _stack.reversed.skip(1)) {
      if (f.kind == _In.parameter) continue;
      return f.kind != _In.commands;
    }
    return false;
  }

  void _inParameter() {
    final c = text[_i];
    if (c == r'\') {
      _i += 2;
    } else if (c == '}') {
      _stack.removeLast();
      _i++;
    } else if (c == '"') {
      _stack.add(_Frame(_In.doubleQuotes));
      _i++;
    } else if (c == "'" && !_parameterQuoted) {
      _stack.add(_Frame(_In.singleQuotes));
      _i++;
    } else if (text.startsWith(r"$'", _i) && !_parameterQuoted) {
      _stack.add(_Frame(_In.ansiCQuotes));
      _i += 2;
    } else if (c == r'$' || c == '`') {
      _expansion();
    } else {
      _i++;
    }
  }

  void _inArithmetic(_Frame f) {
    final c = text[_i];
    if (c == r'\') {
      _i += 2;
    } else if (c == r'$' || c == '`') {
      _expansion();
    } else if (c == '(') {
      f.parens++;
      _i++;
    } else if (c != ')') {
      _i++;
    } else if (f.parens > 0) {
      f.parens--;
      _i++;
    } else if (text.startsWith('))', _i)) {
      _stack.removeLast();
      _i += 2;
    } else {
      // Not a sum after all: `$((a); (b))` is a `$(` and a subshell that has just
      // closed, and `((a); (b))` two subshells, one still open.
      _i++;
      _stack.removeLast();
      if (f.dollar) {
        _stack.add(_Frame(_In.commands, closesAtParen: true)..commandStarts());
      } else {
        _stack.last
          ..parens += 1
          ..commandStarts();
      }
    }
  }

  /// `<<`: its word is read as it is, never filled, as the shell never expands
  /// it; the body starts at the next line. (`<<<` has an ordinary word.)
  void _hereDocOperator(_Frame f) {
    if (text.startsWith('<<<', _i)) {
      _i += 3;
      f.wordStart = true;
      return;
    }
    var j = _i + 2;
    final stripsTabs = j < text.length && text[j] == '-';
    if (stripsTabs) j++;
    while (j < text.length && (text[j] == ' ' || text[j] == '\t')) {
      j++;
    }
    final word = StringBuffer();
    var quoted = false;
    while (j < text.length && !' \t\r\n;&|<>()'.contains(text[j])) {
      final c = text[j];
      if (c == r'\') {
        quoted = true;
        if (j + 1 < text.length) word.write(text[j + 1]);
        j += 2;
      } else if (c == "'" || c == '"') {
        quoted = true;
        final close = text.indexOf(c, j + 1);
        if (close < 0) {
          j = text.length;
        } else {
          word.write(text.substring(j + 1, close));
          j = close + 1;
        }
      } else {
        word.write(c);
        j++;
      }
    }
    if (word.isNotEmpty || quoted) {
      _hereDocsPending.add(_HereDoc(word.toString(), stripsTabs: stripsTabs, literal: quoted));
    }
    _i = j;
    f.wordStart = true;
  }

  void _hereDocsStart() {
    for (final d in _hereDocsPending.reversed) {
      _stack.add(_Frame(_In.hereDocument, hereDoc: d, lineStart: _i, editsAtLine: _edits.length));
    }
    _hereDocsPending.clear();
  }

  bool _hereDocEndsHere(_Frame f) {
    if (_i != f.lineStart) return false;
    final newline = text.indexOf('\n', _i);
    final end = newline < 0 ? text.length : newline;
    if (!f.hereDoc!.endsAt(text.substring(_i, end))) return false;
    _stack.removeLast();
    _i = newline < 0 ? end : end + 1;
    final next = _stack.last;
    if (next.kind == _In.hereDocument) {
      next.lineStart = _i;
      next.editsAtLine = _edits.length;
    }
    return true;
  }

  void _inHereDocument(_Frame f) {
    final c = text[_i];
    if (c == '\n') {
      _hereDocLineEnds(f);
      _i++;
      f.lineStart = _i;
      f.editsAtLine = _edits.length;
    } else if (f.hereDoc!.literal) {
      _i++;
    } else if (c == r'\') {
      _i += 2;
    } else if (c == r'$' || c == '`') {
      _expansion();
    } else {
      _i++;
    }
  }

  /// A value must not end its here-document, whatever it holds: a line of it, or
  /// what it makes of the line it is on, that is the word that ends it would
  /// leave what follows to run as commands. There the line stays one line, and
  /// has a space at its end, so it is not that word any more.
  void _hereDocLineEnds(_Frame f) {
    final ofLine = _edits.sublist(f.editsAtLine);
    if (ofLine.isEmpty) return;
    final line = StringBuffer();
    var at = f.lineStart;
    for (final e in ofLine) {
      line.write(text.substring(at, e.start));
      line.write(e.text);
      at = e.end;
    }
    line.write(text.substring(at, _i));
    if (!line.toString().split('\n').any(f.hereDoc!.endsAt)) return;
    for (var k = f.editsAtLine; k < _edits.length; k++) {
      final e = _edits[k];
      _edits[k] = _Edit(e.start, e.end, e.text.replaceAll('\n', ' '));
    }
    _edits.add(_Edit(_i, _i, ' '));
  }
}
