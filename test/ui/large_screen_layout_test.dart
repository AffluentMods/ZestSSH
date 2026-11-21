import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart' show largeScreenLayoutProvider;
import 'package:zestssh/router/router.dart' show AppHome;
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/ui_density.dart';
import 'package:zestssh/ui/screens/desktop/desktop_shell.dart';
import 'package:zestssh/ui/screens/desktop/widgets/narrow_sidebar.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/widgets/window_bar.dart' show WindowControls;
import 'package:zestssh/utils/platform_utils.dart';

import '../helpers/quick_wins_fixture.dart';

/// The large-screen layout (4.0, as
/// designed): a phone or a tablet
/// whose shortest side is 600 or more and which is 840 or more wide has the
/// computer's shell at touch size; phones keep their tabs and a small tablet
/// upright the tablet's. The controls' size follows Settings' density, Auto
/// following the input.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();

  group('the size rule', () {
    test('a large screen: 600 or more on its shortest side, 840 or more wide', () {
      expect(isLargeScreen(const Size(1024, 1366)), isTrue, reason: 'an iPad Pro 12.9 upright');
      expect(isLargeScreen(const Size(1366, 1024)), isTrue, reason: 'and sideways');
      expect(isLargeScreen(const Size(1280, 800)), isTrue, reason: 'a 10 inch Android tablet sideways');
      expect(isLargeScreen(const Size(800, 1280)), isFalse, reason: 'upright it is 800 wide');
      expect(isLargeScreen(const Size(834, 1194)), isFalse, reason: 'an iPad Pro 11 upright: 834 wide');
      expect(isLargeScreen(const Size(932, 430)), isFalse, reason: 'a phone sideways: 430 on its short side');
      expect(isLargeScreen(const Size(430, 932)), isFalse);
      expect(isLargeScreen(const Size(840, 600)), isTrue, reason: 'both edges are in');
      expect(isLargeScreen(const Size(839, 600)), isFalse);
      expect(isLargeScreen(const Size(900, 599)), isFalse);
    });

    test('a computer is always the shell; a phone or a tablet only on a large screen', () {
      debugTouchLayout = false;
      addTearDown(() => debugTouchLayout = null);
      expect(desktopShellInUse, isTrue);
      debugTouchLayout = true;
      expect(desktopShellInUse, isFalse, reason: 'no shell stands on the touch screen yet');
      touchDesktopShells++;
      addTearDown(() => touchDesktopShells = 0);
      expect(desktopShellInUse, isTrue);
    });
  });

  group('Home by the screen', () {
    for (final (name, size, shell) in [
      ('an iPad Pro 12.9 upright', const Size(1024, 1366), true),
      ('a tablet sideways', const Size(1280, 800), true),
      ('a 10 inch tablet upright (800 wide)', const Size(800, 1280), false),
      ('a phone', quickWinsPhone, false),
    ]) {
      testWidgets('$name: ${shell ? "the computer's shell" : "the tabs"}', (tester) async {
        debugTouchLayout = true;
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpQuickWins(tester, const AppHome(), size);
          expect(find.byType(DesktopShell), shell ? findsOneWidget : findsNothing);
          expect(find.byType(HomeScreen), shell ? findsNothing : findsOneWidget);
          if (shell) {
            // An app bar, no window's controls; it counts itself up.
            expect(find.byType(WindowControls), findsNothing);
            expect(find.byKey(const ValueKey('app-bar-title')), findsOneWidget);
            expect(touchDesktopShells, 1);
            expect(desktopShellInUse, isTrue);
            // Upright, the slim rail with names; sideways the full sidebar.
            final rail = tester.getSize(find.byType(NarrowSidebar));
            expect(
              rail.width,
              size.height > size.width ? NarrowSidebar.labelledRailWidth : NarrowSidebar.touchExpandedWidth,
            );
          }
          await unpumpQuickWins(tester);
          expect(touchDesktopShells, 0, reason: 'the shell counts itself down as it goes');
        } finally {
          debugTouchLayout = null;
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('turned, a tablet goes from the shell to its tabs and back', (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpQuickWins(tester, const AppHome(), const Size(1280, 800));
        expect(find.byType(DesktopShell), findsOneWidget);
        tester.view.physicalSize = const Size(800, 1280);
        await settleQuickWins(tester);
        expect(find.byType(DesktopShell), findsNothing);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(touchDesktopShells, 0);
        tester.view.physicalSize = const Size(1280, 800);
        await settleQuickWins(tester);
        expect(find.byType(DesktopShell), findsOneWidget);
        expect(touchDesktopShells, 1);
        await unpumpQuickWins(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // 4.1.1: a tablet with a keyboard is kept on its side, so turning it was
    // no way to get the tabs (a report of 4.0.0). Settings chooses.
    test('the choice: kept as a word, anything else is the computer layout; a tablet either way up is offered it', () {
      expect(LargeScreenLayout.of('tabs'), LargeScreenLayout.tabs);
      expect(LargeScreenLayout.of('computer'), LargeScreenLayout.computer);
      expect(LargeScreenLayout.of(null), LargeScreenLayout.computer);
      expect(LargeScreenLayout.of('??'), LargeScreenLayout.computer);
      expect(canBeLargeScreen(const Size(800, 1280)), isTrue, reason: 'upright: a large screen once turned');
      expect(canBeLargeScreen(const Size(1280, 800)), isTrue);
      expect(canBeLargeScreen(const Size(412, 915)), isFalse, reason: 'a phone');
      expect(canBeLargeScreen(const Size(915, 412)), isFalse, reason: 'a phone on its side');
      addTearDown(() => largeScreenLayout = LargeScreenLayout.computer);
      largeScreenLayout = LargeScreenLayout.tabs;
      expect(hasLargeScreenShell(const Size(1280, 800)), isFalse);
      largeScreenLayout = LargeScreenLayout.computer;
      expect(hasLargeScreenShell(const Size(1280, 800)), isTrue);
      expect(hasLargeScreenShell(const Size(800, 1280)), isFalse);
    });

    testWidgets('Tabs chosen: a tablet on its side has the tabs, and the computer layout again once chosen back',
        (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpQuickWins(tester, const AppHome(), const Size(1280, 800));
        expect(find.byType(DesktopShell), findsOneWidget);
        final container = ProviderScope.containerOf(tester.element(find.byType(AppHome)));
        container.read(largeScreenLayoutProvider.notifier).set(LargeScreenLayout.tabs);
        await settleQuickWins(tester);
        expect(find.byType(DesktopShell), findsNothing);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(touchDesktopShells, 0);
        expect(container.read(sharedPreferencesProvider).getString(kLargeScreenLayoutKey), 'tabs');
        container.read(largeScreenLayoutProvider.notifier).set(LargeScreenLayout.computer);
        await settleQuickWins(tester);
        expect(find.byType(DesktopShell), findsOneWidget);
        await unpumpQuickWins(tester);
      } finally {
        largeScreenLayout = LargeScreenLayout.computer;
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('the density', () {
    Future<ProviderContainer> container(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final shared = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(shared)]);
      addTearDown(c.dispose);
      return c;
    }

    test('Auto: the device until an input is used, then the input', () async {
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      final c = await container({});
      expect(c.read(uiDensityProvider), UiDensity.auto);
      expect(c.read(touchSizedProvider), isTrue, reason: 'a tablet is touch sized at first');
      expect(c.read(mouseExtrasProvider), isFalse);
      c.read(lastPointerKindProvider.notifier).state = PointerDeviceKind.mouse;
      expect(c.read(touchSizedProvider), isFalse, reason: 'a mouse makes it compact');
      expect(c.read(mouseExtrasProvider), isTrue);
      c.read(lastPointerKindProvider.notifier).state = PointerDeviceKind.trackpad;
      expect(c.read(touchSizedProvider), isFalse);
      c.read(lastPointerKindProvider.notifier).state = PointerDeviceKind.stylus;
      expect(c.read(touchSizedProvider), isTrue, reason: 'a pen is a finger');
      debugTouchLayout = false;
      final computer = await container({});
      expect(computer.read(touchSizedProvider), isFalse, reason: "a computer's is compact at first");
      computer.read(lastPointerKindProvider.notifier).state = PointerDeviceKind.touch;
      expect(computer.read(touchSizedProvider), isTrue, reason: "a 2-in-1's screen touched");
    });

    test('Comfortable and Compact hold whatever the input; the setting is kept', () async {
      final c = await container({kUiDensityKey: 'compact'});
      expect(c.read(uiDensityProvider), UiDensity.compact);
      c.read(lastPointerKindProvider.notifier).state = PointerDeviceKind.touch;
      expect(c.read(touchSizedProvider), isFalse);
      c.read(uiDensityProvider.notifier).state = UiDensity.comfortable;
      c.read(lastPointerKindProvider.notifier).state = PointerDeviceKind.mouse;
      expect(c.read(touchSizedProvider), isTrue);
      expect(UiDensity.parse('nonsense'), UiDensity.auto);
    });

    test("the theme's controls: a finger's 44 and 48 targets, or a computer's 34", () {
      final theme = BuiltInThemes.getById('default_dark');
      final touch = theme.toThemeData(compact: false);
      expect(touch.extension<ZestDensity>()!.touch, isTrue);
      expect(touch.materialTapTargetSize, MaterialTapTargetSize.padded);
      expect(touch.filledButtonTheme.style!.minimumSize!.resolve({}), const Size(0, 44));
      final small = theme.toThemeData(compact: true);
      expect(small.extension<ZestDensity>()!.touch, isFalse);
      expect(small.materialTapTargetSize, MaterialTapTargetSize.shrinkWrap);
      expect(small.filledButtonTheme.style!.minimumSize!.resolve({}), const Size(0, 34));
    });

    testWidgets('the app hears the kind of pointer pressed', (tester) async {
      PointerInputTracker.enabled = true;
      addTearDown(() => PointerInputTracker.enabled = false);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: PointerInputTracker(child: SizedBox.expand()),
          ),
        ),
      );
      expect(c.read(lastPointerKindProvider), isNull);
      await tester.tap(find.byType(SizedBox), kind: PointerDeviceKind.mouse);
      expect(c.read(lastPointerKindProvider), PointerDeviceKind.mouse);
      await tester.tap(find.byType(SizedBox));
      expect(c.read(lastPointerKindProvider), PointerDeviceKind.touch);
    });
  });
}
