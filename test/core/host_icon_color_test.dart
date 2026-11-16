import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

/// What colours a host's icon (3.0): by default
/// its own colour, whatever the host's label or group; the label's colour or
/// a custom one only where the person chose that for the host.
void main() {
  const blue = Color(0xFF3B82F6);
  const pink = Color(0xFFEC4899);

  group('the rule', () {
    test('nothing chosen is the icon\'s own colour, whatever the label', () {
      expect(HostIconColor.tint(null, labelColor: blue), isNull);
      expect(HostIconColor.tint(null, labelColor: null), isNull);
    });

    test('following the label is the label\'s colour, and the icon\'s own while the host has none', () {
      expect(HostIconColor.tint(HostIconColor.followsLabel, labelColor: blue), blue);
      expect(HostIconColor.tint(HostIconColor.followsLabel, labelColor: null), isNull);
    });

    test('a custom colour is that colour, whatever the label', () {
      final stored = HostIconColor.custom(pink);
      expect(HostIconColor.tint(stored, labelColor: blue), pink);
      expect(HostIconColor.tint(stored, labelColor: null), pink);
    });

    test('a custom colour is stored opaque, so it is never taken for another choice', () {
      expect(HostIconColor.custom(pink), 0xFFEC4899);
      expect(HostIconColor.custom(const Color(0x33EC4899)), 0xFFEC4899, reason: 'see-through is made opaque');
      expect(HostIconColor.custom(const Color(0x00000000)), 0xFF000000, reason: 'black is black, not "the label"');
      expect(HostIconColor.custom(const Color(0xFF000000)), isNot(HostIconColor.followsLabel));
      expect(HostIconColor.followsLabel, 0);
    });

    test('which choice a number is', () {
      expect(HostIconColor.isCustom(null), isFalse);
      expect(HostIconColor.isCustom(HostIconColor.followsLabel), isFalse);
      expect(HostIconColor.isCustom(0xFFEC4899), isTrue);
      expect(HostIconColor.customColor(null), isNull);
      expect(HostIconColor.customColor(HostIconColor.followsLabel), isNull);
      expect(HostIconColor.customColor(0xFFEC4899), pink);
    });

    test('every number is a colour that can be seen: one that was not written here is drawn opaque', () {
      expect(HostIconColor.customColor(5), const Color(0xFF000005));
      expect(HostIconColor.customColor(0x00EC4899), pink, reason: 'no alpha is not invisible');
      expect(HostIconColor.tint(0x10EC4899, labelColor: blue), pink);
    });

    test('from outside the app: a number a colour can be is kept as it is, anything else is the icon\'s own', () {
      // What the app writes comes back unchanged, so a sync round trip is stable.
      for (final written in [null, HostIconColor.followsLabel, HostIconColor.custom(pink), 0xFFFFFFFF, 0xFF000000]) {
        expect(HostIconColor.fromOutside(written), written);
      }
      expect(HostIconColor.fromOutside(1), 1);
      expect(HostIconColor.fromOutside(-1), isNull);
      expect(HostIconColor.fromOutside(0x100000000), isNull);
      expect(HostIconColor.fromOutside('4293740697'), isNull);
      expect(HostIconColor.fromOutside(4293740697.0), isNull);
      expect(HostIconColor.fromOutside(true), isNull);
      expect(HostIconColor.fromOutside(const [0]), isNull);
    });
  });

  group('a colour that can be seen', () {
    tearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

    double held(Color c) => ZestColors.contrast(c, OsIcon.tileOf(c));
    double hue(Color c) => HSLColor.fromColor(c).hue;
    double lightness(Color c) => HSLColor.fromColor(c).lightness;

    test('what "seen" is measured by: three to one against the tile the glyph sits on, on a host\'s card', () {
      expect(OsIcon.seenAt, 3.0);
      expect(OsIcon.tileAlpha, 0.18);
      for (final themeId in ['default_dark', 'default_light']) {
        AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
        const c = Color(0xFF3B82F6);
        expect(OsIcon.tileOf(c), Color.alphaBlend(c.withValues(alpha: 0.18), ZestColors.bgSurface), reason: themeId);
      }
    });

    test('on a dark theme a brand\'s dark colour is a lighter shade of itself, and one that shows is itself', () {
      AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
      for (final id in ['debian', 'alma', 'centos', 'alpine', 'gentoo', 'freebsd']) {
        final brand = OsCatalog.get(id).brandColor;
        final own = OsIcon.ownColor(OsCatalog.get(id));
        expect(held(brand), lessThan(OsIcon.seenAt), reason: '$id: the brand\'s own could not be made out');
        expect(held(own), greaterThanOrEqualTo(OsIcon.seenAt), reason: id);
        expect(lightness(own), greaterThan(lightness(brand)), reason: '$id: lighter');
        expect(hue(own), closeTo(hue(brand), 1.5), reason: '$id: the same hue');
        expect(held(own), lessThan(OsIcon.seenAt + 0.2), reason: '$id: no further than needed');
      }
      for (final id in ['ubuntu', 'fedora', 'rhel', 'arch', 'windows']) {
        expect(OsIcon.ownColor(OsCatalog.get(id)), OsCatalog.get(id).brandColor, reason: '$id shows as it is');
      }
    });

    test('on a light theme a pale colour is a darker shade of itself', () {
      AppColors.applyTheme(BuiltInThemes.getById('default_light').colorScheme);
      for (final id in ['macos', 'ubuntu', 'openbsd', 'mint', 'cloud']) {
        final brand = OsCatalog.get(id).brandColor;
        final own = OsIcon.ownColor(OsCatalog.get(id));
        expect(held(brand), lessThan(OsIcon.seenAt), reason: '$id: too pale on a light theme');
        expect(held(own), greaterThanOrEqualTo(OsIcon.seenAt), reason: id);
        expect(lightness(own), lessThan(lightness(brand)), reason: '$id: darker');
      }
      // What is dark enough is left alone.
      for (final id in ['debian', 'alma', 'gentoo']) {
        expect(OsIcon.ownColor(OsCatalog.get(id)), OsCatalog.get(id).brandColor, reason: id);
      }
    });

    test('on every built-in theme every icon of the catalog can be seen in its own colour', () {
      final catalog = OsCatalog.search('');
      expect(catalog.length, greaterThan(150));
      for (final theme in BuiltInThemes.all) {
        AppColors.applyTheme(theme.colorScheme);
        for (final d in catalog) {
          final own = OsIcon.ownColor(d);
          expect(held(own), greaterThanOrEqualTo(OsIcon.seenAt), reason: '${theme.id}: ${d.id}');
          if (held(d.brandColor) >= OsIcon.seenAt) {
            expect(own, d.brandColor, reason: '${theme.id}: ${d.id} already shows and is left as it is');
          }
        }
      }
    });

    test('a colour someone chose is drawn as chosen where it shows, and in a shade that shows where it does not', () {
      AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
      for (final preset in [...AppColors.labelPalette, ...AppColors.connectionLabelColors]) {
        if (held(preset) >= OsIcon.seenAt) expect(OsIcon.seen(preset), preset);
      }
      expect(OsIcon.seen(const Color(0xFFFFEB3B)), const Color(0xFFFFEB3B), reason: 'yellow on a dark theme');
      const navy = Color(0xFF0A1A4A);
      expect(held(OsIcon.seen(navy)), greaterThanOrEqualTo(OsIcon.seenAt));
      expect(lightness(OsIcon.seen(navy)), greaterThan(lightness(navy)));

      AppColors.applyTheme(BuiltInThemes.getById('default_light').colorScheme);
      const yellow = Color(0xFFFFEB3B);
      expect(held(yellow), lessThan(1.5), reason: 'yellow on a light theme is all but invisible');
      expect(held(OsIcon.seen(yellow)), greaterThanOrEqualTo(OsIcon.seenAt));
      expect(hue(OsIcon.seen(yellow)), closeTo(hue(yellow), 1.5));
      expect(OsIcon.seen(navy), navy, reason: 'navy on a light theme shows');
    });

    test('what is drawn stays what it is: seen again, it is the same', () {
      for (final themeId in ['default_dark', 'default_light', 'nord']) {
        AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
        for (final c in [const Color(0xFF0A1A4A), const Color(0xFFFFEB3B), const Color(0xFFA81D33), const Color(0xFF808080)]) {
          expect(OsIcon.seen(OsIcon.seen(c)), OsIcon.seen(c), reason: themeId);
        }
      }
    });

    test('black on a dark theme and white on a light one still become something that shows', () {
      AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
      expect(held(OsIcon.seen(const Color(0xFF000000))), greaterThanOrEqualTo(OsIcon.seenAt));
      AppColors.applyTheme(BuiltInThemes.getById('default_light').colorScheme);
      expect(held(OsIcon.seen(const Color(0xFFFFFFFF))), greaterThanOrEqualTo(OsIcon.seenAt));
    });
  });

  group('the icon as drawn', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

    Color glyph(WidgetTester tester) {
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      final filter = svg.colorFilter!;
      for (final c in [blue, pink, OsIcon.ownColor(OsCatalog.get('debian')), OsIcon.ownColor(OsCatalog.get('ubuntu'))]) {
        if (filter == ColorFilter.mode(c, BlendMode.srcIn)) return c;
      }
      fail('the glyph is in none of the colours of this test: $filter');
    }

    Color tile(WidgetTester tester) {
      final box = tester.widget<Container>(find.descendant(of: find.byType(OsIcon), matching: find.byType(Container)));
      return (box.decoration! as BoxDecoration).color!;
    }

    // As drawn on the theme the tests run on: a shade of the brand's that shows.
    final debian = OsIcon.ownColor(OsCatalog.get('debian'));

    testWidgets('a chosen icon is in its own colour by default, also on a host that has a colour', (tester) async {
      expect(debian, isNot(blue), reason: 'or the test would tell nothing');
      await tester.pumpWidget(wrap(const HostIcon(iconId: 'debian', labelColor: blue)));
      expect(glyph(tester), debian);
      expect(tile(tester), debian.withValues(alpha: 0.18));
    });

    testWidgets('the icon of the detected system follows the same rule', (tester) async {
      final ubuntu = OsIcon.ownColor(OsCatalog.get('ubuntu'));
      await tester.pumpWidget(wrap(const HostIcon(osId: 'ubuntu', labelColor: blue)));
      expect(glyph(tester), ubuntu);
      await tester.pumpWidget(
          wrap(const HostIcon(osId: 'ubuntu', iconColor: HostIconColor.followsLabel, labelColor: blue)));
      expect(glyph(tester), blue);
    });

    testWidgets('following the label it is in the label\'s colour, glyph and tile', (tester) async {
      await tester.pumpWidget(
          wrap(const HostIcon(iconId: 'debian', iconColor: HostIconColor.followsLabel, labelColor: blue)));
      expect(glyph(tester), blue);
      expect(tile(tester), blue.withValues(alpha: 0.18));
    });

    testWidgets('following the label of a host that has no colour it keeps its own', (tester) async {
      await tester.pumpWidget(wrap(const HostIcon(iconId: 'debian', iconColor: HostIconColor.followsLabel)));
      expect(glyph(tester), debian);
    });

    testWidgets('a custom colour wins over the label', (tester) async {
      await tester.pumpWidget(wrap(HostIcon(iconId: 'debian', iconColor: HostIconColor.custom(pink), labelColor: blue)));
      expect(glyph(tester), pink);
      expect(tile(tester), pink.withValues(alpha: 0.18));
    });

    testWidgets('a colour that cannot be seen on the theme is drawn in a shade that can, glyph and tile', (tester) async {
      const navy = Color(0xFF0A1A4A);
      expect(OsIcon.seen(navy), isNot(navy), reason: 'navy on a dark theme');
      await tester.pumpWidget(wrap(HostIcon(iconId: 'debian', iconColor: HostIconColor.custom(navy))));
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.colorFilter, ColorFilter.mode(OsIcon.seen(navy), BlendMode.srcIn));
      expect(tile(tester), OsIcon.seen(navy).withValues(alpha: 0.18));
      // And the same for the colour of a label.
      await tester.pumpWidget(
          wrap(const HostIcon(iconId: 'debian', iconColor: HostIconColor.followsLabel, labelColor: navy)));
      expect(tester.widget<SvgPicture>(find.byType(SvgPicture)).colorFilter,
          ColorFilter.mode(OsIcon.seen(navy), BlendMode.srcIn));
    });

    testWidgets('an uploaded picture is shown as it is, whatever was chosen', (tester) async {
      // A 1x1 PNG.
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      await tester.pumpWidget(
          wrap(HostIcon(iconId: 'debian', customIcon: png, iconColor: HostIconColor.custom(pink), labelColor: blue)));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(SvgPicture), findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.color, isNull, reason: 'no tint over a picture');
    });
  });
}
