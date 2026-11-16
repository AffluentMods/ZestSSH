import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_notices.dart' show parseNotices, separator;

/// The licence files the app adds to its licences page beside the packages' own (pubspec
/// `flutter: licenses:`): the bundled fonts' licences, the notices kept in copied code
/// (zest_ssh_core's bcrypt), the credits and trademark note; and the native libraries' licences per
/// platform (assets/licenses, tool/native_notices.dart). Flutter splits each by lines of 80 hyphens
/// (LF only), each section its names, a blank line, then the text.
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');

  List<({List<String> names, String text})> sectionsOf(String path) {
    final text = File(path).readAsStringSync();
    expect(text.contains('\r'), isFalse, reason: '$path: .gitattributes keeps it LF, or Flutter reads it as one block');
    expect(RegExp('[\u2013\u2014]').hasMatch(text), isFalse, reason: '$path: no long dashes in this repository');
    final sections = parseNotices(text);
    expect(sections.length, text.split(separator).length, reason: '$path: every section has its names and a text');
    for (final s in sections) {
      expect(s.names, isNotEmpty);
      expect(s.text, isNotEmpty, reason: '$path: ${s.names}');
    }
    return sections;
  }

  test('the pubspec adds the fonts, the copied code and the credits to the licences, and bundles the native ones', () {
    for (final path in [
      'third_party/zestssh/NOTICES.txt',
      'third_party/symbols-nerd-font/NOTICES.txt',
      'third_party/fonts/NOTICES.txt',
      'third_party/bcrypt/NOTICES.txt',
      'third_party/wayland-protocols/NOTICES.txt',
      'third_party/credits/NOTICES.txt',
    ]) {
      expect(pubspec, contains('\n    - $path\n'), reason: path);
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(pubspec, contains('\n    - assets/licenses/\n'));
    final attributes = File('.gitattributes').readAsStringSync();
    for (final rule in [
      'third_party/zestssh/NOTICES.txt text eol=lf',
      'third_party/fonts/NOTICES.txt text eol=lf',
      'third_party/bcrypt/NOTICES.txt text eol=lf',
      'third_party/wayland-protocols/NOTICES.txt text eol=lf',
      'third_party/credits/NOTICES.txt text eol=lf',
      'assets/licenses/*.txt text eol=lf',
    ]) {
      expect(attributes, contains(rule));
    }
  });

  test('every font file the app bundles has its family\'s licence, as published upstream', () {
    final sections = sectionsOf('third_party/fonts/NOTICES.txt');
    final byName = {for (final s in sections) s.names.single: s.text};
    // The family of each bundled file, by the start of its name.
    const families = {
      'CascadiaCode-': 'Cascadia Code',
      'FiraCode-': 'Fira Code',
      'GeistSans-': 'Geist',
      'Hack-': 'Hack',
      'JetBrainsMono-': 'JetBrains Mono',
      'SourceCodePro-': 'Source Code Pro',
      'SymbolsNerdFontMono-': null, // third_party/symbols-nerd-font
    };
    final files = Directory('assets/fonts').listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final prefix = families.keys.where(file.startsWith).singleOrNull;
      expect(prefix, isNotNull, reason: '$file: a font with no licence in third_party/');
      final family = families[prefix];
      if (family == null) continue;
      expect(byName[family], contains('assets/fonts/'), reason: family);
      // The section names each file of its family.
      final stem = file.substring(0, file.lastIndexOf('.'));
      final named =
          byName[family]!.contains(file) ||
          byName[family]!.contains('-${stem.split('-').last}') ||
          byName[family]!.contains(stem);
      expect(named, isTrue, reason: '$file is not named in the $family section');
    }
    expect(byName.keys, unorderedEquals(families.values.whereType<String>()));
    for (final family in ['Cascadia Code', 'Fira Code', 'Geist', 'JetBrains Mono', 'Source Code Pro']) {
      expect(byName[family], contains('SIL OPEN FONT LICENSE Version 1.1'), reason: family);
      expect(
        byName[family],
        matches(RegExp(r'Licence text:\s+https://raw\.githubusercontent\.com/')),
        reason: '$family: where the text came from',
      );
    }
    expect(byName['Cascadia Code'], contains('Reserved Font Name Cascadia Code'));
    expect(byName['Cascadia Code'], contains('byte for byte'), reason: 'the file is the release\'s own');
    expect(byName['Source Code Pro'], contains("Reserved Font Name 'Source'"));
    expect(byName['Geist'], contains('Copyright 2024 The Geist Project Authors'));
    expect(byName['JetBrains Mono'], contains('Copyright 2020 The JetBrains Mono Project Authors'));
    expect(byName['Fira Code'], contains('The Fira Code Project Authors'));
    // Hack: MIT for its own work, the Bitstream Vera licence for what it is built on.
    expect(byName['Hack'], contains('Copyright (c) 2018 Source Foundry Authors'));
    expect(byName['Hack'], contains('BITSTREAM VERA LICENSE'));
    expect(byName['Hack'], contains('Permission is hereby granted, free of charge'));
  });

  test('the Wayland protocol code in the Linux runner goes with its notice, as each generated file carries it', () {
    final section = sectionsOf('third_party/wayland-protocols/NOTICES.txt').single;
    expect(section.names, ['wayland-protocols']);
    expect(section.text, contains('linux/runner/wayland/'));
    final files = Directory('linux/runner/wayland')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.c') || f.path.endsWith('.h'))
        .toList();
    expect(files, hasLength(4), reason: 'the client header and the code of two protocols');
    for (final file in files) {
      final code = file.readAsStringSync().replaceAll('\r', '');
      // The notice's own lines, as the file has them behind its comment marks.
      final lines = [
        for (final line in code.split('\n'))
          if (line.startsWith(' * Copyright') || line.contains('Permission is hereby granted'))
            line.substring(3).trim(),
      ];
      expect(lines, isNotEmpty, reason: file.path);
      for (final line in lines) {
        expect(section.text, contains(line), reason: '${file.path}: $line');
      }
    }
  });

  test('the notices kept in zest_ssh_core\'s bcrypt go with the binary, under the package\'s name', () {
    final sections = sectionsOf('third_party/bcrypt/NOTICES.txt');
    expect(sections.map((s) => s.names.single).toSet(), {'zest_ssh_core'});
    final all = sections.map((s) => s.text).join('\n');
    expect(all, contains('Copyright 1997 Niels Provos'));
    expect(all, contains('Redistributions in binary form must reproduce the above'));
    expect(all, contains('Copyright (c) 2013 Ted Unangst'));
    expect(all, contains('Copyright 2016, Joyent Inc'));
    expect(all, contains('Devi Mandiri'));
    // Each is the file's own text: the source still carries them.
    final source = File('packages/zest_ssh_core/lib/src/utils/bcrypt.dart').readAsStringSync();
    for (final words in ['Niels Provos', 'Ted Unangst', 'Joyent Inc']) {
      expect(source, contains(words));
    }
  });

  test('the credits name the redrawn logos as their owners\' marks and the colour schemes with their sources', () {
    final sections = sectionsOf('third_party/credits/NOTICES.txt');
    expect(sections.single.names, ['ZestSSH credits and trademarks']);
    final text = sections.single.text;
    expect(text, contains('trademarks or registered trademarks of their owners'));
    expect(text, contains('lib/core/data/os_logos.dart'));
    for (final scheme in [
      'Catppuccin',
      'Dracula',
      'Gruvbox',
      'Nord',
      'Solarized',
      'Tokyo Night',
      'One Dark',
      'Monokai',
    ]) {
      expect(text, contains(scheme));
    }
    // Every logo the app draws is named.
    final logos = File('lib/core/data/os_logos.dart').readAsStringSync();
    final drawn = RegExp(r'// ── ([^-─]+?) [-─]').allMatches(logos).map((m) => m.group(1)!.trim()).toList();
    expect(drawn.length, greaterThan(15));
    for (final name in drawn) {
      final first = name.split(RegExp(r'[ /]')).first;
      if (first == 'Generic' || first == 'Container' || first == 'Apple' || first == 'ESXi') continue;
      expect(text, contains(first), reason: '$name is drawn but not named in the credits');
    }
  });

  test('the native libraries of Windows and Linux are listed, and no platform file is empty', () {
    final windows = sectionsOf('assets/licenses/windows.txt');
    final names = {for (final s in windows) ...s.names};
    expect(names, containsAll(['PDFium', 'Firebase C++ SDK', 'Windows Implementation Libraries (WIL)', 'C++/WinRT']));
    final pdfium = windows.where((s) => s.names.contains('PDFium')).map((s) => s.text).join('\n');
    for (final library in [
      'PDFium license',
      'FreeType',
      'libjpeg-turbo',
      'ICU',
      'zlib',
      'libpng',
      'lcms',
      'openjpeg',
    ]) {
      expect(pdfium, contains(library), reason: 'PDFium carries $library');
    }
    final linux = sectionsOf('assets/licenses/linux.txt');
    expect({for (final s in linux) ...s.names}, {'PDFium'});
    for (final f in Directory('assets/licenses').listSync().whereType<File>()) {
      expect(f.lengthSync(), greaterThan(1000), reason: f.path);
    }
  });
}
