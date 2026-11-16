import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart'
    show accountSetupNeedsAttentionProvider;
import 'package:zestssh/ui/screens/desktop/widgets/narrow_sidebar.dart';

const _toggle = ValueKey('sidebar-rail-toggle');

/// Turns the mouse wheel over [where], as a person scrolling there does.
Future<void> wheel(WidgetTester tester, Finder where, double by) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(where)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, by)));
  await tester.pump();
}

void main() {
  group('hostsDrawerShown', () {
    test('only while the drawer is on and the Hosts page is not replacing it',
        () {
      expect(
          hostsDrawerShown(
              panelOn: false, terminalShown: true, activeNav: NavSection.keys),
          isFalse);
      expect(
          hostsDrawerShown(
              panelOn: true, terminalShown: true, activeNav: NavSection.hosts),
          isTrue);
      expect(
          hostsDrawerShown(
              panelOn: true, terminalShown: false, activeNav: NavSection.keys),
          isTrue);
      // The Hosts page hides the drawer, so the rail must not stay icon-only.
      expect(
          hostsDrawerShown(
              panelOn: true, terminalShown: false, activeNav: NavSection.hosts),
          isFalse);
    });

    test("on the Hosts page, only where its pill opened it there; over a terminal, the pill's switch", () {
      // On the Hosts page the pill lit up and
      // nothing opened.
      expect(
          hostsDrawerShown(
              panelOn: false, terminalShown: false, activeNav: NavSection.hosts, openedOnHostsPage: true),
          isTrue);
      expect(
          hostsDrawerShown(
              panelOn: true, terminalShown: false, activeNav: NavSection.hosts, openedOnHostsPage: false),
          isFalse);
      expect(
          hostsDrawerShown(
              panelOn: false, terminalShown: true, activeNav: NavSection.hosts, openedOnHostsPage: true),
          isFalse);
    });

    test('opened on the Hosts page, it closes when the Hosts page is come back to', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(hostsDrawerOnHostsPageProvider), isFalse);
      container.read(hostsDrawerOnHostsPageProvider.notifier).toggle();
      expect(container.read(hostsDrawerOnHostsPageProvider), isTrue);
      container.read(activeSidebarNavProvider.notifier).state = NavSection.keys;
      expect(container.read(hostsDrawerOnHostsPageProvider), isTrue, reason: 'still open elsewhere');
      container.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
      expect(container.read(hostsDrawerOnHostsPageProvider), isFalse, reason: 'back on the Hosts page: closed');
    });
  });

  group('NarrowSidebar rail', () {
    late SharedPreferences prefs;
    final pressed = <NavSection>[];
    setUp(pressed.clear);

    Future<void> setPrefs(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      prefs = await SharedPreferences.getInstance();
    }

    Widget app({required ValueNotifier<bool> drawer}) => ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentUserProvider.overrideWith((_) => null),
            // Signed out and quiet: the purchase badges refresh 600 ms after a
            // sign-in event, which would outlive a short test.
            authStateProvider.overrideWith((_) => const Stream.empty()),
            accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: drawer,
                builder: (_, shown, _) => Row(
                  children: [
                    NarrowSidebar(
                      activeSection: NavSection.keys,
                      onSectionChanged: pressed.add,
                      hostsPanelShown: shown,
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ),
        );

    double railWidth(WidgetTester tester) =>
        tester.getSize(find.byType(NarrowSidebar)).width;

    Future<void> setUpWindow(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets(
        'the arrow pushes the rail in and pulls it out, and the choice is kept',
        (tester) async {
      await setUpWindow(tester);
      await setPrefs({});
      await tester.pumpWidget(app(drawer: ValueNotifier(false)));
      await tester.pumpAndSettle();

      expect(railWidth(tester), NarrowSidebar.expandedWidth);
      expect(find.text('Keys'), findsOneWidget);
      expect(find.byIcon(LucideIcons.chevronsLeft), findsOneWidget);

      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      expect(railWidth(tester), NarrowSidebar.collapsedWidth);
      expect(find.text('Keys'), findsNothing);
      expect(find.byIcon(LucideIcons.chevronsRight), findsOneWidget);
      expect(prefs.getBool('desktop_sidebar_collapsed'), isTrue);

      await tester.tap(find.byKey(_toggle));
      await tester.pumpAndSettle();
      expect(railWidth(tester), NarrowSidebar.expandedWidth);
      expect(find.text('Keys'), findsOneWidget);
      expect(prefs.getBool('desktop_sidebar_collapsed'), isFalse);
    });

    testWidgets('a rail pushed in stays in after a restart', (tester) async {
      await setUpWindow(tester);
      await setPrefs({'desktop_sidebar_collapsed': true});
      await tester.pumpWidget(app(drawer: ValueNotifier(false)));
      await tester.pumpAndSettle();

      expect(railWidth(tester), NarrowSidebar.collapsedWidth);
      expect(find.byIcon(LucideIcons.chevronsRight), findsOneWidget);
    });

    testWidgets(
        'the Hosts drawer holds the rail icon-only, and the rail comes back out '
        'when the drawer goes away', (tester) async {
      await setUpWindow(tester);
      await setPrefs({});
      final drawer = ValueNotifier(true);
      await tester.pumpWidget(app(drawer: drawer));
      await tester.pumpAndSettle();

      expect(railWidth(tester), NarrowSidebar.collapsedWidth);
      // No arrow while the drawer decides: it would do nothing.
      expect(find.byKey(_toggle), findsNothing);

      // For example, the Hosts page opens and hides the drawer.
      drawer.value = false;
      await tester.pumpAndSettle();
      expect(railWidth(tester), NarrowSidebar.expandedWidth);
      expect(find.text('Keys'), findsOneWidget);
      expect(find.byKey(_toggle), findsOneWidget);
    });

    testWidgets('the slide lays nothing out of bounds on the way',
        (tester) async {
      await setUpWindow(tester);
      await setPrefs({});
      await tester.pumpWidget(app(drawer: ValueNotifier(false)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_toggle));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byKey(_toggle), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
    // A field finding of the Settings pop-up's own test (3.0):
    // in a window 600 px high the rail's column overflowed by 152 px,
    // so its foot (the Discord button and the account) was cut off.
    group('in a low window', () {
      const sections = ValueKey('rail-sections');
      final l10n = lookupAppLocalizations(const Locale('en'));

      Future<void> window(WidgetTester tester, Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
      }

      ScrollPosition position(WidgetTester tester) =>
          tester.state<ScrollableState>(find.descendant(of: find.byKey(sections), matching: find.byType(Scrollable))).position;

      for (final collapsed in [false, true]) {
        testWidgets(
            'the sections scroll and the account at the foot stays on screen, ${collapsed ? 'pushed in' : 'pulled out'}',
            (tester) async {
          await window(tester, const Size(1200, 420));
          await setPrefs({'desktop_sidebar_collapsed': collapsed});
          await tester.pumpWidget(app(drawer: ValueNotifier(false)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'nothing overflows');

          // The foot is whole, inside the window.
          final guest = collapsed ? find.byTooltip(l10n.narrowSidebarJoinDiscord) : find.text(l10n.narrowSidebarGuest);
          expect(guest, findsOneWidget);
          expect(tester.getRect(guest).bottom, lessThanOrEqualTo(420));
          expect(tester.getRect(find.byType(NarrowSidebar)).bottom, 420);

          // The sections do not fit, and scroll: with the wheel, as a person does it.
          expect(position(tester).maxScrollExtent, greaterThan(0));
          expect(position(tester).pixels, 0);
          await wheel(tester, find.byKey(sections), 80);
          expect(position(tester).pixels, 80);
          await wheel(tester, find.byKey(sections), -80);
          expect(position(tester).pixels, 0);
          // Settings is in reach without scrolling, between the sections and
          // the foot (as the last of the
          // sections it sat half under the foot).
          final settings = collapsed ? find.byTooltip(l10n.narrowSidebarSettings) : find.text(l10n.narrowSidebarSettings);
          expect(position(tester).pixels, 0);
          final r = tester.getRect(settings);
          expect(r.top, greaterThanOrEqualTo(tester.getRect(find.byKey(sections)).bottom), reason: 'below the sections');
          expect(r.bottom, lessThanOrEqualTo(tester.getRect(guest).top), reason: 'above the foot');
          await tester.tap(settings);
          await tester.pump();
          expect(pressed, [NavSection.settings]);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('with room for them all nothing scrolls, and the foot is at the bottom', (tester) async {
        await window(tester, const Size(1200, 900));
        await setPrefs({});
        await tester.pumpWidget(app(drawer: ValueNotifier(false)));
        await tester.pumpAndSettle();
        expect(position(tester).maxScrollExtent, 0);
        expect(tester.getRect(find.text(l10n.narrowSidebarHosts)).top, lessThan(160));
        expect(tester.getRect(find.text(l10n.narrowSidebarGuest)).bottom, greaterThan(820));
        expect(tester.takeException(), isNull);
      });
    });
  });
}
