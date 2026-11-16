import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/hosts/phone/phone_host_page.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/state/host_sort_mode.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/local_shell_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart';

import '../visual/shots_util.dart';

/// A phone's Hosts tab (4.0, as
/// designed): fewer rows of controls before the first host (the search,
/// one row of group chips, the first section's head with the sort; Local
/// terminal an icon in the bar, Active first and Arrange in the sort's sheet,
/// New group in the +'s menu), each host a row as a computer's card has it
/// (its OS tile, Open or 2 open, one health chip) that a tap connects, a long
/// press selects, and one more button opens the rest; room under the list so
/// the + never covers the last host.

/// web-01 open twice; whatever is opened is written down, nothing started.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {
      's1': const SessionState(status: SessionStatus.connected, connectionId: 'c0'),
      's2': const SessionState(status: SessionStatus.connected, connectionId: 'c0'),
    };
  }

  final started = <String>[];

  @override
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) {
    started.add(connection.protocol);
    return 'started-${started.length}';
  }
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _disk = MetricEval(metric: MonitorMetric.disk, value: 100, warn: 80, crit: 90, severity: MetricSeverity.critical);
const _ram = MetricEval(metric: MonitorMetric.ram, value: 84, warn: 80, crit: 90, severity: MetricSeverity.warning);

/// Web (web-01, web-02), Databases (db-primary) and the rest in no group.
const _hosts = [
  ('c0', 'web-01', '192.168.10.21', 'g-web', 'ubuntu'),
  ('c1', 'web-02', '192.168.10.22', 'g-web', 'ubuntu'),
  ('c2', 'db-primary', '192.168.10.31', 'g-db', 'debian'),
  ('c3', 'log-store', '192.168.10.24', null, 'rocky'),
  ('c4', 'mac-studio', '192.168.10.3', null, null),
];

