import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/snippet_providers.dart' show resolveVariables;
import 'package:zestssh/services/automation_service.dart' show withSnippetVariables;
import 'package:zestssh/utils/shell_fill.dart';

/// A value put into a command someone wrote, in every kind of place a command has
/// for one, run by a real shell: nothing of the value may run, and it must arrive
/// as it is. (`grep '${P}' log` with `foo; touch x; echo` ran touch, and `echo
/// "${P}"` with `$(touch x)` left the $(...) live: a review's proof.
/// Values reach this from links and another app's intents.)

/// A POSIX shell with the two programs the proofs need, or null with why not.
(String? shell, String? why) _shellHere() {
  for (final candidate in ['sh', r'C:\Program Files\Git\usr\bin\sh.exe', '/bin/sh']) {
    try {
      final r = Process.runSync(candidate, ['-c', 'cd "\${TMPDIR:-.}" && printf ok | cat']);
      if (r.exitCode == 0 && '${r.stdout}' == 'ok') return (candidate, null);
    } catch (_) {}
  }
  return (null, 'no POSIX sh with cat on this machine: the shell proofs did not run');
}

/// One directory a script runs in at a time.
class _Bench {
  _Bench(this.shell, this.dir);
  final String shell;
  final Directory dir;

  Future<(String, bool)> run(String script) async {
    await File('${dir.path}/s.sh').writeAsBytes(utf8.encode(script));
    final r = await Process.run(shell, ['s.sh'], workingDirectory: dir.path, stdoutEncoding: null, stderrEncoding: null);
    final marker = File('${dir.path}/PWNED');
    final ran = marker.existsSync();
    if (ran) marker.deleteSync();
    return (utf8.decode(r.stdout as List<int>, allowMalformed: true), ran);
  }
}

/// What must arrive of [value]: null where only that nothing ran is asked.
typedef _Arrives = String? Function(String value);

String _same(String value) => value;

/// A `$(...)` takes the line breaks off its end.
String _substituted(String value) => value.replaceFirst(RegExp(r'\n+$'), '');

bool _endsBody(String value, {bool tabs = false}) =>
    value.split('\n').any((l) => (tabs ? l.replaceFirst(RegExp(r'^\t+'), '') : l) == 'EOF');

/// A line of a value that would end its here-document stays on one line with a
/// space after it; any other arrives as it is, with the line break of its line.
String _inBody(String value) => _endsBody(value) ? '${value.replaceAll('\n', ' ')} \n' : '$value\n';

const _hostile = <String>[
  'foo; touch PWNED; echo',
  r'$(touch PWNED)',
  '`touch PWNED`',
  "'; touch PWNED; '",
  '"; touch PWNED; "',
  r"\'; touch PWNED; \'",
  r'\"; touch PWNED; \"',
  r'\',
  r'a\',
  r'\\',
  "'",
  '"',
  '`',
  r'$',
  r'$(',
  ')',
  ') ; touch PWNED ; (',
  ')) ; touch PWNED ; ((',
  '}; touch PWNED; {',
  '}',
  r'${P}',
  '{{P}}',
  r'$[a,b]',
  'a\ntouch PWNED\nb',
  '\ntouch PWNED #',
  'x\nEOF\ntouch PWNED\nEOF\ny',
  'EOF',
  r'$HOME',
  '*',
  '~',
  '!!',
  '%s',
  '-n',
  'a  b\tc',
  'héllo wörld ✓',
  "it's",
  '#',
  '# x',
  '&& touch PWNED',
  '| touch PWNED',
  '> PWNED',
  r"""a'b"c`d$e\f""",
  r'a[$(touch PWNED)]',
  r"$'\x27; touch PWNED; \x27'",
];

