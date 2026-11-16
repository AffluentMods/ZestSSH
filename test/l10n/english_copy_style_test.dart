import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The English copy keeps one style (found in a review): the single
/// ellipsis character, straight quotes and apostrophes, no double space, and
/// every way to sign in named where the texts list them. About 40 strings used
/// "..." and 80 "…", 30 had curly quotes beside straight ones elsewhere, and
/// five lists of the ways to sign in left Microsoft out.
void main() {
  final en = (jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>)
    ..removeWhere((k, v) => k.startsWith('@') || v is! String);

  test('one ellipsis: the single character, but in examples of code', () {
    final dots = RegExp(r'[\w)\]}]\.\.\.(?=$|[\s)"\]}])');
    final bad = [
      for (final e in en.entries)
        if (!e.key.startsWith('autoGuide') && e.key != 'identityPasteKeyHint' && dots.hasMatch(e.value as String)) e.key,
    ];
    expect(bad, isEmpty);
  });

  test('straight quotes and apostrophes', () {
    final curly = RegExp('[‘’“”]');
    expect([for (final e in en.entries) if (curly.hasMatch(e.value as String)) e.key], isEmpty);
  });

  test('no double space but the automation guide\'s bullet layout', () {
    expect(
      [
        for (final e in en.entries)
          if ((e.value as String).contains('  ') &&
              !e.key.startsWith('autoGuide') &&
              !const {'connectionEditConnectViaExampleBody', 'hardwareTokenNotInstalledDescUnix', 'snippetQuickPickerNavHint'}
                  .contains(e.key))
            e.key,
      ],
      isEmpty,
    );
  });

  test('every list of the ways to sign in names Microsoft', () {
    for (final key in [
      'twoStepUnsupportedFirstFactor',
      'lockoutDueBodyProof',
      'lockoutDone',
      'lockoutDoneReset',
      'passkeyRemoveLastBody',
      'twoStepTurnOffAllBody',
    ]) {
      expect(en[key], contains('Microsoft'), reason: key);
    }
  });
}
