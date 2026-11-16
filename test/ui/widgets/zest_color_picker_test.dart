import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    );

const _presets = [
  Color(0xFFFF7A1A),
  Color(0xFF3B82F6),
  Color(0xFF10B981),
];

void main() {
  group('ZestColorPicker.parseHex', () {
    test('#RRGGBB and RRGGBB parse to the same color', () {
      final withHash = ZestColorPicker.parseHex('#FF7A1A');
      final withoutHash = ZestColorPicker.parseHex('FF7A1A');
      expect(withHash, isNotNull);
      expect(withoutHash, isNotNull);
      expect(withHash!.toARGB32(), withoutHash!.toARGB32());
      expect(withHash.toARGB32(), 0xFFFF7A1A);
    });

    test('is case-insensitive', () {
      expect(
        ZestColorPicker.parseHex('ff7a1a')!.toARGB32(),
        ZestColorPicker.parseHex('FF7A1A')!.toARGB32(),
      );
    });

    test('invalid string returns null and does not throw', () {
      expect(() => ZestColorPicker.parseHex('nothex'), returnsNormally);
      expect(ZestColorPicker.parseHex('nothex'), isNull);
      expect(ZestColorPicker.parseHex(''), isNull);
      expect(ZestColorPicker.parseHex('#12'), isNull);
    });

    test('short #RGB / RGB forms expand to opaque RRGGBB', () {
      expect(ZestColorPicker.parseHex('#F00')!.toARGB32(), 0xFFFF0000);
      expect(ZestColorPicker.parseHex('0f0')!.toARGB32(), 0xFF00FF00);
      expect(ZestColorPicker.parseHex('#ABC')!.toARGB32(), 0xFFAABBCC);
    });

    test('8-digit (alpha) forms are now rejected', () {
      expect(ZestColorPicker.parseHex('#80FF7A1A'), isNull);
      expect(ZestColorPicker.parseHex('FF7A1A80'), isNull);
    });

    test('hexOf is always opaque #RRGGBB (alpha stripped)', () {
      expect(ZestColorPicker.hexOf(const Color(0xFFFF7A1A)), '#FF7A1A');
      expect(ZestColorPicker.hexOf(const Color(0x8012AB34)), '#12AB34');
    });
  });

  group('recent custom colors persistence', () {
    testWidgets('round-trips through shared_preferences', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ZestColorPicker.addRecentCustom(const Color(0xFFFF7A1A));
      await ZestColorPicker.addRecentCustom(const Color(0xFF3B82F6));

      final loaded = await ZestColorPicker.loadRecentCustom();
      // Newest first, both present.
      expect(loaded.first.toARGB32(), 0xFF3B82F6);
      expect(loaded.map((c) => c.toARGB32()), contains(0xFFFF7A1A));
    });

    testWidgets('dedups and caps at maxRecentColors', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // Add the same color twice, then more than the cap.
      await ZestColorPicker.addRecentCustom(const Color(0xFFFF7A1A));
      await ZestColorPicker.addRecentCustom(const Color(0xFFFF7A1A));
      for (var i = 0; i < ZestColorPicker.maxRecentColors + 3; i++) {
        await ZestColorPicker.addRecentCustom(Color(0xFF000000 + i));
      }
      final loaded = await ZestColorPicker.loadRecentCustom();
      expect(loaded.length, ZestColorPicker.maxRecentColors);
      expect(loaded.map((c) => c.toARGB32()).toSet().length, loaded.length);
    });

    testWidgets('reads pre-seeded values', (tester) async {
      SharedPreferences.setMockInitialValues({
        ZestColorPicker.recentColorsPrefsKey: [
          const Color(0xFFFF7A1A).toARGB32().toString(),
        ],
      });
      final loaded = await ZestColorPicker.loadRecentCustom();
      expect(loaded.single.toARGB32(), 0xFFFF7A1A);
    });
  });

  group('selection', () {
    testWidgets('selected preset pops with a check affordance',
        (tester) async {
      await tester.pumpWidget(_host(ZestColorPicker(
        presets: _presets,
        selected: _presets[1],
        onChanged: (_) {},
      )));

      // Exactly one selected swatch, and it carries the ✓ affordance.
      expect(find.byKey(const ValueKey('zest-color-picker-selected')),
          findsOneWidget);
      expect(find.byIcon(LucideIcons.check), findsOneWidget);
    });

    testWidgets('tapping a preset fires onChanged with that color',
        (tester) async {
      Color? picked;
      await tester.pumpWidget(_host(ZestColorPicker(
        presets: _presets,
        selected: _presets[0],
        onChanged: (c) => picked = c,
      )));
      // Tap the third preset (its GestureDetector, scoped to this widget so
      // app-level detectors don't shift the index).
      await tester.tap(
        find
            .descendant(
              of: find.byType(ZestColorPicker),
              matching: find.byType(GestureDetector),
            )
            .at(2),
      );
      await tester.pump();
      expect(picked?.toARGB32(), _presets[2].toARGB32());
    });

    testWidgets('None swatch fires onNoneSelected and suppresses preset ring',
        (tester) async {
      var noneTapped = false;
      await tester.pumpWidget(_host(ZestColorPicker(
        presets: _presets,
        selected: _presets[0],
        onChanged: (_) {},
        allowNone: true,
        noneSelected: true,
        onNoneSelected: () => noneTapped = true,
      )));

      // None swatch present; because it is selected, NO preset shows its ring.
      expect(find.byKey(const ValueKey('zest-color-picker-none')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('zest-color-picker-selected')),
          findsNothing);

      await tester.tap(find.byKey(const ValueKey('zest-color-picker-none')));
      await tester.pump();
      expect(noneTapped, isTrue);
    });
  });

  group('custom popover - hex field', () {
    testWidgets('invalid hex shows the error, does not throw, reverts on blur',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(_host(const ZestColorPicker(
        presets: _presets,
        selected: Color(0xFFFF7A1A),
        onChanged: _noop,
      )));

      await tester
          .tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
      await tester.pumpAndSettle();

      final hexField = find.byKey(const ValueKey('zest-color-picker-hex-field'));
      expect(hexField, findsOneWidget);
      // Seeded from the initial color.
      expect((tester.widget<TextField>(hexField)).controller!.text, '#FF7A1A');

      await tester.enterText(hexField, 'nothex');
      await tester.pump();
      // Inline invalid message appears.
      expect(find.text('Enter a valid hex color'), findsOneWidget);

      // Blur (without tapping outside, which would commit-and-close).
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      // Reverted to the last valid value; error cleared; nothing thrown.
      expect((tester.widget<TextField>(hexField)).controller!.text, '#FF7A1A');
      expect(find.text('Enter a valid hex color'), findsNothing);
    });

    testWidgets('valid hex entry updates the working color', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(_host(const ZestColorPicker(
        presets: _presets,
        selected: Color(0xFFFF7A1A),
        onChanged: _noop,
      )));
      await tester
          .tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
      await tester.pumpAndSettle();

      final hexField = find.byKey(const ValueKey('zest-color-picker-hex-field'));
      await tester.enterText(hexField, '3B82F6');
      await tester.pump();
      // No error for a valid value.
      expect(find.text('Enter a valid hex color'), findsNothing);
      // R/G/B steppers reflect the parsed color (0x3B, 0x82, 0xF6).
      expect(find.text('${0x3B}'), findsOneWidget);
      expect(find.text('${0x82}'), findsOneWidget);
      expect(find.text('${0xF6}'), findsOneWidget);
    });

    testWidgets('Enter commits the current color and closes', (tester) async {
      SharedPreferences.setMockInitialValues({});
      Color? committed;
      await tester.pumpWidget(_host(ZestColorPicker(
        presets: _presets,
        selected: const Color(0xFFFF7A1A),
        onChanged: (c) => committed = c,
      )));
      await tester
          .tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('zest-color-picker-hex-field')), '3B82F6');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(committed?.toARGB32(), 0xFF3B82F6);
      // Popover closed.
      expect(find.byKey(const ValueKey('zest-color-picker-hex-field')),
          findsNothing);
    });
  });
}

void _noop(Color _) {}
