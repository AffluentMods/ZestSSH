import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/wol_service.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';

/// The phone's home (3.0; 3.1): Hosts, Sessions,
/// Manage, Monitor and More on a phone (Hosts, Snippets, Sessions, Monitor
/// and More on a tablet), Hosts first; the host search filters the hosts (it
/// filtered nothing before); Manage holds Keys and Port forwarding, which
/// their routes open; More opens each screen, and in an Orchard the Team,
/// with a dot on More when the Team needs someone; the Sessions tab counts
/// live sessions.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> sessions) => state = sessions;
}

const _hosts = ['db-primary', 'web-01', 'log-store'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// The phone home, with three hosts; [orchard] on screen when given.
  /// [wake] names the hosts that have an address to wake saved (host id to
  /// that address).
  Future<ProviderContainer> pumpPhone(WidgetTester tester,
      {OrchardSummary? orchard,
      List<Override> extra = const [],
      Map<String, String> wake = const {},
      Size size = const Size(390, 844)}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      for (var i = 0; i < _hosts.length; i++) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: 'c$i',
              label: _hosts[i],
              host: '10.50.0.${21 + i}',
              port: const Value(22),
              createdAt: DateTime(2026, 9, 25),
              updatedAt: DateTime(2026, 9, 25),
              wolMacAddress: Value(wake['c$i']),
            ));
      }
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => null),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      recordingModeProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 25, 12))),
      ...extra,
      if (orchard != null) ...[
        activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchard.id)),
        activeOrchardProvider.overrideWithValue(AsyncData(orchard)),
      ],
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      // Keys and Port forwarding as the app has them: a phone's Manage tab.
      GoRoute(path: Routes.keys, pageBuilder: (c, s) => manageSectionPage(c, s, ManageSection.keys)),
      GoRoute(path: Routes.portForwards, pageBuilder: (c, s) => manageSectionPage(c, s, ManageSection.portForwards)),
      GoRoute(
        path: '/:rest(.*)',
        builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}')),
      ),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    await settle(tester);
    return container;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder tab(int i) => find.byKey(ValueKey('phone-tab-$i'));

  List<String?> tabLabels(WidgetTester tester) => [
        for (var i = 0; i < 5; i++)
          tester.widget<Text>(find.descendant(of: tab(i), matching: find.byType(Text)).last).data,
      ];

  // 3.1 (the Manage tab): on a phone, Hosts,
  // Sessions, Manage, Monitor and More.
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on ${platform.name}, 430 by 932: five tabs, Hosts, Sessions, Manage, Monitor and More, each with '
        'its page', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpPhone(tester, size: const Size(430, 932));
        expect(tabLabels(tester),
            [l10n.narrowSidebarHosts, l10n.homeSessionsTab, l10n.narrowSidebarGroupManage, l10n.phoneTabMonitor, l10n.phoneTabMore]);
        expect(find.byKey(const ValueKey('phone-hosts')), findsOneWidget);
        expect(find.text('log-store'), findsOneWidget);
        expect(find.byKey(const ValueKey('phone-new-host')), findsOneWidget);

        await tester.tap(tab(1));
        await settle(tester);
        expect(find.text(l10n.homeNoActiveSessions), findsOneWidget);
        expect(find.byKey(const ValueKey('phone-open-session')), findsNothing,
            reason: 'the empty tab has its own button: one solid accent');

        await tester.tap(tab(2));
        await settle(tester);
        expect(find.byKey(const ValueKey('manage-sections')), findsOneWidget);
        expect(find.byKey(const ValueKey('phone-keys')), findsOneWidget, reason: 'Keys first');
        expect(find.byKey(const ValueKey('phone-keys-add')), findsOneWidget);
        expect(find.byKey(const ValueKey('phone-new-host')), findsNothing);

        await tester.tap(tab(3));
        await settle(tester);
        expect(find.byType(ServerMonitorScreen), findsOneWidget);

        await tester.tap(tab(4));
        await settle(tester);
        expect(find.byKey(const ValueKey('phone-more')), findsOneWidget);
        expect(find.byKey(const ValueKey('more-team')), findsNothing, reason: 'your Tree has no team');
        expect(find.byType(SnippetsScreen), findsNothing, reason: 'Snippets is no tab of a phone');
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on ${platform.name}, 430 by 932: Manage has Keys and Port forwarding, and More lists neither',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpPhone(tester, size: const Size(430, 932));
        await tester.tap(tab(2));
        await settle(tester);
        expect(find.descendant(of: find.byKey(const ValueKey('manage-sections')), matching: find.text(l10n.narrowSidebarKeys)),
            findsOneWidget);
        expect(find.text(l10n.narrowSidebarGroupManage), findsWidgets, reason: 'the bar says Manage');
        await tester.tap(find.byKey(const ValueKey('manage-port-forwards')));
        await settle(tester);
        expect(find.byKey(const ValueKey('phone-port-forwards')), findsOneWidget);
        expect(find.byKey(const ValueKey('phone-forwards-add')), findsOneWidget);
        expect(find.text(l10n.portForwardNone), findsOneWidget, reason: 'the port forwarding list, empty');
        expect(find.byKey(const ValueKey('phone-keys')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('manage-keys')));
        await settle(tester);
        expect(find.byKey(const ValueKey('phone-keys')), findsOneWidget);

        await tester.tap(tab(4));
        await settle(tester);
        expect(find.byKey(const ValueKey('more-keys')), findsNothing);
        expect(find.byKey(const ValueKey('more-port-forwards')), findsNothing);
        expect(find.text(l10n.narrowSidebarKeys), findsNothing);
        expect(find.text(l10n.narrowSidebarPortForwarding), findsNothing);
        expect(find.byKey(const ValueKey('more-snippets')), findsOneWidget, reason: 'Snippets moved here');
        expect(find.byKey(const ValueKey('more-networks')), findsOneWidget);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on ${platform.name}, 430 by 932: the Keys and the Port forwarding routes land on Manage, on that part',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pumpPhone(tester, size: const Size(430, 932));
        final router = GoRouter.of(tester.element(find.byType(HomeScreen)));
        unawaited(router.push(Routes.portForwards));
        await settle(tester);
        expect(find.text('route ${Routes.portForwards}'), findsNothing);
        expect(find.byKey(const ValueKey('phone-port-forwards')), findsOneWidget);
        expect(find.byType(HomeScreen), findsOneWidget, reason: 'Home itself, not a second one over it');

        // From a page over Home, too (a key refused by automation, in a
        // terminal), and to Keys.
        unawaited(router.push('/somewhere'));
        await settle(tester);
        expect(find.text('route /somewhere'), findsOneWidget);
        unawaited(router.push(Routes.keys));
        await settle(tester);
        expect(find.text('route /somewhere'), findsNothing);
        expect(find.byKey(const ValueKey('phone-keys')), findsOneWidget);
        expect(find.byType(HomeScreen), findsOneWidget);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  // A tablet below the large screen (an iPad Air upright, 820 wide) has the
  // phone's tabs exactly (4.0): the 3.0 tablet tabs
  // (Hosts, Snippets, Sessions, Monitor, More) are gone.
  testWidgets("a tablet below the large screen has the phone's tabs, Snippets under More", (tester) async {
    await pumpPhone(tester, size: const Size(820, 1180));
    expect(tabLabels(tester),
        [l10n.narrowSidebarHosts, l10n.homeSessionsTab, l10n.narrowSidebarGroupManage, l10n.phoneTabMonitor, l10n.phoneTabMore]);
    await tester.tap(tab(4));
    await settle(tester);
    expect(find.byKey(const ValueKey('more-snippets')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-keys')), findsNothing, reason: 'Keys are the Manage tab');
    expect(find.byKey(const ValueKey('more-port-forwards')), findsNothing);
    await finish(tester);
  });

  testWidgets('the host search filters the hosts, and leaving Hosts ends it', (tester) async {
    final container = await pumpPhone(tester);
    // The quick connect field over the list is the search (the bar's own
    // search, which did the same, is gone).
    expect(find.byKey(const ValueKey('phone-host-search')), findsNothing);
    final field = find.byKey(const ValueKey('quick-connect-bar-field'));
    await tester.enterText(field, 'store');
    await settle(tester);
    expect(find.text('log-store'), findsOneWidget);
    expect(find.text('web-01'), findsNothing);
    expect(find.text('db-primary'), findsNothing);

    await tester.enterText(field, '10.50.0.22');
    await settle(tester);
    expect(find.text('web-01'), findsOneWidget, reason: 'the address matches too');
    expect(find.text('log-store'), findsNothing);

    await tester.enterText(field, 'nothing-like-it');
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-hosts-no-match')), findsOneWidget);

    await tester.tap(tab(4));
    await settle(tester);
    expect(container.read(connectionSearchQueryProvider), '');
    await tester.tap(tab(0));
    await settle(tester);
    expect(find.text('log-store'), findsOneWidget);
    expect(find.text('web-01'), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty, reason: 'the field empties with it');
    await finish(tester);
  });

  // 3.0, the outage work: a phone says how ZestSSH Cloud stands, where a
  // computer has its status bar for it.
  testWidgets('how ZestSSH Cloud stands is said on every tab while something is in the way, and not before',
      (tester) async {
    const refused = SocketException('Connection refused');
    final reach = CloudReachService(check: () async => throw refused);
    addTearDown(reach.dispose);
    await pumpPhone(tester, extra: [cloudReachProvider.overrideWithValue(reach)]);
    final banner = find.byKey(const ValueKey('cloud-reach-banner'));
    expect(banner, findsNothing, reason: 'nothing was asked of the service yet');

    await tester.runAsync(() async {
      reach.noAnswer(refused);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settle(tester);
    expect(banner, findsOneWidget);
    expect(find.text(l10n.cloudChipNotResponding), findsOneWidget);
    for (final i in [1, 2, 3, 4, 0]) {
      await tester.tap(tab(i));
      await settle(tester);
      expect(banner, findsOneWidget, reason: 'on tab $i');
    }
    await finish(tester);
  });

  // Seen on a phone: on the Monitor tab (no bar of the
  // home's, the Monitor screen has its own) the network strip was drawn
  // under the status bar, and the Monitor screen's bar kept the status
  // bar's height again below it, a gap. The status bar's height is kept
  // once, on every tab, with a notch and without, in landscape too. And
  // the banners sit under the tab's own bar, as under every tab's title
  // (they sat above it).
  for (final (phone, platform, top) in [
    ('an iPhone with a notch', TargetPlatform.iOS, 47.0),
    ('an iPhone without one', TargetPlatform.iOS, 20.0),
    ('an Android phone', TargetPlatform.android, 24.0),
  ]) {
    testWidgets('on $phone, 430 by 932: the bar of every tab sits under the status bar with no second gap, and the '
        'banners under the bar', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        tester.view.padding = FakeViewPadding(top: top);
        tester.view.viewPadding = FakeViewPadding(top: top);
        const refused = SocketException('Connection refused');
        final reach = CloudReachService(check: () async => throw refused);
        addTearDown(reach.dispose);
        await pumpPhone(tester, size: const Size(430, 932), extra: [cloudReachProvider.overrideWithValue(reach)]);
        await tester.runAsync(() async {
          reach.noAnswer(refused);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await settle(tester);
        final banner = find.byKey(const ValueKey('cloud-reach-banner'));
        final monitorBar =
            find.descendant(of: find.byType(ServerMonitorScreen), matching: find.byType(AppBar));
        final homeBar = find.byType(AppBar).first;

        // Hosts: the home's bar under the status bar, the banner under it.
        expect(tester.getTopLeft(homeBar).dy, 0);
        expect(tester.getSize(homeBar).height, top + kToolbarHeight);
        expect(tester.getTopLeft(banner).dy, top + kToolbarHeight);

        // Monitor: its own bar right under the status bar, as tall as a bar
        // is without a status bar, and the banner right under the bar.
        await tester.tap(tab(3));
        await settle(tester);
        expect(tester.getTopLeft(monitorBar).dy, top, reason: 'under the status bar, not under its clock');
        expect(tester.getSize(monitorBar).height, kToolbarHeight, reason: 'the status bar kept once, not twice');
        expect(tester.getTopLeft(banner).dy, tester.getBottomLeft(monitorBar).dy, reason: 'under the title');

        // And back: as before, nothing kept twice either way.
        await tester.tap(tab(0));
        await settle(tester);
        expect(tester.getTopLeft(banner).dy, top + kToolbarHeight);

        // With no banner, the Monitor bar is under the status bar, as any
        // bar is.
        await tester.runAsync(() async {
          reach.heard(200);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.tap(tab(3));
        await settle(tester);
        expect(banner, findsNothing);
        expect(tester.getTopLeft(monitorBar).dy, top);
        expect(tester.getSize(monitorBar).height, kToolbarHeight);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('in landscape with a notch at the side: the Monitor bar and the banner under it clear of it, and of '
      'the status bar once', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.padding = const FakeViewPadding(left: 47, right: 47, top: 0);
      tester.view.viewPadding = const FakeViewPadding(left: 47, right: 47, top: 0);
      const refused = SocketException('Connection refused');
      final reach = CloudReachService(check: () async => throw refused);
      addTearDown(reach.dispose);
      await pumpPhone(tester, size: const Size(932, 430), extra: [cloudReachProvider.overrideWithValue(reach)]);
      await tester.runAsync(() async {
        reach.noAnswer(refused);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settle(tester);
      await tester.tap(tab(3));
      await settle(tester);
      final banner = find.byKey(const ValueKey('cloud-reach-banner'));
      final monitorBar = find.descendant(of: find.byType(ServerMonitorScreen), matching: find.byType(AppBar));
      expect(tester.getTopLeft(monitorBar).dy, 0);
      expect(tester.getSize(monitorBar).height, kToolbarHeight);
      expect(tester.getTopLeft(banner), const Offset(47, kToolbarHeight));
      expect(tester.getTopRight(banner).dx, 932 - 47);
      await finish(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // 3.0: Wake-on-LAN is one action on every device; the phone's cards, which
  // had it first, go through it too.
  for (final (device, size) in [('a phone', const Size(390, 844)), ('a tablet', const Size(820, 1180))]) {
    testWidgets('on $device: a host with an address to wake has Wake in its sheet, and it sends for that host',
        (tester) async {
    final sent = <(String, String, int)>[];
    final container = await pumpPhone(
      tester,
      size: size,
      wake: {'c2': 'AA-BB-CC-0D-0E-0F'},
      extra: [
        wolSenderProvider.overrideWithValue(({required macAddress, required broadcastAddress, required port}) async {
          sent.add((macAddress, broadcastAddress, port));
          return const WolResult.sent(1);
        }),
      ],
    );
    // The phone Hosts as designed: Wake is a quick action of
    // the host's sheet (since 3.4: a long press selects the host, and the
    // selection's More has its Host actions). Only the one host that has an
    // address to wake offers it.
    final wakeButton = find.byKey(const ValueKey('phone-sheet-wake'));
    Future<void> hostSheet(String name) async {
      await tester.longPress(find.text(name));
      await settle(tester);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('phone-selection-actions')), matching: find.byKey(const ValueKey('phone-tab-4'))));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('phone-selection-host-actions')));
      await settle(tester);
    }

    await hostSheet('web-01');
    expect(find.byKey(const ValueKey('phone-sheet-connect')), findsOneWidget);
    expect(wakeButton, findsNothing);
    Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
    await settle(tester);
    await hostSheet('log-store');
    expect(wakeButton, findsOneWidget);
    expect(sent, isEmpty);
    await tester.tap(wakeButton);
    await settle(tester);
    expect(sent, [('AA-BB-CC-0D-0E-0F', '255.255.255.255', 9)]);
    final notice = container.read(notificationCenterProvider).history.first;
    expect([notice.title, if (notice.body != null) notice.body].join(' '), l10n.homeWolSent('log-store'));
    await tester.pump(const Duration(minutes: 1));
    await finish(tester);
    });
  }

  // 3.0: it said that something went wrong, and no more.
  testWidgets('hosts that could not be loaded say so, are loaded again, and have their details', (tester) async {
    var tries = 0;
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      },
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpPhone(tester, extra: [
      connectionsWithDetailsProvider.overrideWith((ref) {
        tries++;
        return Stream<List<ConnectionWithDetails>>.error(StateError('disk I/O error'));
      }),
    ]);
    expect(find.text(l10n.homeSomethingWentWrong), findsOneWidget);
    final before = tries;
    await tester.tap(find.byKey(const ValueKey('load-error-retry')));
    await settle(tester);
    expect(tries, greaterThan(before), reason: 'Try again loads them again');
    await tester.tap(find.text('Copy details'));
    await tester.pump();
    expect(copied.single, contains('Where: Loading the hosts'));
    expect(copied.single, contains('disk I/O error'));
    await tester.pump(const Duration(seconds: 3));
    await finish(tester);
  });

  testWidgets('More opens each screen', (tester) async {
    await pumpPhone(tester);
    await tester.tap(tab(4));
    await settle(tester);
    final rows = {
      'more-networks': Routes.networks,
      'more-snippets': Routes.snippets,
      'more-triggers': Routes.triggers,
      'more-history': Routes.commandHistory,
      'more-automation': Routes.automationSettings,
      'more-settings': Routes.settings,
      'more-account': Routes.profile,
      'more-help': Routes.help,
    };
    for (final MapEntry(key: row, value: route) in rows.entries) {
      final finder = find.byKey(ValueKey(row));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await settle(tester);
      expect(find.text('route $route'), findsOneWidget, reason: row);
      GoRouter.of(tester.element(find.text('route $route'))).pop();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('phone-more')), findsOneWidget, reason: 'back on More after $row');
    }
    await finish(tester);
  });

  testWidgets('in an Orchard: the Team at the top of More, and a dot on More when it needs someone',
      (tester) async {
    const quiet = OrchardSummary(id: 'o-1', name: 'Acme', role: 'owner', crates: [], defaultCrateId: 'c');
    await pumpPhone(tester, orchard: quiet);
    Finder dotOnMore() => find.descendant(of: tab(4), matching: find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).shape == BoxShape.circle));
    expect(dotOnMore(), findsNothing);
    await tester.tap(tab(4));
    await settle(tester);
    expect(find.byKey(const ValueKey('more-team')), findsOneWidget);
    expect(find.text(l10n.teamYouAreOwner), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('more-team')));
    await settle(tester);
    expect(find.text('route ${Routes.team}'), findsOneWidget);
    await finish(tester);

    const waiting = OrchardSummary(
        id: 'o-1', name: 'Acme', role: 'owner', crates: [], defaultCrateId: 'c', invitesWaiting: 2);
    await pumpPhone(tester, orchard: waiting);
    expect(dotOnMore(), findsOneWidget);
    await finish(tester);
  }, skip: !kOrchardsEnabled);

  testWidgets('Sessions counts the live sessions, and offers Open session beside them', (tester) async {
    final container = await pumpPhone(tester);
    (container.read(activeSessionsProvider.notifier) as _Sessions).set({
      's1': const SessionState(status: SessionStatus.connected, connectionId: 'c0', connectionLabel: 'db-primary'),
      's2': const SessionState(status: SessionStatus.connecting, connectionId: 'c1', connectionLabel: 'web-01'),
      's3': const SessionState(status: SessionStatus.disconnected, connectionId: 'c2', connectionLabel: 'log-store'),
    });
    await settle(tester);
    expect(find.descendant(of: tab(1), matching: find.text('2')), findsOneWidget, reason: 'two live, one dropped');
    await tester.tap(tab(1));
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-open-session')), findsOneWidget);
    await finish(tester);
  });

  // An audit of an external keyboard and mouse on Android and an iPad:
  // a phone's and a tablet's Home had no keys, and a right
  // click on a session did nothing.
  testWidgets('a keyboard: Ctrl+T gives the quick connect field the keyboard, Ctrl+Shift+N opens New host',
      (tester) async {
    await pumpPhone(tester);
    final field = find.byKey(const ValueKey('quick-connect-bar-field'));
    bool fieldHasKeyboard() => tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).focusNode.hasFocus;
    expect(fieldHasKeyboard(), isFalse);

    // From another tab: Hosts comes to the front with the field.
    await tester.tap(tab(4));
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-hosts')), findsOneWidget);
    expect(fieldHasKeyboard(), isTrue);

    // While a text field has the keyboard its keys are its own.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('route ${Routes.connectionEdit}'), findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('route ${Routes.connectionEdit}'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a right click on a session selects it, as a long press does', (tester) async {
    final container = await pumpPhone(tester);
    (container.read(activeSessionsProvider.notifier) as _Sessions).set({
      's1': const SessionState(status: SessionStatus.connected, connectionId: 'c0', connectionLabel: 'db-primary'),
      's2': const SessionState(status: SessionStatus.connected, connectionId: 'c1', connectionLabel: 'web-01'),
    });
    await settle(tester);
    await tester.tap(tab(1));
    await settle(tester);
    expect(find.text(l10n.sessionsBulkExit), findsNothing);
    await tester.tapAt(tester.getCenter(find.text('web-01').last), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.byTooltip(l10n.sessionsBulkExit), findsOneWidget, reason: 'the bar of the selected ones');
    expect(find.text(l10n.sessionsBulkSelectedCount(1)), findsOneWidget);
    await finish(tester);
  });
}
