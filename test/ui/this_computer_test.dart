// The computer the app runs on, in SFTP (found while
// comparing the five versions): its own files were "This PC" on a Mac and on
// Linux too, and Linux was told a delete goes to the Recycle Bin, where it
// goes to the Trash. Now each computer is named as its system names it.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/sftp/widgets/this_computer.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final (platform, name, bin) in [
    (TargetPlatform.windows, 'This PC', 'Recycle Bin'),
    (TargetPlatform.macOS, 'This Mac', 'Trash'),
    (TargetPlatform.linux, 'This computer', 'Trash'),
  ]) {
    test('on $platform its files are $name, and a delete goes to the $bin', () {
      debugDefaultTargetPlatformOverride = platform;
      expect((thisComputerName(l10n), thisComputerBinName(l10n)), (name, bin));
    });
  }

  test('every language has the two new names', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.sftpThisMac, isNotEmpty, reason: '$locale');
      expect(words.sftpThisComputer, isNotEmpty, reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(words.sftpThisComputer, isNot(l10n.sftpThisComputer), reason: '$locale: not translated');
      }
    }
  });

  test('the names and the bins are read through those two alone, wherever SFTP shows them', () {
    final readers = <String>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.contains('/l10n/generated/')) continue;
      final text = file.readAsStringSync();
      if (RegExp(r'\.(sftpThisPc|sftpThisMac|sftpThisComputer|sftpBinTrash|sftpBinRecycleBin)\b').hasMatch(text)) {
        readers.add(path.split('/').last);
      }
    }
    expect(readers, {'this_computer.dart'});
    for (final (path, uses) in [
      ('lib/ui/screens/sftp/widgets/sftp_source_picker.dart', 2),
      ('lib/ui/screens/sftp/sftp_dual_pane_screen.dart', 3),
      ('lib/ui/screens/sftp/widgets/sftp_pane.dart', 2),
    ]) {
      expect(RegExp(r'thisComputer(Bin)?Name\(').allMatches(File(path).readAsStringSync()).length, uses, reason: path);
    }
  });
}