/// The kinds of place, `@` standing where the placeholder goes.
final _places = <(String, _Arrives)>[
  // Alone, and in the quotes a command already has.
  (r'printf %s @', _same),
  (r"printf %s '@'", _same),
  (r'printf %s "@"', _same),
  (r"printf %s $'@'", _same),
  (r'printf %s a@b', (v) => 'a${v}b'),
  (r"printf %s 'a@b'", (v) => 'a${v}b'),
  (r'printf %s "a@b"', (v) => 'a${v}b'),
  (r"""printf %s 'a'@'b'""", (v) => 'a${v}b'),
  (r"""printf %s "a"'@'"b" """, (v) => 'a${v}b'),
  (r"""printf %s 'a'"@"'b'""", (v) => 'a${v}b'),
  // What looks like a quote and is not one.
  (r"""printf %s "it's @" """, (v) => "it's $v"),
  (r"""printf %s 'say "@"' """, (v) => 'say "$v"'),
  (r"""printf %s \'@""", (v) => "'$v"),
  (r'printf %s \$@', (v) => '\$$v'),
  (r'printf %s $"@"', _same),
  (r'''printf %s "\"@\""''', (v) => '"$v"'),
  (r'printf %s \\@', (v) => '\\$v'),
  ("# it's a comment\nprintf %s @", _same),
  (": <<EOF\nit's a body\nEOF\nprintf %s @", _same),
  (": <<'EOF'\n\"\nEOF\nprintf %s \"@\"", _same),
  (r"""x=a#b'c'; printf %s @""", _same),
  (r"""echo $# >/dev/null; printf %s '@'""", _same),
  // Command substitutions.
  (r'printf %s "$(printf %s @)"', _substituted),
  (r'''printf %s "$(printf %s "@")"''', _substituted),
  (r"""printf %s "$(printf %s '@')" """, _substituted),
  (r'''printf %s "$(printf %s "$(printf %s '@')")"''', _substituted),
  (r"""printf %s "a$(printf %s 'b'"@"'c')d" """, (v) => 'ab${v}cd'),
  (r"""printf %s "$(: ')'; printf %s @)" """, _substituted),
  (r'printf %s $(printf %s ok) @', (v) => 'ok$v'),
  // Backticks.
  (r'printf %s "`printf %s @`"', _substituted),
  (r'''printf %s "`printf %s "@"`"''', _substituted),
  (r"""printf %s "`printf %s '@'`" """, _substituted),
  (r'printf %s "`printf %s "\`printf %s @\`"`"', _substituted),
  // (The middle one's output is split into words by the command itself.)
  (r'printf %s "`printf %s \`printf %s @\``"', (_) => null),
  (r"""printf %s "$(printf %s "`printf %s '@'`")" """, _substituted),
  // The shell's own ${...}.
  (r'printf %s ${x:-@}', _same),
  (r'printf %s "${x:-@}"', _same),
  (r'''printf %s ${x:-"@"}''', _same),
  (r'''printf %s "${x:-"@"}"''', _same),
  (r"""printf %s ${x:-'@'}""", _same),
  (r""": ${x:-'}'}; printf %s @""", _same),
  (r': ${#x}; printf %s @', _same),
  // Commands of every shape.
  (r'(printf %s @)', _same),
  (r'( (printf %s @) )', _same),
  (r'{ printf %s @; }', _same),
  (r'f() { printf %s "$1"; }; f @', _same),
  (r'for x in @; do printf %s "$x"; done', _same),
  (r'if true; then printf %s @; fi', _same),
  (r'x=@; printf %s "$x"', _same),
  (r'x="@"; printf %s "$x"', _same),
  (r'((1)) && printf %s @', _same),
  (r'printf %s $((1+1)) @', (v) => '2$v'),
  (r'printf %s "$((1+1))@"', (v) => '2$v'),
  (r'a=(1 2); printf %s @', _same),
  (r'case x in x) printf %s @;; esac', _same),
  (r'case x in (x) printf %s @;; esac', _same),
  (r'''printf %s "$(case x in x) printf %s @;; esac)"''', _substituted),
  (r'''printf %s "$( (case x in x) printf %s @;; esac) )"''', _substituted),
  (r"""printf %s "$(if true; then case x in x) printf %s '@';; esac; fi)" """, _substituted),
  // Comments: a line break in a value there is not a command's start.
  ('printf %s ok # @', (_) => 'ok'),
  ("printf %s ok # it's @", (_) => 'ok'),
  ('printf %s "\$(printf %s ok # @\n)"', (_) => 'ok'),
  // Here-documents.
  ('cat <<EOF\n@\nEOF\n', _inBody),
  ("cat <<'EOF'\n@\nEOF\n", _inBody),
  ('cat <<"EOF"\n@\nEOF\n', _inBody),
  ('cat <<\\EOF\n@\nEOF\n', _inBody),
  ('cat <<EOF\n@\nEOF', _inBody),
  ('cat <<EOF\n@', _inBody),
  ('cat <<EOF\n\$(printf %s @)\nEOF\n', (v) => _endsBody(v) ? null : '${_substituted(v)}\n'),
  ('cat <<EOF\n`printf %s @`\nEOF\n', (v) => _endsBody(v) ? null : '${_substituted(v)}\n'),
  ('cat <<EOF\n\${x:-@}\nEOF\n', (v) => _endsBody(v) ? null : '$v\n'),
  ('cat <<EOF; printf %s done\n@\nEOF\n', (v) => '${_inBody(v)}done'),
  ('printf %s "\$(cat <<EOF\n@\nEOF\n)"', (v) => _endsBody(v) ? null : _substituted(v)),
  ('cat <<A; cat <<B\n@\nA\nsecond\nB\n', (v) => '$v\nsecond\n'),
  ('cat <<-EOF\n\t@\n\tEOF\n', (_) => null),
  ('cat <<< @', (v) => '$v\n'),
  // Sums: what a sum has no use for does not get in.
  (r'printf %s "$(( @ ))"', (_) => null),
  (r'printf %s $(( @ + 1 ))', (_) => null),
  (r'(( @ )) ; printf %s done', (_) => null),
  (r'''printf %s "$(printf %s "$(( @ ))")"''', (_) => null),
];

