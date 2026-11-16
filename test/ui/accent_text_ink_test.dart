import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart';

import '../helpers/painted_contrast.dart';
import '../visual/shots_util.dart';

/// The accent as a text's or an icon's own colour is the accent's ink (3.0):
/// the accent itself where it reads at 4.5:1, the nearest
/// shade of it that does elsewhere. Nineteen texts and icons were the accent
/// as it is (the settings pages' section titles, the tips of a failed
/// connection, Quick connect's hint, the hints of a drop, and more), which on
/// Daylight is an orange of 2.3:1. (That the ink reads on every theme's
/// surfaces is held by accent_ink_test.dart.)
void main() {
  final raw = RegExp(r'color:\s*(const\s+)?(AppColors\.(brandOrange|orange|v3AccentPrimary)|ZestColors\.accentPrimary)\b');

  /// Each TextStyle, Icon and copyWith of [files] whose own colour is the
  /// accent as it is, as "file:line".
  List<String> rawAccentTexts(Map<String, String> files) {
    final found = <String>[];
    for (final MapEntry(key: path, value: source) in files.entries) {
      final text = source.replaceAll('\r\n', '\n');
      for (final head in ['TextStyle(', 'Icon(', '.copyWith(']) {
        for (var i = text.indexOf(head); i >= 0; i = text.indexOf(head, i + head.length)) {
          if (head == 'Icon(' && i > 0 && RegExp(r'[A-Za-z0-9_]').hasMatch(text[i - 1])) continue;
          var k = i + head.length;
          for (var depth = 1; depth > 0 && k < text.length; k++) {
            if (text[k] == '(') depth++;
            if (text[k] == ')') depth--;
          }
          final call = text.substring(i, k);
          for (final m in raw.allMatches(call)) {
            // The call's own colour, not one of a call inside it.
            final before = call.substring(0, m.start);
            if ('('.allMatches(before).length - ')'.allMatches(before).length == 1) {
              found.add('$path:${'\n'.allMatches(text.substring(0, i + m.start)).length + 1}');
            }
          }
        }
      }
    }
    return found..sort();
  }

  test('no text or icon of lib is the accent as it is', () {
    final files = <String, String>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      // The theme's own files say what the accent is; the rest use it.
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      if (path.startsWith('lib/theme/') || path.startsWith('lib/core/theme/')) continue;
      files[path] = file.readAsStringSync();
    }
    expect(files, isNotEmpty);
    expect(rawAccentTexts(files), isEmpty, reason: "a text or an icon in the accent takes the accent's ink");
  });

  test('the check itself finds the accent as a text, an icon and a copy, and not a fill or the ink', () {
    const samples = '''
      Text('a', style: TextStyle(fontSize: 12, color: AppColors.brandOrange.withValues(alpha: 0.8)));
      Icon(LucideIcons.info, size: 17, color: AppColors.v3AccentPrimary);
      Text('b', style: const TextStyle(fontSize: 13).copyWith(color: AppColors.orange));
      Container(decoration: BoxDecoration(color: AppColors.brandOrange));
      Text('c', style: TextStyle(color: AppColors.accentInk));
      Icon(LucideIcons.info, color: ZestColors.accentInk);
''';
    expect(rawAccentTexts({'a': samples}), ['a:1', 'a:2', 'a:3']);
  });

  test('every filled icon button names the ink on its fill', () {
    final found = <String>[];
    const head = 'IconButton.filled(';
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      final text = file.readAsStringSync();
      for (var i = text.indexOf(head); i >= 0; i = text.indexOf(head, i + head.length)) {
        var k = i + head.length;
        for (var depth = 1; depth > 0 && k < text.length; k++) {
          if (text[k] == '(') depth++;
          if (text[k] == ')') depth--;
        }
        if (!text.substring(i, k).contains('foregroundColor:')) {
          found.add('$path:${'\n'.allMatches(text.substring(0, i)).length + 1}');
        }
      }
    }
    // Unnamed, Flutter gives it the theme's icon colour (the muted text),
    // over a filled button's own ink: light grey on the orange.
    expect(found, isEmpty);
  });

  for (final id in ['default_dark', 'default_light']) {
    testWidgets("$id: Quick connect's arrow reads on its orange", (tester) async {
      await tester.runAsync(loadShotFonts);
      addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
      final theme = BuiltInThemes.getById(id);
      AppColors.applyTheme(theme.colorScheme);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: QuickConnectBar()),
        ),
      ));
      await tester.pumpAndSettle();
      final glyph = 'icon U+${LucideIcons.arrowRight.codePoint.toRadixString(16).toUpperCase()}';
      final page = Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor;
      final arrow = paintedTexts(tester, fallbackGround: page).firstWhere((t) => t.text == glyph);
      expect(arrow.ratio, greaterThanOrEqualTo(3.0), reason: '$arrow');
    });
  }

  test('on Daylight the ink is deeper than the accent, and on Default Dark it is the accent', () {
    addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
    AppColors.applyTheme(BuiltInThemes.getById('default_light').colorScheme);
    expect(AppColors.accentInk.computeLuminance(), lessThan(AppColors.brandOrange.computeLuminance()));
    expect(ZestColors.contrast(AppColors.accentInk, AppColors.surface), greaterThanOrEqualTo(4.5));
    AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
    expect(AppColors.accentInk, AppColors.brandOrange);
  });
}
