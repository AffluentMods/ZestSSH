import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/repository_text.dart';

/// Every private address written anywhere in the repository is a made-up one.
///
/// Tests, comments, strings and documents are where examples get copied from
/// (into the docs, the website, a screenshot), so an address of a network that
/// exists must never be written into them. The test cannot name what must not
/// be used without writing it down, so it goes the other way: a private
/// address (10.x.x.x, 172.16 to 172.31, 192.168.x.x) has to lie in one of the
/// ranges listed here, every one of them made up.
///
/// For a new example use the demo fleet (192.168.10.x, 192.168.20.x), 10.50.0.x
/// or a documentation range (192.0.2.x, 198.51.100.x, 203.0.113.x). A range is
/// added to this list on purpose, when a test needs one that differs; never by
/// typing an address one happens to know.
const _madeUp = {
  // The demo fleet and its second site.
  '192.168.10', '192.168.20',
  // The made-up network of the tests, and a second subnet of it.
  '10.50.0', '10.50.5',
  // What everybody's examples use.
  '10.0.0', '10.0.1', '10.0.2', '10.0.5', '192.168.0', '192.168.1', '192.168.2', '192.168.5', '192.168.7',
  '172.16.0', '172.17.0', '172.31.0', '172.31.255', '10.255.255',
  // A team's other places in the setup tests, and a cloud's own ranges.
  '10.30.0', '10.40.0', '10.90.0', '10.1.0', '10.8.0', '10.128.0',
  // Addresses the masking tests mask, and one a rule refuses.
  '10.77.0', '10.12.111', '10.244.95', '10.6.6',
  // The neighbour a subnet test says is outside.
  '10.21.0',
};

final _private = RegExp(r'(?<![0-9.])0{0,2}'
    r'(10\.[0-9]{1,3}\.[0-9]{1,3}|172\.0?(?:1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}|192\.168\.[0-9]{1,3})'
    r'\.[0-9]{1,3}(?![0-9])');

/// The private addresses in [text] that lie in no made-up range, each with
/// its line number.
List<String> strangers(String text) {
  final out = <String>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    for (final m in _private.allMatches(lines[i])) {
      // 192.168.001.005 is 192.168.1.5: a range is its numbers, not how they are written.
      final range = m.group(1)!.split('.').map((part) => int.parse(part)).join('.');
      if (!_madeUp.contains(range)) out.add('${i + 1}: ${m.group(0)}');
    }
  }
  return out;
}

/// Reads every text file of the repository at [base] (see [repositoryText]
/// for which those are). Returns what was read (paths from [base], with
/// forward slashes) and every stranger found, as `path:line: address`.
({Set<String> read, List<String> found}) scan(Directory base) {
  final read = <String>{};
  final found = <String>[];
  for (final file in repositoryText(base)) {
    read.add(file.path);
    for (final s in strangers(file.text)) {
      found.add('${file.path}:$s');
    }
  }
  return (read: read, found: found);
}

// Built from its parts, so that this file holds no such address itself.
String _at(List<Object> parts) => parts.join('.');

