import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Plurals in the languages whose ONE form covers more than the number 1.
///
/// The generator maps an exact `=1{...}` case to the ONE form. In English,
/// German, Spanish and Italian ONE is exactly 1, so `=1{1 host}` is right.
/// In French, Hindi and Portuguese ONE is 0 and 1; in Russian it is 1, 21,
/// 31, 101 and so on. A ONE form that says a literal "1" was shown for those
/// other numbers too: "1 session active" with no session open in French,
/// "1 активный сеанс" with 21 sessions in Russian.
///
/// So in those four languages the ONE form shows the count through its own
/// placeholder and never a digit, and `=1` (which only looks exact) is not
/// used at all.

const _widerOne = ['fr', 'hi', 'pt', 'ru'];

/// One `{name, plural, ...}` block: the variable and its cases.
class _Plural {
  _Plural(this.variable, this.cases);
  final String variable;
  final Map<String, String> cases;
}

/// Every plural block in [message]. Bodies may hold placeholders and nested
/// braces; a selector that appears twice keeps its last body (as the
/// generator does), with the repeat noted under the key `=1+one` when it is
/// the `=1` and `one` pair.
List<_Plural> _pluralsOf(String message) {
  final out = <_Plural>[];
  final head = RegExp(r'\{\s*([A-Za-z_]\w*)\s*,\s*plural\s*,');
  final selector = RegExp(r'\s*(=\d+|zero|one|two|few|many|other)\s*\{');
  for (final m in head.allMatches(message)) {
    var i = m.end;
    final cases = <String, String>{};
    while (i < message.length) {
      final s = selector.matchAsPrefix(message, i);
      if (s == null) break;
      var j = s.end;
      var depth = 1;
      while (j < message.length && depth > 0) {
        final ch = message[j];
        if (ch == '{') depth++;
        if (ch == '}') depth--;
        j++;
      }
      final name = s.group(1)!;
      if ((name == '=1' && cases.containsKey('one')) ||
          (name == 'one' && cases.containsKey('=1'))) {
        cases['=1+one'] = '';
      }
      cases[name] = message.substring(s.end, j - 1);
      i = j;
    }
    out.add(_Plural(m.group(1)!, cases));
  }
  return out;
}

/// Whether [body] holds a digit 1 that stands for the number one: outside
/// every `{placeholder}`, and not part of a longer number or a name
/// (`1Password`, `v1`, `10`).
bool _saysOne(String body) {
  final bare = body.replaceAll(RegExp(r'\{[^{}]*\}'), '\u0000');
  final unit = RegExp(r'[0-9A-Za-zÀ-￿]');
  for (var i = 0; i < bare.length; i++) {
    if (bare[i] != '1') continue;
    final before = i == 0 ? '' : bare[i - 1];
    final after = i + 1 == bare.length ? '' : bare[i + 1];
    if (unit.hasMatch(before) || unit.hasMatch(after)) continue;
    return true;
  }
  return false;
}

