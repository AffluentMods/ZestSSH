import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/features/networks/widgets/network_list_pane.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/host_slide_out_panel.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_list_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';

import '../visual/shots_util.dart';

/// Switching spaces (the screen flashed when
/// switching vaults): a switch changes the database every list reads, so each
/// reloads, and a list drawn with a spinner while it loaded put one in place of
/// everything for that moment. Each keeps what it shows until the other
/// space's rows are there.
final _space = StateProvider<int>((ref) => 0);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> seed(AppDatabase db, String name) async {
    final now = DateTime(2026, 10, 20);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: '$name-c', label: '$name-host', host: '192.168.10.21', monitored: const Value(true),
        createdAt: now, updatedAt: now));
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: '$name-i', label: '$name-key', username: 'deploy', authMethod: 'password', createdAt: now));
    await db.into(db.snippets).insert(SnippetsCompanion.insert(
        id: '$name-s', label: '$name-snippet', command: 'uptime', createdAt: now, updatedAt: now));
    await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
        id: '$name-p', connectionId: '$name-c', type: 'local', bindPort: 8080, remoteHost: 'localhost', remotePort: 80,
        label: Value('$name-forward'), createdAt: now));
    await db.into(db.networks).insert(NetworksCompanion.insert(
        id: '$name-n', name: '$name-net', iconCodePoint: 0xe1ba, createdAt: now, updatedAt: Value(now)));
    await db.into(db.terminalTriggers).insert(TerminalTriggersCompanion.insert(
        id: '$name-t', name: '$name-trigger', pattern: 'ERROR', createdAt: now));
  }

  Future<ProviderContainer> pump(WidgetTester tester, Widget page) async {
    // The app's own fonts: a narrow panel's rows are laid out as in the app.
    await tester.runAsync(loadShotFonts);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(a.close);
    addTearDown(b.close);
    await tester.runAsync(() async {
      await seed(a, 'alpha');
      await seed(b, 'beta');
    });
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      treeDatabaseProvider.overrideWithValue(a),
      // A space switch, as the app makes it: the database every list reads.
      databaseProvider.overrideWith((ref) => ref.watch(_space) == 0 ? a : b),
      healthChecksEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: page),
      ),
    ));
    await settle(tester);
    return c;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  final pages = <(String, Widget, String)>[
    ('the Hosts page', HostsHomePage(onConnectTo: (_) {}), 'host'),
    // The drawer beside the page, as the shell lays it out.
    (
      'the Hosts drawer',
      Row(children: [
        HostSlideOutPanel(onConnectTo: (_) {}, onManageHosts: () {}, onClose: () {}),
        const Expanded(child: SizedBox()),
      ]),
      'host'
    ),
    ('Keys', KeysListPane(selectedId: null, onSelect: (_) {}, onNew: (_) {}), 'key'),
    ('Snippets', const SnippetsLibraryView(), 'snippet'),
    ('Port forwarding', const PortForwardListView(), 'forward'),
    ('Networks', NetworkListPane(selectedId: null, onSelect: (_) {}, onNew: () {}), 'net'),
    ("a phone's Networks page", const NetworksMobileScreen(), 'net'),
    ('Triggers', const TriggersScreen(embedded: true), 'trigger'),
  ];
  for (final (title, page, what) in pages) {
    testWidgets('$title keeps what it shows while another space loads, then shows that space', (tester) async {
      final c = await pump(tester, page);
      // Its databases' streams end first, whatever the checks find (a check
      // that failed left them open, and the run hung).
      try {
        expect(find.textContaining('alpha-$what'), findsWidgets, reason: 'the first space');
        c.read(_space.notifier).state = 1;
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'no spinner in place of the list');
        expect(find.textContaining('alpha-$what'), findsWidgets,
            reason: 'what it showed, until the other rows are there');
        await settle(tester);
        expect(find.textContaining('beta-$what'), findsWidgets, reason: 'the other space');
      } finally {
        await finish(tester);
      }
    });
  }
}
