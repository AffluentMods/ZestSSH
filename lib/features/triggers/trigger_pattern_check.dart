/// What a trigger's regular expression can cost, told from its shape alone.
///
/// An alert's pattern travels in a team's vault, so anyone who may add to one
/// chooses a pattern that runs on the output of everyone's sessions, and Dart's
/// RegExp backtracks on the one isolate the screen and every session share, with
/// no way to stop it: `(a+)+$` on a line of forty a's and a b holds the app for
/// good (found in a security review). So a pattern is read here before it
/// is used, as the automaton a backtracking engine walks, and what it can cost is
/// worked out from the number of ways that automaton has to read one line:
///
/// * Ways that grow exponentially with the line (two ways round a loop on the
///   same text: a repeat inside a repeat, or alternatives that overlap, under a
///   repeat): refused, whatever the line's length.
/// * More ways than can be tried for each place a match may start, with no loop at
///   all (`a?a?a?...` thirty times): refused.
/// * Polynomial ways, by how many loops can read the same text one after the
///   other. Each adds a power of the line's length, and so does a match that may
///   start anywhere. Up to the square is matched against [kTriggerMaxLineChars]
///   of a line, a cube against [kTriggerMaxOverlapLineChars], and from the fourth
///   power on it is refused (`.*a.*b.*c`, `^.*a.*b.*c.*d`).
/// * What looks around, where the shape of the pattern no longer says the cost: a
///   lookbehind with a repeat of any length (it is run backward, so what reads as
///   the end of it, with nothing after it to fail, is the start: `(?<=z(a+)+)b`
///   goes through every way there is), and a look inside a look (each one tries the
///   rest of the line again, for every place the one around it tried).
///
/// A loop at the end of a pattern, with nothing after it that can fail, costs
/// nothing: the first way through is the match. A `.` loop before a final `$` is
/// such a loop, as a line is matched with no line ending left in it
/// ([boundTriggerLine]): it reads on to the end, where `$` holds. And loops that
/// cannot read the same text have one way to split a line between them (`\d+\.\d+`,
/// `(\d+\.)+`). So what people write works: words, alternatives, `\b`, `\d+`, a `.*`
/// or two between words. Pure Dart, as the engine is, and given every pattern once.
library;

import 'package:zestssh/utils/type_name.dart';

/// The longest pattern used: what is longer is no alert anybody typed.
const int kTriggerMaxPatternChars = 1024;

/// How much of a line a pattern is matched against. A line is 64 KB at most by
/// the time it is matched (the line scanner's limit), and a single `.*` goes back
/// over all of what it read from every place a match may start: at this length
/// about 40 ms, as the app is built, at the very worst.
const int kTriggerMaxLineChars = 4096;

/// How much of a line a pattern is matched against whose cost goes with the cube
/// of it: two loops that can read the same text, starting anywhere (`a.*b.*c`).
const int kTriggerMaxOverlapLineChars = 512;

/// Repeats counted beyond this are not laid out one by one (a single character's
/// is taken for a loop; anything else's is refused).
const int _maxCount = 64;

/// The most characters of a pattern's automaton, with its repeats laid out.
const int _maxPositions = 1024;

/// The most ways through a pattern from one place a match may start, loops
/// counted once.
const int _maxWays = 1 << 14;

/// The most work spent reading one pattern: what takes more is refused. (A
/// thousand characters of words between bars come to less than half of it, and
/// what people write to a few hundred.)
const int _maxWork = 300000;

/// What was found of a pattern: whether it is refused, and how much of a line it
/// is matched against otherwise.
class TriggerPatternCheck {
  const TriggerPatternCheck._(this.refused, this.maxLine);

  static const fine = TriggerPatternCheck._(false, kTriggerMaxLineChars);
  static const overlapping = TriggerPatternCheck._(false, kTriggerMaxOverlapLineChars);
  static const refusedOne = TriggerPatternCheck._(true, 0);

  final bool refused;

  /// How much of a line it is matched against; 0 where it is refused.
  final int maxLine;

  /// [line], as this pattern is matched against it ([boundTriggerLine]).
  String bound(String line) => boundTriggerLine(line, maxLine);
}

final _lineEndings = RegExp('[\n\r\u2028\u2029]');