/// An Android phone.
final _android = TargetPlatformVariant.only(TargetPlatform.android);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  late AppDatabase db;
  late _Sessions sessions;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Home on a phone of [size], on its Hosts tab; [extra] hosts more, to fill
  /// the screen.
  Future<ProviderContainer> pump(WidgetTester tester, {Size size = const Size(390, 844), int extra = 0}) async {
    await tester.runAsync(loadShotFonts);
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 11, 12);
    await tester.runAsync(() async {
      for (final (id, name, order) in [('g-web', 'Web', 0), ('g-db', 'Databases', 1)]) {
        await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
              id: id,
              name: name,
              sortOrder: Value(order),
              createdAt: now,
              updatedAt: Value(now),
            ));
      }
      for (final (id, label, host, group, _) in _hosts) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: host,
              groupId: Value(group),
              createdAt: now,
              updatedAt: now,
            ));
      }
      for (var i = 0; i < extra; i++) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: 'x$i',
              label: 'node-${(i + 10).toString()}',
              host: '10.0.0.${i + 10}',
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
    SharedPreferences.setMockInitialValues({
      // The systems seen on them, as the app keeps them.
      for (final (id, _, _, _, os) in _hosts) 'os_kind_$id': ?os,
    });
    final prefs = await SharedPreferences.getInstance();
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
      isProProvider.overrideWith((ref) => _Pro()),
      activeSessionsProvider.overrideWith((ref) => sessions = _Sessions(ref)),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 12, 12))),
      // Server Monitor: log-store's disk is full; web-02's memory runs high
      // and its disk is full too.
      monitoredHostViewsProvider.overrideWith((ref) => const {
            'c3': MonitorHostView(bucket: MonitorBucket.critical, metrics: [_disk]),
            'c1': MonitorHostView(bucket: MonitorBucket.critical, metrics: [_ram, _disk]),
          }),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.dark(),
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

  Finder row(String section, String id) => find.byKey(ValueKey('phone-host-$section-$id'));

  testWidgets('before the first host: the search, one row of chips with counts and the first head with the sort',
      (tester) async {
    await pump(tester);
    expect(find.byType(QuickConnectBar), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('quick-connect-bar-field')));
    expect((field.decoration!.prefixIcon! as Icon).icon, LucideIcons.search, reason: 'a search, as a computer has it');
    // The chips, each group's with its count; no New group chip.
    expect(find.descendant(of: find.byKey(const ValueKey('phone-filter-g-web')), matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('phone-filter-g-db')), matching: find.text('1')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-filter-new-group')), findsNothing);
    expect(find.byKey(const ValueKey('phone-filter-arrange')), findsNothing, reason: 'in the sort\'s sheet');
    expect(find.byKey(const ValueKey('active-first-phoneHosts')), findsNothing, reason: 'in the sort\'s sheet');
    // The sort on the first head only, saying the sort in use.
    final sort = find.byKey(const ValueKey('phone-hosts-sort'));
    expect(sort, findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('phone-section-g-web')), matching: sort), findsOneWidget);
    expect(find.descendant(of: sort, matching: find.text(en.hostSortRecent)), findsOneWidget);
    expect(tester.getSize(sort).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel(en.hostsHomeSortPrefix(en.hostSortRecent)), findsOneWidget);
    // Local terminal: an icon in the bar where the device has one, no card.
    expect(find.text('Open a shell on this device'), findsNothing);
    expect(find.byKey(const ValueKey('phone-local-terminal')), LocalShellService.isAvailable ? findsOneWidget : findsNothing);
    expect(find.byTooltip(en.homeLocalTerminal), LocalShellService.isAvailable ? findsOneWidget : findsNothing);
    // The first host's row right under the head: nothing else between.
    final head = tester.getRect(find.byKey(const ValueKey('phone-section-g-web')));
    expect(tester.getTopLeft(row('g-web', 'c0')).dy - head.bottom, lessThan(12));
    await finish(tester);
  }, variant: _android);

  testWidgets('Local terminal from the bar opens a shell on the device', (tester) async {
    await pump(tester);
    if (!LocalShellService.isAvailable) return finish(tester);
    await tester.tap(find.byKey(const ValueKey('phone-local-terminal')));
    await settle(tester);
    expect(sessions.started, ['localShell']);
    expect(find.text('route /terminal/started-1'), findsOneWidget);
    await finish(tester);
  }, variant: _android);

  testWidgets('a row: its OS tile, 2 open, one chip, its address and one 48 high more button', (tester) async {
    await pump(tester);
    final web01 = row('g-web', 'c0');
    final web02 = row('g-web', 'c1');
    // The OS tile a computer's card draws, no letter.
    expect(find.descendant(of: web01, matching: find.byType(HostIcon)), findsOneWidget);
    expect(find.descendant(of: row('__ungrouped__', 'c4'), matching: find.byType(HostIcon)), findsOneWidget,
        reason: 'a system not seen yet: the terminal, as a computer draws it');
    expect(find.descendant(of: row('__ungrouped__', 'c4'), matching: find.text('M')), findsNothing);
    // Open, in words.
    expect(find.descendant(of: web01, matching: find.text(en.hostOpenSessionsCount(2))), findsOneWidget);
    // One chip: the worst of two.
    expect(find.descendant(of: web02, matching: find.byType(HostHealthChipView)), findsOneWidget);
    expect(find.descendant(of: web02, matching: find.text('Disk 100%')), findsOneWidget);
    expect(find.descendant(of: row('__ungrouped__', 'c3'), matching: find.text('Disk 100%')), findsOneWidget);
    // One more button, a thumb's size, named; no info and no arrow.
    final more = find.byKey(const ValueKey('phone-host-more-c0'));
    expect(more, findsOneWidget);
    expect(tester.getSize(more), const Size(48, 48));
    expect(find.bySemanticsLabel(en.phoneHostMoreActions('web-01')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-host-info-c0')), findsNothing);
    expect(find.byKey(const ValueKey('phone-connect-c0')), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, variant: _android);

  testWidgets('a tap connects, a long press selects, the more button opens the sheet with Details', (tester) async {
    final c = await pump(tester);
    // web-01 is open: a tap goes back to its session.
    await tester.tap(find.descendant(of: row('g-web', 'c0'), matching: find.text('web-01')));
    await settle(tester);
    expect(find.textContaining('route /terminal/'), findsOneWidget);
    Navigator.of(tester.element(find.textContaining('route /terminal/'))).pop();
    await settle(tester);
    // The more button: the host's sheet, its details first.
    await tester.tap(find.byKey(const ValueKey('phone-host-more-c2')));
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-sheet-details')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-sheet-edit')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-sheet-details')));
    await settle(tester);
    expect(find.byType(PhoneHostPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(PhoneHostPage))).pop();
    await settle(tester);
    // A long press selects, as before.
    await tester.longPress(find.descendant(of: row('g-db', 'c2'), matching: find.text('db-primary')));
    await settle(tester);
    expect(c.read(hostMultiSelectProvider).isSelected('c2'), isTrue);
    expect(find.byKey(const ValueKey('phone-host-more-c2')), findsNothing, reason: 'while selecting a tap selects');
    await finish(tester);
  }, variant: _android);

  testWidgets("the host's sheet is grouped as a computer's menu: Details and Edit, then Organize, then Tools, Delete "
      'last', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('phone-host-more-c2')));
    await settle(tester);
    double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
    final organize = top('phone-sheet-section-organize');
    final tools = top('phone-sheet-section-tools');
    for (final name in [en.hostMenuOrganize, en.hostMenuTools]) {
      expect(find.textContaining(RegExp('^$name\$', caseSensitive: false)), findsOneWidget, reason: name);
    }
    expect(top('phone-sheet-edit'), lessThan(organize));
    // Organize: where the host is kept.
    for (final k in ['phone-sheet-group', 'phone-sheet-pin']) {
      expect(top(k), allOf(greaterThan(organize), lessThan(tools)), reason: k);
    }
    // Tools: what else may be done with it.
    expect(top('phone-sheet-copy'), greaterThan(tools));
    // The sections are headings to a screen reader.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(en.hostMenuOrganize, caseSensitive: false)), findsWidgets);
    semantics.dispose();
    final delete = find.byKey(const ValueKey('phone-sheet-delete'));
    if (delete.evaluate().isNotEmpty) expect(top('phone-sheet-delete'), greaterThan(top('phone-sheet-copy')));
    expect(tester.takeException(), isNull);
    await finish(tester);
  }, variant: _android);

  testWidgets("the sort's sheet: the sorts, Active first and Arrange; a sort orders every section", (tester) async {
    final c = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('phone-hosts-sort')));
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-sort-sheet')), findsOneWidget);
    for (final m in HostSortMode.values) {
      expect(find.byKey(ValueKey('phone-sort-${m.name}')), findsOneWidget, reason: m.name);
    }
    expect(find.bySemanticsLabel(en.hostsActiveFirst), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-sort-arrange')), findsOneWidget);
    // Active first, there and back, the same preference as before.
    await tester.tap(find.byKey(const ValueKey('phone-sort-active-first')));
    await settle(tester);
    expect(c.read(activeFirstProvider(HostListPlace.phoneHosts)), isTrue);
    await tester.tap(find.byKey(const ValueKey('phone-sort-active-first')));
    await settle(tester);
    expect(c.read(activeFirstProvider(HostListPlace.phoneHosts)), isFalse);
    // A sort: picked, and said on the head.
    await tester.tap(find.byKey(const ValueKey('phone-sort-ipAddress')));
    await settle(tester);
    expect(c.read(hostSortModeProvider), HostSortMode.ipAddress);
    expect(find.descendant(of: find.byKey(const ValueKey('phone-hosts-sort')), matching: find.text(en.hostSortIpAddress)),
        findsOneWidget);
    // The hosts in no group by their addresses: mac-studio (.3) before
    // log-store (.24); A to Z puts them the other way round.
    double y(String id) => tester.getTopLeft(row('__ungrouped__', id)).dy;
    expect(y('c4'), lessThan(y('c3')));
    await tester.tap(find.byKey(const ValueKey('phone-hosts-sort')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('phone-sort-alphabetical')));
    await settle(tester);
    expect(y('c3'), lessThan(y('c4')), reason: 'log-store before mac-studio by name');
    await tester.tap(find.byKey(const ValueKey('phone-hosts-sort')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('phone-sort-arrange')));
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-arrange-bar')), findsOneWidget);
    expect(c.read(hostSortModeProvider), HostSortMode.manual);
    await finish(tester);
  }, variant: _android);

  testWidgets('room under the list: scrolled to its end, the + covers no host', (tester) async {
    await pump(tester, extra: 14);
    final list = find.byKey(const ValueKey('phone-hosts-list'));
    await tester.drag(list, const Offset(0, -4000));
    await settle(tester);
    final fab = tester.getRect(find.byKey(const ValueKey('phone-new-host')));
    final last = tester.getRect(row('__ungrouped__', 'x13'));
    expect(last.bottom, lessThan(fab.top), reason: 'the last host above the +');
    await finish(tester);
  }, variant: _android);
}
