import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/repository_text.dart';

// The first word of the company's name, put together here so that this file
// does not hold it standing alone either.
final _word = ['aff', 'luent'].join();

/// The company's name stands for the company only.
///
/// With its second word it says who makes the app, and it is written
/// wherever that is said: a copyright line, a package identifier, a
/// publisher, the address of a repository. Standing alone, the same word
/// reads as the name of a person, an account or a user on a host, and that
/// is how it once stood in fixtures and comments: a user name, the name of a
/// key, an account's Tree, a member of staff. Tests, comments, strings and
/// documents are where examples get copied from (into the docs, the
/// website, a screenshot), and their people are made up.
///
/// For a new example use the people the fixtures have: Alex (an account, a
/// key, a user name), Robin and Morgan (support staff), `deploy` (a user on
/// a host of the demo fleet).
final _alone = RegExp('$_word(?!\\s*labs|mods)', caseSensitive: false);

/// Where the company's name stands alone in [text]: each place with its line
/// number and what stands there.
List<String> alone(String text) => [
      for (final m in _alone.allMatches(text))
        '${'\n'.allMatches(text.substring(0, m.start)).length + 1}: '
            '${text.substring(m.start, m.end + 12 > text.length ? text.length : m.end + 12).split('\n').first}',
    ];

/// Reads every text file of the repository at [base] (see [repositoryText]
/// for which those are). Returns what was read and every place where the
/// name stands alone, as `path:line: what stands there`.
({Set<String> read, List<String> found}) scan(Directory base) {
  final read = <String>{};
  final found = <String>[];
  for (final file in repositoryText(base)) {
    read.add(file.path);
    for (final s in alone(file.text)) {
      found.add('${file.path}:$s');
    }
  }
  return (read: read, found: found);
}

void main() {
  final name = '${_word[0].toUpperCase()}${_word.substring(1)}';

  test('wherever the company is named in the repository, it is named in full', () {
    final result = scan(Directory('.'));
    expect(result.read,
        containsAll(['lib/main.dart', 'test/docs/demo_names_test.dart', 'installer/eula.txt', 'pubspec.yaml', 'README.md']));
    expect(result.found, isEmpty,
        reason: 'the first word of the company\'s name standing alone, as a person, an account or a user would '
            '(see the top of test/docs/demo_names_test.dart for whom to use):\n  ${result.found.join('\n  ')}');
  });

  test('what counts: the word alone, however it is written; not the company in any of its forms', () {
    expect(alone('const username = \'$_word\';'), ['1: $_word\';']);
    expect(alone('first\n  /// A key / identity display name ("$name").\nlast'), ['2: $name").']);
    expect(alone('Redactable.account("$name\'s Tree")'), ['1: $name\'s Tree")']);
    expect(alone('ssh $_word@web-01'), ['1: $_word@web-01']);
    expect(alone('${name.toUpperCase()} DESKTOP'), ['1: ${name.toUpperCase()} DESKTOP']);
    expect(alone('one $name and\nanother $_word'), ['1: $name and', '2: $_word']);
    // The company, as it is written where it is named.
    expect(alone('(c) 2026 $name Labs LLC. All rights reserved.'), isEmpty);
    expect(alone('packageName: \'com.${_word}labs.zestssh\''), isEmpty);
    expect(alone('publisher: CN=$name Labs'), isEmpty);
    expect(alone('${name}Labs.ZestSSH and github.com/${name}Mods/zest_ssh_core'), isEmpty);
    // A line of a legal text that ends between the two words.
    expect(alone('PERMITTED BY LAW, ${name.toUpperCase()}\nLABS LLC SHALL NOT BE LIABLE'), isEmpty);
    // Another word that begins the same way is another word, and is found: nothing here is named so.
    expect(alone('${_word}ial'), ['1: ${_word}ial']);
  });

  test('the whole repository is looked through: the word alone is found wherever its text lives', () {
    final base = Directory.systemTemp.createTempSync('zest-names-');
    addTearDown(() => base.deleteSync(recursive: true));
    void write(String path, String text) {
      File('${base.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }

    write('lib/a/b/deep.dart', '// signs in as $_word\n');
    write('test/x_test.dart', "const keyName = '$name Desktop';\n");
    write('docs/notes.md', 'one\ntwo $name\n');
    write('installer/setup.iss', '#define MyAppPublisher "$name Labs"\n');
    write('README.md', 'by $name Labs LLC\nand $name\n');
    // Not the repository's own text.
    write('lib/l10n/generated/app_localizations.dart', "// '$name'\n");
    write('elsewhere/notes.md', '$name\n');

    final result = scan(base);
    expect(result.found.toSet(), {
      'lib/a/b/deep.dart:1: $_word',
      "test/x_test.dart:1: $name Desktop';",
      'docs/notes.md:2: $name',
      'README.md:2: $name',
    });
    expect(result.read, containsAll(['installer/setup.iss', 'README.md']));
  });
}