/// [line], cut to [maxLine], with a space for any line ending left in it (one for one,
/// so that where a match falls stays where it is on the line). `.` reads none of them,
/// so with one left in a line a `.*$` could fail after all, and the check above counts
/// on it that it cannot: `^(.*?),(.*?),(.*?),(.*?)$` on commas and a U+2028 would go
/// through every way there is.
String boundTriggerLine(String line, int maxLine) =>
    (line.length > maxLine ? line.substring(0, maxLine) : line).replaceAll(_lineEndings, ' ');

/// Asked again whenever the alerts change, and for each key typed in an editor.
final _checked = <String, TriggerPatternCheck>{};

/// What [source], a regular expression as Dart's RegExp takes it, can cost
/// ([ignoreCase]: matched with upper and lower case alike).
TriggerPatternCheck checkTriggerPattern(String source, {required bool ignoreCase}) {
  if (source.length > kTriggerMaxPatternChars) return TriggerPatternCheck.refusedOne;
  final key = '${ignoreCase ? 'i' : 'c'}$source';
  final known = _checked[key];
  if (known != null) return known;
  final TriggerPatternCheck result;
  try {
    result = _check(source, ignoreCase);
  } on _CannotTell {
    return _keep(key, TriggerPatternCheck.refusedOne);
  }
  return _keep(key, result);
}

TriggerPatternCheck _keep(String key, TriggerPatternCheck result) {
  if (_checked.length >= 256) _checked.clear();
  return _checked[key] = result;
}

/// Too much to read, or nothing this reader knows: such a pattern is not used.
class _CannotTell implements Exception, HasTypeName {
  const _CannotTell();

  @override
  String get typeName => '_CannotTell';

  @override
  String toString() => 'This pattern cannot be told to be safe to run';
}

TriggerPatternCheck _check(String source, bool ignoreCase) {
  final parser = _Parser(source, ignoreCase);
  final root = parser.parse();
  final work = _Work();
  // The power of a line's length it can cost: its loops that read the same text
  // one after the other, and one more where a match may start anywhere.
  var power = _loopsOf(root, work) + (_startsAtStart(root) ? 0 : 1);
  // What looks around is read as a pattern of its own, tried at each place it is
  // reached, a loop before it among them (a repeat around one, with a loop
  // inside, was refused as it was read).
  var inside = 0;
  for (final look in parser.looks) {
    final loops = _loopsOf(look, work);
    if (loops > inside) inside = loops;
  }
  power += inside;
  if (parser.refused) throw const _CannotTell();
  // What a back-reference matches is whatever its group did: no automaton says
  // what that costs in a loop.
  if (parser.backReference && parser.hasLoop) throw const _CannotTell();
  return power <= 2
      ? TriggerPatternCheck.fine
      : power == 3
          ? TriggerPatternCheck.overlapping
          : TriggerPatternCheck.refusedOne;
}

/// Whether a pattern can only match from the start of a line.
bool _startsAtStart(_Node root) {
  final first = root is _Sequence ? root.items.firstOrNull : root;
  return first is _Check && first.lineStart;
}

/// Counts what is spent: what is too much to read is not used.
class _Work {
  var _spent = 0;

  void spend(int n) {
    _spent += n;
    if (_spent > _maxWork) throw const _CannotTell();
  }
}

// ── Characters ─────────────────────────────────────────────────────────────

/// A set of characters: exact for ASCII, and past that by which of 64 buckets a
/// character falls into, or all of them; the spaces past ASCII apart, so that
/// `\s` and `\S` are told apart.
class _Chars {
  int _low = 0;
  int _high = 0;
  int _rest = 0;

  /// It holds a space past ASCII; it holds all of them.
  bool _someSpaces = false;
  bool _allSpaces = false;

  static bool _isSpace(int code) =>
      const {0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff}.contains(code) ||
      (code >= 0x2000 && code <= 0x200a);

  void add(int code, bool ignoreCase) {
    if (!ignoreCase) return _addOne(code);
    final text = String.fromCharCode(code);
    _addOne(code);
    for (final other in [text.toLowerCase(), text.toUpperCase()]) {
      if (other.length == 1) _addOne(other.codeUnitAt(0));
    }
  }

