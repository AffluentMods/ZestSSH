import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// The Hosts page scrolls with every kind of scroll input (2.2.1 field
/// report: the wheel did nothing on the Hosts page alone). A classic wheel
/// is a pointer-scroll event; a touchpad's two-finger scroll, and on Windows
/// the wheel of many mice with smooth-scrolling drivers, is a pan-zoom
/// gesture that only the scroll view's drag recogniser takes, so the page
/// must accept trackpad drags. A mouse click-drag on empty space stays the
/// rubber-band selection's, never a scroll.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime(2026, 9, 24);
    // Enough hosts to run well past the window however many cards a row
    // holds (40 no longer did, with four cards to a row).
    for (var i = 0; i < 60; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'c$i', label: 'host-$i', host: '10.0.0.$i', port: const Value(22), createdAt: now, updatedAt: now));
    }
  });

  tearDown(() => db.close());

  Future<ScrollPosition> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        // No reachability probes to the seeded addresses from a test.
        healthChecksEnabledProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HostsHomePage(onConnectTo: (_) {})),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The test font draws every glyph one em wide, so some labels overflow
    // here that fit with a real font; that is not what this test is about.
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
    final page = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .firstWhere((s) => s.position.axis == Axis.vertical && s.position.maxScrollExtent > 0);
    expect(page.position.maxScrollExtent, greaterThan(300), reason: '60 hosts overflow the window');
    return page.position;
  }

  Future<void> settleUp(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    // Unmount the page before the database closes (its streams end with it),
    // and let the database's close-down timers run.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
    while (tester.takeException() != null) {}
  }

  testWidgets('a classic mouse wheel scrolls, over a card and over the empty edge', (tester) async {
    final page = await pumpPage(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    mouse.hover(tester.getCenter(find.text('host-3')));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(page.pixels, 120);
    mouse.hover(const Offset(1190, 400));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(page.pixels, 240);
    await settleUp(tester);
  });

  testWidgets('a trackpad or smooth-scrolling wheel (a pan-zoom gesture) scrolls', (tester) async {
    final page = await pumpPage(tester);
    final pad = TestPointer(2, PointerDeviceKind.trackpad);
    final at = tester.getCenter(find.text('host-3'));
    await tester.sendEventToBinding(pad.panZoomStart(at));
    await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: const Offset(0, -60)));
    await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: const Offset(0, -150)));
    await tester.sendEventToBinding(pad.panZoomEnd());
    await tester.pump(const Duration(milliseconds: 500));
    expect(page.pixels, greaterThan(100), reason: 'the page follows the two-finger scroll');
    await settleUp(tester);
  });

  testWidgets('a mouse click-drag on empty space does not scroll (it is the rubber-band selection)', (tester) async {
    final page = await pumpPage(tester);
    final start = const Offset(1190, 600);
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, -40));
    await gesture.moveBy(const Offset(0, -200));
    await gesture.up();
    await tester.pump();
    expect(page.pixels, 0);
    await settleUp(tester);
  });
}
