import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/wol_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/host_slide_out_panel.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';

import '../../helpers/desktop_mouse.dart';

/// Wake-on-LAN on a computer (3.0: all devices
/// should have it ). The host editor saves an address to wake on
/// every device, and only a phone's host cards could send the packet. Every
/// place a computer shows a menu for a host offers it now, and so does the
/// host's panel: the Hosts page, the hosts shown where no session is open
/// (as a grid and as a list), and the hosts drawer. Only for a host that has
/// an address to wake saved, and each through the same action.

/// The fonts the app ships. (The test font draws every letter as a square
/// as wide as the text is high, so rows that fit in the app overflow in it.)
Future<void> _loadFonts() async {
  for (final (family, files) in [
    ('GeistSans', ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf', 'GeistSans-Bold.ttf']),
    ('JetBrainsMono', ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf']),
  ]) {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File('assets/fonts/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load().timeout(const Duration(seconds: 30));
  }
}

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
}

class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// What was asked to be sent: (address to wake, where to, port).
  late List<(String, String, int)> sent;

  /// Lets the database answer and the screen follow, for longer than a
  /// click waits to see whether it is the first of two.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// [body] on a computer's screen, over a database with two hosts: one
  /// with an address to wake saved (db-primary) and one without (web-01).
  Future<ProviderContainer> pump(WidgetTester tester, Widget body) async {
    sent = [];
    await tester.runAsync(_loadFonts);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 9);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-db',
          label: 'db-primary',
          host: '192.168.10.31',
          createdAt: now,
          updatedAt: now,
          wolMacAddress: const Value('AA-BB-CC-0D-0E-0F'),
          wolBroadcastAddress: const Value('192.168.10.255'),
        ));
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: '192.168.10.21',
          createdAt: now,
          updatedAt: now,
        ));
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      serverStatsProvider.overrideWith(_NoStats.new),
      // Whether the host's Crate is closed is asked for real (never, in a
      // Tree); only the sockets are stood in for.
      wolSenderProvider.overrideWithValue(({required macAddress, required broadcastAddress, required port}) async {
        sent.add((macAddress, broadcastAddress, port));
        return const WolResult.sent(1);
      }),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: body),
      ),
    ));
    await settle(tester);
    return c;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  final wake = find.text(l10n.connectionCardWakeWol);

  /// What the last notice says.
  String said(ProviderContainer c) {
    final notice = c.read(notificationCenterProvider).history.first;
    return [notice.title, if (notice.body != null) notice.body].join(' ');
  }

  /// A right-click on the host shown as [label], and on the Hosts page its
  /// Tools (4.0: the menu grouped), where Wake is; what is on its menu is
  /// then on screen. (The slide-out panel's menu is one list.)
  Future<void> menuOf(WidgetTester tester, String label) async {
    await TestMouse(tester).rightClick(find.text(label).first);
    await settle(tester);
    final tools = find.byKey(const ValueKey('host-menu-tools'));
    if (tools.evaluate().isNotEmpty) {
      await tester.tap(tools);
      await settle(tester);
    }
  }

  /// Presses Wake on the open menu and lets the packet go.
  Future<void> pressWake(WidgetTester tester) async {
    await tester.tap(wake);
    await settle(tester);
  }

  /// Closes an open menu without choosing from it.
  Future<void> closeMenu(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
  }

  const forTheHost = [('AA-BB-CC-0D-0E-0F', '192.168.10.255', 9)];

  Widget hostsPage() => HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {}, onSwitchToSession: (_) {});

  desktopTest('the Hosts page: a right-click offers Wake for a host with an address to wake, and sends for it',
      (tester) async {
    final c = await pump(tester, hostsPage());
    await menuOf(tester, 'db-primary');
    expect(wake, findsOneWidget);
    await pressWake(tester);
    expect(sent, forTheHost);
    expect(said(c), l10n.homeWolSent('db-primary'));

    // A host with none saved has no such item.
    await menuOf(tester, 'web-01');
    expect(find.text(l10n.edit), findsOneWidget, reason: 'its menu is open');
    expect(wake, findsNothing);
    await closeMenu(tester);
    expect(sent, hasLength(1));
    await finish(tester);
  });

  desktopTest('the host panel: says what Wake does and sends for the host; no such section without an address',
      (tester) async {
    final c = await pump(tester, hostsPage());
    await tester.tap(find.text('db-primary').first);
    await settle(tester);
    expect(find.byKey(const ValueKey('host-panel-h-db')), findsOneWidget);
    expect(find.text(l10n.hostPanelWakeHint), findsOneWidget);
    expect(sent, isEmpty, reason: 'opening the panel sends nothing');
    await tester.tap(find.byKey(const ValueKey('host-panel-wake')));
    await settle(tester);
    expect(sent, forTheHost);
    expect(said(c), l10n.homeWolSent('db-primary'));

    await tester.tap(find.text('web-01').first);
    await settle(tester);
    expect(find.byKey(const ValueKey('host-panel-h-web')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-panel-wake')), findsNothing);
    expect(find.text(l10n.hostPanelWakeHint), findsNothing);
    await finish(tester);
  });


  desktopTest('the hosts drawer: the same', (tester) async {
    final c = await pump(
        tester,
        Row(children: [
          HostSlideOutPanel(onConnectTo: (_) {}, onManageHosts: () {}, onClose: () {}),
          const Expanded(child: SizedBox()),
        ]));
    await menuOf(tester, 'db-primary');
    expect(wake, findsOneWidget);
    await pressWake(tester);
    expect(sent, forTheHost);
    expect(said(c), l10n.homeWolSent('db-primary'));

    await menuOf(tester, 'web-01');
    expect(find.text(l10n.hostMenuEdit), findsOneWidget, reason: 'its menu is open');
    expect(wake, findsNothing);
    await closeMenu(tester);
    expect(sent, hasLength(1));
    await finish(tester);
  });
}
