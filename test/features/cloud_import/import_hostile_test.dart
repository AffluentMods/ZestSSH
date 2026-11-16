import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';

/// A small text file once froze the whole app, live sessions included: a
/// pattern that tries two ways of reading each word takes twice as long with
/// each word, on the screen's own thread, for a file chosen, a file dropped, a
/// hand-picked importer and text pasted. Anything may come here, so nothing may
/// take longer than the file is long: what is made to be slow, at the largest
/// size that is read, within a limit. Each runs on an isolate of its own, killed
/// at the limit, so that a pattern that never ends fails this test and does not
/// hang it. And what is large never runs on the screen's own thread.

/// Far above what any of these takes (a second or two on a busy computer), far
/// below what a pattern that is not linear takes on [_mb] megabytes.
const _limit = Duration(seconds: 40);

const _mb = kCsvMaxBytes;

/// As much of [unit], and a line of [tail], as the largest file holds.
String _fill(String unit, [String tail = '']) {
  final b = StringBuffer();
  final times = (_mb - utf8.encode(tail).length) ~/ utf8.encode(unit).length;
  for (var i = 0; i < times; i++) {
    b.write(unit);
  }
  b.write(tail);
  return b.toString();
}

void _work((SendPort, Object? Function()) job) {
  final (port, work) = job;
  try {
    port.send((work(), null));
  } catch (e) {
    port.send((null, '$e'));
  }
}

/// [work] on its own isolate within [_limit]; what it threw comes back as words.
Future<(Object?, String?)> _within(Object? Function() work) async {
  final answer = ReceivePort();
  final isolate = await Isolate.spawn(_work, (answer.sendPort, work));
  try {
    return await answer.first.timeout(_limit) as (Object?, String?);
  } finally {
    isolate.kill(priority: Isolate.immediate);
    answer.close();
  }
}