  void _addOne(int code) {
    if (code < 64) {
      _low |= 1 << code;
    } else if (code < 128) {
      _high |= 1 << (code - 64);
    } else if (_isSpace(code)) {
      _someSpaces = true;
    } else {
      _rest |= 1 << (code & 63);
    }
  }

  void addRange(int from, int to, bool ignoreCase) {
    for (var c = from; c <= to && c < 128; c++) {
      add(c, ignoreCase);
    }
    if (to >= 128) {
      _rest = -1;
      _someSpaces = true;
    }
  }

  void addAll(_Chars other) {
    _low |= other._low;
    _high |= other._high;
    _rest |= other._rest;
    _someSpaces = _someSpaces || other._someSpaces;
    _allSpaces = _allSpaces || other._allSpaces;
  }

  /// Everything but these.
  void negate() {
    _low = ~_low;
    _high = ~_high;
    _rest = -1;
    final some = _someSpaces;
    _someSpaces = !_allSpaces;
    _allSpaces = !some;
  }

  /// It holds whatever a line, with no line ending left in it, can hold.
  bool get holdsAnyLine {
    final dot = _Chars.dot();
    return dot._low & ~_low == 0 && dot._high & ~_high == 0 && dot._rest & ~_rest == 0 && _someSpaces && _allSpaces;
  }

  bool meets(_Chars other) =>
      _low & other._low != 0 ||
      _high & other._high != 0 ||
      _rest & other._rest != 0 ||
      (_someSpaces && other._someSpaces);

  bool meetsBoth(_Chars a, _Chars b) =>
      _low & a._low & b._low != 0 ||
      _high & a._high & b._high != 0 ||
      _rest & a._rest & b._rest != 0 ||
      (_someSpaces && a._someSpaces && b._someSpaces);

  static _Chars digits() => _Chars()..addRange(0x30, 0x39, false);

  static _Chars word() => _Chars()
    ..addRange(0x30, 0x39, false)
    ..addRange(0x41, 0x5a, false)
    ..addRange(0x61, 0x7a, false)
    ..add(0x5f, false);

  static _Chars space() => _Chars()
    ..addRange(0x09, 0x0d, false)
    ..add(0x20, false)
    .._someSpaces = true
    .._allSpaces = true;

  static _Chars anything() => _Chars()..negate();

  /// What `.` matches.
  static _Chars dot() {
    final none = _Chars()
      ..add(0x0a, false)
      ..add(0x0d, false);
    return none..negate();
  }
}

// ── The pattern as a tree ──────────────────────────────────────────────────

sealed class _Node {}

/// One character.
final class _One extends _Node {
  _One(this.chars);

  final _Chars chars;
}

final class _Sequence extends _Node {
  _Sequence(this.items);

  final List<_Node> items;
}

final class _Either extends _Node {
  _Either(this.branches);

  final List<_Node> branches;
}

final class _Repeat extends _Node {
  _Repeat(this.child, this.min, this.max);

  final _Node child;
  final int min;

  /// Null for no limit.
  final int? max;
}

/// Something that reads nothing and can fail: `^`, `$`, `\b`, what looks around,
/// or a back-reference.
final class _Check extends _Node {
  _Check({this.loopInside = false, this.lineStart = false, this.lineEnd = false});

  /// What looks around has a loop in it: tried at each place it is reached.
  final bool loopInside;

  /// It is `^`.
  final bool lineStart;

  /// It is `$`.
  final bool lineEnd;
}

class _Parser {
  _Parser(this.source, this.ignoreCase);

  final String source;
  final bool ignoreCase;
  var _at = 0;

  /// What looks around, to be read as patterns of their own.
  final looks = <_Node>[];

  bool backReference = false;
  bool hasLoop = false;

  /// A repeat around something that looks around with a loop inside, a repeat of any
  /// length in a lookbehind, or a look inside a look.
  bool refused = false;

  /// How many looks the reader is inside.
  var _looksOpen = 0;

  _Node parse() {
    final node = _either();
    if (_at != source.length) throw const _CannotTell();
    return node;
  }

  bool get _ended => _at >= source.length;

  String get _next => _ended ? '' : source[_at];

  bool _take(String text) {
    if (!source.startsWith(text, _at)) return false;
    _at += text.length;
    return true;
  }

  _Node _either() {
    final branches = [_sequence()];
    while (_take('|')) {
      branches.add(_sequence());
    }
    return branches.length == 1 ? branches.single : _Either(branches);
  }

