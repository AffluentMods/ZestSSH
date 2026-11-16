// Remote screens (4.0): the session panel on its own. It follows the
// session's state as it changes, keeps open for a switch or a choice, closes
// for an action done once, says why an option is greyed, comes in from the
// end side (the left in Arabic), and holds its words whole at the largest
// text in the longest language.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/features/screens/menu/screen_session_panel.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ScreenMenuState stateOf({bool viewOnly = false, ScreenFit fit = ScreenFit.fit, bool phone = false}) =>
      ScreenMenuState.of(
        phone: phone,
        fit: fit,
        viewOnly: viewOnly,
        canResizeRemote: true,
        clipboardTogglable: true,
        clipboardOn: true,
      );

  Future<void> open(
    WidgetTester tester,
    ValueNotifier<ScreenMenuState> state,
    List<ScreenAction> picked, {
    Locale locale = const Locale('en'),
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      // This profile's preferences, as the app hands them.
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open'),
                onPressed: () => showScreenPanel(context, state: state, onAction: picked.add),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  /// A row of the open panel, scrolled into view (its list builds rows as
  /// they come into view, and an RDP host's panel is longer than a window).
  Future<Finder> shown(WidgetTester tester, String key) async {
    final row = find.byKey(ValueKey(key));
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    // From the top, whichever way the last row was.
    tester.state<ScrollableState>(list).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(row, 120, scrollable: list);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    return row;
  }

  testWidgets('a switch acts and the panel shows what the session reports; an action done once closes it',
      (tester) async {
    final state = ValueNotifier(stateOf());
    final picked = <ScreenAction>[];
    await open(tester, state, picked);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-panel-fullScreen')), findsOneWidget, reason: "a computer's");

    await tester.tap(find.byKey(const ValueKey('screen-panel-viewOnly')));
    await tester.pump();
    expect(picked, [ScreenAction.viewOnly]);
    // The session turns View only on: the keys grey out, with the reason.
    state.value = stateOf(viewOnly: true);
    await tester.pumpAndSettle();
    final cad = find.descendant(
        of: await shown(tester, 'screen-panel-sendCtrlAltDel'), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(cad).onPressed, isNull);
    expect(find.text('Not while View only is on'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);

    state.value = stateOf();
    await tester.pumpAndSettle();
    await tester.tap(await shown(tester, 'screen-panel-refresh'));
    await tester.pumpAndSettle();
    expect(picked.last, ScreenAction.refresh);
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
  });

  testWidgets('a state changed while a frame is being built redraws the panel after it, without an error',
      (tester) async {
    final state = ValueNotifier(stateOf());
    await open(tester, state, []);
    // As a view does: the state handed on during its own build.
    await tester.pumpWidget(Builder(builder: (context) {
      state.value = stateOf(fit: ScreenFit.fill);
      return const SizedBox();
    }));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('in Arabic it comes in from the left', (tester) async {
    final state = ValueNotifier(stateOf(phone: true));
    await open(tester, state, [], locale: const Locale('ar'), size: const Size(400, 800));
    final panel = tester.getRect(find.byKey(const ValueKey('screen-panel')));
    expect(panel.left, 0);
    expect(panel.right, lessThan(400));
  });

  testWidgets('German at the largest text on a narrow phone: nothing overflows, every row whole', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final state = ValueNotifier(stateOf(phone: true));
    await open(tester, state, [], locale: const Locale('de'), size: const Size(320, 700));
    expect(tester.takeException(), isNull);
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    for (final a in stateOf(phone: true).offered) {
      if (a == ScreenAction.disconnect) continue;
      final row = find.byKey(ValueKey('screen-panel-${a.name}'));
      await tester.scrollUntilVisible(row, 150, scrollable: list);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: a.name);
      expect(row, findsOneWidget, reason: '${a.name} is in the panel');
      expect(tester.getRect(row).right, lessThanOrEqualTo(320), reason: a.name);
    }
  });

  testWidgets('from the keyboard alone at 150 percent text: the first option has the focus, Up and Down move, '
      'Enter picks and keeps it open for a choice, a switch is one stop, Esc closes', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final state = ValueNotifier(stateOf());
    final picked = <ScreenAction>[];
    await open(tester, state, picked);

    Element primary() => FocusManager.instance.primaryFocus!.context! as Element;
    bool inRow(String id) {
      var found = false;
      primary().visitAncestorElements((e) {
        if (e.widget.key == ValueKey('screen-panel-$id')) found = true;
        return !found;
      });
      return found;
    }

    expect(inRow('fit'), isTrue, reason: 'the first option has the focus as it opens');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(inRow('fill'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(picked, [ScreenAction.fill]);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a choice keeps it open');
    expect(inRow('fill'), isTrue, reason: 'the focus stays where it was');

    // Down past 1:1 and Resize the remote to View only: one stop, its switch not one of its own.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(inRow('viewOnly'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(picked.last, ScreenAction.viewOnly);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(inRow('remoteResize'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a group folds at its heading and opens again; this device remembers which are folded', (tester) async {
    final state = ValueNotifier(stateOf());
    await open(tester, state, []);
    expect(await shown(tester, 'screen-panel-keys'), findsOneWidget);
    await tester.tap(await shown(tester, 'screen-panel-fold-input'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel-keys')), findsNothing, reason: 'Input folded');
    expect(await shown(tester, 'screen-panel-fit'), findsOneWidget, reason: 'Session still open');
    expect(prefs.getStringList(kScreenPanelFoldedKey), ['input']);

    // Opened again in a new run (a new app on the same preferences): still folded.
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await open(tester, state, []);
    await tester.tap(await shown(tester, 'screen-panel-fold-input'));
    await tester.pumpAndSettle();
    expect(await shown(tester, 'screen-panel-keys'), findsOneWidget, reason: 'opened again');
  });

  testWidgets('a heading says to a screen reader that it folds, and whether it is open', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, ValueNotifier(stateOf()), []);
    final heading = tester.getSemantics(find.byKey(const ValueKey('screen-panel-fold-video'))).getSemanticsData();
    expect(heading.label, 'Video');
    expect(heading.flagsCollection.isHeader, isTrue);
    expect(heading.flagsCollection.isExpanded, Tristate.isTrue);
    handle.dispose();
  });

  test('which picks close the panel', () {
    expect(screenPanelClosesOn(ScreenAction.sendCtrlAltDel), isTrue);
    expect(screenPanelClosesOn(ScreenAction.disconnect), isTrue);
    expect(screenPanelClosesOn(ScreenAction.fullScreen), isTrue);
    // The details are shown where the panel is: it gets out of their way.
    expect(screenPanelClosesOn(ScreenAction.sessionDetails), isTrue);
    expect(screenPanelClosesOn(ScreenAction.viewOnly), isFalse);
    expect(screenPanelClosesOn(ScreenAction.fill), isFalse);
    expect(screenPanelClosesOn(ScreenAction.touchPointer), isFalse);
  });

  testWidgets('every option the list has today carries its line or says it in its words', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        for (final a in ScreenAction.values) {
          // Full screen is a button at the panel's top, named by its words.
          if (a.kind != ScreenActionKind.plain && a != ScreenAction.fullScreen) {
            expect(screenActionHelpIn(l10n, a), isNotNull, reason: '${a.name}: a switch or a choice says what it does');
          }
        }
        return const SizedBox();
      }),
    ));
  });
}
