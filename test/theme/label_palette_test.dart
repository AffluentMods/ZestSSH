import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';

/// Every Dart file of the app but what is generated.
Iterable<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart') && !f.path.contains('generated'));

/// A file's text without its comment lines (a doc comment may name a list).
String _code(File f) =>
    f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');

String _name(File f) => f.path.replaceAll(r'\', '/');

void main() {
  group('the one list of colours', () {
    test('eight colours, all different, in the order saved indexes read them by', () {
      expect(AppColors.labelPalette.map((c) => c.toARGB32()).toList(), const [
        0xFFEF4444, 0xFFF59E0B, 0xFFFF7A1A, 0xFF10B981, 0xFF3B82F6, 0xFFA855F7, 0xFFEC4899, 0xFF14B8A6,
      ]);
      expect(AppColors.labelPalette.toSet(), hasLength(8));
      expect(identical(AppColors.v3GroupColors, AppColors.labelPalette), isTrue,
          reason: "a group's saved index reads the same list a picker offers");
      expect(GroupColor.values.take(8).map((g) => g.value).toList(), AppColors.labelPalette,
          reason: "the group colour tokens (and the network editor's picker) line up with it");
    });

    test('a colour saved on a host still means what it meant, on the list or not', () {
      // By index, from before the one list: brown and this yellow are not on it.
      expect(AppColors.connectionLabelColors.map((c) => c.toARGB32()).toList(), const [
        0xFFFF7A1A, 0xFF10B981, 0xFF3B82F6, 0xFFEF4444, 0xFFA855F7, 0xFFEAB308, 0xFF14B8A6, 0xFFA16207,
      ]);
      expect(AppColors.labelColorFor(null, 7), const Color(0xFFA16207));
      expect(AppColors.explicitConnectionLabel(null, 5), const Color(0xFFEAB308));
      // By value, any colour at all.
      expect(AppColors.labelColorFor(0xFF123456, 3), const Color(0xFF123456));
    });

    test('every picker offers the one list, none its own', () {
      // The app's brand colour on the Appearance page is not a label's colour.
      const notALabel = {'_brandPresets'};
      final offenders = <String>[];
      var pickers = 0;
      for (final f in _libFiles()) {
        if (_name(f).endsWith('lib/ui/widgets/zest_color_picker.dart')) continue;
        final code = _code(f);
        for (final m in RegExp(r'\bZestColorPicker\(').allMatches(code)) {
          pickers++;
          final arg = RegExp(r'\bpresets:\s*([^,]+),').firstMatch(code.substring(m.end))?.group(1)?.trim();
          if (arg != 'AppColors.labelPalette' && !notALabel.contains(arg)) offenders.add('${_name(f)}: $arg');
        }
      }
      expect(offenders, isEmpty, reason: 'a picker for a host, a group or a tag offers AppColors.labelPalette');
      expect(pickers, greaterThanOrEqualTo(10), reason: 'the scan is still finding the pickers');
    });

    test('the table of older saved indexes is only read, in AppColors, and never offered', () {
      final users = [
        for (final f in _libFiles())
          if (_code(f).contains('connectionLabelColors')) _name(f),
      ];
      expect(users, ['lib/theme/app_colors.dart']);
    });

    test('swatches drawn by hand use the one list, and no file has a palette of its own', () {
      for (final path in const [
        'lib/features/groups/widgets/phone_group_sheets.dart',
        'lib/ui/screens/desktop/widgets/snippets_library_view.dart',
      ]) {
        expect(_code(File(path)), contains('AppColors.labelPalette'), reason: path);
      }
      // A list of colours written out: the theme's own, the brand colours and
      // the theme builder's, and no other. Every one allowed still has one: an
      // entry that does not is an open door for the next (the picker's was,
      // found in a review).
      const allowed = {
        'lib/theme/app_colors.dart',
        'lib/ui/screens/settings/appearance_screen.dart',
        'lib/ui/screens/settings/widgets/custom_theme_builder.dart',
      };
      final literal = RegExp(r'(?:List<Color>\s+\w+\s*=\s*(?:const\s*)?(?:<Color>)?\[|<Color>\[)\s*(?:const\s+)?Color\(0x');
      final having = {for (final f in _libFiles()) if (literal.hasMatch(_code(f))) _name(f)};
      expect(having.difference(allowed), isEmpty);
      expect(allowed.difference(having), isEmpty, reason: 'allowed files that no longer have a palette of their own');
    });
  });

  group('a colour off the list in the picker', () {
    const brown = Color(0xFFA16207);
    final current = find.byKey(const ValueKey('zest-color-picker-current'));

    Future<List<Color>> pump(WidgetTester tester, Color selected, {bool noneSelected = false}) async {
      final picked = <Color>[];
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ZestColorPicker(
            presets: AppColors.labelPalette,
            selected: selected,
            allowNone: true,
            noneSelected: noneSelected,
            onNoneSelected: () {},
            onChanged: picked.add,
          ),
        ),
      ));
      return picked;
    }

    testWidgets('shows first, as it is, and tapping it rewrites nothing', (tester) async {
      final picked = await pump(tester, brown);
      expect(current, findsOneWidget);
      // None, the colour chosen, then the list: before the first of the list.
      final swatches = find.descendant(of: find.byType(ZestColorPicker), matching: find.byType(GestureDetector));
      expect(swatches, findsNWidgets(1 + 1 + AppColors.labelPalette.length + 1));
      expect(tester.widget(find.descendant(of: current, matching: find.byType(GestureDetector)).first),
          same(tester.widget(swatches.at(1))));
      await tester.tap(current);
      await tester.pump();
      expect(picked, isEmpty);
      await tester.tap(swatches.at(2));
      await tester.pump();
      expect(picked, [AppColors.labelPalette.first], reason: 'choosing from the list still works');
    });

    testWidgets('a colour on the list, None, or nothing chosen adds no swatch', (tester) async {
      await pump(tester, AppColors.labelPalette[3]);
      expect(current, findsNothing);
      await pump(tester, brown, noneSelected: true);
      expect(current, findsNothing, reason: 'None wins');
      await pump(tester, const Color(0x00000000));
      expect(current, findsNothing, reason: 'the bulk bar: nothing common to several hosts');
    });
  });
}
