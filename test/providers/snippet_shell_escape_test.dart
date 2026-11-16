import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/snippet_providers.dart';

/// Lock down [shellEscapeArg] / [resolveVariables] against shell-
/// injection regressions. Each test is a concrete attack we want to
/// stay defended against.
void main() {
  group('shellEscapeArg', () {
    test('plain word wraps in single quotes', () {
      expect(shellEscapeArg('hello'), "'hello'");
    });

    test('whitespace stays inside the quotes', () {
      expect(shellEscapeArg('a b c'), "'a b c'");
    });

    test('empty string yields a literal pair of single quotes', () {
      // POSIX shell: bare '' is a valid empty argument; without it
      // the variable would degenerate to no argument at all.
      expect(shellEscapeArg(''), "''");
    });

    test('semicolon does not split into a new command', () {
      final escaped = shellEscapeArg('foo; rm -rf /');
      expect(escaped, "'foo; rm -rf /'");
      // Quick smoke test: the whole thing should be a single
      // single-quoted token.
      expect(escaped.startsWith("'"), isTrue);
      expect(escaped.endsWith("'"), isTrue);
      // No unescaped single-quote terminators in the middle.
      expect(escaped.substring(1, escaped.length - 1).contains("'"),
          isFalse);
    });

    test('embedded single quote uses the close-and-reopen trick', () {
      // Canonical: it's → 'it'\''s'  (close, escaped quote, open)
      expect(shellEscapeArg("it's"), r"'it'\''s'");
    });

    test('multiple embedded single quotes are all escaped', () {
      expect(shellEscapeArg(r"'a'b'"), r"''\''a'\''b'\'''");
    });

    test('command-substitution metacharacters are inert', () {
      // `$(rm -rf /)` only fires inside *double* quotes; single
      // quotes turn it back into a literal string.
      expect(shellEscapeArg(r'$(rm -rf /)'), r"'$(rm -rf /)'");
      expect(shellEscapeArg(r'`whoami`'), r"'`whoami`'");
    });

    test('backslash stays literal', () {
      // Inside single quotes, backslash has no special meaning.
      expect(shellEscapeArg(r'a\b'), r"'a\b'");
    });

    test('newline is preserved (callers assume single-line)', () {
      // Allowed by POSIX inside single quotes; we don't strip
      // newlines because legitimate values (multi-line text)
      // should also work. The caller is responsible for limiting
      // length in their UI if needed.
      expect(shellEscapeArg('a\nb'), "'a\nb'");
    });
  });

  group('resolveVariables', () {
    test('substitutes free-text values escaped', () {
      final out = resolveVariables(
        r'echo ${MSG}',
        {'MSG': 'hello world'},
      );
      expect(out, "echo 'hello world'");
    });

    test('blocks shell injection via free-text variable', () {
      // Without escaping, this would have ended `echo foo` and run
      // `rm -rf /`. With escaping, the entire malicious payload is
      // a single `echo` argument and never executes.
      final out = resolveVariables(
        r'echo ${MSG}',
        {'MSG': 'foo; rm -rf /'},
      );
      expect(out, "echo 'foo; rm -rf /'");
      expect(out.contains('rm -rf /'), isTrue,
          reason: 'literal preserved as a string');
      // Crucial property: no unescaped semicolons in the output
      // outside of the quoted region.
      final beforeQuote = out.substring(0, out.indexOf("'"));
      expect(beforeQuote.contains(';'), isFalse);
    });

    test('blocks command substitution attempts', () {
      final out = resolveVariables(
        r'echo ${MSG}',
        {'MSG': r'$(cat /etc/shadow)'},
      );
      expect(out, r"echo '$(cat /etc/shadow)'");
    });

    test('blocks backtick command substitution', () {
      final out = resolveVariables(
        r'echo ${MSG}',
        {'MSG': r'`whoami`'},
      );
      expect(out, r"echo '`whoami`'");
    });

    test('inline list value is also escaped', () {
      final out = resolveVariables(
        r'docker logs $[a,b,c]',
        {'[a,b,c]': 'foo; rm /'},
      );
      expect(out, "docker logs 'foo; rm /'");
    });

    test('value with embedded single quote substitutes safely', () {
      final out = resolveVariables(
        r'cat ${PATH}',
        {'PATH': "/path/with'quote"},
      );
      // Value escaped to '/path/with'\''quote'
      expect(out, r"cat '/path/with'\''quote'");
    });

    test('multiple substitutions are independently escaped', () {
      final out = resolveVariables(
        r'cp ${SRC} ${DST}',
        {'SRC': 'a; b', 'DST': 'c d'},
      );
      expect(out, "cp 'a; b' 'c d'");
    });

    test('empty value substitutes as empty single-quoted token', () {
      final out = resolveVariables(
        r'echo ${MSG}',
        {'MSG': ''},
      );
      expect(out, "echo ''");
    });
  });
}