  _Node _sequence() {
    final items = <_Node>[];
    while (!_ended && _next != '|' && _next != ')') {
      items.add(_repeated(_atom()));
    }
    return items.length == 1 ? items.single : _Sequence(items);
  }

  static final _counted = RegExp(r'\{([0-9]+)(,([0-9]*))?\}');

  _Node _repeated(_Node atom) {
    final int min;
    int? max;
    if (_take('*')) {
      min = 0;
    } else if (_take('+')) {
      min = 1;
    } else if (_take('?')) {
      min = 0;
      max = 1;
    } else {
      final count = _next == '{' ? _counted.matchAsPrefix(source, _at) : null;
      if (count == null) return atom;
      _at = count.end;
      // Past what a whole number holds is no count anybody needs.
      min = int.tryParse(count.group(1)!) ?? (throw const _CannotTell());
      if (count.group(2) == null) {
        max = min;
      } else if (count.group(3)!.isNotEmpty) {
        max = int.tryParse(count.group(3)!) ?? (throw const _CannotTell());
      }
    }
    _take('?'); // Lazy goes through the same ways, in another order.
    if (max == null || max > 1) {
      if (_looksWithLoop(atom)) refused = true;
      hasLoop = true;
    }
    return _Repeat(atom, min, max);
  }

  static bool _looksWithLoop(_Node node) => switch (node) {
        _One() => false,
        _Sequence(:final items) => items.any(_looksWithLoop),
        _Either(:final branches) => branches.any(_looksWithLoop),
        _Repeat(:final child) => _looksWithLoop(child),
        _Check(:final loopInside) => loopInside,
      };

  /// A repeat that can read more than one length, or holds one: a lookbehind is run
  /// backward, so no end of it is safe.
  static bool _varies(_Node node) => switch (node) {
        _One() || _Check() => false,
        _Sequence(:final items) => items.any(_varies),
        _Either(:final branches) => branches.any(_varies),
        _Repeat(:final child, :final min, :final max) => max == null || (max > 1 && max != min) || _varies(child),
      };

  static bool _loopIn(_Node node) => switch (node) {
        _One() || _Check() => false,
        _Sequence(:final items) => items.any(_loopIn),
        _Either(:final branches) => branches.any(_loopIn),
        _Repeat(:final child, :final max) => max == null || max > 1 || _loopIn(child),
      };

  _Node _atom() {
    final c = _next;
    switch (c) {
      case '^':
        _at++;
        return _Check(lineStart: true);
      case r'$':
        _at++;
        return _Check(lineEnd: true);
      case '.':
        _at++;
        return _One(_Chars.dot());
      case '[':
        return _One(_class());
      case r'\':
        return _escape();
      case '(':
        _at++;
        return _group();
    }
    _at++;
    return _character(c.codeUnitAt(0));
  }

  _Node _character(int code) => _One(_Chars()..add(code, ignoreCase));

  _Node _group() {
    final behind = source.startsWith('?<=', _at) || source.startsWith('?<!', _at);
    final look = _take('?=') || _take('?!') || _take('?<=') || _take('?<!');
    if (!look && !_take('?:') && _take('?<')) {
      final end = source.indexOf('>', _at);
      if (end < 0) throw const _CannotTell();
      _at = end + 1;
    }
    if (look) {
      if (_looksOpen > 0) refused = true;
      _looksOpen++;
    }
    final inside = _either();
    if (look) _looksOpen--;
    if (!_take(')')) throw const _CannotTell();
    if (!look) return inside;
    if (behind && _varies(inside)) refused = true;
    looks.add(inside);
    return _Check(loopInside: _loopIn(inside));
  }

  _Node _escape() {
    _at++;
    if (_ended) throw const _CannotTell();
    final c = _next;
    if (c == 'b' || c == 'B') {
      _at++;
      return _Check();
    }
    if (c == 'k' && _at + 1 < source.length && source[_at + 1] == '<') {
      final end = source.indexOf('>', _at);
      if (end < 0) throw const _CannotTell();
      _at = end + 1;
      backReference = true;
      return _Check();
    }
    if (c.codeUnitAt(0) >= 0x31 && c.codeUnitAt(0) <= 0x39) {
      while (!_ended && _next.codeUnitAt(0) >= 0x30 && _next.codeUnitAt(0) <= 0x39) {
        _at++;
      }
      backReference = true;
      return _Check();
    }
    final set = _set(c);
    if (set != null) {
      _at++;
      return _One(set);
    }
    return _character(_escapedCode());
  }

