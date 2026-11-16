import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/utils/number_text.dart';

import '../helpers/monitor_table_fixture.dart';
import '../visual/shots_util.dart' show loadShotFonts;

/// A number the app shows is written as the app's language writes it: "0,52"
/// in German, "0.52" in English (found in a review: about 30 numbers
/// went through toStringAsFixed, a decimal point in every language).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final en = lookupAppLocalizations(const Locale('en'));
  final de = lookupAppLocalizations(const Locale('de'));

  test('formatDecimal: the language decimal mark, the digits asked for', () {
    expect(formatDecimal(0.52, digits: 2, l10n: en), '0.52');
    expect(formatDecimal(0.52, digits: 2, l10n: de), '0,52');
    expect(formatDecimal(1.5, l10n: de), '1,5');
    expect(formatDecimal(1.5, locale: 'fr'), '1,5');
    expect(formatDecimal(4.5, l10n: en), '4.5');
    expect(formatDecimal(12, digits: 0, l10n: de), '12');
    expect(formatDecimal(2.0, digits: 2, l10n: de), '2,00');
    // Grouping is the language's too.
    expect(formatDecimal(1234, digits: 0, l10n: en), '1,234');
    expect(formatDecimal(1234, digits: 0, l10n: de), '1.234');
  });

  test('formatDecimalUpTo: whole numbers bare, a fraction in the language', () {
    expect(formatDecimalUpTo(14.0, l10n: en), '14');
    expect(formatDecimalUpTo(14.0, l10n: de), '14');
    expect(formatDecimalUpTo(14.5, l10n: en), '14.5');
    expect(formatDecimalUpTo(14.5, l10n: de), '14,5');
    expect(formatDecimalUpTo(13.25, maxDigits: 1, l10n: de), '13,3');
  });

  test('formatPercentNumber: as the app has drawn it, the number then %', () {
    expect(formatPercentNumber(92, l10n: en), '92%');
    expect(formatPercentNumber(92, l10n: de), '92%');
    expect(formatPercentNumber(92.46, digits: 1, l10n: de), '92,5%');
  });

  test('with no language given it follows the app language', () {
    final was = gl10n;
    addTearDown(() => L10nGlobal.update(was));
    L10nGlobal.update(de);
    expect(formatDecimal(0.52, digits: 2), '0,52');
    L10nGlobal.update(en);
    expect(formatDecimal(0.52, digits: 2), '0.52');
  });

  for (final (locale, want) in [(const Locale('en'), '2.14  2.14  2.14'), (const Locale('de'), '2,14  2,14  2,14')]) {
    testWidgets('the phone Server monitor load average in $locale reads $want', (tester) async {
      // The real fonts: a German label in the test font's wide boxes does
      // not fit the card, which is not what this test is about.
      await tester.runAsync(loadShotFonts);
      final theme = BuiltInThemes.getById('graphite');
      AppColors.applyTheme(theme.colorScheme);
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fleet = MonitorFleet();
      final db = (await tester.runAsync(fleet.database))!;
      final prefs = (await tester.runAsync(fleet.preferences))!;
      addTearDown(() => tester.runAsync(db.close));
      await tester.pumpWidget(fleet.app(fleet.overrides(db, prefs), const ServerMonitorScreen(),
          theme: theme.toThemeData(), locale: locale));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(want), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }

  test('no screen formats a number with toStringAsFixed (a point in every language)', () {
    // What may keep it, and why: each is read back by a machine.
    const allowed = {
      // A whole number put in an editable field and read back by double.parse.
      'lib/ui/screens/monitoring/monitor_thresholds_dialog.dart',
    };
    final found = <String>[];
    for (final dir in ['lib/ui', 'lib/features']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final path = f.path.replaceAll('\\', '/');
        if (allowed.contains(path)) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('toStringAsFixed(')) found.add('$path:${i + 1}');
        }
      }
    }
    expect(found, isEmpty, reason: 'format shown numbers with formatDecimal (lib/utils/number_text.dart)');
  });
}
