import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart' show TerminalTrigger;
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart' show compileTriggerRules;

CompiledTrigger _t(
  String pattern, {
  String id = 'r1',
  String name = 'rule',
  bool caseSensitive = false,
  bool notify = true,
  bool highlight = false,
  String? connectionId,
}) {
  final t = CompiledTrigger.tryCompile(
    id: id,
    name: name,
    pattern: pattern,
    caseSensitive: caseSensitive,
    notify: notify,
    highlight: highlight,
    highlightColor: null,
    playSound: false,
    connectionId: connectionId,
  );
  return t!;
}

void main() {
  group('stripAnsi', () {
    test('removes SGR colour sequences, keeps the visible text', () {
      expect(stripAnsi('\x1B[31mERROR\x1B[0m: boom'), 'ERROR: boom');
    });

    test('removes cursor-movement CSI sequences', () {
      expect(stripAnsi('a\x1B[2Kb\x1B[1;5Hc'), 'abc');
    });

    test('removes an OSC title sequence (BEL and ST terminated)', () {
      expect(stripAnsi('\x1B]0;my title\x07done'), 'done');
      expect(stripAnsi('\x1B]0;t\x1B\\x'), 'x');
    });

    test('drops carriage returns and other control bytes but keeps tab', () {
      expect(stripAnsi('a\rb\tc\x00d'), 'ab\tcd');
    });

    test('leaves plain text untouched', () {
      expect(stripAnsi('BUILD SUCCESSFUL in 2s'), 'BUILD SUCCESSFUL in 2s');
    });
  });

  group('CompiledTrigger.tryCompile', () {
    test('returns null for an invalid regex instead of throwing', () {
      expect(
        CompiledTrigger.tryCompile(
          id: 'x',
          name: 'bad',
          pattern: r'([unclosed',
          caseSensitive: false,
          notify: true,
          highlight: false,
          highlightColor: null,
          playSound: false,
          connectionId: null,
        ),
        isNull,
      );
    });

    test('returns null for an empty pattern', () {
      expect(
        CompiledTrigger.tryCompile(
          id: 'x',
          name: 'empty',
          pattern: '',
          caseSensitive: false,
          notify: true,
          highlight: false,
          highlightColor: null,
          playSound: false,
          connectionId: null,
        ),
        isNull,
      );
    });

    test('honours case sensitivity', () {
      expect(_t('error', caseSensitive: false).regex.hasMatch('ERROR'), isTrue);
      expect(_t('error', caseSensitive: true).regex.hasMatch('ERROR'), isFalse);
    });
  });

  group('appliesTo (host scope)', () {
    test('a global rule (null connectionId) applies to any session', () {
      final t = _t('x', connectionId: null);
      expect(t.appliesTo('host-a'), isTrue);
      expect(t.appliesTo(null), isTrue);
    });

    test('a host-scoped rule only applies to that host', () {
      final t = _t('x', connectionId: 'host-a');
      expect(t.appliesTo('host-a'), isTrue);
      expect(t.appliesTo('host-b'), isFalse);
      expect(t.appliesTo(null), isFalse);
    });
  });

  group('TriggerLineScanner', () {
    test('emits complete lines and carries a partial across chunks', () {
      final s = TriggerLineScanner();
      expect(s.addChunk('hello wo'), isEmpty);
      expect(s.addChunk('rld\nsecond line\npar'), ['hello world', 'second line']);
      expect(s.addChunk('tial\n'), ['partial']);
    });

    test('strips ANSI before splitting', () {
      final s = TriggerLineScanner();
      expect(s.addChunk('\x1B[32mok\x1B[0m\nnext\n'), ['ok', 'next']);
    });

    test('reset drops the buffered partial line', () {
      final s = TriggerLineScanner();
      s.addChunk('half');
      s.reset();
      expect(s.addChunk(' done\n'), [' done']);
    });
  });

  group('matchLine', () {
    test('returns a hit per matching, applicable, actionable trigger', () {
      final triggers = [
        _t('error', id: 'e'),
        _t('warn', id: 'w'),
      ];
      final hits = matchLine('this is an error line', triggers, 'h1');
      expect(hits, hasLength(1));
      expect(hits.single.trigger.id, 'e');
      expect(hits.single.match, 'error');
    });

    test('skips triggers with neither action enabled', () {
      final t = _t('error', notify: false, highlight: false);
      expect(matchLine('an error', [t], 'h1'), isEmpty);
    });

    test('skips triggers scoped to a different host', () {
      final t = _t('error', connectionId: 'other');
      expect(matchLine('an error', [t], 'h1'), isEmpty);
    });
  });

  group('TriggerCoalescer', () {
    test('suppresses a repeat of the same trigger+line within the window', () {
      final c = TriggerCoalescer(window: const Duration(seconds: 10));
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(c.shouldNotify('r1', 'error here', t0), isTrue);
      expect(
        c.shouldNotify('r1', 'error here', t0.add(const Duration(seconds: 3))),
        isFalse,
      );
    });

    test('fires again once the window has elapsed', () {
      final c = TriggerCoalescer(window: const Duration(seconds: 10));
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(c.shouldNotify('r1', 'error', t0), isTrue);
      expect(
        c.shouldNotify('r1', 'error', t0.add(const Duration(seconds: 11))),
        isTrue,
      );
    });

    test('different lines and different triggers fire independently', () {
      final c = TriggerCoalescer();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(c.shouldNotify('r1', 'line A', t0), isTrue);
      expect(c.shouldNotify('r1', 'line B', t0), isTrue);
      expect(c.shouldNotify('r2', 'line A', t0), isTrue);
    });
  });

  // Dart's RegExp refuses an inline (?i), which other engines take, so a rule
  // written so never compiled: the three that "Add examples" made never fired
  // (found while rebuilding the page as Alerts).
  group('inline flags', () {
    test('a leading (?i) is taken as ignoring case', () {
      final c = CompiledTrigger.tryCompile(
        id: 'e',
        name: 'Error',
        pattern: r'(?i)\b(error|failed|fatal)\b',
        caseSensitive: true,
        notify: true,
        highlight: true,
        highlightColor: null,
        playSound: false,
        connectionId: null,
      );
      expect(c, isNotNull);
      expect(matchLine('Build FAILED in 3s', [c!], null), hasLength(1));
      expect(matchLine('all good', [c], null), isEmpty);
    });

    test('(?m), (?s) and several together; anything else is still refused', () {
      expect(triggerRegExp(r'(?is)a.b', caseSensitive: true)!.hasMatch('A\nB'), isTrue);
      expect(triggerRegExp(r'(?x)a', caseSensitive: true), isNull);
      expect(triggerRegExp(r'(?i)', caseSensitive: true), isNull);
      expect(triggerRegExp(r'(unclosed', caseSensitive: true), isNull);
    });

    test("the editors' check agrees with the engine", () {
      expect(triggerPatternError(r'(?i)\bwarn(ing)?\b'), isNull);
      expect(triggerPatternError(r'warn(ing'), isNotNull);
      expect(triggerPatternError(''), isNull);
    });
  });

  // Found in a security review: a team's alert
  // rule, written by another member, could hold the screen's thread on output
  // made for it. Time is counted by a clock the test turns by hand.
  group('a share of time for each rule', () {
    test('a rule that used its share sits out the rest of the burst; the others do not', () {
      var now = 0;
      final costs = <String, int>{'slow': 10000, 'quick': 5};
      String? running;
      final budget = TriggerWorkBudget(nowMicros: () => now);
      final slow = _t('error', id: 'slow');
      final quick = _t('error', id: 'quick');
      // Each rule's run moves the clock by its cost (10 ms and 5 microseconds).
      int ran(String id) => costs[id]!;
      final seen = <String, int>{'slow': 0, 'quick': 0};
      for (var i = 0; i < 10; i++) {
        for (final r in [slow, quick]) {
          if (!budget.allows(r)) continue;
          running = r.id;
          budget.run(r, () {
            seen[r.id] = seen[r.id]! + 1;
            now += ran(running!);
          });
        }
      }
      expect(seen['slow'], 3, reason: '10, 20, 30 ms: over 25 after the third line');
      expect(seen['quick'], 10, reason: 'a quick rule never misses a line');
      expect(budget.overBudget, {'slow'});
    });

    test('matchLine leaves out a rule that used its share and still finds the rest', () {
      var now = 0;
      final budget = TriggerWorkBudget(nowMicros: () => now += 30000);
      final slow = _t('error', id: 'slow');
      final quick = _t('err', id: 'quick');
      final first = matchLine('error here', [slow, quick], null, budget: budget);
      expect(first.map((h) => h.trigger.id), ['slow', 'quick'], reason: 'both run once');
      final next = matchLine('error again', [slow, quick], null, budget: budget);
      expect(next, isEmpty, reason: 'both used their share on the first line (30 ms each)');
      expect(matchLine('error', [slow, quick], null).map((h) => h.trigger.id), ['slow', 'quick'],
          reason: 'with no budget, as before');
    });

    // Found in a review: forty rules, each inside its
    // own share, held one burst for a second.
    test('every rule together has a share too: once it is used, none runs for the rest of the burst', () {
      var now = 0;
      final budget = TriggerWorkBudget(nowMicros: () => now);
      final rules = [for (var i = 0; i < 40; i++) _t('error', id: 'r$i')];
      var runs = 0;
      for (var line = 0; line < 20; line++) {
        for (final r in rules) {
          if (!budget.allows(r)) continue;
          budget.run(r, () {
            runs++;
            now += 14000; // 14 ms a rule a line: inside each rule's 25 ms for one line
          });
        }
      }
      expect(budget.spent, isTrue);
      expect(runs, 4, reason: '14, 28, 42, 56 ms: over the 50 ms of the whole after the fourth');
      expect(now, lessThanOrEqualTo(const Duration(milliseconds: 50).inMicroseconds + 14000),
          reason: 'a burst costs at most the whole share and one match more');
      expect(TriggerWorkBudget().allows(rules.first), isTrue, reason: 'the next burst starts afresh');
    });

    test('quick rules on a long burst never reach the whole share', () {
      var now = 0;
      final budget = TriggerWorkBudget(nowMicros: () => now += 2); // 2 microseconds a match
      final rules = [for (var i = 0; i < 20; i++) _t('err', id: 'q$i')];
      var hits = 0;
      for (var line = 0; line < 500; line++) {
        hits += matchLine('error $line', rules, null, budget: budget).length;
      }
      expect(hits, 500 * 20, reason: 'no line missed');
      expect(budget.spent, isFalse);
    });

    test('no more than kMaxTriggerRules rules that are on run; those past them are not compiled', () {
      TerminalTrigger row(int i, {bool enabled = true}) => TerminalTrigger(
            id: 'r$i',
            name: 'rule $i',
            pattern: 'a.*b.*c$i',
            caseSensitive: true,
            notify: true,
            highlight: false,
            playSound: false,
            enabled: enabled,
            sortOrder: i,
            createdAt: DateTime(2026, 11, 5),
          );
      final rows = [
        row(-1, enabled: false), // off: not counted
        for (var i = 0; i < kMaxTriggerRules + 40; i++) row(i),
      ];
      final compiled = compileTriggerRules(rows);
      expect(compiled, hasLength(kMaxTriggerRules));
      expect(compiled.first.id, 'r0');
      expect(compiled.last.id, 'r${kMaxTriggerRules - 1}');
      expect(compileTriggerRules(rows.take(10)), hasLength(9), reason: 'fewer: each that is on');
    });

    test('a new burst gives every rule its share again', () {
      var now = 0;
      final slow = _t('error', id: 'slow');
      final a = TriggerWorkBudget(nowMicros: () => now += 30000);
      matchLine('error', [slow], null, budget: a);
      expect(a.allows(slow), isFalse);
      expect(TriggerWorkBudget().allows(slow), isTrue);
    });
  });
}