  /// What `\d` and the like stand for, by the letter [c]; null for anything else.
  static _Chars? _set(String c) => switch (c) {
        'd' => _Chars.digits(),
        'D' => _Chars.digits()..negate(),
        'w' => _Chars.word(),
        'W' => _Chars.word()..negate(),
        's' => _Chars.space(),
        'S' => _Chars.space()..negate(),
        _ => null,
      };

  /// The character an escape, read from just after its backslash, stands for.
  int _escapedCode() {
    final c = _next;
    _at++;
    switch (c) {
      case 't':
        return 0x09;
      case 'n':
        return 0x0a;
      case 'v':
        return 0x0b;
      case 'f':
        return 0x0c;
      case 'r':
        return 0x0d;
      case '0':
        return 0;
      case 'c':
        if (!_ended && RegExp('[A-Za-z]').hasMatch(_next)) {
          final code = _next.codeUnitAt(0) % 32;
          _at++;
          return code;
        }
      case 'x':
        final code = _hex(2);
        if (code != null) return code;
      case 'u':
        final code = _hex(4);
        if (code != null) return code;
    }
    return c.codeUnitAt(0);
  }

  int? _hex(int digits) {
    if (_at + digits > source.length) return null;
    final text = source.substring(_at, _at + digits);
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) return null;
    _at += digits;
    return int.parse(text, radix: 16);
  }

  _Chars _class() {
    _at++;
    final negated = _take('^');
    final set = _Chars();
    while (true) {
      if (_ended) throw const _CannotTell();
      if (_take(']')) break;
      final from = _classMember(set);
      if (from != null && _next == '-' && _at + 1 < source.length && source[_at + 1] != ']') {
        _at++;
        final to = _classMember(set);
        if (to == null) {
          set
            ..add(from, ignoreCase)
            ..add(0x2d, false);
        } else if (from <= to) {
          set.addRange(from, to, ignoreCase);
        }
      } else if (from != null) {
        set.add(from, ignoreCase);
      }
    }
    if (negated) set.negate();
    return set;
  }

  /// The next character of a `[...]`, as its code; or, where it is `\d` or the
  /// like, null, with what it stands for added to [set].
  int? _classMember(_Chars set) {
    if (_next != r'\') {
      final code = _next.codeUnitAt(0);
      _at++;
      return code;
    }
    _at++;
    if (_ended) throw const _CannotTell();
    if (_next == 'b') {
      _at++;
      return 0x08;
    }
    final preset = _set(_next);
    if (preset != null) {
      _at++;
      set.addAll(preset);
      return null;
    }
    return _escapedCode();
  }
}

// ── The automaton ──────────────────────────────────────────────────────────

/// A part of a pattern as positions of its automaton: whether it can read
/// nothing, where it can start and end, where it can end with nothing after it
/// that can fail ([safe]), and whether reading nothing through it can fail.
class _Part {
  _Part(this.nullable, this.first, this.last, this.safe, this.checks, {this.endsLine = false});

  final bool nullable;
  final Set<int> first;
  final Set<int> last;
  final Set<int> safe;
  final bool checks;

  /// It is `$`.
  final bool endsLine;
}

/// The automaton of a pattern, with one position for each character it may read
/// (each repeat laid out), as a backtracking engine walks it.
class _Automaton {
  final chars = <_Chars>[];
  final follow = <Set<int>>[];

  /// Positions with two ways round to the same next position: a repeat right
  /// inside a repeat.
  final twice = <int>{};

  int _position(_Chars set) {
    if (chars.length >= _maxPositions) throw const _CannotTell();
    chars.add(set);
    follow.add({});
    return chars.length - 1;
  }

  void _link(Set<int> from, Set<int> to) {
    for (final p in from) {
      for (final q in to) {
        if (!follow[p].add(q)) twice.add(p);
      }
    }
  }

