import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/hosts/models/host_card_settings.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The host cards' options in Settings are named in the person's language
/// (3.0): their sizes ("Compact", "Comfortable",
/// "Spacious"), the number of columns ("Auto", "2 columns") and the accent
/// ("Per group colour", "Uniform orange", "No accent") were English, whatever
/// the language; and "Uniform orange" drew the app's accent colour, which the
/// brand colours change.
void main() {
  final all = [for (final locale in AppLocalizations.supportedLocales) lookupAppLocalizations(locale)];
  final de = lookupAppLocalizations(const Locale('de'));

  test("every option has a name in each language's words", () {
    for (final l10n in all) {
      for (final names in [
        [for (final d in HostCardDensity.values) d.nameIn(l10n)],
        [for (final c in HostCardColumns.values) c.nameIn(l10n)],
        [for (final a in HostCardAccentMode.values) a.nameIn(l10n)],
      ]) {
        expect(names.every((n) => n.trim().isNotEmpty), isTrue, reason: l10n.localeName);
        expect(names.toSet(), hasLength(names.length), reason: '${l10n.localeName}: no two options of a list alike');
      }
    }
    expect([for (final d in HostCardDensity.values) d.nameIn(de)], ['Kompakt', 'Komfortabel', 'Geräumig']);
    expect([for (final a in HostCardAccentMode.values) a.nameIn(de)],
        ['Farbe des Hosts', 'Akzentfarbe der App', 'Keine Akzentfarbe']);
  });

  test('the columns: automatic, or as many as asked, counted as each language counts', () {
    expect([for (final c in HostCardColumns.values) c.nameIn(de)],
        ['Automatisch', '1 Spalte', '2 Spalten', '3 Spalten', '4 Spalten', '5 Spalten', '6 Spalten']);
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect([for (final c in HostCardColumns.values) c.nameIn(ru)],
        ['Автоматически', '1 столбец', '2 столбца', '3 столбца', '4 столбца', '5 столбцов', '6 столбцов']);
    final en = lookupAppLocalizations(const Locale('en'));
    expect(HostCardColumns.one.nameIn(en), '1 column');
    expect(HostCardColumns.two.nameIn(en), '2 columns');
  });
}
