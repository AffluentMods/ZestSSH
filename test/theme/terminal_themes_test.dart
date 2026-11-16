import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimitDesktop, freeSessionLimitMobile;
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

/// The six colours of the console in the JetBrains IDEs' dark schemes.
const _ideDark = [
  Color(0xFFF0524F),
  Color(0xFF5C962C),
  Color(0xFFA68A0D),
  Color(0xFF3993D4),
  Color(0xFFA771BF),
  Color(0xFF00A3A3),
];

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The built-in terminal themes (3.0): One Dark, One Light, Darcula,
/// IntelliJ Dark and IntelliJ Light were added, free; a theme a person
/// designs stays with Squeezed.
void main() {
  test('every built-in theme has a name, and every name a theme', () {
    expect(TerminalThemes.builtInNames.keys.toSet(), TerminalThemes.builtIn.keys.toSet());
    for (final name in TerminalThemes.builtInNames.values) {
      expect(name.trim(), isNotEmpty);
    }
    expect(TerminalThemes.builtInNames.values.toSet(), hasLength(TerminalThemes.builtInNames.length),
        reason: 'no two themes share a name');
  });

  test('One Dark, One Light and Darcula are there, with the colours they are known by', () {
    final dark = TerminalThemes.builtIn[TerminalThemes.oneDark]!;
    expect(TerminalThemes.builtInNames[TerminalThemes.oneDark], 'One Dark');
    expect(dark.background, const Color(0xFF282C34));
    expect(dark.foreground, const Color(0xFFABB2BF));
    expect([dark.red, dark.green, dark.yellow, dark.blue, dark.magenta, dark.cyan], const [
      Color(0xFFE06C75),
      Color(0xFF98C379),
      Color(0xFFE5C07B),
      Color(0xFF61AFEF),
      Color(0xFFC678DD),
      Color(0xFF56B6C2),
    ]);

    final light = TerminalThemes.builtIn[TerminalThemes.oneLight]!;
    expect(TerminalThemes.builtInNames[TerminalThemes.oneLight], 'One Light');
    expect(light.background, const Color(0xFFF9F9F9));
    expect(light.foreground, const Color(0xFF2A2C33));
    expect(light.background.computeLuminance(), greaterThan(0.8), reason: 'a light theme');
    expect(light.cyan, isNot(light.green), reason: 'cyan is its own colour');

    // Darcula in the console colours of the IDE itself, not those of a
    // terminal scheme that took its name.
    final darcula = TerminalThemes.builtIn[TerminalThemes.darcula]!;
    expect(TerminalThemes.builtInNames[TerminalThemes.darcula], 'Darcula');
    expect(darcula.background, const Color(0xFF2B2B2B));
    expect(darcula.foreground, const Color(0xFFBBBBBB));
    expect(darcula.cursor, const Color(0xFFBBBBBB));
    expect([darcula.red, darcula.green, darcula.yellow, darcula.blue, darcula.magenta, darcula.cyan], _ideDark);
    expect([darcula.black, darcula.white, darcula.brightBlack, darcula.brightWhite],
        const [Color(0xFF000000), Color(0xFF808080), Color(0xFF595959), Color(0xFFFFFFFF)]);
  });

  test('IntelliJ Dark and IntelliJ Light are there, in the console colours of the IDE', () {
    final dark = TerminalThemes.builtIn[TerminalThemes.intellijDark]!;
    expect(TerminalThemes.intellijDark, 'intellij_dark');
    expect(TerminalThemes.builtInNames[TerminalThemes.intellijDark], 'IntelliJ Dark');
    expect(dark.background, const Color(0xFF1E1F22));
    expect(dark.foreground, const Color(0xFFBCBEC4));
    expect(dark.cursor, const Color(0xFFCED0D6));
    expect([dark.red, dark.green, dark.yellow, dark.blue, dark.magenta, dark.cyan], _ideDark,
        reason: 'it takes its sixteen colours from Darcula, as the IDE does');
    expect(dark.background, isNot(TerminalThemes.builtIn[TerminalThemes.darcula]!.background));

    final light = TerminalThemes.builtIn[TerminalThemes.intellijLight]!;
    expect(TerminalThemes.intellijLight, 'intellij_light');
    expect(TerminalThemes.builtInNames[TerminalThemes.intellijLight], 'IntelliJ Light');
    expect(light.background, const Color(0xFFFFFFFF));
    expect(light.foreground, const Color(0xFF080808));
    expect([light.red, light.green, light.yellow, light.blue, light.magenta, light.cyan], const [
      Color(0xFFCE0505),
      Color(0xFF067D17),
      Color(0xFFB28C00),
      Color(0xFF063FDB),
      Color(0xFFB309B3),
      Color(0xFF028E8E),
    ]);
    expect([light.brightRed, light.brightGreen, light.brightYellow, light.brightBlue, light.brightMagenta, light.brightCyan],
        const [
          Color(0xFFFF1616),
          Color(0xFF16B42C),
          Color(0xFFECC32C),
          Color(0xFF2D61F0),
          Color(0xFFE617E6),
          Color(0xFF15C1C1),
        ]);
  });

  test('every built-in theme is free, and nothing else is: a theme a person designs is not', () {
    expect(TerminalThemes.freeThemeIds, TerminalThemes.builtIn.keys.toSet());
    expect(TerminalThemes.freeThemeIds, containsAll([TerminalThemes.dracula, TerminalThemes.nord, TerminalThemes.oneDark]));
    expect(TerminalThemes.freeThemeIds.contains('custom_1'), isFalse);
    expect(() => TerminalThemes.freeThemeIds.add('custom_1'), throwsUnsupportedError);
  });

  test('every built-in app theme is free too', () {
    expect(kFreeAppThemeIds, {for (final theme in BuiltInThemes.all) theme.id});
    expect(kFreeAppThemeIds.length, greaterThan(4), reason: 'four were');
    expect(kFreeAppThemeIds.contains(kCustomBrandThemeId), isFalse, reason: 'a theme a person designs is not');
  });

  test('what the app sells is custom themes, in every language, not the built-in ones', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final en = lookupAppLocalizations(const Locale('en'));
      if (locale.languageCode == 'en') {
        expect(l.homeUnlimitedConnectionsThemes, 'Unlimited sessions & custom themes');
        expect(l.upgradeFeatureAllThemes, 'Your own custom themes');
        expect(l.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile), contains('custom themes'));
        expect(l.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile), isNot(contains('every theme')));
        expect(l.deskUpgSqueezedFeatureThemes, isNot(contains('All terminal themes')));
        continue;
      }
      for (final say in <String Function(AppLocalizations)>[
        (x) => x.homeUnlimitedConnectionsThemes,
        (x) => x.settingsUnlockConnectionsThemes,
        (x) => x.upgradeFeatureAllThemes,
        (x) => x.deskUpgSqueezedFeatureThemes,
        (x) => x.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile),
      ]) {
        expect(say(l), isNot(say(en)), reason: '$locale');
      }
    }
  });

  test('every built-in theme can be read: its text, its cursor and what a search finds stand out', () {
    for (final entry in TerminalThemes.builtIn.entries) {
      final t = entry.value;
      expect(_contrast(t.foreground, t.background), greaterThan(4.5), reason: '${entry.key}: text on its background');
      expect(_contrast(t.cursor, t.background), greaterThan(2.5), reason: '${entry.key}: the cursor');
      expect(_contrast(t.searchHitForeground, t.searchHitBackgroundCurrent), greaterThan(3.0),
          reason: '${entry.key}: the match being looked at');
      final ansi = {t.red, t.green, t.yellow, t.blue, t.magenta, t.cyan};
      expect(ansi.length, greaterThanOrEqualTo(5), reason: '${entry.key}: its colours are told apart');
    }
  });
}
