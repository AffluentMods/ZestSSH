import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/triggers/alert_presets.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/features/triggers/trigger_pattern_check.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/triggers_view.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';

/// A team's alert runs on the output of everyone's sessions, on the isolate the
/// screen shares with them, and nothing can stop a regular expression once it
/// runs: whoever may add to a vault could hold up everyone's app with `(a+)+$`
/// and a host that prints a's (found in a security review). So the shape
/// of a pattern is read before it is used, and what it is matched against is
/// bounded. What people write has to go on working.
void main() {
  CompiledTrigger? compiled(String pattern, {bool caseSensitive = false}) => CompiledTrigger.tryCompile(
        id: 't',
        name: 'n',
        pattern: pattern,
        caseSensitive: caseSensitive,
        notify: true,
        highlight: true,
        highlightColor: null,
        playSound: false,
        connectionId: null,
      );

  group('a review of the check', () {
    bool refused(String pattern) => checkTriggerPattern(pattern, ignoreCase: false).refused;

    // Each of these ran for seconds on a line of under 200 characters, and doubled
    // with each more, with no way to stop it, on the isolate the screen shares.
    for (final pattern in const [
      // Anchored, and so one power short of what was counted; and counting stopped at three.
      r'^.*x.*x.*x.*x.*x.*x.*y',
      r'^.*a.*b.*c.*d',
      r'^(.*)a(.*)b(.*)c(.*)d$',
      // A lookbehind is run backward: what reads as its end, with nothing after it, is its start.
      r'(?<=z(a+)+)b',
      r'(?<!z(a+)+)b',
      r'(?<=a+)b',
      r'(?<=\w{1,3})x',
      // A look inside a look tries the rest of the line for every place the one around it did.
      r'(?=.*(?=.*(?=.*(?=.*y))))x',
      r'(?=(?!a)b)',
      r'(?<=(?=a)a)b',
    ]) {
      test('refused: $pattern', () {
        expect(refused(pattern), isTrue);
        expect(triggerRegExp(pattern, caseSensitive: true), isNull);
      });
    }

    test('what looks around and stays cheap passes', () {
      for (final pattern in const [
        r'(?<![a-z])error(?![a-z])',
        r'(?<=\d{4})-',
        r'(?<=ab?)c',
        r'^(?!.*healthcheck).*error',
        r'(?=.*a)(?=.*b)x',
      ]) {
        expect(refused(pattern), isFalse, reason: pattern);
      }
    });

    test('three runs that can read the same text, anchored, still pass on a short line', () {
      final check = checkTriggerPattern(r'^.*a.*b.*c', ignoreCase: false);
      expect(check.refused, isFalse);
      expect(check.maxLine, kTriggerMaxOverlapLineChars);
    });

    // Tried as what people write; three are refused, and stay so:
    // the first is one power past the limit only for its leading `.*`, which a search
    // does not need (`error.*disk.*full` passes and finds the same lines); the second
    // does grow exponentially; the third is a back-reference, whose cost no shape says.
    const ordinary = <String>[
      r'error|fail',
      r'^\s*WARN',
      r'\bOOM\b',
      r'(foo|bar)+',
      r'(foo|bar)+baz',
      r'(foo|bar|baz)*qux',
      r'.*error.*',
      r'^.*(error|fail).*$',
      r'\berror\b.*\btimeout\b',
      r'ERROR|WARN|FATAL|PANIC',
      r'\[(ERROR|WARN)\]',
      r'^\d{4}-\d{2}-\d{2}',
      r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}.*ERROR',
      r'\d+\.\d+\.\d+\.\d+',
      r'(\d{1,3}\.){3}\d{1,3}',
      r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
      r'([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}',
      r'([0-9a-f]{2}:){5}[0-9a-f]{2}',
      r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
      r'SRC=(\d{1,3}\.){3}\d{1,3} DST=(\d{1,3}\.){3}\d{1,3} .*DPT=\d{1,5}',
      r'Failed password for (invalid user )?\S+ from \S+ port \d+',
      r'^\w{3}\s+\d{1,2} \d{2}:\d{2}:\d{2} \S+ sshd\[\d+\]: .*',
      r'load average: (\d+\.\d+), (\d+\.\d+), (\d+\.\d+)',
      r'\d+(\.\d+)?%',
      r'^\s*$',
      r'\s+$',
      r'.*error.*timeout.*',
      r'^(\S+)\s+(\S+)\s+(\S+)$',
      r'(\w+\s+)+failed',
      r'^(.*?),(.*?),(.*?),(.*?)$',
      r'[\w.+-]+@[\w-]+\.[\w.-]+',
      r'https?://[^\s]+',
      r'(?<level>ERROR|WARN): (?<msg>.*)',
      r'^(?!.*healthcheck).*error',
      r'(?<![a-z])error(?![a-z])',
      r'[#$>] ?$',
      r'password:\s*$',
      r'(?:^|\s)sudo(?:\s|$)',
      r'Connection (closed|reset|refused)',
      r'(kernel|systemd|sshd).*(fail|error)',
      r'.{0,80}ERROR.{0,80}',
      r'" (4|5)\d{2} ',
      r'(?i)error',
      r'(?im)^error',
    ];
    test('the 44 of 47 ordinary patterns pass; the same three are refused', () {
      expect(ordinary, hasLength(44));
      expect([for (final p in ordinary) if (refused(p)) p], isEmpty);
      expect(refused(r'.*error.*disk.*full.*'), isTrue);
      expect(refused(r'(\w+\s*)+failed'), isTrue);
      expect(refused(r'(\w+) \1'), isTrue);
      expect(refused(r'error.*disk.*full'), isFalse);
    });

    test('a line is matched with no line ending in it, each for a space, so that where a match falls stays', () {
      expect(boundTriggerLine('a\u2028b\u2029c\rd\ne', 100), 'a b c d e');
      expect(boundTriggerLine('abcdef', 3), 'abc');
      final check = checkTriggerPattern(r'^(.*?),(.*?),(.*?),(.*?)$', ignoreCase: false);
      expect(check.bound('a\u2028,b').length, 'a\u2028,b'.length);
      expect(compiled(r'b$')!.triggerLine('b\u2028'), 'b ');
    });

    test('a .* before a final \$ cannot fail: the one line left that would make it, run, comes back at once', () {
      const source = r'^(.*?),(.*?),(.*?),(.*?)$';
      final check = checkTriggerPattern(source, ignoreCase: false);
      expect(check.refused, isFalse);
      final line = '${',' * (kTriggerMaxOverlapLineChars - 1)}\u2028';
      final watch = Stopwatch()..start();
      expect(RegExp(source).hasMatch(check.bound(line)), isTrue);
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });

    test('a loop that cannot read all a line holds still counts before a \$', () {
      expect(refused(r'^[^,]*a[^,]*b[^,]*c[^,]*$'), isTrue);
      expect(refused(r'^\S*a\S*b\S*c\S*$'), isTrue);
      expect(refused(r'(.*)*\b$'), isTrue);
    });
  });

  group('a shape that could hold up the app is refused', () {
    const shapes = <String>[
      // A repeat inside a repeat.
      r'(a+)+$',
      r'(a+)+b',
      r'(a*)*b',
      r'(a*)*$',
      r'(.*)*x',
      r'(.+)+x',
      r'(\d+)+\.',
      r'([a-zA-Z]+)*1',
      r'(?:a+)+b',
      r'(?<n>a+)+b',
      r'(?:(?:a+)+)+b',
      r'(a+){2,}b',
      r'(a{1,100}){1,100}b',
      // Not written as one, and the same.
      r'(x+x+)+y',
      r'(\w+\s?)*$',
      r'^(\w+\s?)+$',
      r'(\s*\w+\s*)+$',
      r'^(([a-z])+.)+[A-Z]([a-z])+$',
      // Alternatives that overlap, under a repeat.
      r'(a|a)*b',
      r'(a|a)*$',
      r'(a|aa)+$',
      r'(a|b|ab)*c',
      r'(é|é)*x',
      r'(错误|错误)+x',
      // Loops that read the same text, one after the other.
      r'(.*a){20}',
      r'(.*a){3}x',
      r'.*.*.*x',
      r'a*a*a*b',
      r'.*a.*b.*c.*d',
      // No loop at all, and too many ways through.
      r'(a?){30}a{30}',
      r'(a?){100}a{100}',
      r'a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      // A catastrophe in what looks around, or around that.
      r'(?=(a+)+b)',
      r'(?!(a|a)*b)',
      r'(?:(?=.*a)x)+y',
      // What a back-reference costs in a loop no automaton says.
      r'(a*)\1+b',
      // A mail address as it went round the web for years.
      r'^([a-zA-Z0-9])(([\-.]|[_]+)?([a-zA-Z0-9]+))*(@){1}[a-z0-9]+[.]{1}(([a-z]{2,3})|([a-z]{2,3}[.]{1}[a-z]{2,3}))$',
    ];
    for (final pattern in shapes) {
      test(pattern, () {
        expect(() => RegExp(pattern), returnsNormally, reason: 'a regular expression like any other');
        expect(triggerPatternRefused(pattern, caseSensitive: false), isTrue);
        expect(triggerRegExp(pattern, caseSensitive: false), isNull);
        expect(compiled(pattern), isNull, reason: 'it is never run');
      });
    }

    test('whichever way case is told apart, and with flags in front', () {
      expect(triggerPatternRefused(r'(a|A)*b', caseSensitive: false), isTrue, reason: 'the same letter, here');
      expect(triggerPatternRefused(r'(a|A)*b', caseSensitive: true), isFalse);
      expect(triggerPatternRefused(r'(?i)(a|A)*b', caseSensitive: true), isTrue);
      expect(triggerPatternRefused(r'(?is)(a+)+$', caseSensitive: true), isTrue);
    });

    test('a pattern no one typed, however it reads', () {
      final long = 'word|' * 300;
      expect(long.length, greaterThan(kTriggerMaxPatternChars));
      expect(triggerPatternRefused(long, caseSensitive: false), isTrue);
    });

    test('what is no regular expression is another matter, as it was', () {
      expect(triggerPatternRefused(r'warn(ing', caseSensitive: false), isFalse);
      expect(triggerPatternError(r'warn(ing'), isNotNull);
      expect(triggerPatternError(r'(a+)+$'), isNull, reason: 'that one is said in other words');
    });
  });

  group('what people write goes on working', () {
    // (pattern, a line it matches)
    const patterns = <(String, String)>[
      // The phone's Add examples.
      (r'(?i)\b(error|failed|fatal)\b', 'Build FAILED in 3s'),
      (r'(?i)(built in|build (succeeded|successful|finished|complete|done)|compiled successfully)', 'Compiled successfully'),
      (r'(?i)\bwarn(ing)?\b', 'WARN disk 85% full'),
      // Words and alternatives.
      (r'error', 'an error here'),
      (r'(?i)out of memory', 'Out of memory: killed'),
      (r'Connection (refused|reset|timed out)', 'ssh: Connection refused'),
      (r'segfault|panic|oom-killer', 'kernel panic'),
      (r'(?i)(fail(ed|ure)?|error|exception|traceback)', 'Traceback (most recent call last):'),
      (r'\[(ERROR|WARN|FATAL)\]', '[WARN] careful'),
      (r'(错误|失败)+', '构建失败'),
      // Numbers and addresses.
      (r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}', 'from 10.0.0.1 port 22'),
      (r'(\d{1,3}\.){3}\d{1,3}', 'from 10.0.0.1 port 22'),
      (r'\d+\.\d+\.\d+', 'version 3.2.8'),
      (r'(\d+\.)+\d+', 'version 3.2.8'),
      (r'took \d+(\.\d+)? ?(ms|s)', 'took 12.5 ms'),
      (r'exit code [1-9][0-9]*', 'exit code 137'),
      (r'HTTP/1\.[01]" 5\d\d\b', 'GET / HTTP/1.1" 503 12'),
      (r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', 'id 0f0e0d0c-0b0a-4908-8706-050403020100'),
      (r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]', '[2026-10-31 12:00:00] started'),
      // A stretch of anything between words.
      (r'ERROR.*timeout', 'ERROR: a timeout'),
      (r'.*error', 'an error'),
      (r'.*error.*', 'an error here'),
      (r'^.*ERROR.*$', 'an ERROR here'),
      (r'error: (.*)', 'error: oh no'),
      (r'error:\s*(.*)$', 'error:   oh no'),
      (r'foo.*bar.*baz', 'foo and bar and baz'),
      (r'Exception in thread ".*"', 'Exception in thread "main"'),
      (r'Are you sure.*\?', 'Are you sure about this?'),
      // Fields.
      (r'(\w+)\s+(\w+)', 'two words'),
      (r'^(\S+)\s+(\S+)\s+(\S+)', 'three words here'),
      (r'^\S+@\S+\.\S+$', 'me@example.com'),
      (r'[a-z]+@[a-z]+\.[a-z]+', 'write to me@example.com'),
      (r'^\w+:\s', 'warning: careful'),
      // Lines and prompts.
      (r'^\s*$', '   '),
      (r'\s+$', 'trailing  '),
      (r'^\s+|\s+$', '  leading'),
      (r'[$#>] ?$', 'root@host:~# '),
      (r'\(yes/no\)', 'Continue (yes/no)?'),
      (r'.{80,}', 'a line of more than eighty characters, which someone might watch for, as a thing to say'),
      // What looks around, repeats of a whole word, a group used again.
      (r'^(?!.*DEBUG).*ERROR', 'an ERROR here'),
      (r'(?<!\d)\d{3}(?!\d)', 'code 503.'),
      (r'^(foo|bar)+$', 'foobar'),
      (r'(ab)+c', 'ababc'),
      (r'user(name)?:', 'username:'),
      (r'(a)\1', 'aa'),
    ];

    for (final (pattern, line) in patterns) {
      test(pattern, () {
        final t = compiled(pattern);
        expect(t, isNotNull, reason: 'it is used');
        expect(t!.regex.hasMatch(line), isTrue);
        expect(matchLine(line, [t], null), hasLength(1));
      });
    }

    test('the choices of Simple mode, each with the lines it says it matches, and a person\'s own text', () {
      for (final preset in AlertPreset.values) {
        if (preset == AlertPreset.ownText) continue;
        final t = compiled(preset.pattern)!;
        expect(t.maxLine, kTriggerMaxLineChars, reason: preset.name);
        for (final line in preset.examples) {
          expect(matchLine(line, [t], null), hasLength(1), reason: line);
        }
      }
      final own = AlertPreset.ownTextPattern(r'(a+)+$ is what I typed.*');
      expect(triggerPatternRefused(own, caseSensitive: false), isFalse, reason: 'every character as itself');
      expect(matchLine(r'look: (a+)+$ is what I typed.*', [compiled(own)!], null), hasLength(1));
    });

    test('the patterns the app itself names as examples', () {
      expect(triggerPatternRefused(r'\b(error|failed)\b', caseSensitive: false), isFalse);
      expect(triggerPatternRefused(r'(?i)\berror\b', caseSensitive: false), isFalse);
    });
  });

  group('how much of a line is read', () {
    test('a pattern is matched against the start of a long line, and goes on matching past it no further', () {
      final t = compiled('needle')!;
      expect(t.maxLine, kTriggerMaxLineChars);
      final at = kTriggerMaxLineChars - 10;
      expect(matchLine('${'x' * at}needle${'x' * 9000}', [t], null), hasLength(1));
      expect(matchLine('${'x' * kTriggerMaxLineChars}needle', [t], null), isEmpty);
    });

    test('a line within it is read whole, and what an alert says of it is cut to it', () {
      final t = compiled('needle')!;
      final hits = matchLine('x' * 100 + 'needle', [t], null);
      expect(hits.single.line, hasLength(106));
      final long = matchLine('needle${'x' * 9000}', [t], null);
      expect(long.single.line, hasLength(kTriggerMaxLineChars));
      expect(long.single.match, 'needle');
    });

    test('two loops that read the same text, starting anywhere, read less of it', () {
      final t = compiled(r'foo.*bar.*baz')!;
      expect(t.maxLine, kTriggerMaxOverlapLineChars);
      expect(t.maxLine, lessThan(kTriggerMaxLineChars));
      expect(matchLine('foo bar baz', [t], null), hasLength(1));
      expect(matchLine('${'x' * kTriggerMaxOverlapLineChars}foo bar baz', [t], null), isEmpty);
      // From the start of a line alone, as much as any other.
      expect(compiled(r'^foo.*bar.*baz')!.maxLine, kTriggerMaxLineChars);
    });

    test('what looks around, with a loop in it, is tried at each place a loop before it can stop', () {
      expect(compiled(r'.*(?=.*x)y')!.maxLine, kTriggerMaxOverlapLineChars);
      expect(compiled(r'^(?!.*DEBUG).*ERROR')!.maxLine, kTriggerMaxLineChars);
      expect(compiled(r'(?<!\d)\d{3}(?!\d)')!.maxLine, kTriggerMaxLineChars);
    });

    test('a loop at the end with nothing after it costs nothing', () {
      expect(compiled(r'a.*b.*c.*')!.maxLine, kTriggerMaxOverlapLineChars);
      expect(compiled(r'a.*')!.maxLine, kTriggerMaxLineChars);
      expect(compiled(r'(a|a)*')!.maxLine, kTriggerMaxLineChars, reason: 'nothing can fail after it');
    });

    test('what is let through ends in good time on the lines it could suffer most from', () {
      const worst = <String>[
        r'.*error',
        r'.*error.*',
        r'\d+\.\d+\.\d+',
        r'(\d+\.)+\d+',
        r'[a-z]+@[a-z]+\.[a-z]+',
        r'(\w+)\s+(\w+)',
        r'foo.*bar.*baz',
        r'.*.*x',
        r'.*a.*b',
        r'^.*.*.*x',
        r'^\S+@\S+\.\S+$',
        r'password[^:]*:\s*$',
        r'\s+$',
        r'.{0,200}x',
      ];
      for (final pattern in worst) {
        final t = compiled(pattern);
        expect(t, isNotNull, reason: pattern);
        final n = t!.maxLine;
        for (final line in [
          'a' * n,
          ' ' * n,
          '1' * n,
          ('error' * n).substring(0, n),
          ('foobar' * n).substring(0, n),
          ('foobarbaz' * n).substring(0, n),
          ('1.' * n).substring(0, n),
          ('a@a.' * n).substring(0, n),
          ('password' * n).substring(0, n),
        ]) {
          final took = Stopwatch()..start();
          t.regex.firstMatch(t.triggerLine(line));
          // (Generous for a machine that is busy with other tests: a shape that
          // got through by mistake takes minutes at these lengths, or for ever.)
          expect(took.elapsed, lessThan(const Duration(seconds: 20)), reason: '$pattern on ${line.substring(0, 12)}...');
        }
      }
    });
  });

  test('every odd thing a regular expression can hold is read without a fault, in good time', () {
    const tokens = <String>[
      'a', 'b', '.', r'\d', r'\D', r'\w', r'\W', r'\s', r'\S', '(', ')', '(?:', '(?=', '(?!', '(?<=', '(?<!', '(?<n>', '[ab]',
      '[^a]', '[a-z]', '[', ']', '[]', '[^]', '|', '*', '+', '?', '{', '}', '{2}', '{1,3}', '{2,}', '{,3}', '^', r'$', r'\b', r'\B',
      r'\1', r'\k<n>', 'x', ' ', r'\', '-', '*?', '+?', 'é', r'\x41', r'\x-a', r'é', r'\u12', r'\cA', r'\c', r'\0', r'\t', r'\-',
    ];
    final random = Random(20261031);
    var read = 0;
    for (var i = 0; i < 40000; i++) {
      final pattern = List.generate(1 + random.nextInt(10), (_) => tokens[random.nextInt(tokens.length)]).join();
      try {
        RegExp(pattern);
      } on FormatException {
        continue;
      }
      read++;
      final check = checkTriggerPattern(pattern, ignoreCase: i.isEven);
      expect(check.refused ? 0 : check.maxLine, anyOf(0, kTriggerMaxLineChars, kTriggerMaxOverlapLineChars), reason: pattern);
    }
    expect(read, greaterThan(1000));
  });

  test('the worst pattern that fits is read in good time', () {
    final took = Stopwatch()..start();
    for (final pattern in [
      '(${'[ab]|' * 200}c)*d',
      '(${'.|' * 300}.)+x',
      '${'.*a' * 150}x',
      '${'(a|b)' * 200}x',
      '(((((a{1,64}){1,64}){1,64}){1,64}){1,64})',
    ]) {
      expect(pattern.length, lessThanOrEqualTo(kTriggerMaxPatternChars));
      expect(checkTriggerPattern(pattern, ignoreCase: false).refused, isTrue, reason: pattern);
    }
    expect(took.elapsed, lessThan(const Duration(seconds: 10)));
  });

  group('the alert says so', () {
    TerminalTrigger row(String id, String pattern) => TerminalTrigger(
          id: id,
          name: 'From a teammate',
          pattern: pattern,
          caseSensitive: false,
          notify: true,
          highlight: false,
          highlightColor: null,
          playSound: false,
          connectionId: null,
          enabled: true,
          sortOrder: 0,
          createdAt: DateTime(2026, 10, 31),
        );

    Future<AppLocalizations> pump(WidgetTester tester, Widget page, List<TerminalTrigger> rows) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          triggerRuntimeProvider.overrideWith((ref) {
            final runtime = TriggerRuntime.forTesting(ref);
            ref.onDispose(runtime.dispose);
            return runtime;
          }),
          triggersProvider.overrideWith((ref) => Stream.value(rows)),
          triggerScopeConnectionsProvider.overrideWith((ref) => Stream.value(const <Connection>[])),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: page),
        ),
      ));
      await tester.pumpAndSettle();
      return lookupAppLocalizations(const Locale('en'));
    }

    for (final (name, Widget page) in [('a computer', const TriggersView()), ('a phone', const TriggersScreen(embedded: true))]) {
      testWidgets('in its row on $name, and only on the one it is about', (tester) async {
        final l10n = await pump(tester, page, [row('evil', r'(a+)+$'), row('fine', r'\berror\b')]);
        expect(find.byKey(const ValueKey('alert-refused-evil')), findsOneWidget);
        expect(find.byKey(const ValueKey('alert-refused-fine')), findsNothing);
        expect(find.text(l10n.trgPatternRefused), findsOneWidget);
      });
    }

    testWidgets('and in the editor, where it cannot be saved as it is and its test line stays out of it', (tester) async {
      final l10n = await pump(tester, const TriggersView(), [row('evil', r'(a+)+$')]);
      await tester.tap(find.byKey(const ValueKey('alert-refused-evil')));
      await tester.pumpAndSettle();
      // The field says it, under the pattern, as well as the row above it.
      expect(find.text(l10n.trgPatternRefused), findsNWidgets(2));
      expect(find.text(l10n.trgTestFix), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('alert-pattern')).last, r'a+$');
      await tester.pump();
      expect(find.text(l10n.trgPatternRefused), findsOneWidget, reason: 'the row, which has not been saved over');
      expect(find.text(l10n.trgTestFix), findsNothing);
    });
  });
}
