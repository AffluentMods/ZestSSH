// Remote screens (4.0): choosing which of a remote's displays is
// shown. The computer's segment and strip, the phone's button and list, and
// the session panel's Displays group: each follows the displays as they change,
// hands a pick on (null: all of them), draws nothing for one display, and is
// named and sized for a screen reader and a finger.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/displays/screen_display_bars.dart';
import 'package:zestssh/features/screens/menu/screen_session_panel.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../a11y/a11y_checks.dart';

const _three = [
  ScreenDisplay(index: 0, x: 0, y: 0, width: 2560, height: 1440, primary: true),
  ScreenDisplay(index: 1, x: 2560, y: 0, width: 1920, height: 1080),
  ScreenDisplay(index: 2, x: 4480, y: 0, width: 1080, height: 1920),
];

void main() {
  late ValueNotifier<ScreenDisplays> displays;
  late List<int?> picked;

  late SharedPreferences prefs;

  setUp(() async {
    displays = ValueNotifier(const ScreenDisplays(list: _three, shown: 0));
    picked = [];
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(1280, 800), Locale? locale}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // On the ground the app draws them on: the screen's bar and panels.
        home: Scaffold(backgroundColor: ZestColors.surfacePanel, body: child),
      ),
    ));
  }

  Widget preview(int index, Size size) =>
      SizedBox.fromSize(key: ValueKey('preview-$index-${size.width.round()}x${size.height.round()}'), size: size);

  group("a computer's segment", () {
    testWidgets('1 2 3 All, the one shown marked, a pick handed on, following the displays', (tester) async {
      await pump(tester, Center(child: ScreenDisplaySegment(displays: displays, onDisplay: picked.add)));
      for (final id in ['0', '1', '2', 'all']) {
        expect(find.byKey(ValueKey('screen-display-segment-$id')), findsOneWidget, reason: id);
      }
      expect(find.text('All'), findsOneWidget);
      expect(find.byTooltip('Display 2 (1920 × 1080)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-display-segment-2')));
      await tester.tap(find.byKey(const ValueKey('screen-display-segment-all')));
      expect(picked, [2, null]);

      // A display dropped mid-session: one left, nothing to choose.
      displays.value = const ScreenDisplays(list: [ScreenDisplay(index: 0, x: 0, y: 0, width: 2560, height: 1440)], shown: 0);
      await tester.pump();
      expect(find.byKey(const ValueKey('screen-display-segment')), findsNothing);
    });

    testWidgets('a screen reader hears each as a selectable name with its size', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, Center(child: ScreenDisplaySegment(displays: displays, onDisplay: picked.add)));
      expect(find.bySemanticsLabel('Display 1, 2560 by 1440, main'), findsOneWidget);
      expect(find.bySemanticsLabel('All displays'), findsOneWidget);
      final data = tester.getSemantics(find.bySemanticsLabel('Display 1, 2560 by 1440, main')).getSemanticsData();
      expect(data.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });
  });

  group("a computer's strip", () {
    testWidgets('a picture of each at its own shape, the one shown outlined; All last; closes to a rail', (tester) async {
      var open = true;
      await pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Row(children: [
            ScreenDisplayStrip(
              displays: displays,
              onDisplay: picked.add,
              preview: preview,
              open: open,
              onOpenChanged: (v) => setState(() => open = v),
            ),
            const Expanded(child: SizedBox()),
          ]),
        ),
      );
      // 140 across inside the strip: a flat display short, the tall one tall.
      expect(find.byKey(const ValueKey('preview-0-140x79')), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-1-140x79')), findsOneWidget);
      expect(find.byKey(const ValueKey('preview-2-140x249')), findsOneWidget);
      expect(find.text('2560 × 1440'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-display-strip-1')));
      await tester.ensureVisible(find.byKey(const ValueKey('screen-display-strip-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('screen-display-strip-all')));
      expect(picked, [1, null]);

      await tester.tap(find.byKey(const ValueKey('screen-display-strip-close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('screen-display-strip')), findsNothing);
      expect(find.byKey(const ValueKey('screen-display-strip-closed')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-display-strip-open')));
      await tester.pump();
      expect(find.byKey(const ValueKey('screen-display-strip')), findsOneWidget);
    });

    testWidgets('the accessibility pass: named, a mouse\'s targets, contrast', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        Row(children: [
          ScreenDisplayStrip(
            displays: displays,
            onDisplay: picked.add,
            preview: preview,
            open: true,
            onOpenChanged: (_) {},
          ),
          Expanded(child: Center(child: ScreenDisplaySegment(displays: displays, onDisplay: picked.add))),
        ]),
      );
      expect(await a11yCheck(tester, computer: true, where: 'the strip and the segment'), isEmpty);
      handle.dispose();
    });
  });

  group('a phone', () {
    testWidgets('"1 of 3" opens the list; a pick closes it; All last, with its line; the three finger hint',
        (tester) async {
      await pump(
        tester,
        Center(child: ScreenDisplayButton(displays: displays, onDisplay: picked.add)),
        size: const Size(390, 800),
      );
      expect(find.text('1 of 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-display-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-display-picker')), findsOneWidget);
      expect(find.text('2560 × 1440 · main'), findsOneWidget);
      expect(find.text('The whole remote desktop, fitted.'), findsOneWidget);
      expect(find.text('Swipe with three fingers to change display'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('screen-display-picker-2')));
      await tester.pumpAndSettle();
      expect(picked, [2]);
      expect(find.byKey(const ValueKey('screen-display-picker')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('screen-display-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('screen-display-picker-all')));
      await tester.pumpAndSettle();
      expect(picked, [2, null], reason: 'All displays hands on null');

      displays.value = const ScreenDisplays(list: _three);
      await tester.pump();
      expect(find.text('All'), findsOneWidget, reason: 'all displays shown');
    });

    testWidgets('the accessibility pass on a narrow phone, the list open', (tester) async {
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        Center(child: _onPhoneBar(ScreenDisplayButton(displays: displays, onDisplay: picked.add, ink: _barInk))),
        size: const Size(320, 700),
      );
      expect(await a11yCheck(tester, computer: false, where: 'the button'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('screen-display-button')));
      await tester.pumpAndSettle();
      expect(await a11yCheck(tester, computer: false, where: 'the list'), isEmpty);
      handle.dispose();
    });

    testWidgets('German at the largest text: nothing overflows', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(
        tester,
        Center(child: ScreenDisplayButton(displays: displays, onDisplay: picked.add)),
        size: const Size(320, 700),
        locale: const Locale('de'),
      );
      await tester.tap(find.byKey(const ValueKey('screen-display-button')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group("the session panel's Displays group", () {
    testWidgets('each display a choice and All last; a pick keeps the panel open; none for one display',
        (tester) async {
      final state = ValueNotifier(ScreenMenuState.of(phone: false, fit: ScreenFit.fit, viewOnly: false));
      await pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showScreenPanel(
                context,
                state: state,
                onAction: (_) {},
                displays: displays,
                onDisplay: picked.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('screen-panel-display-1'));
      await tester.scrollUntilVisible(row, 120,
          scrollable: find.descendant(
              of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable)));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pump();
      expect(picked, [1]);
      expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
      displays.value = const ScreenDisplays(list: _three, shown: 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-panel-display-all'), skipOffstage: false), findsOneWidget);

      displays.value = const ScreenDisplays(list: [ScreenDisplay(index: 0, x: 0, y: 0, width: 1920, height: 1080)], shown: 0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-panel-group-displays'), skipOffstage: false), findsNothing);
    });
  });
}

/// The phone's bar under a button of it, as the screen draws it.
const _barInk = Color(0xFFEDEBE6);
Widget _onPhoneBar(Widget child) => Material(color: const Color(0xFF151412), child: child);
