import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';

import '../visual/shots_util.dart';

/// Server Monitor while it is turned off, in a low window (3.0, found
/// by the test of the Settings pop-up in a window 600 px
/// high): what the page says, and its two buttons under that, stood in a
/// column that did not fit, so the buttons were cut off, the one that turns
/// the monitor on among them.
/// Turns the mouse wheel over [where], as a person scrolling there does.
Future<void> wheel(WidgetTester tester, Finder where, double by) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(where)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, by)));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester, Size size, {Locale locale = const Locale('en')}) async {
    // The app's own fonts: the test font is wider, and the page's header does
    // not fit a window of this width in it.
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        theme: ThemeData(fontFamily: 'GeistSans'),
        home: const Scaffold(body: MonitorTableView()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return container;
  }

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
          find.descendant(of: find.byKey(const ValueKey('monitor-off')), matching: find.byType(Scrollable)))
      .position;

  testWidgets('in a low window the page scrolls, nothing overflows, and the button that turns the monitor on can be '
      'reached and pressed', (tester) async {
    final container = await pump(tester, const Size(1000, 330));
    expect(tester.takeException(), isNull, reason: 'nothing overflows');
    expect(find.text(en.monitorAgentlessOffTitle), findsOneWidget);
    expect(position(tester).maxScrollExtent, greaterThan(0));
    // With the wheel, as a person does it.
    expect(position(tester).pixels, 0);
    await wheel(tester, find.byKey(const ValueKey('monitor-off')), 40);
    expect(position(tester).pixels, 40);

    final enable = find.text(en.monitorAgentlessEnableAction);
    await tester.ensureVisible(enable);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(enable).bottom, lessThanOrEqualTo(330));
    expect(container.read(agentlessMonitorEnabledProvider), isFalse);
    await tester.tap(enable);
    await tester.pump(const Duration(milliseconds: 100));
    expect(container.read(agentlessMonitorEnabledProvider), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('with room for it nothing scrolls, and it stands in the middle as before', (tester) async {
    await pump(tester, const Size(1000, 800));
    expect(position(tester).maxScrollExtent, 0);
    final title = tester.getRect(find.text(en.monitorAgentlessOffTitle));
    expect(title.center.dx, closeTo(500, 2));
    expect(title.top, greaterThan(250));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('in every language its two buttons fit the page, side by side or one under the other', (tester) async {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      await pump(tester, const Size(1000, 800), locale: locale);
      expect(tester.takeException(), isNull, reason: '$locale');
      final enable = tester.getRect(find.text(l.monitorAgentlessEnableAction));
      final manage = tester.getRect(find.text(l.monitorManageAction));
      final page = tester.getRect(find.byKey(const ValueKey('monitor-off')));
      for (final r in [enable, manage]) {
        expect(r.left, greaterThanOrEqualTo(page.left), reason: '$locale');
        expect(r.right, lessThanOrEqualTo(page.right), reason: '$locale');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }
  });
}
