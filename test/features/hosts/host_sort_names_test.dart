import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/host_sort_mode.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/host_slide_out_panel.dart';

import '../../visual/shots_util.dart';

/// The host sort's names are in the person's language wherever its menu is
/// drawn (3.0). The Hosts page's menu and its button, and a
/// computer's host panel, showed each sort's English name ("Recent", "IP
/// address", "Group color"), whatever the language; the SFTP picker alone said
/// them in the person's.
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
  final de = lookupAppLocalizations(const Locale('de'));

  test("every sort is named in each language's own words", () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect([for (final m in HostSortMode.values) m.nameIn(l10n)], [
        l10n.hostSortRecent,
        l10n.hostSortHealth,
        l10n.hostSortStatus,
        l10n.hostSortAlphabetical,
        l10n.hostSortIpAddress,
        l10n.hostSortGroupColor,
        l10n.hostSortManual,
      ], reason: '$locale');
    }
    expect(HostSortMode.recent.nameIn(de), isNot('Recent'));
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget body) async {
    // The fonts the app ships: the test font draws each letter as a square as
    // wide as it is high, and rows that fit in the app overflow in it.
    await tester.runAsync(loadShotFonts);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 9, 24);
    for (final (id, label, host) in [('c0', 'db-primary', '10.50.0.21'), ('c1', 'web-01', '10.50.0.13')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id, label: label, host: host, port: const Value(22), createdAt: now, updatedAt: now));
    }
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      serverStatsProvider.overrideWith(_NoStats.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: Scaffold(body: body),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return container;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  testWidgets("the Hosts page's sort menu and its button, in German", (tester) async {
    final container =
        await pump(tester, HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {}, onSwitchToSession: (_) {}));
    final button = find.text(de.hostsHomeSortPrefix(de.hostSortRecent));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    // In the menu (the Hosts section's head names the sort too), with
    // Active first under the sorts since 4.0.
    Finder inMenu(String text) =>
        find.descendant(of: find.byType(PopupMenuItem<Object>), matching: find.text(text));
    for (final m in HostSortMode.values) {
      expect(inMenu(m.nameIn(de)), findsOneWidget, reason: m.name);
    }
    expect(inMenu(de.hostsActiveFirst), findsOneWidget);
    await tester.tap(inMenu(de.hostSortIpAddress));
    await tester.pumpAndSettle();
    expect(container.read(hostSortModeProvider), HostSortMode.ipAddress);
    expect(find.text(de.hostsHomeSortPrefix(de.hostSortIpAddress)), findsOneWidget);
    await finish(tester);
  });

  testWidgets("a computer's host panel: its sort menu in German", (tester) async {
    final container = await pump(
        tester,
        Row(children: [
          HostSlideOutPanel(onConnectTo: (_) {}, onManageHosts: () {}, onClose: () {}),
          const Expanded(child: SizedBox()),
        ]));
    await tester.tap(find.byTooltip(de.sftpSortHosts));
    await tester.pumpAndSettle();
    for (final m in HostSortMode.values) {
      expect(find.text(m.nameIn(de)), findsOneWidget, reason: m.name);
    }
    await tester.tap(find.text(de.hostSortGroupColor));
    await tester.pumpAndSettle();
    expect(container.read(hostSortModeProvider), HostSortMode.groupColor);
    await finish(tester);
  });
}
