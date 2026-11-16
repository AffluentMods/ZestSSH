// The app theme picker on a computer (4.0, a theme gallery).
// It was a dropdown of 18 names with three
// tiny swatches each, open over half the page: a theme could not be seen
// before it was picked, and the phone already had a gallery. Now each theme
// is a card drawn in its own colours (its sidebar, a card with its accent, a
// terminal line in its paired terminal colours); the one in use has the
// accent's border and a check, and is said as chosen; three rows show until
// Show all N; the cards are reached and picked by keyboard. Under them,
// Custom theme with the Squeezed tag (a tap says what Squeezed is, in the
// plan popover; a team member is not shown it) and Open theme designer.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/app_theme_gallery.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_dock.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';

import '../visual/shots_util.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  var fontsLoaded = false;
  late ProviderContainer container;

  Finder k(String key) => find.byKey(ValueKey(key));

  /// Settings' Appearance, as a computer shows it, with a theme of one's own.
  Future<void> pumpAppearance(WidgetTester tester,
      {String themeId = 'graphite', bool pro = true, bool followSystem = false, List<Override> extra = const []}) async {
    if (!fontsLoaded) {
      await tester.runAsync(loadShotFonts);
      fontsLoaded = true;
    }
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId, 'follow_system_theme': followSystem});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1100, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(pro)),
      ...extra,
    ]);
    addTearDown(container.dispose);
    final base = BuiltInThemes.getById('nord');
    await container.read(customAppThemesProvider.notifier).save(ZestTheme(
          id: 'custom_app_1',
          name: 'Harbor Night',
          brightness: base.brightness,
          colorScheme: base.colorScheme.copyWith(id: 'custom_app_1', name: 'Harbor Night'),
        ));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: BuiltInThemes.getById('graphite').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: SettingsInlineView()),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.settingsInlineSectionAppearance).first);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  final builtIn = BuiltInThemes.all;
  final total = builtIn.length + 1;

  testWidgets('the app theme is a gallery: a card for each theme, three rows of four until Show all, the one in use '
      'checked; the dropdown is gone', (tester) async {
    await pumpAppearance(tester);
    expect(find.text(en.settingsInlineAppTheme), findsOneWidget);
    expect(find.text(en.settingsInlineAppThemeGalleryDesc), findsOneWidget);
    // Three rows of four, in the order themes are listed, and the rest folded.
    for (final t in builtIn.take(12)) {
      expect(k('app-theme-${t.id}'), findsOneWidget, reason: t.id);
    }
    for (final t in builtIn.skip(12)) {
      expect(k('app-theme-${t.id}'), findsNothing, reason: t.id);
    }
    final first = tester.getTopLeft(k('app-theme-${builtIn[0].id}'));
    expect(tester.getTopLeft(k('app-theme-${builtIn[3].id}')).dy, first.dy);
    expect(tester.getTopLeft(k('app-theme-${builtIn[4].id}')).dx, first.dx);
    expect(tester.getTopLeft(k('app-theme-${builtIn[4].id}')).dy, greaterThan(first.dy));
    // The one in use: its card has the check (not colour alone).
    expect(find.descendant(of: k('app-theme-graphite'), matching: k('app-theme-check')), findsOneWidget);
    expect(k('app-theme-check'), findsOneWidget);
    // Show all N, every theme there is, a theme of one's own among them.
    expect(find.text(en.settingsInlineThemesShowAll(total)), findsOneWidget);
    await tester.tap(k('app-theme-show-all'));
    await tester.pumpAndSettle();
    for (final t in builtIn) {
      expect(k('app-theme-${t.id}'), findsOneWidget, reason: t.id);
    }
    expect(k('app-theme-custom_app_1'), findsOneWidget);
    expect(find.descendant(of: k('app-theme-custom_app_1'), matching: find.text(en.settingsInlineCustomBadge)), findsOneWidget);
    expect(find.text(en.settingsInlineThemesShowFewer), findsOneWidget);
    await tester.tap(k('app-theme-show-all'));
    await tester.pumpAndSettle();
    expect(k('app-theme-custom_app_1'), findsNothing);
    // The old dropdown of names with swatches: no select is left in its place.
    expect(find.text('Harbor Night'), findsNothing);
    await finish(tester);
  });

  testWidgets('a card picks its theme as the dropdown did: the terminal follows while matched, and Follow system theme '
      'stops', (tester) async {
    await pumpAppearance(tester, followSystem: true);
    expect(find.text(en.settingsInlineAppThemeFollowingDesc), findsOneWidget, reason: 'said while following');
    await tester.tap(k('app-theme-dracula'));
    await tester.pumpAndSettle();
    expect(container.read(appThemeIdProvider), 'dracula');
    expect(container.read(followSystemThemeProvider), isFalse);
    expect(container.read(terminalThemeIdProvider), kAppToTerminalThemeId['dracula']);
    expect(find.descendant(of: k('app-theme-dracula'), matching: k('app-theme-check')), findsOneWidget);
    expect(find.descendant(of: k('app-theme-graphite'), matching: k('app-theme-check')), findsNothing);
    await finish(tester);
  });

  testWidgets('a theme in use past the first rows: the gallery opens with it in sight', (tester) async {
    await pumpAppearance(tester, themeId: builtIn.last.id);
    expect(k('app-theme-${builtIn.last.id}'), findsOneWidget);
    expect(find.descendant(of: k('app-theme-${builtIn.last.id}'), matching: k('app-theme-check')), findsOneWidget);
    expect(find.text(en.settingsInlineThemesShowFewer), findsOneWidget);
    await finish(tester);
  });

  testWidgets('by keyboard: a card takes the focus, the arrow keys move along the row, and Enter picks', (tester) async {
    await pumpAppearance(tester);
    Focus.of(tester.element(find.descendant(of: k('app-theme-graphite'), matching: find.byType(GestureDetector)).first))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final next = builtIn[2].id;
    expect(
        Focus.of(tester.element(find.descendant(of: k('app-theme-$next'), matching: find.byType(GestureDetector)).first))
            .hasFocus,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(container.read(appThemeIdProvider), next);
    await finish(tester);
  });

  testWidgets('a screen reader hears each card as a button with its theme, the one in use as chosen', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAppearance(tester);
    expect(tester.getSemantics(k('app-theme-graphite')),
        isSemantics(isButton: true, isSelected: true, isInMutuallyExclusiveGroup: true, label: 'Graphite'));
    expect(tester.getSemantics(k('app-theme-nord')), isSemantics(isButton: true, isSelected: false, label: 'Nord'));
    semantics.dispose();
    await finish(tester);
  });

  test('each card draws its theme with the terminal colours paired with it; a theme of one\'s own, its own', () {
    for (final t in builtIn) {
      final paired = AppThemePreview.pairedTerminal(t);
      expect(paired, isNotNull, reason: t.id);
      expect(paired, same(TerminalThemes.all[kAppToTerminalThemeId[t.id]]), reason: t.id);
    }
    final base = BuiltInThemes.getById('nord');
    expect(
        AppThemePreview.pairedTerminal(ZestTheme(
            id: 'custom_app_1', name: 'Harbor Night', brightness: base.brightness, colorScheme: base.colorScheme)),
        isNull);
  });

  testWidgets('Custom theme: the Squeezed tag says what Squeezed is, in the plan popover; Open theme '
      'designer opens the designer beside Settings', (tester) async {
    await pumpAppearance(tester);
    expect(find.text(en.settingsInlineCustomTheme), findsOneWidget);
    expect(find.text(en.settingsInlineCustomThemeDescSaved(1)), findsOneWidget);
    // (The list of pages says Squeezed beside Plan too, 4.0.)
    expect(find.descendant(of: k('plan-chip-squeezed'), matching: find.text(en.narrowSidebarTierSqueezed)), findsOneWidget);
    await tester.tap(k('plan-chip-squeezed'));
    await tester.pumpAndSettle();
    // What the account has, and what each plan is.
    expect(k('plan-popover'), findsOneWidget);
    expect(find.descendant(of: k('plan-popover'), matching: find.text(en.planPopoverTitle(en.narrowSidebarTierSqueezed))),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(k('plan-popover'), findsNothing);
    await tester.tap(find.text(en.settingsInlineOpenThemeDesigner).first);
    await tester.pumpAndSettle();
    expect(container.read(settingsDockProvider), SettingsDock.appThemeDesigner);
    await finish(tester);
  });

  testWidgets('a free plan: Unlock with Squeezed in its place, and what Squeezed unlocks', (tester) async {
    await pumpAppearance(tester, pro: false);
    expect(find.text(en.settingsInlineCustomAppThemesDescFree), findsOneWidget);
    expect(find.text(en.deskUnlockWithSqueezed), findsWidgets);
    expect(k('plan-chip-squeezed'), findsOneWidget);
    await finish(tester);
  });

  testWidgets("a team's member is not shown the plan's name", (tester) async {
    await pumpAppearance(tester, extra: [
      orchardSummariesProvider.overrideWith((ref) async => [OrchardSummary.closedOffline('o-demo')]),
    ]);
    expect(find.text(en.settingsInlineCustomTheme), findsOneWidget);
    expect(k('plan-chip-squeezed'), findsNothing);
    await finish(tester);
  });
}
