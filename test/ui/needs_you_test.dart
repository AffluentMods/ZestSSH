// "Needs you" at the top of a phone's notification center (3.1): what needs
// the person now, from what the app already holds, each row with the one
// action that resolves it; a row leaves by itself once resolved, the
// section is hidden while nothing needs them, and the bell's badge counts
// these rows and the unread messages.

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/features/notifications/needs_you.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/notification_permission_provider.dart';
import 'package:zestssh/features/notifications/widgets/mobile_notification_bell.dart';
import 'package:zestssh/features/orchards/orchard_service.dart'
    show AccessRequestView, DeviceRequestStage, DeviceRequestView, OrchardPeople;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/settings_service.dart' show SyncPause;
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/notifications/notifications_screen.dart';

const _cpuHot = MetricEval(metric: MonitorMetric.cpu, value: 97, warn: 80, crit: 90, severity: MetricSeverity.critical);
const _ramWarm = MetricEval(metric: MonitorMetric.ram, value: 85, warn: 80, crit: 90, severity: MetricSeverity.warning);

final _views = StateProvider<Map<String, MonitorHostView>>((_) => const {});
final _sync = StateProvider<SyncHealthState>((_) => const SyncHealthState(SyncHealth.upToDate));
final _keys = StateProvider<List<Identity>>((_) => const []);
final _orchard = StateProvider<OrchardSummary?>((_) => null);
final _devices = StateProvider<List<DeviceRequestView>>((_) => const []);
final _asking = StateProvider<List<AccessRequestView>>((_) => const []);