Map<String, String> _messages(String language) {
  final json = jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
      as Map<String, dynamic>;
  return {
    for (final e in json.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}

void main() {
  test('the checker itself reads plurals the way the generator does', () {
    final p = _pluralsOf(
        'a {n, plural, =0{none} =1{1 thing {x}} other{{n} things}} b '
        '{m, plural, one{{m} file} few{{m} files} other{{m} files}}');
    expect(p, hasLength(2));
    expect(p[0].variable, 'n');
    expect(p[0].cases, {'=0': 'none', '=1': '1 thing {x}', 'other': '{n} things'});
    expect(p[1].cases.keys, ['one', 'few', 'other']);
    expect(_saysOne('1 thing'), isTrue);
    expect(_saysOne('Add 1'), isTrue);
    expect(_saysOne('{n} thing'), isFalse);
    expect(_saysOne('{count1} of 10 with 1Password v1'), isFalse);
    expect(_saysOne('1 of {n}'), isTrue);
  });

  test('every language file is there', () {
    final files = Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'app_[a-z]+\.arb$').hasMatch(f.path))
        .toList();
    expect(files, hasLength(12));
  });

  for (final language in _widerOne) {
    test('$language: no ONE form says a literal 1, and none is written =1',
        () {
      final problems = <String>[];
      _messages(language).forEach((key, message) {
        for (final plural in _pluralsOf(message)) {
          if (plural.cases.containsKey('=1')) {
            problems.add('$key: `=1{...}` is the ONE form here, which is not '
                'only the number 1; write it `one{...}` with '
                '{${plural.variable}}');
          }
          if (plural.cases.containsKey('=1+one')) {
            problems.add('$key: has both `=1{}` and `one{}`; one overrides '
                'the other');
          }
          for (final form in const ['=1', 'one']) {
            final body = plural.cases[form];
            if (body != null && _saysOne(body)) {
              problems.add('$key: the $form form says a literal 1: "$body"');
            }
          }
        }
      });
      expect(problems, isEmpty, reason: problems.take(30).join('\n'));
    });
  }

  test('Russian: a ONE form shows its number unless the number is printed '
      'right before it, and few and many are there where the word changes',
      () {
    final problems = <String>[];
    _messages('ru').forEach((key, message) {
      for (final plural in _pluralsOf(message)) {
        final one = plural.cases['one'];
        if (one == null) continue;
        final shown = one.contains('{${plural.variable}}');
        // "{count} {count, plural, one{файл} ...}": the number stands in
        // front of the block, the block is only the noun.
        final nounOnly = RegExp(
                '\\{${plural.variable}\\}\\s*\\{\\s*${plural.variable}\\s*,\\s*plural')
            .hasMatch(message);
        // A label with no number in it at all (a button: "Add tag").
        final label = !one.contains(RegExp(r'\d'));
        if (!shown && !nounOnly && !label) {
          problems.add('$key: the ONE form does not show the number: "$one"');
        }
        if (nounOnly && !(plural.cases.containsKey('few') &&
            plural.cases.containsKey('many'))) {
          problems.add('$key: a noun after a number needs few and many');
        }
      }
    });
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  group('what the app actually says', () {
    AppLocalizations l(String code) => lookupAppLocalizations(Locale(code));

    test('French: nothing is 0, not 1', () {
      final fr = l('fr');
      expect(fr.trayActiveSessions(0), '0 session active');
      expect(fr.trayActiveSessions(1), '1 session active');
      expect(fr.trayActiveSessions(2), '2 sessions actives');
      expect(fr.sessionsBulkClose(0), 'Fermer 0 session');
      expect(fr.tmuxPaneCount(1), '1 volet');
      // A string with its own words for nothing still uses them.
      expect(fr.zestKeysMetricUsedBy(0), 'Utilisée par aucun hôte');
      expect(fr.zestKeysMetricUsedBy(1), 'Utilisée par 1 hôte');
    });

    test('Russian: 21 is 21, and 2, 5, 11 and 22 take their own forms', () {
      final ru = l('ru');
      expect(ru.trayActiveSessions(1), '1 активный сеанс');
      expect(ru.trayActiveSessions(21), '21 активный сеанс');
      expect(ru.trayActiveSessions(2), '2 активных сеанса');
      expect(ru.trayActiveSessions(22), '22 активных сеанса');
      expect(ru.trayActiveSessions(5), '5 активных сеансов');
      expect(ru.trayActiveSessions(11), '11 активных сеансов');
      expect(ru.trayActiveSessions(111), '111 активных сеансов');
      expect(ru.sftpFileCount(21), '21 файл');
      expect(ru.sftpFileCount(3), '3 файла');
      expect(ru.sftpFileCount(12), '12 файлов');
      expect(ru.zestKeysMetricUsedBy(0), 'Не используется ни одним хостом');
      expect(ru.zestKeysMetricUsedBy(101), 'Используется 101 хостом');
      expect(ru.sessionsBulkClose(31), 'Закрыть 31 сеанс');
      expect(ru.sessionsBulkClose(4), 'Закрыть сеансы: 4');
    });

    test('Hindi and Portuguese: nothing is 0, not 1', () {
      final hi = l('hi');
      expect(hi.sessionsBulkClose(0), startsWith('0 '));
      expect(hi.sessionsBulkClose(1), startsWith('1 '));
      final pt = l('pt');
      expect(pt.sessionsBulkClose(0), 'Fechar 0 sessão');
      expect(pt.sessionsBulkClose(1), 'Fechar 1 sessão');
      expect(pt.sessionsBulkClose(3), 'Fechar 3 sessões');
    });

    test('where ONE is exactly one, an exact case still reads as before', () {
      expect(l('en').trayActiveSessions(1), '1 active session');
      expect(l('en').trayActiveSessions(0), '0 active sessions');
      expect(l('de').sessionsBulkClose(1), contains('1'));
      // Japanese has no ONE form; the exact case is still honoured for 1.
      expect(l('ja').tmuxPaneCount(1), contains('1'));
      expect(l('ja').tmuxPaneCount(21), contains('21'));
    });
  });
}
