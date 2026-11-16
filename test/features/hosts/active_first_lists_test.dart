import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/host_slide_out_panel.dart';

import '../../helpers/desktop_mouse.dart';
import '../../helpers/monitor_table_fixture.dart';
import '../../visual/shots_util.dart';

/// Active first on the lists that are no pickers (Active first is
/// on all host lists and pickers): off by itself there, and with it on the
/// hosts with an open session stand first.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {'s1': const SessionState(status: SessionStatus.connected, connectionId: 'web1')};
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
  }

  Future<AppDatabase> pump(WidgetTester tester, Widget child) async {
    // The real fonts: with the test's, every glyph one em wide, labels overflow
    // that fit in the app, and what really overflows would go unseen among them.
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(fleet.database))!;
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(
      [
        ...fleet.overrides(db, prefs),
        activeSessionsProvider.overrideWith(_Sessions.new),
        hostPanelWidthProvider.overrideWith((ref) => 440),
      ],
      child,
      theme: ThemeData(fontFamily: 'GeistSans'),
    ));
    await settle(tester);
    return db;
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    await db.close();
  }

  Finder toggle(HostListPlace place) => find.byKey(ValueKey('active-first-${place.name}'));
  final activeHeading = find.text(en.hostsSectionActive.toUpperCase());
  final restHeading = find.text(en.hostsSectionInactive.toUpperCase());

  desktopTest('the sidebar: off by itself, and on the open ones stand first, then the rest', (tester) async {
    final db = await pump(
      tester,
      Row(children: [
        HostSlideOutPanel(onConnectTo: (_) {}, onManageHosts: () {}, onClose: () {}),
        const Expanded(child: SizedBox()),
      ]),
    );
    expect(activeHeading, findsNothing);
    await tester.tap(toggle(HostListPlace.hostsPanel));
    await settle(tester);
    expect(activeHeading, findsOneWidget);
    expect(restHeading, findsOneWidget);
    final open = tester.getTopLeft(find.text('web-01')).dy;
    final rest = tester.getTopLeft(restHeading).dy;
    expect(open, lessThan(rest));
    expect(tester.getTopLeft(find.text('build-runner')).dy, greaterThan(rest));
    await finish(tester, db);
  });

  desktopTest('the Hosts page: off by itself, and on the open ones have a grid of their own', (tester) async {
    final db = await pump(tester, HostsHomePage(onConnectTo: (_) {}));
    expect(activeHeading, findsNothing);
    // In the band's Sort since 4.0: no switch
    // of its own beside Select.
    expect(toggle(HostListPlace.hostsPage), findsNothing);
    expect(find.byKey(const ValueKey('hosts-select')), findsOneWidget);
    Future<void> sortMenu() async {
      await tester.tap(find.byKey(const ValueKey('hosts-sort')));
      await settle(tester);
      // Its last items fade in last.
      await tester.pump(const Duration(milliseconds: 400));
    }

    final semantics = tester.ensureSemantics();
    await sortMenu();
    final item = find.byKey(const ValueKey('hosts-sort-active-first'));
    expect(find.descendant(of: item, matching: find.text(en.hostsActiveFirst)), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(en.hostsActiveFirst)),
        isSemantics(hasToggledState: true, isToggled: false));
    await tester.tap(item);
    await settle(tester);
    expect(activeHeading, findsOneWidget);
    expect(restHeading, findsOneWidget);
    expect(tester.getTopLeft(find.text('web-01')).dy, lessThan(tester.getTopLeft(restHeading).dy));
    expect(tester.getTopLeft(find.text('web-02')).dy, greaterThan(tester.getTopLeft(restHeading).dy));
    // The same preference as the switch had, kept for the page.
    final container = ProviderScope.containerOf(tester.element(find.byType(HostsHomePage)));
    expect(container.read(activeFirstProvider(HostListPlace.hostsPage)), isTrue);
    // And off again from the menu, which says it is on.
    await sortMenu();
    expect(tester.getSemantics(find.bySemanticsLabel(en.hostsActiveFirst)),
        isSemantics(hasToggledState: true, isToggled: true));
    await tester.tap(item);
    await settle(tester);
    expect(activeHeading, findsNothing);
    expect(container.read(activeFirstProvider(HostListPlace.hostsPage)), isFalse);
    semantics.dispose();
    await finish(tester, db);
  });

  testWidgets("a phone's Hosts: off by itself, and on the open ones have a section of their own on top", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (arguments, events) {}));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(loadShotFonts);
      final fleet = MonitorFleet();
      final db = (await tester.runAsync(fleet.database))!;
      final prefs = await fleet.preferences();
      await tester.pumpWidget(fleet.app(
        [...fleet.overrides(db, prefs), activeSessionsProvider.overrideWith(_Sessions.new)],
        Scaffold(
          body: Consumer(builder: (context, ref, _) {
            final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
            return PhoneHostsList(hosts: hosts, actionsOf: (h) => PhoneHostActions(connect: () {}, edit: () {}));
          }),
        ),
        theme: ThemeData(fontFamily: 'GeistSans'),
      ));
      await settle(tester);
      final active = find.byKey(const ValueKey('phone-host-__active__-web1'));
      expect(active, findsNothing);
      // In the sort's sheet since 4.0: no row of
      // its own over the list.
      expect(toggle(HostListPlace.phoneHosts), findsNothing);
      Future<void> flip() async {
        await tester.tap(find.byKey(const ValueKey('phone-hosts-sort')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('phone-sort-active-first')));
        await settle(tester);
        Navigator.of(tester.element(find.byKey(const ValueKey('phone-sort-sheet')))).pop();
        await settle(tester);
      }

      await flip();
      expect(active, findsOneWidget);
      expect(activeHeading, findsOneWidget);
      expect(find.text('web-01'), findsOneWidget, reason: 'there, and not in its group as well');
      expect(tester.getTopLeft(active).dy, lessThan(tester.getTopLeft(find.text('hypervisor-a')).dy));

      await flip();
      expect(active, findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      await db.close();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
