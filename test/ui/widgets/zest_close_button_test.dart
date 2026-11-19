import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/ui_density.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_close_button.dart';

// The editors' close button (the host editor's header, the detail panes'): in
// the danger colour of the theme in use, 32 square with a mouse and pressed
// in a finger's 48 where the controls are touch sized, named Close for a
// screen reader and a tooltip, reached with Tab and pressed with Enter.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> pump(WidgetTester tester, VoidCallback? onPressed, {String themeId = 'default_dark', bool touch = false}) async {
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final data = theme.toThemeData();
    await tester.pumpWidget(MaterialApp(
      theme: data.copyWith(extensions: [...data.extensions.values.where((e) => e is! ZestDensity), ZestDensity(touch: touch)]),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Center(child: ZestCloseButton(key: const ValueKey('close'), onPressed: onPressed)),
      ),
    ));
  }

  for (final themeId in const ['default_dark', 'default_light']) {
    testWidgets('red in every theme ($themeId), 32 square, larger than the old 16 glyph', (tester) async {
      await pump(tester, () {}, themeId: themeId);
      final icon = tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('close')), matching: find.byType(Icon)));
      expect(icon.color, ZestTokens.statusCritical);
      expect(icon.size, greaterThanOrEqualTo(20));
      final box = find.descendant(of: find.byKey(const ValueKey('close')), matching: find.byType(Container)).first;
      expect(tester.getSize(box), const Size(32, 32));
    });
  }

  testWidgets('a button named Close, with its tooltip', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, () {});
    expect(
      tester.getSemantics(find.bySemanticsLabel(en.close)),
      isSemantics(label: en.close, isButton: true, hasTapAction: true, isEnabled: true, hasEnabledState: true, isFocusable: true),
    );
    expect(find.byTooltip(en.close), findsOneWidget);
    handle.dispose();
  });

  testWidgets("a finger's 48 where the controls are touch sized", (tester) async {
    await pump(tester, () {}, touch: true);
    final size = tester.getSize(find.byKey(const ValueKey('close')));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('Tab rings it and Enter presses it; a click presses it', (tester) async {
    var pressed = 0;
    await pump(tester, () => pressed++);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.descendant(of: find.byKey(const ValueKey('close')), matching: find.byKey(ZestFocusRing.ringKey)),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pressed, 1);
    await tester.tap(find.byKey(const ValueKey('close')));
    await tester.pump();
    expect(pressed, 2);
  });

  testWidgets('the tint deepens under the pointer', (tester) async {
    await pump(tester, () {});
    Color fill() => ((tester.widget<Container>(
                    find.descendant(of: find.byKey(const ValueKey('close')), matching: find.byType(Container)).first))
                .decoration! as BoxDecoration)
            .color!;
    final before = fill().a;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('close'))));
    await tester.pump();
    expect(fill().a, greaterThan(before));
  });
}
