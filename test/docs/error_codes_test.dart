import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/utils/error_report.dart';

import '../../tool/error_codes.dart';

/// The errors the app names by code (3.0): a simpler error gets a code
/// that can be given to Astryx, the help assistant, so it knows exactly
/// what each error or message means and what the fix
/// is.
///
/// A code is only worth anything if it can be looked up, by anybody, for as
/// long as a version that shows it is in use. So: one list gives every code
/// its meaning, the page people and the help assistant read is written from
/// that list and from nothing else, no code is shown that is not on it, and
/// none is on it that nothing shows.
void main() {
  group('the list', () {
    test('holds to its own rules: every code well formed, used once, in order, with what it means and what to do', () {
      expect(errorCodeProblems(ErrorCodes.all), isEmpty);
      expect(ErrorCodes.all, isNotEmpty);
    });

    test('a code is found by what it is written as, and anything else is none of ours', () {
      for (final code in ErrorCodes.all) {
        expect(ErrorCodes.find(code.code), same(code));
        expect('$code', code.code);
      }
      expect(ErrorCodes.find('ZS-0000'), isNull);
      expect(ErrorCodes.find('zs-1101'), isNull);
      expect(ErrorCodes.find(''), isNull);
    });

    test('every entry says what still works or what was not lost, since that is what is asked first', () {
      for (final code in ErrorCodes.all) {
        expect(code.means.length, greaterThan(80), reason: '${code.code} says too little of what is going on');
        expect(code.fix.first.length, greaterThan(15), reason: code.code);
      }
    });
  });

  group('the page', () {
    test('is the list, written out, and nothing else', () {
      final page = File(errorCodesPath).readAsStringSync().replaceAll('\r\n', '\n');
      expect(page, errorCodesPage(ErrorCodes.all), reason: 'run: dart tool/error_codes.dart');
    });

    test('names every code in a heading of its own, with what it means, what to do and since when', () {
      final page = errorCodesPage(ErrorCodes.all);
      for (final code in ErrorCodes.all) {
        expect(page, contains('## ${code.code}: ${code.title}\n'));
        expect(page, contains('**What it means.** ${code.means}\n'));
        for (var i = 0; i < code.fix.length; i++) {
          expect(page, contains('${i + 1}. ${code.fix[i]}\n'));
        }
        if (code.support != null) expect(page, contains('**For whoever is helping.** ${code.support}\n'));
      }
      // Its headings are the list, in the list's order. (An entry may name
      // another, later ones too: "not responding" says which three it can
      // turn out to be.)
      final headings = RegExp(r'^## (ZS-[0-9]{4}): ', multiLine: true).allMatches(page).map((m) => m.group(1)).toList();
      expect(headings, [for (final c in ErrorCodes.all) c.code], reason: 'in the order of the list');
      expect(errorCodesIn(page).toSet(), {for (final c in ErrorCodes.all) c.code},
          reason: 'every code of the list, and no code the list does not hold');
      expect(page, endsWith('*\n'));
      expect(page, isNot(contains('\n\n\n')));
    });

    test('a code that is no longer shown stays on the page, and says so', () {
      const gone = ErrorCode('ZS-1999', title: 'Gone', means: 'It was this.', fix: ['Nothing.'], since: '2.9', retired: true);
      final page = errorCodesPage(const [gone]);
      expect(page, contains('## ZS-1999: Gone'));
      expect(page, contains('*Since ZestSSH 2.9. No longer shown by current versions.*'));
    });
  });

  group('the app and the list agree', () {
    // Every text file of the app's own source: what it shows comes from here.
    Iterable<File> sources() sync* {
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path.replaceAll('\\', '/');
        if (path.contains('/l10n/generated/')) continue;
        if (path.endsWith('.dart') || path.endsWith('.arb')) yield entity;
      }
    }

    const catalogue = 'lib/core/errors/error_codes.dart';

    test('no code is written anywhere in the app that is not on the list', () {
      final unknown = <String>[];
      for (final file in sources()) {
        for (final code in errorCodesIn(file.readAsStringSync())) {
          if (ErrorCodes.find(code) == null) unknown.add('$code in ${file.path}');
        }
      }
      expect(unknown, isEmpty, reason: 'a code somebody may be shown and nobody can look up');
    });

    test('every code on the list is shown by something (or marked as no longer shown)', () {
      final used = <String>{};
      for (final file in sources()) {
        if (file.path.replaceAll('\\', '/').endsWith(catalogue)) continue;
        final text = file.readAsStringSync();
        for (final code in ErrorCodes.all) {
          // By its number, or by its name in the list.
          if (text.contains(code.code)) used.add(code.code);
        }
        for (final m in RegExp(r'ErrorCodes\.([A-Za-z0-9_]+)').allMatches(text)) {
          used.add(m.group(1)!);
        }
      }
      final list = File(catalogue).readAsStringSync();
      final unused = <String>[];
      for (final m in RegExp(r"static (?:const|final) ([A-Za-z0-9_]+) = ErrorCode\(\s*'(ZS-[0-9]{4})'").allMatches(list)) {
        final name = m.group(1)!, code = m.group(2)!;
        if (ErrorCodes.find(code)!.retired) continue;
        if (!used.contains(name) && !used.contains(code)) unused.add('$code ($name)');
      }
      expect(unused, isEmpty, reason: 'a code on the page that the app never shows');
      expect(RegExp(r'static (?:const|final) [A-Za-z0-9_]+ = ErrorCode\(').allMatches(list).length, ErrorCodes.all.length,
          reason: 'every entry of the file is in ErrorCodes.all');
    });
  });

  group('a message and its code', () {
    final code = ErrorCodes.cloudNotResponding;

    test('the code goes at the end, in parentheses, once', () {
      expect(ErrorCodes.withCode('It is not responding.', code), 'It is not responding. (ZS-1101)');
      expect(ErrorCodes.withCode('It is not responding.  \n', code), 'It is not responding. (ZS-1101)');
      expect(ErrorCodes.withCode('It is not responding. (ZS-1101)', code), 'It is not responding. (ZS-1101)');
      expect(ErrorCodes.withCode('It is offline. (ZS-1102)', code), 'It is offline. (ZS-1102) (ZS-1101)',
          reason: 'another code is part of the message');
    });

    test('a message is read for the code it names', () {
      expect(ErrorCodes.codeIn('It is not responding. (ZS-1101)'), same(code));
      expect(ErrorCodes.codeIn('ZS-1101'), same(code));
      expect(ErrorCodes.codeIn('It is not responding.'), isNull);
      expect(ErrorCodes.codeIn('Something else (ZS-0001), then (ZS-1102).'), same(ErrorCodes.deviceOffline),
          reason: 'what looks like a code and is none of ours is passed over');
    });

    test('a message is taken apart into its words and the code it ends in', () {
      expect(ErrorCodes.withoutCode('It is not responding. (ZS-1101)'), ('It is not responding.', code));
      expect(ErrorCodes.withoutCode('It is not responding. (ZS-1101)  '), ('It is not responding.', code));
      expect(ErrorCodes.withoutCode('It is not responding.'), ('It is not responding.', null));
      expect(ErrorCodes.withoutCode('(ZS-1101) comes first here.'), ('(ZS-1101) comes first here.', null),
          reason: 'only a code at the end is the message\'s code');
    });
  });

  group('the details somebody copies', () {
    test('name the code of the message again, with what it stands for in English', () {
      final report = ErrorReport.build(what: 'ZestSSH Cloud antwortet nicht. (ZS-1101)', logLines: 0);
      expect(report, contains('What: ZestSSH Cloud antwortet nicht. (ZS-1101)'));
      expect(report, contains('Code: ZS-1101 (ZestSSH Cloud is not responding)'),
          reason: 'whoever reads the report may not read the language of the message');
      expect(report.indexOf('Code:'), greaterThan(report.indexOf('What:')));
    });

    test('say nothing of a code where the message names none', () {
      expect(ErrorReport.build(what: 'The file could not be read.', logLines: 0), isNot(contains('Code:')));
    });
  });

  group('the check itself', () {
    ErrorCode entry(String code, {String title = 'A title', String means = 'It means this.', List<String> fix = const ['Do this.'], String? support}) =>
        ErrorCode(code, title: title, means: means, fix: fix, support: support);

    test('a code that is not "ZS-" and four digits, one used twice, a list out of order', () {
      expect(errorCodeProblems([entry('ZS-110')]), [contains('is not "ZS-" and four digits')]);
      expect(errorCodeProblems([entry('ZX-1101')]), [contains('is not "ZS-" and four digits')]);
      expect(errorCodeProblems([entry('ZS-1101'), entry('ZS-1101')]),
          containsAll([contains('ZS-1101 is used twice'), contains('the list is in order')]));
      expect(errorCodeProblems([entry('ZS-1102'), entry('ZS-1101')]), [contains('ZS-1101 comes after ZS-1102')]);
      expect(errorCodeProblems([entry('ZS-1101'), entry('ZS-1102'), entry('ZS-1201')]), isEmpty);
    });

    test('a text that is empty, runs over lines, has space around it or does not end as a sentence', () {
      expect(errorCodeProblems([entry('ZS-1101', title: ' ')]), contains(contains('its title is empty')));
      expect(errorCodeProblems([entry('ZS-1101', means: 'It means this')]), [contains('its means does not end as a sentence')]);
      expect(errorCodeProblems([entry('ZS-1101', means: 'It means\nthis.')]), [contains('runs over lines')]);
      expect(errorCodeProblems([entry('ZS-1101', means: 'It means this. ')]), contains(contains('has space around it')));
      expect(errorCodeProblems([entry('ZS-1101', fix: const [])]), [contains('says nothing of what to do')]);
      expect(errorCodeProblems([entry('ZS-1101', fix: const ['Do this'])]), [contains('step 1 does not end as a sentence')]);
      expect(errorCodeProblems([entry('ZS-1101', title: 'A title.')]), [contains('its title ends in a stop')]);
      expect(errorCodeProblems([entry('ZS-1101', support: 'Ask for the details')]),
          [contains('its support does not end as a sentence')]);
    });

    test('a dash that is not a hyphen, anywhere in an entry', () {
      for (final dash in [String.fromCharCode(0x2014), String.fromCharCode(0x2013)]) {
        expect(errorCodeProblems([entry('ZS-1101', means: 'It means this $dash or that.')]),
            [contains('has a dash that is not a hyphen')]);
        expect(errorCodeProblems([entry('ZS-1101', fix: ['Do this $dash now.'])]),
            [contains('has a dash that is not a hyphen')]);
      }
    });

    test('an entry that names a code the list does not hold', () {
      expect(errorCodeProblems([entry('ZS-1101', means: 'See ZS-1999 for more.')]),
          [contains('ZS-1101: its means names ZS-1999, which the list does not hold')]);
      expect(errorCodeProblems([entry('ZS-1101', fix: const ['Then look at ZS-1998.'])]),
          [contains('its step 1 names ZS-1998')]);
      // An entry may name another, whichever comes first in the list, and itself.
      expect(errorCodeProblems([entry('ZS-1101', fix: const ['Look at ZS-1102.']), entry('ZS-1102')]), isEmpty);
      expect(errorCodeProblems([entry('ZS-1101'), entry('ZS-1102', support: 'Often comes with ZS-1101.')]), isEmpty);
      expect(errorCodeProblems([entry('ZS-1101', support: 'It is ZS-1101 itself.')]), isEmpty);
    });

    test('codes are found where they are written, each once, in the order they come', () {
      expect(errorCodesIn('See ZS-1102, then ZS-1101 (and ZS-1102 again), not ZS-11 or XS-1101.'), ['ZS-1102', 'ZS-1101']);
      expect(errorCodesIn('none here'), isEmpty);
    });
  });
}