final _hostile = <String, String Function()>{
  // Lines short enough to be looked at as keys, where a pattern that tries two
  // ways of reading each word never comes back.
  'a short line of tokens each with several =': () => '${'a=b=c=d ' * 40}end\n',
  'a short line of base64 tokens ending ==': () => '${'QUJDREVGR0g== ' * 60}\n',
  'line after line of them': () => _fill('${'a=b=c=d ' * 40}end\n'),
  'lines of tokens, as long as a key line is looked at': () => _fill('${'a=b=c=d ' * 8000}end\n'),
  'options, as long as a key line is looked at': () => _fill('${'pty,' * 16000}pty x\n'),
  'quoted options, as long as a key line is looked at': () => _fill('${'from="a b",' * 5000}pty x\n'),
  'host names, as long as a key line is looked at': () => _fill('${'a' * 60000} x\n'),
  'tokens each with several =': () => _fill('a=b=c=d '),
  'base64 tokens ending ==': () => _fill('QUJDREVGR0g== '),
  'one token of = alone': () => _fill('='),
  'blank lines': () => 'x${_fill('\n')}x',
  'lines of spaces': () => 'x\n${_fill('    \n')}x',
  'spaces without an end': () => 'x\n${_fill(' ')}x',
  'option after option': () => '${_fill('pty,')}pty ssh-ed25519 ',
  'an option\'s value with no end': () => 'from="${_fill('a')}',
  'an option\'s value of escapes': () => 'from="${_fill(r'\\')}',
  'quoted option after quoted option': () => _fill('from="a",'),
  'a key line with a long end': () => 'ssh-ed25519 AAAA${_fill('A')}\u2028x',
  'a host key line with no type': () => _fill('a'),
  'markers': () => _fill('@a '),
  'hashed names': () => _fill('|1|a '),
  'a config line with white space and no end': () => 'Host${_fill(' ')}x\u2028y',
  'a config line with = and no end': () => '${_fill('=')}\u2028y',
  'a config key and white space, line after line': () => _fill('Host      x\u2028\n'),
  'a Host line of names': () => 'Host ${_fill('a ')}',
  'a Host line again and again': () => _fill('Host a\n'),
  'wildcards again and again': () => _fill('Host *\n'),
  'pem starts': () => _fill('-----BEGIN '),
  'pem starts with a long name': () => '-----BEGIN ${_fill('A ')}',
  'dashes': () => _fill('-'),
  'ssh2 starts': () => _fill('---- BEGIN SSH2 '),
  'bookmarks almost': () => _fill('[Bookmark\n'),
  'securecrt almost': () => _fill('S:"Hostname"\n'),
  'a session file of settings': () => 'S:"Hostname"=a\n${_fill('S:"Port"=1\n')}',
  'a reg file of sections': () => 'Windows Registry Editor SimonTatham\n${_fill(r'[\SimonTatham\PuTTY\Sessions\a')}',
  'a reg file of values': () =>
      'Windows Registry Editor SimonTatham\n[\\SimonTatham\\PuTTY\\Sessions\\a]\n${_fill('"a"="b"\n')}',
  'moba sessions': () => '[Bookmarks]\n${_fill('a=#109#0%b%22%c%\n')}',
  'moba sessions with no end': () => '[Bookmarks]\na=#109#0%${_fill('b')}',
  'quotes': () => _fill('"'),
  'a csv of fields': () => 'host,name\n${_fill('a,b\n')}',
  'a csv with a quote left open': () => 'host,name\n"${_fill('a,b\n')}',
  'a csv header of commas': () => _fill(','),
  'nested xml': () => '<VanDyke><key name="Sessions">${_fill('<key name="a">')}',
  'nested xml, closed': () {
    const open = '<key name="a">';
    const shut = '</key>';
    final times = (_mb - 40) ~/ (open.length + shut.length);
    return '<VanDyke><key name="Sessions">${open * times}${shut * times}</key></VanDyke>';
  },
  'xml attributes': () => '<VanDyke ${_fill('a="b" ')}',
  'nested json': () => _fill('['),
  'json with a nesting of keys': () => _fill('{"a":'),
};

void main() {
  for (final e in _hostile.entries) {
    test('what is made to be slow: ${e.key}', () async {
      final bytes = utf8.encode(e.value());
      expect(bytes.length, lessThanOrEqualTo(_mb + 1024));
      final detected = await _within(() => importKindOf(bytes));
      expect(detected.$2, isNull, reason: 'the detector threw: ${detected.$2}');
      final read = await _within(() => readHostBytes(bytes).file.rows.length);
      expect(read.$2, isNull, reason: 'the host file reader threw: ${read.$2}');
      final pasted = await _within(() => readHostBytes(bytes, pasted: true).file.rows.length);
      expect(pasted.$2, isNull, reason: 'the list reader threw: ${pasted.$2}');
      final config = await _within(() => parseSshConfigBytes(bytes).entries.length);
      expect(config.$2, isNull, reason: 'the config reader threw: ${config.$2}');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  group('what is large is looked at away from the screen', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zest_import_large_');
      debugImportWorkHere = 0;
    });
    tearDown(() => dir.delete(recursive: true));

    String write(String name, String text) {
      final path = '${dir.path}${Platform.pathSeparator}$name';
      File(path).writeAsStringSync(text);
      return path;
    }

    final large = 'host\n${List.filled(30000, 'web.example.com').join('\n')}\n';
    const small = 'host\nweb.example.com\n';

    test('a file chosen or dropped: the detector', () async {
      expect((await readImportFile(write('large.csv', large))).kind, ImportKind.csv);
      expect(debugImportWorkHere, 0, reason: 'it ran on the screen\'s thread');
      expect((await readImportFile(write('small.csv', small))).kind, ImportKind.csv);
      expect(debugImportWorkHere, 1, reason: 'a small file takes no time anywhere');
    });

    test('text pasted: the detector', () async {
      expect((await importFileAway(name: 'x', bytes: utf8.encode(large))).kind, ImportKind.csv);
      expect(debugImportWorkHere, 0);
    });

    test('the host file reader, and the list reader', () async {
      expect((await readHostBytesAway(utf8.encode(large))).file.cut, isTrue);
      expect((await readHostBytesAway(utf8.encode(large), pasted: true)).kind, HostFileKind.paste);
      expect(debugImportWorkHere, 0);
    });

    test('the SSH config reader, and the config this computer has', () async {
      final config = 'Host ${List.filled(30000, 'web').join(' ')}\n';
      expect((await parseSshConfigAway(utf8.encode(config))).entries, hasLength(kCsvMaxHosts));
      expect((await const SshConfigSource().detectAt(write('config', config)))!.entries, hasLength(kCsvMaxHosts));
      expect(debugImportWorkHere, 0);
    });

    test('a config larger than a host file may be is not read at all', () async {
      final path = write('config', _fill('# a comment\n', '# and more than that\n' * 1000));
      File(path).writeAsBytesSync(utf8.encode('Host web\n'), mode: FileMode.append);
      expect(File(path).lengthSync(), greaterThan(kCsvMaxBytes));
      expect(await const SshConfigSource().detectAt(path), isNull);
    });
  });
}
