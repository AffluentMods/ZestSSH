import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

import '../../helpers/orchard_db_fixture.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A team's host saved as a local shell never opens one (found in a security
/// audit): one that came here anyway says so on its row, where it would be
/// tapped, and the host form does not offer a local shell in a team's space.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  const summary = OrchardSummary(id: kFixtureOrchardId, name: 'Acme', role: 'owner', crates: [], defaultCrateId: kFixtureCrateId);
  late AppDatabase team;
  late AppDatabase tree;

  Future<void> host(AppDatabase db, String id, String protocol) async {
    final at = DateTime(2026, 10, 30);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: '$id.example.com', protocol: Value(protocol), createdAt: at, updatedAt: at));
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
  }

  setUp(() async {
    team = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    await seedOrchardAsOwner(team);
    await host(team, 'blocked', 'localShell');
    await host(team, 'ordinary', 'ssh');
    await host(tree, 'mine', 'localShell');
  });

  tearDown(() async {
    debugHostFormLocalShell = null;
    debugHostFormOnComputer = null;
    await team.close();
    await tree.close();
  });

  Future<void> pump(WidgetTester tester, AppDatabase db, Widget home) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(tree),
      isProProvider.overrideWith((ref) => _Pro()),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      if (db.isOrchard) activeOrchardProvider.overrideWithValue(const AsyncData(summary)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The test font draws every glyph one em wide, so some labels overflow here
    // that fit with a real font.
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Widget phoneRows(List<Connection> hosts) => ListView(children: [
        for (final h in hosts)
          PhoneHostRow(
            host: ConnectionWithDetails(connection: h),
            open: false,
            health: null,
            pinned: false,
            actions: PhoneHostActions(connect: () {}, edit: () {}),
          ),
      ]);

  testWidgets("a phone's row says it is blocked, in place of its address; another of the team's shows its address", (tester) async {
    final hosts = [for (final id in ['blocked', 'ordinary']) (await team.connectionsDao.getById(id))!];
    await pump(tester, team, phoneRows(hosts));
    expect(find.text(en.teamHostLocalShellRow), findsOneWidget);
    expect(find.textContaining('ordinary.example.com'), findsOneWidget);
    expect(find.textContaining('blocked.example.com'), findsNothing);
    await finish(tester);
  });

  testWidgets("a phone's row of a person's own local shell says nothing of it", (tester) async {
    await pump(tester, tree, phoneRows([(await tree.connectionsDao.getById('mine'))!]));
    expect(find.text(en.teamHostLocalShellRow), findsNothing);
    await finish(tester);
  });

  testWidgets("a computer's card says it is blocked too", (tester) async {
    await pump(tester, team, HostsHomePage(onConnectTo: (_) {}));
    expect(find.text(en.teamHostLocalShellRow), findsOneWidget);
    await finish(tester);
  });

  testWidgets("the host form offers a local shell in a person's own space, not in a team's", (tester) async {
    debugHostFormOnComputer = true;
    debugHostFormLocalShell = true;
    await pump(tester, tree, ConnectionEditScreen(inDialog: true, onClose: () {}));
    expect(find.text(en.connectionEditProtocolLocalShort), findsOneWidget);
    await finish(tester);

    await pump(tester, team, ConnectionEditScreen(inDialog: true, onClose: () {}));
    expect(find.text(en.connectionEditProtocolLocalShort), findsNothing);
    expect(find.text(en.connectionEditProtocolSerialShort), findsOneWidget, reason: 'SSH to a console server stays');
    await finish(tester);
  });
}
