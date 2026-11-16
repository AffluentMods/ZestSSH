import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/snippet_providers.dart';

/// Covers the 1.7 detected-variables work:
///  * parsing `${NAME}` and `${NAME:-default}` (the new default syntax)
///  * the write-side [setVariableDefault] that the Default cell uses
///  * run-time filtering ([variablesToPrompt] / [defaultSeedValues]) so only
///    variables WITHOUT a default get prompted
///  * [resolveVariables] resolving a defaulted placeholder
///  * the snippet-metadata JSON round-trip (per-variable descriptions)
void main() {
  group('parseVariablesWithOptions - free-text + defaults', () {
    test(r'${NAME} parses as a required free-text variable', () {
      final vars = parseVariablesWithOptions(r'echo ${NAME}');
      expect(vars, hasLength(1));
      final v = vars.single;
      expect(v.name, 'NAME');
      expect(v.type, VariableType.freeText);
      expect(v.defaultValue, isNull);
      expect(v.hasDefault, isFalse);
      expect(v.isRequired, isTrue);
      expect(v.matchPattern, r'${NAME}');
    });

    test(r'${NAME:-default} captures the default and is NOT required', () {
      final vars = parseVariablesWithOptions(r'docker restart ${NAME:-web}');
      expect(vars, hasLength(1));
      final v = vars.single;
      expect(v.name, 'NAME');
      expect(v.type, VariableType.freeText);
      expect(v.defaultValue, 'web');
      expect(v.hasDefault, isTrue);
      expect(v.isRequired, isFalse);
      expect(v.matchPattern, r'${NAME:-web}');
    });

    test(r'${VAR:-} (empty default) is a real, non-null default', () {
      final v = parseVariablesWithOptions(r'echo ${VAR:-}').single;
      expect(v.defaultValue, '');
      expect(v.hasDefault, isTrue);
      expect(v.isRequired, isFalse);
    });

    test('a default may contain spaces and punctuation', () {
      final v =
          parseVariablesWithOptions(r'echo ${MSG:-hello world!}').single;
      expect(v.defaultValue, 'hello world!');
    });

    test('mixed bare + defaulted occurrences: first wins, dedup by name', () {
      final vars =
          parseVariablesWithOptions(r'cp ${P:-/tmp} ${P} ${Q}');
      expect(vars.map((v) => v.name), ['P', 'Q']);
      final p = vars.firstWhere((v) => v.name == 'P');
      expect(p.defaultValue, '/tmp');
      final q = vars.firstWhere((v) => v.name == 'Q');
      expect(q.defaultValue, isNull);
    });

    test('list + dynamic syntaxes still parse (regression)', () {
      final inline =
          parseVariablesWithOptions(r'systemctl $[start,stop] nginx').single;
      expect(inline.type, VariableType.inlineList);
      expect(inline.options, ['start', 'stop']);
      expect(inline.isRequired, isFalse); // list resolves via picker

      final dyn = parseVariablesWithOptions(r'docker logs $[DOCKER]').single;
      expect(dyn.type, VariableType.dynamicList);
      expect(dyn.dynamicSource, 'DOCKER');
    });

    test(r'every ${} placeholder in a command with defaults is detected', () {
      // A representative command mixing all forms.
      final vars = parseVariablesWithOptions(
          r'ssh ${USER:-root}@${HOST} -p ${PORT:-22} $[a,b]');
      expect(vars.map((v) => v.name).toSet(),
          containsAll(<String>{'USER', 'HOST', 'PORT'}));
      final byName = {for (final v in vars) v.name: v};
      expect(byName['USER']!.defaultValue, 'root');
      expect(byName['HOST']!.defaultValue, isNull);
      expect(byName['PORT']!.defaultValue, '22');
    });
  });

  group('setVariableDefault - the Default cell write-side', () {
    test('adds a default to a bare placeholder', () {
      expect(setVariableDefault(r'echo ${NAME}', 'NAME', 'web'),
          r'echo ${NAME:-web}');
    });

    test('replaces an existing default', () {
      expect(setVariableDefault(r'echo ${NAME:-old}', 'NAME', 'new'),
          r'echo ${NAME:-new}');
    });

    test('clearing (empty/null) reverts to the bare placeholder', () {
      expect(setVariableDefault(r'echo ${NAME:-old}', 'NAME', ''),
          r'echo ${NAME}');
      expect(setVariableDefault(r'echo ${NAME:-old}', 'NAME', null),
          r'echo ${NAME}');
    });

    test('rewrites every occurrence of the variable', () {
      expect(setVariableDefault(r'${N} and ${N:-x}', 'N', 'y'),
          r'${N:-y} and ${N:-y}');
    });

    test('round-trips through the parser', () {
      final cmd = setVariableDefault(r'run ${TARGET}', 'TARGET', 'prod');
      final v = parseVariablesWithOptions(cmd).single;
      expect(v.defaultValue, 'prod');
      expect(v.isRequired, isFalse);
    });

    test("strips '}' from a default so the placeholder can't corrupt (regression)",
        () {
      // A '}' would terminate the ${NAME:-…} placeholder early and truncate the
      // rest of the command on the next parse. It must be stripped, and the
      // command must still parse cleanly with a single intact variable.
      final cmd = setVariableDefault(r'echo ${J}', 'J', '{"a":1}');
      expect(cmd, r'echo ${J:-{"a":1}');
      final vars = parseVariablesWithOptions(cmd);
      expect(vars, hasLength(1));
      expect(vars.single.name, 'J');
      expect(vars.single.defaultValue, '{"a":1');
    });
  });

  group('run-time prompt filtering', () {
    test('only no-default variables are prompted; defaults are seeded', () {
      const cmd = r'ssh ${USER:-root}@${HOST} -p ${PORT:-22}';
      final prompt = variablesToPrompt(cmd);
      expect(prompt.map((v) => v.name), ['HOST'],
          reason: 'USER and PORT carry defaults, so only HOST is prompted');

      final seeds = defaultSeedValues(cmd);
      expect(seeds, {'USER': 'root', 'PORT': '22'});
    });

    test('a fully-defaulted command needs no prompt', () {
      const cmd = r'docker restart ${NAME:-web}';
      expect(variablesToPrompt(cmd), isEmpty);
      expect(defaultSeedValues(cmd), {'NAME': 'web'});
    });

    test('a command with no defaults prompts for everything', () {
      const cmd = r'cp ${SRC} ${DST}';
      expect(variablesToPrompt(cmd).map((v) => v.name), ['SRC', 'DST']);
      expect(defaultSeedValues(cmd), isEmpty);
    });
  });

  group('resolveVariables with defaulted placeholders', () {
    test(r'substitutes a ${VAR:-default} placeholder from the values map', () {
      final out = resolveVariables(
          r'docker restart ${NAME:-web}', {'NAME': 'web'});
      expect(out, "docker restart 'web'");
    });

    test('an overridden value replaces the whole defaulted placeholder', () {
      final out = resolveVariables(
          r'docker restart ${NAME:-web}', {'NAME': 'api'});
      expect(out, "docker restart 'api'");
    });

    test('escaping still applies to defaulted placeholders', () {
      final out = resolveVariables(
          r'echo ${MSG:-hi}', {'MSG': 'a; rm -rf /'});
      expect(out, "echo 'a; rm -rf /'");
    });

    test(r'a bare ${VAR} still resolves (regression)', () {
      expect(resolveVariables(r'echo ${X}', {'X': 'y'}), "echo 'y'");
    });

    test(r'masked ${VAR:secret} / ${VAR:password} resolve (suffix consumed)',
        () {
      // The :secret / :password suffix only changes how the value is COLLECTED
      // (obscured input); the resolver must still substitute, keyed by the bare
      // name. Regression guard for the parser/resolver regex mismatch that left
      // the placeholder verbatim (leaking it to the remote shell).
      expect(resolveVariables(r'auth ${TOKEN:secret}', {'TOKEN': 'abc123'}),
          "auth 'abc123'");
      expect(resolveVariables(r'login ${PW:password}', {'PW': 'p@ss'}),
          "login 'p@ss'");
      // Combined default + secret marker.
      expect(
          resolveVariables(r'x ${K:-def:secret}', {'K': 'v'}), "x 'v'");
    });
  });

  group('snippetRunsUnattended - "run snippet on connect" safety gate', () {
    test('a plain command with no variables runs unattended', () {
      expect(
        snippetRunsUnattended('uptime && df -h', confirmBeforeRun: false),
        isTrue,
      );
    });

    test('a fully-defaulted command runs (defaults resolve remotely)', () {
      expect(
        snippetRunsUnattended(r'docker restart ${NAME:-web}',
            confirmBeforeRun: false),
        isTrue,
      );
    });

    test('confirm-before-run is never auto-fired', () {
      expect(
        snippetRunsUnattended('uptime', confirmBeforeRun: true),
        isFalse,
      );
    });

    test(r'a bare ${VAR} with no default is skipped (nothing to prompt with)',
        () {
      expect(
        snippetRunsUnattended(r'deploy ${TARGET}', confirmBeforeRun: false),
        isFalse,
      );
    });

    test('a list/dynamic variable is skipped (needs a picker)', () {
      expect(
        snippetRunsUnattended(r'systemctl $[start,stop] nginx',
            confirmBeforeRun: false),
        isFalse,
      );
      expect(
        snippetRunsUnattended(r'docker logs $[DOCKER]', confirmBeforeRun: false),
        isFalse,
      );
    });
  });

  group('snippet metadata JSON round-trip', () {
    test('encode → decode preserves description + variable notes', () {
      const meta = SnippetMetadata(
        description: 'Restarts the web container',
        variableDescriptions: {'NAME': 'container to restart'},
      );
      final encoded = encodeSnippetMetadata(meta);
      expect(encoded, isNotNull);
      final decoded = parseSnippetMetadata(encoded);
      expect(decoded.description, 'Restarts the web container');
      expect(decoded.variableDescriptions['NAME'], 'container to restart');
    });

    test('empty metadata encodes to null (stores NULL, not "{}")', () {
      expect(encodeSnippetMetadata(SnippetMetadata.empty), isNull);
      expect(
          encodeSnippetMetadata(const SnippetMetadata(description: '')), isNull);
    });

    test('null / blank / malformed decode to empty, never throw', () {
      expect(parseSnippetMetadata(null).isEmpty, isTrue);
      expect(parseSnippetMetadata('').isEmpty, isTrue);
      expect(parseSnippetMetadata('not json{').isEmpty, isTrue);
      expect(parseSnippetMetadata('[1,2,3]').isEmpty, isTrue);
    });
  });
}
