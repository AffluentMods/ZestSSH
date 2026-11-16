import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/widgets/host_icon_color_field.dart';
import 'package:zestssh/ui/screens/connection/widgets/host_icon_picker.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';

/// The icon picker (3.0): every icon is shown in
/// its own colour unless the person chooses the colour of the host's label
/// (its own, or its group's) or a colour for the icon; the picker says what
/// each choice does for this host, and gives the choice back with the icon.
void main() {
  const blue = Color(0xFF3B82F6);
  // A 1x1 PNG.
  const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  // Their own colours as drawn: a shade of the brand's that shows.
  final debian = OsIcon.ownColor(OsCatalog.get('debian'));
  final ubuntu = OsIcon.ownColor(OsCatalog.get('ubuntu'));

  // What the picker was closed with: [closed] says it was, [choice] with what.
  late bool closed;
  HostIconChoice? choice;

  Future<void> open(
    WidgetTester tester, {
    String? iconId = 'debian',
    String? picture,
    int? iconColor,
    Color? labelColor = blue,
    HostLabelColorSource source = HostLabelColorSource.group,
    String? groupName = 'Web',
    Locale locale = const Locale('en'),
  }) async {
    closed = false;
    choice = null;
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              choice = await showHostIconPicker(
                context,
                currentIconId: iconId,
                currentCustomIcon: picture,
                currentIconColor: iconColor,
                labelColor: labelColor,
                labelSource: source,
                groupName: groupName,
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The colour the catalog's tile of [id] is drawn in: null is its own.
  Color? tile(WidgetTester tester, String id) {
    final icons = tester.widgetList<OsIcon>(find.byWidgetPredicate((w) => w is OsIcon && w.osId == id && w.size == 32));
    expect(icons, hasLength(1), reason: 'one tile of $id in the catalog');
    return icons.single.color;
  }

  /// The picker's own picture of the choice, top left.
  HostIcon preview(WidgetTester tester) =>
      tester.widget<HostIcon>(find.byWidgetPredicate((w) => w is HostIcon && w.size == 40));

  /// Which of the three choices is marked as the one in force.
  String marked(WidgetTester tester) {
    final field = find.byKey(const ValueKey('host-icon-color'));
    final bold = tester
        .widgetList<Text>(find.descendant(of: field, matching: find.byType(Text)))
        .where((t) => t.style?.fontWeight == FontWeight.w600)
        .map((t) => t.data!)
        .toList();
    expect(bold, hasLength(1));
    return bold.single;
  }

  String hint(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('host-icon-color-hint'))).data!;

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('host-icon-color')), matching: find.text(label)));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, isTrue);
  }

  testWidgets('as it opens for a host in a group: every icon in its own colour, and it says so', (tester) async {
    await open(tester);
    expect(marked(tester), "Icon's own");
    expect(hint(tester), 'The icon is drawn in its own color.');
    expect(tile(tester, 'debian'), isNull);
    expect(tile(tester, 'ubuntu'), isNull, reason: 'not the group\'s blue: this is what was asked for');
    expect(preview(tester).iconColor, isNull);
    expect(find.text('Icon color'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-icon-color-swatches')), findsNothing);
    // The three choices, the middle one named for where this host's colour comes from.
    for (final label in ["Icon's own", 'Group color', 'Custom']) {
      expect(find.descendant(of: find.byKey(const ValueKey('host-icon-color')), matching: find.text(label)),
          findsOneWidget);
    }
    await apply(tester);
    expect(choice, (iconId: 'debian', customIcon: null, iconColor: null));
  });

  testWidgets('the group\'s colour: every icon is shown in it, it says whose colour that is, and it is given back',
      (tester) async {
    await open(tester);
    await pick(tester, 'Group color');
    expect(marked(tester), 'Group color');
    expect(hint(tester), 'Using the group "Web" color');
    expect(tile(tester, 'debian'), blue);
    expect(tile(tester, 'ubuntu'), blue);
    expect(preview(tester).iconColor, HostIconColor.followsLabel);
    expect(preview(tester).labelColor, blue);
    await apply(tester);
    expect(choice, (iconId: 'debian', customIcon: null, iconColor: HostIconColor.followsLabel));
  });

  testWidgets('a host with a colour label of its own: the choice is named for the label and says so', (tester) async {
    await open(tester, source: HostLabelColorSource.label, iconColor: HostIconColor.followsLabel);
    expect(marked(tester), 'Label color');
    expect(find.text('Group color'), findsNothing);
    expect(hint(tester), "Using this host's color label.");
    expect(tile(tester, 'ubuntu'), blue, reason: 'opened with the choice the host has');
  });

  testWidgets('a host with no label and no group: the choice can be made, and it says what that means for now',
      (tester) async {
    await open(tester, source: HostLabelColorSource.none, labelColor: null, groupName: null);
    await pick(tester, 'Group color');
    expect(marked(tester), 'Group color');
    expect(hint(tester),
        'This host has no color label and is in no group, so its icon keeps its own color until it has one.');
    expect(tile(tester, 'ubuntu'), isNull, reason: 'nothing to follow yet');
    await apply(tester);
    expect(choice!.iconColor, HostIconColor.followsLabel, reason: 'a standing choice: it follows once there is a colour');
  });

  testWidgets('a custom colour starts from the colour shown, so choosing Custom changes nothing by itself',
      (tester) async {
    await open(tester);
    await pick(tester, 'Custom');
    expect(marked(tester), 'Custom');
    expect(find.byKey(const ValueKey('host-icon-color-swatches')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-icon-color-hint')), findsNothing);
    expect(preview(tester).iconColor, HostIconColor.custom(debian), reason: 'the chosen icon\'s own colour');
    expect(tile(tester, 'ubuntu'), debian, reason: 'one colour for whichever icon is picked');
    await apply(tester);
    expect(choice!.iconColor, HostIconColor.custom(debian));
  });

  testWidgets('from the group\'s colour, Custom starts from the group\'s colour', (tester) async {
    await open(tester, iconColor: HostIconColor.followsLabel);
    await pick(tester, 'Custom');
    expect(preview(tester).iconColor, HostIconColor.custom(blue));
  });

  testWidgets('picking a colour: the icons take it, it is given back, and it comes back after another choice',
      (tester) async {
    await open(tester);
    await pick(tester, 'Custom');
    final swatches = find.descendant(
        of: find.byKey(const ValueKey('host-icon-color-swatches')), matching: find.byType(GestureDetector));
    // The colour shown now (off the list), the list, then the entry for any colour.
    expect(swatches, findsNWidgets(1 + AppColors.labelPalette.length + 1));
    await tester.tap(swatches.at(6));
    await tester.pump(const Duration(milliseconds: 200));
    final purple = AppColors.labelPalette[5];
    expect(tile(tester, 'debian'), purple);
    expect(tester.widget<ZestColorPicker>(find.byType(ZestColorPicker)).selected, purple);

    await pick(tester, "Icon's own");
    expect(tile(tester, 'debian'), isNull);
    await pick(tester, 'Group color');
    expect(tile(tester, 'debian'), blue);
    await pick(tester, 'Custom');
    expect(tile(tester, 'debian'), purple, reason: 'the colour picked before, not the one shown a moment ago');
    await apply(tester);
    expect(choice, (iconId: 'debian', customIcon: null, iconColor: HostIconColor.custom(purple)));
  });

  testWidgets('opened on a host with a custom colour: that colour, marked and shown', (tester) async {
    await open(tester, iconColor: 0xFF22C55E);
    expect(marked(tester), 'Custom');
    expect(tile(tester, 'ubuntu'), const Color(0xFF22C55E));
    expect(tester.widget<ZestColorPicker>(find.byType(ZestColorPicker)).selected, const Color(0xFF22C55E));
  });

  testWidgets('the colour a host came with comes back too, after another choice', (tester) async {
    await open(tester, iconColor: 0xFF22C55E);
    await pick(tester, "Icon's own");
    expect(tile(tester, 'debian'), isNull);
    await pick(tester, 'Custom');
    expect(tile(tester, 'debian'), const Color(0xFF22C55E), reason: 'the colour it had, not the icon\'s own');
    await apply(tester);
    expect(choice!.iconColor, 0xFF22C55E);
  });

  testWidgets('another icon, or the automatic one, keeps the colour choice', (tester) async {
    await open(tester);
    await pick(tester, 'Group color');
    await tester.tap(find.byWidgetPredicate((w) => w is OsIcon && w.osId == 'ubuntu' && w.size == 32));
    await tester.pump(const Duration(milliseconds: 200));
    expect(preview(tester).iconId, 'ubuntu');
    expect(preview(tester).iconColor, HostIconColor.followsLabel);
    await tester.tap(find.text('Use auto'));
    await tester.pump(const Duration(milliseconds: 200));
    await apply(tester);
    expect(choice, (iconId: null, customIcon: null, iconColor: HostIconColor.followsLabel));
  });

  testWidgets('Custom on an icon chosen meanwhile starts from that icon\'s colour', (tester) async {
    await open(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is OsIcon && w.osId == 'ubuntu' && w.size == 32));
    await tester.pump(const Duration(milliseconds: 200));
    await pick(tester, 'Custom');
    expect(preview(tester).iconColor, HostIconColor.custom(ubuntu));
    expect(ubuntu, isNot(debian));
  });

  testWidgets('an uploaded picture: the choices are there, off, and it says why', (tester) async {
    await open(tester, iconId: null, picture: png, iconColor: HostIconColor.followsLabel);
    expect(hint(tester), 'An uploaded picture keeps its own colors.');
    expect(marked(tester), 'Group color', reason: 'what the host has is still shown');
    await pick(tester, "Icon's own");
    expect(marked(tester), 'Group color', reason: 'off: a tap changes nothing');
    await pick(tester, 'Custom');
    expect(find.byKey(const ValueKey('host-icon-color-swatches')), findsNothing);
    // Each choice says why it is off to whoever points at it.
    final reasons = tester
        .widgetList<Tooltip>(find.descendant(of: find.byKey(const ValueKey('host-icon-color')), matching: find.byType(Tooltip)))
        .map((t) => t.message)
        .toList();
    expect(reasons, List.filled(3, 'An uploaded picture keeps its own colors.'));
    await apply(tester);
    expect(choice, (iconId: null, customIcon: png, iconColor: HostIconColor.followsLabel), reason: 'kept for later');
  });

  testWidgets('a picture with a custom colour kept from before shows no swatches either', (tester) async {
    await open(tester, iconId: null, picture: png, iconColor: 0xFF22C55E);
    expect(find.byKey(const ValueKey('host-icon-color-swatches')), findsNothing);
    expect(hint(tester), 'An uploaded picture keeps its own colors.');
  });

  testWidgets('going back to a built-in icon from a picture turns the choices on again', (tester) async {
    await open(tester, iconId: null, picture: png);
    await tester.tap(find.byWidgetPredicate((w) => w is OsIcon && w.osId == 'debian' && w.size == 32));
    await tester.pump(const Duration(milliseconds: 200));
    await pick(tester, 'Group color');
    expect(marked(tester), 'Group color');
    expect(tile(tester, 'ubuntu'), blue);
  });

  testWidgets('Cancel and the cross give nothing back', (tester) async {
    await open(tester);
    await pick(tester, 'Group color');
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, isTrue);
    expect(choice, isNull);

    await open(tester);
    await pick(tester, 'Custom');
    // The cross (Close, the shell's).
    await tester.tap(find.byTooltip('Close'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, isTrue);
    expect(choice, isNull);
  });

  testWidgets('it fits: in every language, with each choice and with the colours to pick from', (tester) async {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final source in HostLabelColorSource.values) {
        for (final iconColor in [null, HostIconColor.followsLabel, 0xFF22C55E]) {
          await tester.pumpWidget(const SizedBox.shrink());
          await open(tester,
              locale: locale,
              source: source,
              iconColor: iconColor,
              groupName: source == HostLabelColorSource.group ? 'Production web servers' : null,
              labelColor: source == HostLabelColorSource.none ? null : blue);
          expect(tester.takeException(), isNull, reason: '${locale.languageCode} $source $iconColor');
          expect(find.text(l10n.hostIconColorLabel), findsOneWidget);
          expect(find.text(l10n.hostIconColorOwn), findsOneWidget);
          expect(find.text(l10n.zestColorPickerCustom), findsOneWidget);
          expect(
              find.text(source == HostLabelColorSource.label ? l10n.hostIconColorLabelColor : l10n.hostIconColorGroup),
              findsOneWidget);
        }
      }
    }
  });

  test('the words: every language has its own, and the picker\'s older words have their accents', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l10n = lookupAppLocalizations(locale);
      for (final (name, mine, english) in [
        ('label', l10n.hostIconColorLabel, en.hostIconColorLabel),
        ('own', l10n.hostIconColorOwn, en.hostIconColorOwn),
        ('group', l10n.hostIconColorGroup, en.hostIconColorGroup),
        ('label colour', l10n.hostIconColorLabelColor, en.hostIconColorLabelColor),
        ('own hint', l10n.hostIconColorOwnHint, en.hostIconColorOwnHint),
        ('from label', l10n.hostIconColorFromLabel, en.hostIconColorFromLabel),
        ('no label', l10n.hostIconColorNoLabel, en.hostIconColorNoLabel),
        ('picture', l10n.hostIconColorPicture, en.hostIconColorPicture),
        ('bulk title', l10n.hostIconColorBulkTitle(3), en.hostIconColorBulkTitle(3)),
        ('bulk hint', l10n.hostIconColorBulkGroupHint, en.hostIconColorBulkGroupHint),
        ('bulk or', l10n.hostIconColorBulkOr, en.hostIconColorBulkOr),
      ]) {
        expect(mine.trim(), isNotEmpty, reason: '${locale.languageCode} $name');
        expect(mine, isNot(english), reason: '${locale.languageCode} $name is still English');
      }
      expect(l10n.hostIconColorBulkTitle(3), contains('3'), reason: locale.languageCode);
    }
    expect(en.hostIconColorBulkTitle(1), 'Icon color of 1 host');
    expect(en.hostIconColorBulkTitle(7), 'Icon color of 7 hosts');

    // Shipped in 2.2.1 without their accents.
    final de = lookupAppLocalizations(const Locale('de'));
    expect([de.hostIconChange, de.hostIconPickerTitle, de.hostIconApply], ['Ändern', 'Symbol wählen', 'Übernehmen']);
    final fr = lookupAppLocalizations(const Locale('fr'));
    expect([fr.hostIconLabel, fr.hostIconPickerTitle, fr.hostIconCustomSubtitle],
        ['Icône', 'Choisir une icône', 'Image personnalisée']);
    final pt = lookupAppLocalizations(const Locale('pt'));
    expect([
      pt.hostIconLabel,
      pt.hostIconPickerTitle,
      pt.hostIconResetAuto,
      pt.hostIconUploadFailed,
    ], [
      'Ícone',
      'Escolher um ícone',
      'Usar automático',
      'Não foi possível ler essa imagem. Tente um PNG ou JPG menor.',
    ]);
    final es = lookupAppLocalizations(const Locale('es'));
    expect([es.hostIconResetAuto, es.hostIconUploadFailed], [
      'Usar automático',
      'No se pudo leer esa imagen. Prueba con un PNG o JPG más pequeño.',
    ]);
    final it = lookupAppLocalizations(const Locale('it'));
    expect(it.hostIconUploadFailed, "Impossibile leggere l'immagine. Prova un PNG o JPG più piccolo.");
  });
}
