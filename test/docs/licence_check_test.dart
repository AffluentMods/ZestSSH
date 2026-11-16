import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/licence_check.dart';

/// tool/licence_check.dart: every Dart package and Rust crate the app is built from is under a
/// licence tool/licence_policy.yaml allows, and one that is not (or cannot be told) fails it.
void main() {
  final policy = readPolicy();

  const mit =
      'MIT License\n\nCopyright (c) 2020 Someone\n\nPermission is hereby granted, free of charge, to any '
      'person obtaining a copy\nof this software and associated documentation files (the "Software")';
  const bsd3 =
      'Copyright 2013 Someone. All rights reserved.\n\nRedistribution and use in source and binary forms, '
      'with or without\nmodification, are permitted provided that ...\n  * Neither the name of Someone nor the '
      'names of its\ncontributors may be used to endorse or promote products';
  const gpl3 =
      '                    GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007\n\n'
      ' Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>';

  test('the policy allows the permissive licences and no GPL family', () {
    expect(
      policy.allowed,
      containsAll(['MIT', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'ISC', 'Zlib', 'MPL-2.0']),
    );
    for (final copyleft in [
      'GPL',
      'LGPL',
      'AGPL',
      'GPL-3.0-only',
      'GPL-2.0-only',
      'LGPL-2.1-or-later',
      'OpenSSL',
      'SSPL-1.0',
    ]) {
      expect(policy.allowed, isNot(contains(copyleft)));
    }
  });

  test('a licence file is known by its words', () {
    expect(classify(mit), {'MIT'});
    expect(classify(bsd3), {'BSD-3-Clause'});
    expect(classify('Redistribution and use in source and binary forms, with or without modification'), {
      'BSD-2-Clause',
    });
    expect(classify('Apache License\n                           Version 2.0, January 2004'), {'Apache-2.0'});
    expect(
      classify(
        'Permission to use, copy, modify, and/or distribute this software for any purpose with or '
        'without fee is hereby granted',
      ),
      {'ISC'},
    );
    expect(
      classify(
        'Mozilla Public License Version 2.0\n==================\n'
        '"Secondary License" means either the GNU General Public License, Version 2.0',
      ),
      {'MPL-2.0'},
      reason: "MPL-2.0 names the GPL as a secondary licence; that is not the GPL's own text",
    );
    expect(classify(gpl3), {'GPL'});
    expect(classify('GNU LESSER GENERAL PUBLIC LICENSE Version 2.1'), containsAll(['LGPL']));
    expect(classify('GNU AFFERO GENERAL PUBLIC LICENSE'), contains('AGPL'));
    expect(classify('$mit\n\n$bsd3'), {'MIT', 'BSD-3-Clause'}, reason: 'a file with two licences gives both');
    expect(classify('All rights reserved. You may not copy this.'), isEmpty);
  });

  test('a licence expression needs one allowed side of an OR, and each side of an AND', () {
    final allowed = {'MIT', 'Apache-2.0', 'ISC', 'Unicode-3.0'};
    expect(expressionAllowed('MIT', allowed), isTrue);
    expect(expressionAllowed('MIT OR Apache-2.0', allowed), isTrue);
    expect(expressionAllowed('MIT/Apache-2.0', allowed), isTrue, reason: 'the old way of writing OR');
    expect(expressionAllowed('GPL-3.0-only OR MIT', allowed), isTrue);
    expect(expressionAllowed('GPL-3.0-only', allowed), isFalse);
    expect(expressionAllowed('Apache-2.0 AND ISC', allowed), isTrue);
    expect(expressionAllowed('MIT AND GPL-2.0-only', allowed), isFalse);
    expect(expressionAllowed('(MIT OR Apache-2.0) AND Unicode-3.0', allowed), isTrue);
    expect(expressionAllowed('(MIT OR Apache-2.0) AND OpenSSL', allowed), isFalse);
    expect(expressionAllowed('Apache-2.0 WITH LLVM-exception OR MIT', allowed), isTrue);
    expect(() => expressionAllowed('(MIT OR', allowed), throwsFormatException);
  });

  group('a made-up package', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('licence_check_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('under the GPL fails, by name', () {
      File('${dir.path}/LICENSE').writeAsStringSync(gpl3);
      final v = dartVerdict('copyleft_pkg', dir, policy);
      expect(v.problem, 'not allowed: GPL');
    });

    test('with MIT passes, and with MIT beside the GPL fails', () {
      File('${dir.path}/LICENSE').writeAsStringSync(mit);
      expect(dartVerdict('fine_pkg', dir, policy).problem, isNull);
      File('${dir.path}/COPYING').writeAsStringSync(gpl3);
      expect(dartVerdict('fine_pkg', dir, policy).problem, 'not allowed: GPL');
    });

    test('with a licence nobody can tell, or none, fails', () {
      expect(dartVerdict('bare_pkg', dir, policy).problem, startsWith('no licence file'));
      File('${dir.path}/LICENSE.md').writeAsStringSync('Proprietary. All rights reserved.');
      expect(dartVerdict('odd_pkg', dir, policy).problem, startsWith('licence not recognised'));
    });

    test('a Rust crate whose Cargo.toml says GPL fails', () {
      final made = (allowed: policy.allowed, dart: <String, String>{}, rust: {'copyleft-crate': 'GPL-3.0-or-later'});
      expect(rustVerdict('copyleft-crate', '1.0.0', made).problem, 'not allowed: GPL-3.0-or-later');
      final fine = (allowed: policy.allowed, dart: <String, String>{}, rust: {'fine-crate': 'MIT OR Apache-2.0'});
      expect(rustVerdict('fine-crate', '1.0.0', fine).problem, isNull);
    });
  });

  test('the app\'s own pubspec dependencies are followed, its dev dependencies are not', () {
    final folders = packageFolders();
    final shipped = shippedDartPackages(folders);
    expect(shipped, containsAll(['flutter', 'zest_ssh_core', 'xterm', 'drift', 'sqlcipher_flutter_libs']));
    for (final dev in pubspecDevOnly()) {
      expect(shipped, isNot(contains(dev)), reason: '$dev is a dev dependency only');
    }
  });

  test('every Dart package and Rust crate of the app is under an allowed licence', () {
    final folders = packageFolders();
    final dart = [for (final p in shippedDartPackages(folders)) dartVerdict(p, folders[p]!, policy)];
    expect(dart.length, greaterThan(150));
    expect([
      for (final v in dart)
        if (v.problem != null) '${v.name}: ${v.problem}',
    ], isEmpty);
    final crates = lockedCrates();
    expect(crates.length, greaterThan(200));
    final rust = [for (final (n, v) in crates) rustVerdict(n, v, policy)];
    expect([
      for (final v in rust)
        if (v.problem != null) '${v.name}: ${v.problem}',
    ], isEmpty);
  });
}

/// The dev dependencies of the app's pubspec that are nowhere among its own dependencies' trees
/// by the pubspec alone: the ones the check must leave out.
List<String> pubspecDevOnly() {
  final lines = File('pubspec.yaml').readAsLinesSync();
  final out = <String>[];
  var inside = false;
  for (final raw in lines) {
    if (raw.trim().isEmpty || raw.trimLeft().startsWith('#')) continue;
    final indent = raw.length - raw.trimLeft().length;
    if (indent == 0) {
      inside = raw.startsWith('dev_dependencies:');
      continue;
    }
    final m = RegExp(r'^\s{2}(\w+):').firstMatch(raw);
    if (inside && indent == 2 && m != null) out.add(m.group(1)!);
  }
  return out
      .where((p) => const {'build_runner', 'drift_dev', 'flutter_lints', 'msix', 'flutter_launcher_icons'}.contains(p))
      .toList();
}