  _Part _then(_Part a, _Part b) {
    _link(a.last, b.first);
    return _Part(
      a.nullable && b.nullable,
      {...a.first, if (a.nullable) ...b.first},
      {...b.last, if (b.nullable) ...a.last},
      {
        ...b.safe,
        if (b.nullable && !b.checks) ...a.safe,
        // A loop that reads anything a line holds goes on to its end, where `$` holds.
        if (b.endsLine) ...a.safe.where((p) => follow[p].contains(p) && chars[p].holdsAnyLine),
      },
      a.checks || b.checks,
    );
  }

  static _Part _nothing() => _Part(true, {}, {}, {}, false);

  _Part build(_Node node) {
    switch (node) {
      case _One(:final chars):
        final p = _position(chars);
        return _Part(false, {p}, {p}, {p}, false);
      case _Check(:final lineEnd):
        return _Part(true, {}, {}, {}, true, endsLine: lineEnd);
      case _Sequence(:final items):
        return items.map(build).fold(_nothing(), _then);
      case _Either(:final branches):
        final parts = branches.map(build).toList();
        return _Part(
          parts.any((p) => p.nullable),
          {for (final p in parts) ...p.first},
          {for (final p in parts) ...p.last},
          {for (final p in parts) ...p.safe},
          parts.any((p) => p.nullable && p.checks),
        );
      case _Repeat(:final child, :final min, :final max):
        return _repeat(child, min, max);
    }
  }

  _Part _repeat(_Node child, int min, int? max) {
    if ((max ?? min) > _maxCount) {
      // Too many to lay out: one character's is as good as a loop.
      if (child is! _One) throw const _CannotTell();
      final part = build(child);
      _link(part.last, part.first);
      return _Part(min == 0, part.first, part.last, part.safe, false);
    }
    var whole = _nothing();
    if (max == null) {
      // x{2,}: x x+, the loop standing for the last copy it needs.
      for (var i = 1; i < min; i++) {
        whole = _then(whole, build(child));
      }
      final part = build(child);
      _link(part.last, part.first);
      return _then(whole, _Part(min == 0 || part.nullable, part.first, part.last, part.safe, min > 0 && part.checks));
    }
    for (var i = 0; i < min; i++) {
      whole = _then(whole, build(child));
    }
    // x{2,4}: x x (x (x)?)?, which has one way to read each length.
    _Part? rest;
    for (var i = min; i < max; i++) {
      final copy = build(child);
      final inner = rest == null ? copy : _then(copy, rest);
      rest = _Part(true, inner.first, inner.last, inner.safe, false);
    }
    return rest == null ? whole : _then(whole, rest);
  }
}

/// The strongly connected parts of the graph [next] gives, reached from [root],
/// each one finished after those it leads to.
List<List<int>> _parts(int root, List<int> Function(int) next) {
  final index = <int, int>{};
  final low = <int, int>{};
  final open = <int>{};
  final order = <int>[];
  final out = <List<int>>[];
  final nodes = <int>[];
  final edges = <List<int>>[];
  final positions = <int>[];

  void enter(int v) {
    index[v] = low[v] = index.length;
    order.add(v);
    open.add(v);
    nodes.add(v);
    edges.add(next(v));
    positions.add(0);
  }

  enter(root);
  while (nodes.isNotEmpty) {
    final v = nodes.last;
    final at = positions.last;
    if (at < edges.last.length) {
      positions[positions.length - 1] = at + 1;
      final w = edges.last[at];
      if (!index.containsKey(w)) {
        enter(w);
      } else if (open.contains(w) && index[w]! < low[v]!) {
        low[v] = index[w]!;
      }
      continue;
    }
    nodes.removeLast();
    edges.removeLast();
    positions.removeLast();
    if (nodes.isNotEmpty && low[v]! < low[nodes.last]!) low[nodes.last] = low[v]!;
    if (low[v] == index[v]) {
      final part = <int>[];
      while (true) {
        final w = order.removeLast();
        open.remove(w);
        part.add(w);
        if (w == v) break;
      }
      out.add(part);
    }
  }
  return out;
}

