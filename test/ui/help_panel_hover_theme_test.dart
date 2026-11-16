import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';

/// Fixes spec, section 1: a hovered Help row must stay readable on every
/// theme. The bug was a hover overlay authored as the theme's TEXT colour at
/// low alpha, flattened to opaque, so the fill became the label's own colour.
/// This checks the class of mistake, not the instance: on every built-in
/// theme plus a deliberately hostile scheme, no row fill is a text token and
/// the hovered label keeps a WCAG contrast of at least 4.5 against it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() => AppColors.applyTheme(BuiltInThemes.defaultTheme.colorScheme));

  Widget harness() => ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          helpDockProvider.overrideWith((_) => HelpPage.home),
          cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
          appVersionLabelProvider.overrideWith((_) async => '1.9.7'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Row(
              children: [
                const Expanded(child: SizedBox()),
                HelpDock(
                  captureScreenshot: ({required bool redacted}) async =>
                      Uint8List(0),
                  onCopyRedactedScreenshot: () {},
                  onOpenShortcuts: () {},
                  onAbout: () {},
                ),
              ],
            ),
          ),
        ),
      );

  // The hostile case: hover authored as the text colour at
  // 5% alpha, on a dark pane. Flattening it to opaque yields the text colour.
  final hostile = ZestTheme(
    id: 'hostile_hover',
    name: 'Hostile hover',
    brightness: Brightness.dark,
    colorScheme: BuiltInThemes.defaultTheme.colorScheme.copyWith(
      hover: const Color(0x0DF8F8F2),
      onSurface: const Color(0xFFF8F8F2),
    ),
  );

  Finder rows() =>
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_HelpRow');

  Color rowFill(WidgetTester tester, Finder row) {
    final container = tester.widget<Container>(find
        .descendant(of: row, matching: find.byType(Container))
        .first);
    return container.color ?? Colors.transparent;
  }

  Color rowLabel(WidgetTester tester, Finder row) {
    final text =
        tester.widget<Text>(find.descendant(of: row, matching: find.byType(Text)).first);
    return text.style?.color ?? Colors.black;
  }

  for (final theme in [...BuiltInThemes.all, hostile]) {
    testWidgets('hovered Help rows stay readable on ${theme.name}',
        (tester) async {
      AppColors.applyTheme(theme.colorScheme);
      final cs = theme.colorScheme;
      final textTokens = {
        cs.onSurface.toARGB32(),
        cs.onSurfaceMuted.toARGB32(),
        cs.onBackground.toARGB32(),
        cs.onBackgroundMuted.toARGB32(),
        cs.onBackgroundSubtle.toARGB32(),
      };

      await tester.binding.setSurfaceSize(const Size(1200, 900));
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(rows(), findsAtLeast(8));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      final count = tester.widgetList(rows()).length;
      for (var i = 0; i < count; i++) {
        final row = rows().at(i);
        await tester.ensureVisible(row);
        // The panel's rows scroll at this height: the row is where it was
        // brought once a frame has laid it out.
        await tester.pump();
        await gesture.moveTo(tester.getCenter(row));
        await tester.pump();

        final bg = rowFill(tester, row);
        final fg = rowLabel(tester, row);
        expect(bg.a, 1.0, reason: 'hover fill is opaque on ${theme.name}');
        expect(textTokens, isNot(contains(bg.toARGB32())),
            reason: 'row $i background is a text token on ${theme.name}');
        expect(AppColors.contrastRatio(fg, bg), greaterThan(4.5),
            reason: 'row $i hovered label is unreadable on ${theme.name}: '
                'fg ${fg.toARGB32().toRadixString(16)} on '
                'bg ${bg.toARGB32().toRadixString(16)} '
                '(onSurface ${cs.onSurface.toARGB32().toRadixString(16)}, '
                'surface ${cs.surface.toARGB32().toRadixString(16)}, '
                'hover ${cs.hover.toARGB32().toRadixString(16)})');
      }

      // Back at rest the fill goes away again; the resting label is the
      // theme's own muted text, whose contrast is the theme's business.
      await gesture.moveTo(Offset.zero);
      await tester.pump();
      expect(rowFill(tester, rows().first), Colors.transparent,
          reason: 'hover fill lingers on ${theme.name}');
    });
  }

  test('the flattened overlay that caused the bug is what the fix rejects',
      () {
    // What the old code did: strip the alpha. That is the text colour.
    const overlay = Color(0x0DF8F8F2);
    expect(overlay.withValues(alpha: 1.0).toARGB32(), 0xFFF8F8F2);
    // What the fix does: composite onto the pane. One step up, still dark.
    final blended =
        Color.alphaBlend(overlay, const Color(0xFF282A36)); // Dracula pane
    expect(blended.toARGB32(), isNot(0xFFF8F8F2));
    expect(AppColors.contrastRatio(const Color(0xFFF8F8F2), blended),
        greaterThan(4.5));
  });
}
