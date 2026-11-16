import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/dart_calls.dart';

// When something was, in the person's language (3.0). The
// automation's runs and API keys, the bell, the Keys page, the palette, the
// Hosts page's recent hosts, the Server Monitor and the history said it in
// English in every language, each with words of its own ("just now", "5m
// ago", "3d", "Jan" to "Dec"), and a date written with no language is
// written in English ("Sep 28", "9/28/2026", "2:05 PM").
//
// What this finds in the strings written in lib/ (past comments, and past
// the generated code: the strings of the twelve languages, the database's):
// "just now"; a time with "ago" after it; a time in minutes, hours or days
// with a letter for its unit, at the end of a string ("5m", "3h"); "now" and
// "<1m" of their own; an English month's name of its own; and a DateFormat
// given no language. What it lets be is listed below with why; an allowance
// that is no longer needed fails it too.

/// What is let be: a file and what is found in it, with why.
const _allowed = <String, String>{
  'lib/services/demo_shell_service.dart|month': "the demo server's date command, as a server prints it",
  'lib/features/teams/crypto/fingerprint_word_list.dart|now': 'a word of the list a fingerprint is said in',
};

final _justNow = RegExp(r'\bjust now\b', caseSensitive: false);
final _ago = RegExp(r'(\}|\$[A-Za-z_]\w*)\s?[a-z]{0,7}\s+ago\b');
final _unit = RegExp(r'\$\{[^}]*\.in(?:Minutes|Hours|Days)\b[^}]*\}\s?(?:m|h|d|w|mo|y)$');
const _bare = {'now', 'Now', '<1m'};
const _months = {
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Sept', 'Oct', 'Nov', 'Dec', //
  'January', 'February', 'March', 'April', 'June', 'July', 'August', 'September', 'October', 'November', 'December',
};
final _formatNamed = RegExp(r'\bDateFormat\.[A-Za-z_]\w*\s*\(');
final _formatPattern = RegExp(r'\bDateFormat\s*\(');

/// "kind|file:line: what" for each English time written in [files].
List<({String path, String kind, String said})> englishTimes(Map<String, String> files) {
  final found = <({String path, String kind, String said})>[];
  for (final MapEntry(key: path, value: text) in files.entries) {
    void add(String kind, int line, String said) => found.add((path: path, kind: kind, said: '$path:$line: $said'));
    for (final s in stringsIn(text)) {
      if (_justNow.hasMatch(s.text)) add('just now', s.line, s.text);
      if (_ago.hasMatch(s.text)) add('ago', s.line, s.text);
      if (_unit.hasMatch(s.text)) add('unit', s.line, s.text);
      if (_bare.contains(s.text)) add('now', s.line, s.text);
      if (_months.contains(s.text)) add('month', s.line, s.text);
    }
    for (final call in callsIn(text, _formatNamed)) {
      if (argsOf(call.args).isEmpty) add('DateFormat', call.line, 'DateFormat.x(${call.args})');
    }
    for (final call in callsIn(text, _formatPattern)) {
      if (argsOf(call.args).length < 2) add('DateFormat', call.line, 'DateFormat(${call.args})');
    }
  }
  return found;
}

void main() {
  test("the app says when something was in the page's language: no English time is written in lib, and no date "
      'without a language, but what is listed with why', () {
    final files = <String, String>{
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') &&
            !file.path.endsWith('.g.dart') &&
            !file.path.replaceAll(r'\', '/').contains('/generated/'))
          file.path.replaceAll(r'\', '/'): file.readAsStringSync().replaceAll('\r\n', '\n'),
    };
    expect(files.length, greaterThan(500));
    final found = <String>[];
    final used = <String>{};
    for (final f in englishTimes(files)) {
      final allowance = '${f.path}|${f.kind}';
      if (_allowed.containsKey(allowance)) {
        used.add(allowance);
      } else {
        found.add('${f.kind}: ${f.said}');
      }
    }
    expect(found, isEmpty, reason: 'the shared words of lib/l10n/time_ago.dart, and a DateFormat given l10n.localeName');
    expect(used, _allowed.keys.toSet(), reason: 'every allowance is still needed');
  });

  test('the check finds them where they are written, past comments, and lets be what the languages say', () {
    const written = r'''
// 'just now', '${d.inMinutes}m ago' and DateFormat.yMMMd() in a comment are let be
String a(Duration d) => '${d.inMinutes}m ago';
final b = 'Just now';
final c = '${(d.inDays / 7).floor()}w';
final e = DateFormat.yMMMd().format(x);
final f = DateFormat('MMM d').format(x);
const g = ['Jan', 'Feb'];
final h = '$days days ago';
final i = d.inMinutes < 1 ? '<1m' : 'now';
''';
    expect(englishTimes({'a.dart': written}).map((f) => '${f.kind} ${f.said.split(': ').first}'), [
      'ago a.dart:2',
      'just now a.dart:3',
      'unit a.dart:4',
      'month a.dart:7',
      'month a.dart:7',
      'ago a.dart:8',
      'now a.dart:9',
      'now a.dart:9',
      'DateFormat a.dart:5',
      'DateFormat a.dart:6',
    ]);
    const fine = r'''
final a = l10n.timeMinutesAgo(5);
final b = DateFormat.yMMMd(l10n.localeName).add_jm().format(x);
final c = DateFormat('HH:mm', l10n.localeName).format(x);
final d = '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
final e = r"sudo journalctl --since '10 min ago' --no-pager";
final f = 'Sep 28 is a date in words';
/* '5m ago', 'just now' */
''';
    expect(englishTimes({'b.dart': fine}), isEmpty);
  });
}