void main() {
  test('a private address anywhere in the repository lies in a made-up range', () {
    final result = scan(Directory('.'));
    expect(
        result.read,
        containsAll([
          'lib/main.dart',
          'lib/l10n/app_en.arb',
          'test/docs/demo_addresses_test.dart',
          'test/visual/shell_shots_test.dart',
          if (File('docs/CHANGELOG-3.0.md').existsSync()) 'docs/CHANGELOG-3.0.md',
          'packages/zest_ssh_core/README.md',
          'installer/zestssh_setup.iss',
          'infra/status_worker/src/worker.js',
          'infra/status_worker/test/worker.test.mjs',
          'infra/status_worker/wrangler.toml',
          'pubspec.yaml',
        ]),
        reason: 'the app, its strings, its tests, its documents, its packages, what runs beside it and the files '
            'at the top are read');
    expect(result.read.where((p) => p.contains('/generated/') || p.contains('node_modules')), isEmpty);
    expect(result.found, isEmpty,
        reason: 'an address of a private network that is not one of the made-up ranges '
            '(see the top of test/docs/demo_addresses_test.dart for what to use):\n  ${result.found.join('\n  ')}');
  });

  test('what counts: any private address outside the made-up ranges, however it is written', () {
    final outside10 = _at([10, 233, 7, 4]);
    final outside172 = _at([172, 20, 3, 9]);
    final outside192 = _at([192, 168, 77, 1]);
    expect(strangers('ssh deploy@$outside10 -p 22'), ['1: $outside10']);
    expect(strangers('first\nhost: "$outside172",\nlast'), ['2: $outside172']);
    expect(strangers('a ${_at([192, 168, 10, 21])} b $outside192:2222 c'), ['1: $outside192']);
    expect(strangers('$outside10 and $outside192'), ['1: $outside10', '1: $outside192'], reason: 'each one on a line');
    expect(strangers('${_at([10, 50, 0, 7])} ${_at([192, 168, 20, 11])} ${_at([10, 0, 0, 5])}'), isEmpty,
        reason: 'made-up ranges');
    // Each end of the private ranges is one of them.
    for (final edge in [
      [172, 16, 9, 1],
      [172, 31, 9, 1],
      [10, 0, 9, 1],
      [10, 255, 9, 1],
      [192, 168, 255, 1],
    ]) {
      expect(strangers(_at(edge)), ['1: ${_at(edge)}']);
    }
    // Written with leading zeros it is the same range.
    expect(strangers('192.168.001.005'), isEmpty);
    final padded = _at(['010', '233', '007', '004']);
    expect(strangers(padded), ['1: $padded']);
    final padded172 = _at(['172', '020', '003', '009']);
    expect(strangers(padded172), ['1: $padded172']);
    // Public and documentation addresses, version numbers and longer numbers are none of its business.
    expect(strangers('203.0.113.10 192.0.2.44 8.8.8.8 172.15.0.1 172.32.0.1 192.169.1.1 11.0.0.1'), isEmpty);
    expect(strangers('Windows 10.0.26200 build, version 1.10.2.3.4, 110.1.2.3, 10.1.2.3456'), isEmpty);
  });

  test('the whole repository is looked through: a stranger is found wherever its text lives', () {
    final base = Directory.systemTemp.createTempSync('zest-addresses-');
    addTearDown(() => base.deleteSync(recursive: true));
    final outside = _at([10, 233, 7, 4]);
    void write(String path, String text) {
      File('${base.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }

    write('lib/a/b/deep.dart', '// e.g. ssh root@$outside\n');
    write('test/x_test.dart', "const host = '$outside';\n");
    write('docs/notes.md', 'one\ntwo $outside\n');
    write('tool/t.dart', 'ok ${_at([10, 50, 0, 9])}\n');
    write('packages/core/README.md', 'see $outside\n');
    write('installer/setup.iss', '; $outside\n');
    write('infra/status/src/worker.js', '// $outside\n');
    write('infra/status/test/worker.test.mjs', "const origin = '$outside';\n");
    write('README.md', 'top $outside\n');
    write('lib/l10n/app_en.arb', '{"hint": "$outside"}\n');
    // Not the repository's own text.
    write('lib/l10n/generated/app_localizations.dart', "// '$outside'\n");
    write('docs/whitepaper/node_modules/pkg/readme.md', '$outside\n');
    write('packages/core/build/out.txt', '$outside\n');
    write('packages/core/.dart_tool/package_config.json', '{"x": "$outside"}\n');
    write('elsewhere/notes.md', '$outside\n');
    write('lib/picture.png', '$outside\n');

    final result = scan(base);
    expect(result.found.toSet(), {
      'lib/a/b/deep.dart:1: $outside',
      'test/x_test.dart:1: $outside',
      'docs/notes.md:2: $outside',
      'packages/core/README.md:1: $outside',
      'installer/setup.iss:1: $outside',
      'infra/status/src/worker.js:1: $outside',
      'infra/status/test/worker.test.mjs:1: $outside',
      'README.md:1: $outside',
      'lib/l10n/app_en.arb:1: $outside',
    });
    expect(result.read, contains('tool/t.dart'));
    expect(result.read, isNot(contains('lib/picture.png')));
  });
}
