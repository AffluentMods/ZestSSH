import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/os_descriptor.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/host_icon_names.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/widgets/host_icon_picker.dart';

import '../visual/shots_util.dart';

/// The host icon picker names its icons in the person's language (3.0).
/// Every name under an icon was English, whatever the language
/// ("Database", "Router", "Moon"), and the search found an icon by its English
/// name alone. A brand or an acronym (Ubuntu, Docker, VPN) keeps its name.
void main() {
  final all = [for (final locale in AppLocalizations.supportedLocales) lookupAppLocalizations(locale)];
  final de = lookupAppLocalizations(const Locale('de'));

  /// The icons named by an acronym or a name every language writes so: kept
  /// as written.
  const asWritten = {'vps', 'nvme', 'cpu', 'gpu', 'ups', 'tv', 'vpn', 'dns', 'cdn', 'hpc', 'api', 'cms', 'wifi', 'ethernet'};

  /// The icons named by a word (a brand's icon is of the category of systems).
  bool isWord(OsDescriptor d) => d.category != HostIconCategory.os && !asWritten.contains(d.id);

  test("every icon has a name in every language: a thing's in that language, a brand's as it is written", () {
    for (final d in OsCatalog.pickable) {
      final names = {for (final l10n in all) hostIconName(d, l10n)};
      expect(names.every((n) => n.trim().isNotEmpty), isTrue, reason: d.id);
      if (!isWord(d)) {
        expect(names, {d.displayName}, reason: '${d.id}: a brand or an acronym keeps its name');
      } else {
        expect(names.length, greaterThan(1), reason: '${d.id}: said in each language, not in English alone');
      }
    }
    expect(hostIconName(OsCatalog.get('database'), de), 'Datenbank');
    expect(hostIconName(OsCatalog.get('vpn'), de), 'VPN', reason: 'an acronym as it is written');
    expect(hostIconName(OsCatalog.get('ubuntu'), de), 'Ubuntu');
    expect(hostIconName(OsCatalog.get(null), de), de.iconNameUnknown, reason: 'the icon of a host with none');
  });

  test('the search finds an icon by its name in the person\'s language, and by its English one', () {
    List<String> found(String q) => [for (final d in OsCatalog.search(q, nameOf: (d) => hostIconName(d, de))) d.id];
    expect(found('datenbank'), containsAll(['database', 'database_replica']));
    expect(found('database'), contains('database'));
    expect(found('mond'), ['moon']);
  });

  testWidgets('the picker, in German: the names under the icons, and a search by them', (tester) async {
    // The fonts the app ships (the test font's letters are squares, wider
    // than any of the app's).
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHostIconPicker(context, currentIconId: 'debian', currentCustomIcon: null),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 400));

    Finder tile(String id) => find.byWidgetPredicate((w) => w is OsIcon && w.osId == id && w.size == 32);
    await tester.enterText(find.byType(TextField).first, 'Datenbank');
    await tester.pump(const Duration(milliseconds: 400));
    expect(tile('database'), findsOneWidget, reason: 'found by its German name');
    expect(find.byTooltip('Datenbank'), findsOneWidget, reason: 'and named so');
    expect(tile('router'), findsNothing, reason: 'the search kept the icons named by it alone');
  });
}
