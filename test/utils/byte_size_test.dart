import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/utils/byte_size.dart';

/// Sizes are written as the app's language writes them: its decimal mark
/// and its units (3.0). Every screen wrote "1.5 MB" its
/// own way, in English.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  const kb = 1024;
  const mb = 1024 * kb;
  const gb = 1024 * mb;
  const tb = 1024 * gb;

  test('in English, from bytes to terabytes', () {
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(512), '512 B');
    expect(formatByteSize(1023), '1,023 B');
    expect(formatByteSize(kb), '1.0 KB');
    expect(formatByteSize(1536), '1.5 KB');
    expect(formatByteSize(10 * mb), '10.0 MB');
    expect(formatByteSize(3 * gb ~/ 2), '1.5 GB');
    expect(formatByteSize(2 * tb), '2.0 TB');
    expect(formatByteSize(2048 * tb), '2,048.0 TB');
  });

  test('how many decimals', () {
    expect(formatByteSize(5 * gb ~/ 4, digits: SizeDigits.oneThenTwo), '1.25 GB');
    expect(formatByteSize(5 * tb ~/ 4, digits: SizeDigits.oneThenTwo), '1.25 TB');
    expect(formatByteSize(10 * mb, digits: SizeDigits.oneThenTwo), '10.0 MB');
    expect(formatByteSize(1536, digits: SizeDigits.oneThenTwo), '1.5 KB');
    expect(formatByteSize(15 * kb, digits: SizeDigits.belowTen), '15 KB');
    expect(formatByteSize(10 * kb, digits: SizeDigits.belowTen), '10 KB');
    expect(formatByteSize(1536, digits: SizeDigits.belowTen), '1.5 KB');
    expect(formatByteSize(234 * gb, digits: SizeDigits.belowHundred), '234 GB');
    expect(formatByteSize(100 * gb, digits: SizeDigits.belowHundred), '100 GB');
    expect(formatByteSize(47 * gb ~/ 2, digits: SizeDigits.belowHundred), '23.5 GB');
    expect(formatByteSize(512, digits: SizeDigits.belowHundred), '512 B');
  });

  test('in each language its own way', () {
    String say(String code, int bytes) => formatByteSize(bytes, l10n: lookupAppLocalizations(Locale(code)));
    expect(say('de', 1536), '1,5 KB');
    expect(say('fr', 512), '512 o');
    expect(say('fr', 1536), '1,5 Ko');
    expect(say('fr', 3 * gb ~/ 2), '1,5 Go');
    expect(say('ru', 1536), '1,5 КБ');
    expect(say('ru', 2 * tb), '2,0 ТБ');
    expect(say('ja', 1536), '1.5 KB');
    // The app's own language when none is given.
    L10nGlobal.update(lookupAppLocalizations(const Locale('fr')));
    expect(formatByteSize(10 * mb), '10,0 Mo');
  });

  test('a rate is so many a second', () {
    expect(formatByteRate(2.3 * mb), '2.3 MB/s');
    expect(formatByteRate(100), '100 B/s');
    expect(formatByteRate(15 * kb, digits: SizeDigits.belowTen), '15 KB/s');
    expect(formatByteRate(2.3 * mb, l10n: lookupAppLocalizations(const Locale('ru'))), '2,3 МБ/с');
  });

  test('every language has every unit, with the size in it', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      for (final say in [t.sizeBytes, t.sizeKilobytes, t.sizeMegabytes, t.sizeGigabytes, t.sizeTerabytes, t.sizePerSecond]) {
        expect(say('7'), contains('7'), reason: '$locale');
      }
    }
  });

  test('a listed file says its size this way; a folder none, a link a dash', () {
    expect(const SftpEntry(name: 'a.bin', path: '/a.bin', isDirectory: false, size: 1536).formattedSize, '1.5 KB');
    expect(const SftpEntry(name: 'd', path: '/d', isDirectory: true, size: 4096).formattedSize, '');
    expect(const SftpEntry(name: 'l', path: '/l', isDirectory: false, size: 0, isSymlink: true).formattedSize, '-');
  });

  test('no screen writes a size unit by hand any more', () {
    final unit = RegExp(r'''\}\s?(?:B|KB|MB|GB|TB)(?:/s)?['"]|'B',\s*'KB'|' KB'|' MB'|' GB'|' TB'|' KiB'|' MiB' ''');
    // Where a unit stays as it is written, and why.
    const allowed = {
      // The server table's columns are a few characters wide: "1.2M", as
      // top writes it.
      'monitor_table_view.dart',
      // A line of the log, which is English.
      'main.dart',
    };
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.contains('${Platform.pathSeparator}generated${Platform.pathSeparator}')) continue;
      if (allowed.contains(f.uri.pathSegments.last)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (unit.hasMatch(line)) found.add('${f.path}:${i + 1}: ${line.trim()}');
      }
    }
    expect(found, isEmpty);
  });
}
