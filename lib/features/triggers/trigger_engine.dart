/// Terminal trigger engine: the pure, dependency-free core behind the
/// "trigger / highlight rules" feature.
///
/// A trigger is a user-defined regular expression that ZestSSH watches for in a
/// session's output. When a line matches, the trigger can fire a NOTIFICATION
/// (an alert in the notification center, optionally with a sound) and/or
/// HIGHLIGHT the matching text in the terminal.
///
/// This file deliberately has no Flutter, Drift, or Riverpod imports so it can
/// be unit-tested in isolation. The database row -> [CompiledTrigger] mapping,
/// the notification firing, and the terminal highlighting all live in the
/// service/provider layer that wraps this engine.
library;

import 'package:zestssh/features/triggers/trigger_pattern_check.dart';

/// Default highlight colour (ARGB) used when a highlight rule sets none: the
/// brand amber. Kept here (dependency-free) so the engine, the editor and the
/// terminal binder all agree on the fallback.
const int kTriggerDefaultHighlightArgb = 0xFFE8600A;

/// A trigger compiled and ready to match, decoupled from its database row so
/// the engine stays pure. Build one per enabled rule via [CompiledTrigger.tryCompile].
class CompiledTrigger {
  /// Stable id of the source rule (used for coalescing and de-duplication).
  final String id;

  /// Human name, surfaced in the fired notification.
  final String name;

  /// The compiled pattern. Matching is done against ANSI-stripped text.
  final RegExp regex;

  /// Raise an alert in the notification center when this fires.
  final bool notify;

  /// Colour the matching text in the terminal when this fires.
  final bool highlight;

  /// ARGB colour for the highlight (null = a sensible default chosen by the UI).
  final int? highlightColor;

  /// Play the alert sound with the notification (only meaningful with [notify]).
  final bool playSound;

  /// The host this rule is scoped to, or null for "every host".
  final String? connectionId;

  /// How much of a line it is matched against ([triggerLine]).
  final int maxLine;

  const CompiledTrigger({
    required this.id,
    required this.name,
    required this.regex,
    required this.notify,
    required this.highlight,
    required this.highlightColor,
    required this.playSound,
    required this.connectionId,
    this.maxLine = kTriggerMaxLineChars,
  });

  /// [line], cut to what this rule is matched against: a pattern runs on the
  /// isolate the screen and every session share, and nothing can stop it once
  /// it runs.
  String triggerLine(String line) => boundTriggerLine(line, maxLine);

  /// Whether this rule applies to a session on [sessionConnectionId].
  bool appliesTo(String? sessionConnectionId) =>
      connectionId == null || connectionId == sessionConnectionId;

  /// Compile [pattern] into a trigger, returning null when the pattern is not a
  /// valid regular expression, or one this app will not run ([triggerRegExp]),
  /// so one bad rule never breaks the engine.
  static CompiledTrigger? tryCompile({
    required String id,
    required String name,
    required String pattern,
    required bool caseSensitive,
    required bool notify,
    required bool highlight,
    required int? highlightColor,
    required bool playSound,
    required String? connectionId,
  }) {
    final regex = triggerRegExp(pattern, caseSensitive: caseSensitive);
    if (regex == null) return null;
    return CompiledTrigger(
      id: id,
      name: name,
      regex: regex,
      notify: notify,
      highlight: highlight,
      highlightColor: highlightColor,
      playSound: playSound,
      connectionId: connectionId,
      maxLine: triggerPatternCheck(pattern, caseSensitive: caseSensitive).maxLine,
    );
  }
}

/// [pattern] as a trigger matches it, or null where it is empty or no
/// regular expression. A leading group of inline flags as other engines write
/// them, `(?i)` above all (and `(?m)`, `(?s)` or several, `(?is)`), is taken
/// as those flags: Dart's RegExp refuses it, so such a rule never compiled,
/// and never fired or highlighted, among them the three the phone's "Add
/// examples" made (found while rebuilding the page as
/// Alerts). `(?i)` makes the rule ignore case whatever [caseSensitive] says.
///
/// Null too for a pattern that could hold up the app ([triggerPatternRefused]).
RegExp? triggerRegExp(String pattern, {required bool caseSensitive}) {
  final regex = _compiled(pattern, caseSensitive);
  if (regex == null || triggerPatternCheck(pattern, caseSensitive: caseSensitive).refused) return null;
  return regex;
}

/// What a leading group of inline flags in [pattern] comes to.
({String source, bool ignoreCase, bool multiLine, bool dotAll}) _flagsOf(String pattern, bool caseSensitive) {
  final flags = RegExp(r'^\(\?([ims]+)\)').firstMatch(pattern);
  if (flags == null) return (source: pattern, ignoreCase: !caseSensitive, multiLine: false, dotAll: false);
  final f = flags.group(1)!;
  return (
    source: pattern.substring(flags.end),
    ignoreCase: !caseSensitive || f.contains('i'),
    multiLine: f.contains('m'),
    dotAll: f.contains('s'),
  );
}