/// How many loops of [root] can read the same text one after the other, with
/// something after them that can fail; throws [_CannotTell] for what grows
/// exponentially, or is too much to read.
int _loopsOf(_Node root, _Work work) {
  final automaton = _Automaton();
  final whole = automaton.build(root);
  final follow = automaton.follow;
  final chars = automaton.chars;
  // Where every match starts from, reading nothing.
  final start = chars.length;
  chars.add(_Chars.anything());
  follow.add(whole.first);
  final safe = whole.safe;
  final count = chars.length;

  if (automaton.twice.any((p) => !safe.contains(p))) throw const _CannotTell();

  final parts = _parts(start, (p) {
    work.spend(follow[p].length);
    return follow[p].toList();
  });

  // More ways through than can be tried, loops counted once.
  final partOf = <int, int>{
    for (var i = 0; i < parts.length; i++)
      for (final p in parts[i]) p: i,
  };
  final ways = List<int>.filled(parts.length, 1);
  for (var i = 0; i < parts.length; i++) {
    var sum = 0;
    for (final p in parts[i]) {
      for (final q in follow[p]) {
        if (partOf[q] != i) sum += ways[partOf[q]!];
        if (sum > _maxWays) throw const _CannotTell();
      }
    }
    if (sum > 0) ways[i] = sum;
  }

  // Two ways round a loop, reading the same text: the pairs of positions the
  // automaton can be in at once, one way and the other. A part of those holding
  // both one position twice and two different ones comes back to where it was
  // after going two ways.
  int pair(int p, int q) => p < q ? p * count + q : q * count + p;
  final pairs = _parts(pair(start, start), (node) {
    final p = node ~/ count, q = node % count;
    final next = <int>{};
    for (final a in follow[p]) {
      work.spend(follow[q].length);
      for (final b in follow[q]) {
        if (chars[a].meets(chars[b])) next.add(pair(a, b));
      }
    }
    return next.toList();
  });
  for (final part in pairs) {
    if (part.length < 2) continue;
    var same = false, different = false, canFail = false;
    for (final node in part) {
      final p = node ~/ count, q = node % count;
      p == q ? same = true : different = true;
      if ((p != start && !safe.contains(p)) || (q != start && !safe.contains(q))) canFail = true;
    }
    if (same && different && canFail) throw const _CannotTell();
  }

  // The loops with something after them that can fail, in the order the
  // automaton reaches them (parts finish after those they lead to).
  final loops = [
    for (final part in parts.reversed)
      if ((part.length > 1 || follow[part.single].contains(part.single)) && part.any((p) => !safe.contains(p))) part,
  ];
  if (loops.length > 32) throw const _CannotTell();
  if (loops.isEmpty) return 0;

  // One loop leads on to another reading the same text where some text takes
  // the automaton round the first, from it to the second, and round the second.
  bool overlap(List<int> first, List<int> second) {
    for (final p in first) {
      for (final q in second) {
        if (_roundAndOn(p, q, follow, chars, count, work)) return true;
      }
    }
    return false;
  }

  var longest = 1;
  final length = List<int>.filled(loops.length, 1);
  for (var i = 1; i < loops.length; i++) {
    for (var j = 0; j < i; j++) {
      if (length[j] + 1 > length[i] && overlap(loops[j], loops[i])) length[i] = length[j] + 1;
    }
    if (length[i] > longest) longest = length[i];
    // Four is refused however the pattern starts; three alone, anchored, is not.
    if (longest >= 4) return longest;
  }
  return longest;
}

/// Whether one text takes the automaton from [p] back to [p], from [p] to [q], and
/// from [q] back to [q], at once.
bool _roundAndOn(int p, int q, List<Set<int>> follow, List<_Chars> chars, int count, _Work work) {
  int three(int a, int b, int c) => (a * count + b) * count + c;
  final goal = three(p, q, q);
  final seen = <int>{three(p, p, q)};
  final waiting = <int>[three(p, p, q)];
  while (waiting.isNotEmpty) {
    final node = waiting.removeLast();
    final c = node % count, rest = node ~/ count;
    final b = rest % count, a = rest ~/ count;
    work.spend(1 + follow[a].length * follow[b].length);
    for (final a2 in follow[a]) {
      for (final b2 in follow[b]) {
        if (!chars[a2].meets(chars[b2])) continue;
        work.spend(follow[c].length);
        for (final c2 in follow[c]) {
          if (!chars[a2].meetsBoth(chars[b2], chars[c2])) continue;
          final next = three(a2, b2, c2);
          if (next == goal) return true;
          if (seen.add(next)) waiting.add(next);
        }
      }
    }
  }
  return false;
}
