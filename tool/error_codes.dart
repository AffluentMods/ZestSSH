// Writes docs/ERROR-CODES.md, the page of every error the app names by code,
// from the one place a code is given its meaning
// (lib/core/errors/error_codes.dart). The help assistant's corpus is fed
// from the page, so it is never written by hand.
//
//   dart tool/error_codes.dart           writes the page
//   dart tool/error_codes.dart --check   changes nothing; fails when the page is not current
//
// test/docs/error_codes_test.dart holds the page to the list, and the list
// to its own rules (see [errorCodeProblems]).
import 'dart:io';

import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';

const errorCodesPath = 'docs/ERROR-CODES.md';

// The two dashes no text of ours holds, named by their numbers so that this
// file holds neither.
final _emDash = String.fromCharCode(0x2014);
final _enDash = String.fromCharCode(0x2013);

/// What a code looks like, wherever one is written.
final errorCodePattern = RegExp(r'ZS-[0-9]{4}');

/// The page, from [codes].
String errorCodesPage(List<ErrorCode> codes) {
  final out = StringBuffer()
    ..writeln('# ZestSSH error codes')
    ..writeln()
    ..writeln('<!-- Written by tool/error_codes.dart from lib/core/errors/error_codes.dart. Not edited by hand. -->')
    ..writeln()
    ..writeln('Some messages in ZestSSH end in a code in parentheses, like (ZS-1101). The code is the same in every')
    ..writeln('language the app speaks. This page says for each code what is going on, what still works, and what to')
    ..writeln('do. A message with much behind it (a connection that failed, a file that could not be read) has a')
    ..writeln('"Copy details" button instead of, or beside, its code: what it copies names the code as well, with')
    ..writeln('the names of hosts, people and folders, addresses, keys and passwords taken out.')
    ..writeln();
  for (final c in codes) {
    out
      ..writeln('## ${c.code}: ${c.title}')
      ..writeln()
      ..writeln('**What it means.** ${c.means}')
      ..writeln()
      ..writeln('**What to do.**')
      ..writeln();
    for (var i = 0; i < c.fix.length; i++) {
      out.writeln('${i + 1}. ${c.fix[i]}');
    }
    out.writeln();
    final support = c.support;
    if (support != null) {
      out
        ..writeln('**For whoever is helping.** $support')
        ..writeln();
    }
    out
      ..writeln(c.retired
          ? '*Since ZestSSH ${c.since}. No longer shown by current versions.*'
          : '*Since ZestSSH ${c.since}.*')
      ..writeln();
  }
  return '${out.toString().trimRight()}\n';
}

/// What is wrong with [codes] as a list, one line each: a code that is not
/// "ZS-" and four digits, one used twice, the list out of order, a text
/// that is empty or holds a dash that is not a hyphen, a step that does not
/// end as a sentence, a text that names a code the list does not hold.
List<String> errorCodeProblems(List<ErrorCode> codes) {
  final problems = <String>[];
  final seen = <String>{};
  final held = {for (final c in codes) c.code};
  String? before;
  final whole = RegExp(r'^ZS-[0-9]{4}$');
  for (final c in codes) {
    if (!whole.hasMatch(c.code)) problems.add('${c.code} is not "ZS-" and four digits');
    if (!seen.add(c.code)) problems.add('${c.code} is used twice');
    if (before != null && c.code.compareTo(before) <= 0) problems.add('${c.code} comes after $before: the list is in order');
    before = c.code;
    final texts = {'title': c.title, 'means': c.means, 'support': c.support ?? 'x.', 'since': c.since};
    for (var i = 0; i < c.fix.length; i++) {
      texts['step ${i + 1}'] = c.fix[i];
    }
    if (c.fix.isEmpty) problems.add('${c.code} says nothing of what to do');
    texts.forEach((name, text) {
      if (text.trim().isEmpty) problems.add('${c.code}: its $name is empty');
      if (text != text.trim()) problems.add('${c.code}: its $name has space around it');
      if (text.contains(_emDash) || text.contains(_enDash)) problems.add('${c.code}: its $name has a dash that is not a hyphen');
      if (text.contains('\n')) problems.add('${c.code}: its $name runs over lines');
      for (final named in errorCodesIn(text)) {
        if (!held.contains(named)) problems.add('${c.code}: its $name names $named, which the list does not hold');
      }
    });
    for (final name in ['means', 'support']) {
      final text = texts[name]!;
      if (!RegExp(r'[.!?)]$').hasMatch(text)) problems.add('${c.code}: its $name does not end as a sentence');
    }
    for (var i = 0; i < c.fix.length; i++) {
      if (!RegExp(r'[.!?)]$').hasMatch(c.fix[i])) problems.add('${c.code}: step ${i + 1} does not end as a sentence');
    }
    if (RegExp(r'[.:]$').hasMatch(c.title)) problems.add('${c.code}: its title ends in a stop');
  }
  return problems;
}

/// The codes written in [text], in the order they first appear.
List<String> errorCodesIn(String text) {
  final found = <String>[];
  for (final m in errorCodePattern.allMatches(text)) {
    final code = m.group(0)!;
    if (!found.contains(code)) found.add(code);
  }
  return found;
}

void main(List<String> args) {
  // The page is the release's: its words name the release's addresses.
  debugZestOfficial = true;
  final problems = errorCodeProblems(ErrorCodes.all);
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    exitCode = 1;
    return;
  }
  final page = errorCodesPage(ErrorCodes.all);
  final file = File(errorCodesPath);
  if (args.contains('--check')) {
    final current = file.existsSync() ? file.readAsStringSync().replaceAll('\r\n', '\n') : null;
    if (current != page) {
      stderr.writeln('$errorCodesPath is not current: run dart tool/error_codes.dart');
      exitCode = 1;
    } else {
      stdout.writeln('${ErrorCodes.all.length} codes, the page is current');
    }
    return;
  }
  file.writeAsStringSync(page);
  stdout.writeln('${ErrorCodes.all.length} codes written to $errorCodesPath');
}