void main() {
  final (shell, why) = _shellHere();
  late List<_Bench> benches;
  late Directory root;

  setUpAll(() async {
    if (shell == null) return;
    root = await Directory.systemTemp.createTemp('shell_fill');
    benches = [
      for (var i = 0; i < 8; i++) _Bench(shell, await Directory('${root.path}/$i').create()),
    ];
  });
  tearDownAll(() async {
    if (shell != null) await root.delete(recursive: true);
  });

  /// [run] over [cases], a few at once, with what failed.
  Future<List<String>> over(List<String> values, Future<String?> Function(_Bench bench, String value) run) async {
    final failed = <String>[];
    var next = 0;
    Future<void> worker(_Bench bench) async {
      while (next < values.length) {
        final said = await run(bench, values[next++]);
        if (said != null) failed.add(said);
      }
    }

    await Future.wait(benches.map(worker));
    return failed;
  }

  /// [template] filled with [value] by [fill], run: what went wrong, or null.
  Future<String?> proof(_Bench bench, String template, String value, String Function(String, String) fill, _Arrives arrives) async {
    final script = fill(template, value);
    final (out, ran) = await bench.run(script);
    if (ran) return 'RAN: template <$template> value <$value>\n  script: $script';
    final want = arrives(value);
    if (want != null && out != want) {
      return 'ARRIVED WRONG: template <$template> value <$value>\n  script: $script\n  got <$out>\n  want <$want>';
    }
    return null;
  }

  test('the proofs can see a command run', () async {
    final (out, ran) = await benches.first.run('touch PWNED; printf %s ok');
    expect(ran, isTrue, reason: 'the marker the proofs look for');
    expect(out, 'ok');
  }, skip: why);

  group('a value in every place, by a real shell', () {
    for (final (place, arrives) in _places) {
      test(place.replaceAll('\n', r'\n'), () async {
        final failed = await over(
          _hostile,
          (bench, value) => proof(bench, place.replaceAll('@', r'${P}'), value, (t, v) => resolveVariables(t, {'P': v}), arrives),
        );
        expect(failed, isEmpty, reason: failed.join('\n'));
      }, skip: why, timeout: const Timeout(Duration(minutes: 3)));
    }
  });

  group('every form a placeholder is written in', () {
    const nastiest = <String>[
      'foo; touch PWNED; echo',
      r'$(touch PWNED)',
      '`touch PWNED`',
      "'; touch PWNED; '",
      '"; touch PWNED; "',
      r'\',
      'x\nEOF\ntouch PWNED\nEOF\ny',
      r"""a'b"c`d$e\f""",
    ];
    const forms = <(String, String)>[
      (r'${P:-dflt}', 'P'),
      (r'${P:secret}', 'P'),
      (r'${P:password}', 'P'),
      ('{{P}}', 'P'),
      (r'$[a,b]', '[a,b]'),
      (r'${[a,b]}', '[a,b]'),
    ];
    // One place of each kind: what differs here is only how a placeholder is
    // written, and the walk is the same.
    final someOf = [for (var i = 0; i < _places.length; i += 6) _places[i]];
    for (final (form, key) in forms) {
      test(form, () async {
        final failed = <String>[];
        for (final (place, arrives) in someOf) {
          failed.addAll(await over(
            nastiest,
            (bench, value) => proof(
              bench,
              place.replaceAll('@', form),
              value,
              (t, v) => withSnippetVariables(t, {key: v}),
              arrives,
            ),
          ));
        }
        expect(failed, isEmpty, reason: failed.join('\n'));
      }, skip: why, timeout: const Timeout(Duration(minutes: 5)));
    }
  });

  group('what a review proved', () {
    test('quotes the template has are kept to', () {
      expect(resolveVariables(r"grep '${P}' log", {'P': 'foo; touch x; echo'}), "grep 'foo; touch x; echo' log");
      expect(resolveVariables(r'echo "${P}"', {'P': r'$(touch x)'}), r'echo "\$(touch x)"');
      expect(withSnippetVariables(r"grep '{{P}}' log", {'P': "it's"}), r"grep 'it'\''s' log");
      expect(withSnippetVariables(r'echo "{{P}}"', {'P': 'a`b"c'}), r'echo "a\`b\"c"');
    });

    test('an ordinary value in quotes comes out as itself: no quotes of its own', () {
      expect(resolveVariables(r'echo "${P}"', {'P': 'hello'}), 'echo "hello"');
      expect(resolveVariables(r"echo '${P}'", {'P': 'hello'}), "echo 'hello'");
      expect(resolveVariables(r'echo ${P}', {'P': 'hello'}), "echo 'hello'");
    });

    test('a placeholder escaped by its author is text', () {
      expect(resolveVariables(r'echo \${P}', {'P': 'x'}), r'echo \${P}');
      expect(resolveVariables(r'echo \\${P}', {'P': 'x'}), r"echo \\'x'");
      expect(resolveVariables(r"echo '\${P}'", {'P': 'x'}), r"echo '\x'", reason: 'a backslash is an ordinary character in single quotes');
    });

    test('one pass: what a value holds is not read for placeholders', () {
      expect(resolveVariables(r'echo ${A} ${B}', {'A': r'${B}', 'B': 'x'}), r"echo '${B}' 'x'");
      expect(resolveVariables(r'echo "${A}" "${B}"', {'A': r'${B}', 'B': 'x'}), r'echo "\${B}" "x"');
    });

    test('with no value it is left as it is, in any place', () {
      for (final t in const [r'tar czf ${HOME}/backup.tgz /etc', r'echo "${HOME}"', r"echo '${HOME}'", r'$(echo ${HOME})', r'cat <<EOF' '\n' r'${HOME}' '\nEOF']) {
        expect(fillPlaceholders(t, const {'OTHER': 'x'}), t);
      }
    });

    test('a backtick inside backticks is what it was, around the value', () {
      expect(resolveVariables(r'echo `date` ${P}', {'P': 'x'}), "echo `date` 'x'");
      expect(resolveVariables(r'echo `printf %s \`date\` $HOME "\$PATH"` ${P}', {'P': 'x'}), r'''echo `printf %s \`date\` $HOME "\$PATH"` 'x' ''' .trimRight());
    });

    test('a sum takes what a sum can use', () {
      expect(resolveVariables(r'echo $(( ${N} + 1 ))', {'N': '41'}), r'echo $(( 41 + 1 ))');
      expect(resolveVariables(r'echo $(( ${N} + 1 ))', {'N': r'a[$(touch x)]'}), r'echo $(( atouch x + 1 ))');
    });
  });

  // A `$` and a quote: bash reads that as `$'...'`, where a backslash is live.
  test('a dollar right before a placeholder', () async {
    final failed = await over(
      _hostile,
      (bench, value) => proof(bench, r'printf %s $${P}', value, (t, v) => resolveVariables(t, {'P': v}), _same),
    );
    expect(failed, isEmpty, reason: failed.join('\n'));
  }, skip: why);

  test('the ways a value can be written, for what keeps one out of a log', () {
    expect(filledForms('plain'), {'plain'});
    expect(filledForms("it's"), containsAll(["it's", r"it'\''s", r'it\x27s']));
    expect(filledForms(r'a$b'), containsAll([r'a$b', r'a\$b']));
    expect(filledForms('a"b'), containsAll(['a"b', r'a\"b']));
  });

  test('the sum comes out right, and a value that is one works', () async {
    final (out, _) = await benches.first.run(resolveVariables(r'printf %s $(( ${N} + 1 ))', {'N': '41'}));
    expect(out, '42');
    final (quoted, _) = await benches.first.run(resolveVariables(r'printf %s "$(( ${N} ))"', {'N': '2*3'}));
    expect(quoted, '6');
  }, skip: why);
}
