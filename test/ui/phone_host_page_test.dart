// A host's page on a phone (3.1): the small info button at the end of a
// host's row opens it, with Connect and Files at the top and what the
// computer's host panel shows (health from Server Monitor, recent sessions,
// port forwards, tags, note) and Edit. A tap on the row still connects.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/pending_files.dart';
import 'package:zestssh/features/hosts/phone/phone_host_page.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _cpu = MetricEval(metric: MonitorMetric.cpu, value: 42, warn: 80, crit: 90, severity: MetricSeverity.healthy);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 24);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1',
          label: 'web-01',
          host: '192.168.10.21',
          monitored: const Value(true),
          note: const Value('Rack 3, top shelf'),
          createdAt: at,
          updatedAt: at,
        ));
    await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: 'pf1',
          connectionId: 'h1',
          type: 'local',
          bindPort: 8080,
          remoteHost: 'localhost',
          remotePort: 80,
          label: const Value('Web UI'),
          createdAt: at,
        ));
    await db.connectionTagsDao.setTagsForConnection('h1', ['lab', 'web']);
  });

  tearDown(() => db.close());

  final calls = <String>[];

  Future<ProviderContainer> pump(WidgetTester tester, {Widget? home}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    calls.clear();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
      monitoredHostViewsProvider
          .overrideWith((ref) => const {'h1': MonitorHostView(bucket: MonitorBucket.healthy, metrics: [_cpu])}),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: home ??
              Consumer(builder: (context, ref, _) {
                final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
                return ListView(children: [
                  for (final h in hosts)
                    PhoneHostRow(
                      host: h,
                      open: false,
                      health: null,
                      pinned: false,
                      actions: PhoneHostActions(
                        connect: () => calls.add('connect ${h.connection.id}'),
                        edit: () => calls.add('edit ${h.connection.id}'),
                      ),
                    ),
                ]);
              }),
        ),
      ),
    ));
    await settle(tester);
    return c;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  /// The host's page, from the row's one more button and its sheet's Details
  /// (4.0: it was an info button at the row's end).
  Future<void> openDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('phone-host-more-h1')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('phone-sheet-details')));
    await settle(tester);
  }

  testWidgets('a tap on the row still connects; the more button opens the sheet and connects nothing',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('web-01'));
    await settle(tester);
    expect(calls, ['connect h1']);
    expect(find.byType(PhoneHostPage), findsNothing);
    calls.clear();
    await tester.tap(find.byKey(const ValueKey('phone-host-more-h1')));
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-sheet-details')), findsOneWidget);
    expect(calls, isEmpty);
    await finish(tester);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));

  testWidgets("the sheet's Details opens the host's page: Connect, Files, health, sessions' forwards, tags, note, Edit",
      (tester) async {
    final c = await pump(tester);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(en.phoneHostMoreActions('web-01')), findsOneWidget);
    semantics.dispose();
    await openDetails(tester);
    expect(find.byType(PhoneHostPage), findsOneWidget);
    expect(calls, isEmpty, reason: 'opening the page connects nothing');
    expect(find.byKey(const ValueKey('phone-host-page-connect')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-host-page-files')), findsOneWidget);
    expect(find.text(en.hostPanelConnect), findsOneWidget);
    expect(find.text(en.phoneHostsFiles), findsOneWidget);
    // What the computer's panel shows of it.
    expect(find.text(en.hostPanelHealth.toUpperCase()), findsOneWidget);
    expect(find.byKey(const ValueKey('host-panel-metric-cpu')), findsOneWidget);
    expect(find.text(en.hpanelPortForwards.toUpperCase()), findsOneWidget);
    expect(find.textContaining('Web UI'), findsOneWidget);
    expect(find.text(en.hostPanelConnection.toUpperCase()), findsOneWidget);
    expect(find.textContaining('192.168.10.21'), findsWidgets);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('phone-host-page-note')), 200);
    expect(find.descendant(of: find.byKey(const ValueKey('phone-host-page-tags')), matching: find.byType(HostTagChip)),
        findsNWidgets(2));
    expect(find.text('Rack 3, top shelf'), findsOneWidget);
    // Edit is the row's.
    await tester.tap(find.byKey(const ValueKey('phone-host-page-edit')));
    await settle(tester);
    expect(calls, ['edit h1']);
    // Files: the host's files open with the session connecting opens, and
    // the page gives way to it.
    await tester.tap(find.byKey(const ValueKey('phone-host-page-files')));
    await settle(tester);
    expect(c.read(sftpPendingConnectionProvider), 'h1');
    expect(calls, ['edit h1', 'connect h1']);
    expect(find.byType(PhoneHostPage), findsNothing);
    // Connect, from the page opened again.
    await openDetails(tester);
    await tester.tap(find.byKey(const ValueKey('phone-host-page-connect')));
    await settle(tester);
    expect(calls.last, 'connect h1');
    expect(find.byType(PhoneHostPage), findsNothing);
    await finish(tester);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));

  testWidgets("the computer's host card has no more button (its panel opens beside it)", (tester) async {
    await pump(
      tester,
      home: const HostCard(
        data: HostCardData(
          id: 'h1',
          name: 'web-01',
          subtitle: 'root@192.168.10.21',
          osId: null,
          status: HostStatus.offline,
          hasActiveSession: false,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('phone-host-more-h1')), findsNothing);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(en.phoneHostMoreActions('web-01')), findsNothing);
    semantics.dispose();
    await finish(tester);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}