Identity _key(String id, String label, DateTime runsOut) => Identity(
      id: id,
      label: label,
      username: 'alex',
      authMethod: 'certificate',
      colorIndex: 0,
      isDefault: false,
      usesAgent: false,
      allowUnattended: false,
      passwordAfterKey: false,
      certValidAfter: runsOut.subtract(const Duration(days: 90)),
      certValidBefore: runsOut,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

const _team = OrchardSummary(
  id: 'o1',
  name: 'Example',
  role: 'owner',
  crates: [],
  defaultCrateId: null,
  can: {RoleCan.invite},
  invitesWaiting: 2,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 24);
    for (final (id, label, host) in [('h1', 'web-01', '192.168.10.11'), ('h2', 'db-01', '192.168.10.12')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id, label: label, host: host, monitored: const Value(true), createdAt: at, updatedAt: at));
    }
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pump(WidgetTester tester) async {
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
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      notificationsEnabledProvider.overrideWith((ref) async => true),
      monitoredHostViewsProvider.overrideWith((ref) => ref.watch(_views)),
      syncHealthProvider.overrideWith((ref) => ref.watch(_sync)),
      identitiesProvider.overrideWith((ref) => Stream.value(ref.watch(_keys))),
      activeOrchardProvider.overrideWith((ref) => AsyncData(ref.watch(_orchard))),
      teamPeopleProvider.overrideWith((ref, id) => Completer<OrchardPeople>().future),
      deviceRequestsProvider.overrideWith((ref, id) async => ref.watch(_devices)),
      accessRequestsProvider.overrideWith((ref, id) async => (mine: const <AccessRequestView>[], waiting: ref.watch(_asking))),
    ]);
    addTearDown(c.dispose);
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
                appBar: AppBar(actions: const [MobileNotificationBell()]),
                body: const Text('home'),
              )),
      GoRoute(path: '/notifications', builder: (context, state) => const NotificationsScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('at ${state.uri}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await settle(tester);
    return c;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder row(NeedsYouKind kind, String id) => find.byKey(ValueKey('needs-you-${kind.name}-$id'));
  Finder action(NeedsYouKind kind, String id) => find.byKey(ValueKey('needs-you-action-${kind.name}-$id'));
  Finder badge(String text) =>
      find.descendant(of: find.byType(MobileNotificationBell), matching: find.text(text));

  Future<void> openCenter(WidgetTester tester) async {
    await tester.tap(find.byType(MobileNotificationBell));
    await settle(tester);
    expect(find.byType(NotificationsScreen), findsOneWidget);
  }

  testWidgets('each kind shows with its action, the badge counts them, and each leaves once resolved',
      (tester) async {
    final c = await pump(tester);
    final now = DateTime.now();
    c.read(_views.notifier).state = {
      'h1': const MonitorHostView(bucket: MonitorBucket.critical, metrics: [_cpuHot], breachedMetric: MonitorMetric.cpu),
      'h2': const MonitorHostView(bucket: MonitorBucket.cantCheck, metrics: [], cantCheckReason: CantCheckReason.authFailed),
    };
    c.read(_sync.notifier).state =
        const SyncHealthState(SyncHealth.failing, problem: 'Your sync server refused the access token');
    c.read(_keys.notifier).state = [_key('k1', 'deploy-cert', now.subtract(const Duration(days: 1)))];
    c.read(_orchard.notifier).state = _team;
    c.read(_devices.notifier).state = [
      const DeviceRequestView(id: 'd1', uid: 'u-alex', stage: DeviceRequestStage.asks, expiresAt: 0),
    ];
    c.read(_asking.notifier).state = [
      const AccessRequestView(
          id: 'a1', uid: 'u-sam', crateId: null, level: CrateLevel.connect, duration: Duration(hours: 2), expiresAt: 0),
    ];
    // The Team page read the requests: the bell lists what it found, and
    // asks for nothing of its own.
    c.listen(deviceRequestsProvider('o1'), (_, _) {});
    c.listen(accessRequestsProvider('o1'), (_, _) {});
    await settle(tester);

    // h1, h2, a device, an access request, invitations, sync, a key: 7.
    expect(badge('7'), findsOneWidget);
    // An unread message adds one.
    c.read(notificationCenterProvider.notifier).warning('Backup failed');
    await settle(tester);
    expect(badge('8'), findsOneWidget);

    await openCenter(tester);
    expect(find.text(en.needsYouTitle.toUpperCase()), findsOneWidget);
    expect(row(NeedsYouKind.hostCritical, 'h1'), findsOneWidget);
    expect(find.text('web-01'), findsOneWidget);
    expect(find.text(en.zestMonitorTipCritical('CPU', '97%', '90%')), findsOneWidget);
    expect(row(NeedsYouKind.hostCantCheck, 'h2'), findsOneWidget);
    expect(find.descendant(of: action(NeedsYouKind.hostCritical, 'h1'), matching: find.text(en.needsYouOpenInMonitor)),
        findsOneWidget);
    expect(row(NeedsYouKind.teamDevice, 'd1'), findsOneWidget);
    expect(find.text(en.deviceRequestTitle('u-alex')), findsOneWidget);
    expect(row(NeedsYouKind.teamAccess, 'a1'), findsOneWidget);
    expect(row(NeedsYouKind.teamInvites, 'teamInvites'), findsOneWidget);
    expect(find.text(en.teamAttnInvites(2)), findsOneWidget);
    expect(find.descendant(of: action(NeedsYouKind.teamDevice, 'd1'), matching: find.text(en.teamReview)),
        findsOneWidget);
    expect(row(NeedsYouKind.syncFailing, 'sync'), findsOneWidget);
    expect(find.text(en.needsYouSyncFailing), findsOneWidget);
    expect(find.text('Your sync server refused the access token'), findsOneWidget);
    await tester.scrollUntilVisible(row(NeedsYouKind.certRanOut, 'k1'), 200);
    expect(find.text(en.certReminderRanOutTitle('deploy-cert')), findsOneWidget);
    expect(find.descendant(of: action(NeedsYouKind.certRanOut, 'k1'), matching: find.text(en.needsYouOpenKey)),
        findsOneWidget);
    // The past messages stay below.
    await tester.scrollUntilVisible(find.text('Backup failed'), 200);
    expect(find.text('Backup failed'), findsOneWidget);

    // Each action opens what resolves it.
    for (final (kind, id, at) in [
      (NeedsYouKind.hostCritical, 'h1', '/monitor/server/h1'),
      (NeedsYouKind.teamDevice, 'd1', '/team/overview'),
      (NeedsYouKind.syncFailing, 'sync', '/profile'),
      (NeedsYouKind.certRanOut, 'k1', '/identity/edit/k1'),
    ]) {
      await tester.ensureVisible(action(kind, id));
      await tester.pumpAndSettle();
      await tester.tap(action(kind, id));
      await settle(tester);
      expect(find.text('at $at'), findsOneWidget, reason: kind.name);
      Navigator.of(tester.element(find.text('at $at'))).pop();
      await settle(tester);
    }

    // Resolved, one at a time: each row leaves by itself.
    c.read(_views.notifier).state = {
      'h2': const MonitorHostView(bucket: MonitorBucket.cantCheck, metrics: [], cantCheckReason: CantCheckReason.authFailed),
    };
    await settle(tester);
    expect(row(NeedsYouKind.hostCritical, 'h1'), findsNothing);
    expect(row(NeedsYouKind.hostCantCheck, 'h2'), findsOneWidget);
    c.read(_views.notifier).state = const {};
    c.read(_sync.notifier).state = const SyncHealthState(SyncHealth.upToDate);
    c.read(_keys.notifier).state = const [];
    c.read(_devices.notifier).state = const [];
    c.read(_asking.notifier).state = const [];
    c.read(_orchard.notifier).state = null;
    await settle(tester);
    expect(find.byKey(const ValueKey('needs-you')), findsNothing);
    expect(find.text('Backup failed'), findsOneWidget);
    await finish(tester);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));

  testWidgets('a warning host, a paused sync and a certificate that runs out soon', (tester) async {
    final c = await pump(tester);
    c.read(_views.notifier).state = {
      'h1': const MonitorHostView(bucket: MonitorBucket.warning, metrics: [_ramWarm], breachedMetric: MonitorMetric.ram),
      // Being checked now: nothing the person can do, so not listed.
      'h2': const MonitorHostView(bucket: MonitorBucket.cantCheck, metrics: [], cantCheckReason: CantCheckReason.connecting),
    };
    c.read(_sync.notifier).state = const SyncHealthState(SyncHealth.paused, pause: SyncPause());
    c.read(_keys.notifier).state = [_key('k1', 'deploy-cert', DateTime.now().add(const Duration(days: 3)))];
    await settle(tester);
    expect(badge('3'), findsOneWidget);
    await openCenter(tester);
    expect(row(NeedsYouKind.hostWarning, 'h1'), findsOneWidget);
    expect(find.text(en.zestMonitorTipWarning('RAM', '85%', '80%')), findsOneWidget);
    expect(find.byKey(const ValueKey('needs-you-hostCantCheck-h2')), findsNothing);
    expect(row(NeedsYouKind.syncPaused, 'sync'), findsOneWidget);
    expect(find.text(en.needsYouSyncPaused), findsOneWidget);
    expect(find.descendant(of: action(NeedsYouKind.syncPaused, 'sync'), matching: find.text(en.needsYouOpenSync)),
        findsOneWidget);
    expect(row(NeedsYouKind.certSoon, 'k1'), findsOneWidget);
    expect(find.text(en.certReminderSoonTitle('deploy-cert')), findsOneWidget);
    // With no past message, the section alone.
    expect(find.text(en.notificationsEmptyTitle), findsNothing);
    await finish(tester);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));

  testWidgets('nothing needs the person: no section, no badge; a failing sync that retries by itself is not listed',
      (tester) async {
    final c = await pump(tester);
    c.read(_sync.notifier).state = const SyncHealthState(SyncHealth.failing, retrying: true);
    // A team with requests the Team page never read: nothing is asked for
    // from here, so nothing is listed.
    c.read(_orchard.notifier).state = const OrchardSummary(
        id: 'o1', name: 'Example', role: 'owner', crates: [], defaultCrateId: null);
    c.read(_devices.notifier).state = [
      const DeviceRequestView(id: 'd1', uid: 'u-alex', stage: DeviceRequestStage.asks, expiresAt: 0),
    ];
    await settle(tester);
    expect(c.read(needsYouProvider), isEmpty);
    expect(find.descendant(of: find.byType(MobileNotificationBell), matching: find.byType(Text)), findsNothing);
    await openCenter(tester);
    expect(find.byKey(const ValueKey('needs-you')), findsNothing);
    expect(find.text(en.notificationsEmptyTitle), findsOneWidget);
    await finish(tester);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}