RegExp? _compiled(String pattern, bool caseSensitive) {
  if (pattern.isEmpty) return null;
  final f = _flagsOf(pattern, caseSensitive);
  if (f.source.isEmpty) return null;
  try {
    return RegExp(f.source, caseSensitive: !f.ignoreCase, multiLine: f.multiLine, dotAll: f.dotAll);
  } on FormatException {
    return null;
  }
}

/// What [pattern] can cost on a line of output ([checkTriggerPattern]).
TriggerPatternCheck triggerPatternCheck(String pattern, {required bool caseSensitive}) {
  final f = _flagsOf(pattern, caseSensitive);
  return checkTriggerPattern(f.source, ignoreCase: f.ignoreCase);
}

/// Whether [pattern] is a regular expression this app will not run, because its
/// shape could hold up the app on a line of output: it is not used, and the
/// alert says so. (One that is no regular expression at all is
/// [triggerPatternError]'s.)
bool triggerPatternRefused(String pattern, {required bool caseSensitive}) =>
    _compiled(pattern, caseSensitive) != null && triggerPatternCheck(pattern, caseSensitive: caseSensitive).refused;

/// Why [pattern] is no regular expression a trigger can match by, or null
/// where it is one (or is empty): the editors' check, held to what the engine
/// takes ([triggerRegExp]).
String? triggerPatternError(String pattern) {
  if (pattern.isEmpty || _compiled(pattern, true) != null) return null;
  final flags = RegExp(r'^\(\?[ims]+\)').firstMatch(pattern);
  try {
    RegExp(flags == null ? pattern : pattern.substring(flags.end));
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}

/// A single trigger firing against one line of output.
class TriggerHit {
  final CompiledTrigger trigger;

  /// The clean (ANSI-stripped) line the pattern matched.
  final String line;

  /// The exact substring that matched, surfaced in the alert body.
  final String match;

  const TriggerHit({
    required this.trigger,
    required this.line,
    required this.match,
  });
}

// ── ANSI / control-sequence stripping ──────────────────────────────────────

// OSC (Operating System Command): ESC ] ... terminated by BEL or ST (ESC \).
final RegExp _osc = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');

// CSI (Control Sequence Introducer): ESC [ params intermediates final-byte.
final RegExp _csi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

// Two-character escapes: ESC followed by a single non-[ , non-] byte.
final RegExp _escShort = RegExp(r'\x1B[@-Za-z\\^_`~]');

// Remaining C0 control bytes except TAB (09) and LF (0A), plus DEL (7F).
final RegExp _controls = RegExp(r'[\x00-\x08\x0B-\x1F\x7F]');

/// Strip ANSI/VT escape sequences and stray control bytes so a user's regex
/// matches the VISIBLE text rather than the escape codes a server interleaves
/// with it. TAB and newline survive; carriage returns and other control bytes
/// are removed.
String stripAnsi(String input) {
  if (input.isEmpty) return input;
  return input
      .replaceAll(_osc, '')
      .replaceAll(_csi, '')
      .replaceAll(_escShort, '')
      .replaceAll(_controls, '');
}

// ── Streaming line scanner ─────────────────────────────────────────────────

/// Splits a session's raw output stream into complete, ANSI-stripped lines.
///
/// Output arrives in arbitrary chunks that may split a line anywhere, so the
/// scanner carries the trailing partial line between [addChunk] calls and only
/// emits a line once its terminating newline has been seen. This keeps trigger
/// matching correct across chunk boundaries.
class TriggerLineScanner {
  final StringBuffer _carry = StringBuffer();

  /// Guard against a runaway line with no newline (e.g. a binary dump) growing
  /// the carry buffer without bound. A single logical line beyond this is force
  /// flushed for matching and then reset.
  static const int _maxCarry = 64 * 1024;

  /// Feed a raw output chunk; returns any lines completed by it.
  List<String> addChunk(String rawChunk) {
    if (rawChunk.isEmpty) return const [];
    final clean = stripAnsi(rawChunk);
    if (clean.isEmpty) return const [];

    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < clean.length; i++) {
      if (clean.codeUnitAt(i) == 0x0A) {
        _carry.write(clean.substring(start, i));
        lines.add(_carry.toString());
        _carry.clear();
        start = i + 1;
      }
    }
    if (start < clean.length) {
      _carry.write(clean.substring(start));
      if (_carry.length > _maxCarry) {
        lines.add(_carry.toString());
        _carry.clear();
      }
    }
    return lines;
  }

  /// Drop any buffered partial line (e.g. when a session closes).
  void reset() => _carry.clear();
}

