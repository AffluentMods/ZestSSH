import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The search of Settings on a computer knows every row (3.0).
/// Its list was written by hand in English, apart from the rows: it lacked
/// rows, and in another language a word of that language found nothing. Now
/// the list names each row's own strings. This reads the code and holds that
/// the list has one line for every row, and that no two rows of a section
/// say the same (a result lands on a row by its section and its name).
void main() {
  final code = File('lib/ui/screens/desktop/widgets/settings_inline_view.dart').readAsStringSync().replaceAll('\r\n', '\n');

  /// The section each function's rows are in.
  const sectionOf = {
    '_buildPlan': 'plan',
    '_buildNotifications': 'notifications',
    '_buildGeneral': 'general',
    '_buildConnectionDefaults': 'terminal',
    '_buildFiles': 'files',
    '_buildTerminal': 'terminal',
    '_buildSessionLog': 'terminal',
    '_buildAppearance': 'appearance',
    '_buildHostCardSection': 'appearance',
    '_buildKeyboard': 'keyboard',
    '_buildSecurity': 'security',
    '_buildScreens': 'screens',
    '_buildAbout': 'about',
  };

  /// Every row in the code: (section, the key of its name).
  List<(String, String)> rows() {
    final out = <(String, String)>[];
    final lines = code.split('\n');
    final function = RegExp(r'^\s+(?:List<Widget>|Widget|Future<void>)\s+(_[A-Za-z]+)\(');
    String? inFunction;
    for (var i = 0; i < lines.length; i++) {
      final f = function.firstMatch(lines[i]);
      if (f != null && !lines[i].trimRight().endsWith(';')) inFunction = f.group(1);
      if (!lines[i].contains('_SettingRow(')) continue;
      if (lines[i].contains('class _SettingRow') || lines[i].contains('const _SettingRow({')) continue;
      final head = lines.skip(i).take(14).join('\n').split('child:').first;
      final label = RegExp(r'label:\s*l10n\.([A-Za-z0-9_]+)\s*,').firstMatch(head);
      expect(label, isNotNull, reason: 'a row at line ${i + 1} whose name is no plain string: the search cannot know it');
      expect(sectionOf, contains(inFunction), reason: 'a row at line ${i + 1} in $inFunction: say which section that is');
      out.add((sectionOf[inFunction]!, label!.group(1)!));
    }
    return out;
  }

  /// The search's list: (section, the key of the name).
  List<(String, String)> listed() => [
        for (final m in RegExp(r'_SettingSearchSpec(?:\.macOnly|\.plans|\.computerOnly)?\(_SettingsSection\.([a-z]+), \(l\) => l\.([A-Za-z0-9_]+)[,)]')
            .allMatches(code))
          (m.group(1)!, m.group(2)!),
      ];

  test('the list has every row of the code, in its section, and nothing else', () {
    final inCode = rows();
    expect(inCode.length, greaterThan(50));
    expect(listed().toSet(), inCode.toSet());
    expect(listed().length, inCode.length, reason: 'each once');
  });

  test("the pages that are the account page's own are found too: each entry is a name it shows, on its page", () {
    // It found nothing for "export": the page
    // is the account page's own, with no _SettingRow, so the list skipped it.
    // Its two-step rows are a card of their own (3.3), in a file of their own;
    // Backups and data shows the cloud accounts' list too (4.0).
    final page = [
      File('lib/ui/screens/profile/profile_screen.dart').readAsStringSync(),
      File('lib/ui/screens/profile/widgets/two_step_section.dart').readAsStringSync(),
      File('lib/features/cloud_import/ui/cloud_accounts_view.dart').readAsStringSync(),
    ].join('\n');
    final entries = [
      for (final m in RegExp(r'_SettingSearchSpec\.page\(_SettingsSection\.([a-z]+), \(l\) => l\.([A-Za-z0-9_]+)')
          .allMatches(code))
        (m.group(1)!, m.group(2)!),
    ];
    final keys = [for (final (_, key) in entries) key];
    expect(keys, containsAll(['accountExport', 'accountImport', 'settingsMobConnectionsAsSshConfig', 'accountDeleteAccount']));
    for (final key in keys) {
      expect(page, contains('l10n.$key'), reason: '$key is not shown on the account page');
    }
    expect(keys.toSet().length, keys.length, reason: 'each once');
    // Each on the page that shows it (4.0): the account's, the plan's, and
    // the data's.
    String sectionOf(String key) => entries.firstWhere((e) => e.$2 == key).$1;
    for (final key in ['accountTwoStep', 'zestProfileNavDevices', 'zestProfileNavSync', 'accountDeleteAccount']) {
      expect(sectionOf(key), 'account', reason: key);
    }
    expect(sectionOf('settingsMobRedeemCode'), 'plan');
    for (final key in [
      'accountExport',
      'accountImport',
      'accountAutoBackups',
      'accountClearCache',
      'accountDeleteLocal',
      'settingsInlineResetAllSettings',
      'cloudAccTitle',
    ]) {
      expect(sectionOf(key), 'data', reason: key);
    }
  });

  test('nothing of the list is written out in words: each entry names strings of the app', () {
    final start = code.indexOf('final List<_SettingSearchSpec> _kSettingsSearchIndex = [');
    expect(start, isNot(-1));
    final list = code.substring(start, code.indexOf('\n];\n', start));
    expect(list, isNot(contains("'")), reason: 'a word in quotes');
    expect(list, isNot(contains('"')));
  });

  test('in every language no two rows of a section have the same name (a result lands on a row by it)', () {
    for (final locale in AppLocalizations.supportedLocales) {
      // The names are read from the language's own string file, by key.
      final arb = File('lib/l10n/app_${locale.languageCode}.arb').readAsStringSync();
      String said(String key) {
        final m = RegExp('"$key": "((?:[^"\\\\]|\\\\.)*)"').firstMatch(arb);
        expect(m, isNotNull, reason: '$key in $locale');
        return m!.group(1)!;
      }

      final seen = <String>{};
      for (final (section, key) in listed()) {
        expect(seen.add('$section/${said(key)}'), isTrue, reason: '$locale: two rows of $section are named "${said(key)}"');
      }
    }
    expect(lookupAppLocalizations(const Locale('en')).settingsSearchHint, isNotEmpty);
  });
}
