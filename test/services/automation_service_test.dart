import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/automation_service.dart';

void main() {
  group('AutomationService.applyOutputFilters', () {
    const sampleOutput = 'alpha\nbeta\ngamma\ndelta\nepsilon\n'
        'Alpha line 2\nBeta line 2\nGamma line 2';

    // ── Passthrough ──────────────────────────────────────────────

    group('null filters (passthrough)', () {
      test('returns original output when all filters are null', () {
        const input = 'line1\nline2\nline3';
        expect(AutomationService.applyOutputFilters(input), input);
      });

      test('returns original output when all filters are explicitly null', () {
        const input = 'foo\nbar\nbaz';
        expect(
          AutomationService.applyOutputFilters(
            input,
            grepPattern: null,
            head: null,
            tail: null,
          ),
          input,
        );
      });
    });

    // ── Empty input ──────────────────────────────────────────────

    group('empty input', () {
      test('returns empty string when input is empty', () {
        expect(
          AutomationService.applyOutputFilters(
            '',
            grepPattern: 'foo',
            head: 5,
          ),
          '',
        );
      });

      test('returns empty string when grep matches nothing on empty input',
          () {
        expect(
          AutomationService.applyOutputFilters('', grepPattern: 'test'),
          '',
        );
      });
    });

    // ── Grep filtering ───────────────────────────────────────────

    group('grep filtering', () {
      test('filters lines matching a simple pattern', () {
        final result = AutomationService.applyOutputFilters(
          sampleOutput,
          grepPattern: 'alpha',
        );
        final lines = result.split('\n');
        expect(lines.length, 2);
        expect(lines[0], 'alpha');
        expect(lines[1], 'Alpha line 2');
      });

      test('is case-insensitive', () {
        const input = 'ERROR: disk full\ninfo: all good\nerror: timeout';
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: 'ERROR',
        );
        final lines = result.split('\n');
        expect(lines.length, 2);
        expect(lines[0], 'ERROR: disk full');
        expect(lines[1], 'error: timeout');
      });

      test('a pattern that could hold the app for good is searched for as plain text, and answers at once '
          '(found in a security review)', () {
        final hostile = '${'a' * 40}b';
        final input = 'first line\n$hostile\nthe text (a|aa)+\$ itself\nlast (a+)+\$ line';
        final watch = Stopwatch()..start();
        // A repeat inside a repeat, and alternatives that overlap under a repeat.
        expect(AutomationService.applyOutputFilters(input, grepPattern: r'(a+)+$'), 'last (a+)+\$ line');
        expect(AutomationService.applyOutputFilters(input, grepPattern: r'(a|aa)+$'), 'the text (a|aa)+\$ itself');
        expect(AutomationService.applyOutputFilters(input, grepPattern: r'(a|a?)+$'), '');
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      });

      test('what people write is still a regular expression', () {
        const input = 'ERROR 500 at /api\nwarning: slow\nok 200\nError: disk';
        expect(AutomationService.applyOutputFilters(input, grepPattern: r'^(error|warning)\b'),
            'ERROR 500 at /api\nwarning: slow\nError: disk');
        expect(AutomationService.applyOutputFilters(input, grepPattern: r'\d{3}'), 'ERROR 500 at /api\nok 200');
        expect(AutomationService.applyOutputFilters(input, grepPattern: r'error.*disk'), 'Error: disk');
      });

      test('a pattern that is no regular expression is plain text', () {
        expect(AutomationService.applyOutputFilters('a [b\nc', grepPattern: '[b'), 'a [b');
      });

      test('returns empty when no lines match', () {
        final result = AutomationService.applyOutputFilters(
          sampleOutput,
          grepPattern: 'zzz_no_match',
        );
        expect(result, '');
      });

      test('supports regex patterns', () {
        const input = 'foo123\nbar456\nfoo789\nbaz000';
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: r'^foo\d+',
        );
        final lines = result.split('\n');
        expect(lines.length, 2);
        expect(lines[0], 'foo123');
        expect(lines[1], 'foo789');
      });

      test('falls back to plain contains on invalid regex', () {
        const input = 'hello [world]\ngoodbye [earth]\nhello planet';
        // Unbalanced bracket is invalid regex
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: '[world',
        );
        final lines = result.split('\n');
        // Plain contains '[world' matches the first line
        expect(lines.length, 1);
        expect(lines[0], 'hello [world]');
      });

      test('treats empty grepPattern as no-op', () {
        const input = 'a\nb\nc';
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: '',
        );
        expect(result, input);
      });
    });

    // ── Head filtering ───────────────────────────────────────────

    group('head filtering', () {
      test('takes first N lines', () {
        const input = 'one\ntwo\nthree\nfour\nfive';
        final result = AutomationService.applyOutputFilters(input, head: 3);
        expect(result, 'one\ntwo\nthree');
      });

      test('returns all lines when head > line count', () {
        const input = 'one\ntwo';
        final result = AutomationService.applyOutputFilters(input, head: 10);
        expect(result, input);
      });

      test('returns all lines when head == line count', () {
        const input = 'one\ntwo\nthree';
        final result = AutomationService.applyOutputFilters(input, head: 3);
        expect(result, input);
      });

      test('head of 1 returns first line only', () {
        const input = 'first\nsecond\nthird';
        final result = AutomationService.applyOutputFilters(input, head: 1);
        expect(result, 'first');
      });

      test('head of 0 does not filter (treated as no-op)', () {
        const input = 'a\nb\nc';
        final result = AutomationService.applyOutputFilters(input, head: 0);
        expect(result, input);
      });
    });

    // ── Tail filtering ───────────────────────────────────────────

    group('tail filtering', () {
      test('takes last N lines', () {
        const input = 'one\ntwo\nthree\nfour\nfive';
        final result = AutomationService.applyOutputFilters(input, tail: 2);
        expect(result, 'four\nfive');
      });

      test('returns all lines when tail > line count', () {
        const input = 'one\ntwo';
        final result = AutomationService.applyOutputFilters(input, tail: 10);
        expect(result, input);
      });

      test('returns all lines when tail == line count', () {
        const input = 'one\ntwo\nthree';
        final result = AutomationService.applyOutputFilters(input, tail: 3);
        expect(result, input);
      });

      test('tail of 1 returns last line only', () {
        const input = 'first\nsecond\nthird';
        final result = AutomationService.applyOutputFilters(input, tail: 1);
        expect(result, 'third');
      });

      test('tail of 0 does not filter (treated as no-op)', () {
        const input = 'a\nb\nc';
        final result = AutomationService.applyOutputFilters(input, tail: 0);
        expect(result, input);
      });
    });

    // ── Combined filters ─────────────────────────────────────────

    group('combined filters', () {
      test('grep then head: filters first, then takes first N', () {
        const input = 'err: a\ninfo: b\nerr: c\ninfo: d\nerr: e\nerr: f';
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: 'err',
          head: 2,
        );
        expect(result, 'err: a\nerr: c');
      });

      test('grep then tail: filters first, then takes last N', () {
        const input = 'err: a\ninfo: b\nerr: c\ninfo: d\nerr: e\nerr: f';
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: 'err',
          tail: 2,
        );
        expect(result, 'err: e\nerr: f');
      });

      test('head then tail: head applied first, then tail on result', () {
        // 5 lines -> head 4 -> 4 lines -> tail 2 -> last 2 of the head result
        const input = 'one\ntwo\nthree\nfour\nfive';
        final result = AutomationService.applyOutputFilters(
          input,
          head: 4,
          tail: 2,
        );
        expect(result, 'three\nfour');
      });

      test('grep + head + tail: all three in order', () {
        const input =
            'log: a\nlog: b\nlog: c\nlog: d\nlog: e\nwarn: x\nlog: f';
        // grep 'log' -> [a, b, c, d, e, f] (6 lines)
        // head 5 -> [a, b, c, d, e]
        // tail 2 -> [d, e]
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: 'log',
          head: 5,
          tail: 2,
        );
        expect(result, 'log: d\nlog: e');
      });

      test('grep with no matches followed by head/tail returns empty', () {
        const input = 'a\nb\nc\nd\ne';
        final result = AutomationService.applyOutputFilters(
          input,
          grepPattern: 'zzz',
          head: 3,
          tail: 1,
        );
        expect(result, '');
      });
    });
  });
}