// ── Coalescer ──────────────────────────────────────────────────────────────

/// Suppresses repeat notifications for the same trigger firing on the same line
/// in quick succession, so a rule on "error" does not fire a hundred times when
/// a stack trace scrolls past. Pure: the caller passes the clock in.
class TriggerCoalescer {
  final Duration window;
  final Map<String, DateTime> _lastFired = {};

  TriggerCoalescer({this.window = const Duration(seconds: 10)});

  /// Whether a notification for [triggerId] matching [line] should fire at
  /// [now], given the coalescing [window]. Records the time when it returns
  /// true.
  bool shouldNotify(String triggerId, String line, DateTime now) {
    final key = '$triggerId $line';
    final last = _lastFired[key];
    if (last != null && now.difference(last) < window) {
      return false;
    }
    _lastFired[key] = now;
    // Opportunistic prune so the map cannot grow without bound on a long
    // session: drop entries older than twice the window.
    if (_lastFired.length > 256) {
      final cutoff = now.subtract(window * 2);
      _lastFired.removeWhere((_, t) => t.isBefore(cutoff));
    }
    return true;
  }

  void reset() => _lastFired.clear();
}

// ── Matching ───────────────────────────────────────────────────────────────

/// How long one rule may spend on one burst of a session's output, or on one
/// pass of the terminal's highlights, before it sits out the rest of it (found in
/// a security review), and how long all of
/// them together may, before every rule sits out the rest of it (found in a review:
/// a share per rule alone let forty slow rules
/// hold one burst for a second). A team's alert rules are written by whoever
/// may add to its vaults, and a pattern the checks let through
/// ([triggerPatternCheck]) can still take many milliseconds on a long line:
/// on the screen's thread, many such lines froze the app. A rule a person
/// writes takes microseconds a line, far inside both, so it does not miss a
/// line; a rule over its share, or every rule once the burst's or pass's
/// whole share is used, misses the rest of that burst or pass only, and runs
/// again on the next. A match already running is not cut short: a burst costs
/// at most [total] and one line's match more.
class TriggerWorkBudget {
  TriggerWorkBudget({
    this.perRule = const Duration(milliseconds: 25),
    this.total = const Duration(milliseconds: 50),
    int Function()? nowMicros,
  }) : _now = nowMicros ?? _clock;

  final Duration perRule;

  /// For every rule together.
  final Duration total;
  final int Function() _now;
  final Map<String, int> _spent = {};
  int _spentAll = 0;

  /// The rules that used their share, by id.
  final Set<String> overBudget = {};

  /// Whether every rule together used the whole share: none runs again in
  /// this burst or pass.
  bool get spent => _spentAll > total.inMicroseconds;

  static final Stopwatch _watch = Stopwatch()..start();
  static int _clock() => _watch.elapsedMicroseconds;

  /// Whether [t] may still run in this burst or pass.
  bool allows(CompiledTrigger t) => !spent && !overBudget.contains(t.id);

  /// Runs [work] for [t], its time counted against [t]'s share and the whole.
  R run<R>(CompiledTrigger t, R Function() work) {
    final start = _now();
    try {
      return work();
    } finally {
      final took = _now() - start;
      final spent = (_spent[t.id] ?? 0) + took;
      _spent[t.id] = spent;
      _spentAll += took;
      if (spent > perRule.inMicroseconds) overBudget.add(t.id);
    }
  }
}

/// The most alert rules a space runs:
/// a team's are written by whoever may add to its vaults. The first this
/// many that are on run; the rest do not until some are turned off or
/// deleted. Far more than anyone writes.
const int kMaxTriggerRules = 100;

/// Test one clean line against every trigger that applies to
/// [sessionConnectionId], returning a hit per matching trigger. Triggers with
/// neither action enabled are skipped (nothing to do). With a [budget], a rule
/// that used its share sits out ([TriggerWorkBudget]).
List<TriggerHit> matchLine(
  String line,
  Iterable<CompiledTrigger> triggers,
  String? sessionConnectionId, {
  TriggerWorkBudget? budget,
}) {
  if (line.isEmpty) return const [];
  final hits = <TriggerHit>[];
  for (final t in triggers) {
    if (!t.notify && !t.highlight) continue;
    if (!t.appliesTo(sessionConnectionId)) continue;
    if (budget != null && !budget.allows(t)) continue;
    final text = t.triggerLine(line);
    final m = budget == null ? t.regex.firstMatch(text) : budget.run(t, () => t.regex.firstMatch(text));
    if (m != null) {
      hits.add(TriggerHit(trigger: t, line: text, match: m.group(0) ?? ''));
    }
  }
  return hits;
}
