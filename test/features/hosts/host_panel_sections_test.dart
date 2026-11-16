import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/hosts/widgets/host_panel.dart';
import 'package:zestssh/features/hosts/widgets/host_panel_sections.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_host_alerts.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitor_thresholds_provider.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The host panel as designed: sections only
/// where they have something to say, "Watch this host" where Server monitor
/// does not watch it (within the free plan's limit), and an alert choice per
/// metric (mute, snooze, a limit of its own, ZFS's ARC counted as free).

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The views as the real provider makes them, without the poller that would
/// connect to the hosts: every watched host is resolved from the readings
/// the test commits, with its alert choices.
Map<String, MonitorHostView> _views(Ref ref) {
  final monitored = ref.watch(monitoredConnectionsProvider).valueOrNull ?? const [];
  final stats = ref.watch(serverStatsProvider);
  final config = ref.watch(monitorThresholdsProvider);
  final prefs = ref.watch(hostAlertPrefsProvider);
  final now = DateTime.now();
  return {
    for (final c in monitored)
      c.id: resolveMonitorHost(
        history: const [],
        stats: stats[c.id],
        health: null,
        monitor: null,
        hasActiveSession: false,
        thresholds: config.resolveFor(c.id),
        debounceReadings: 1,
        staleAfter: const Duration(hours: 1),
        now: now,
        silenced: prefs[c.id]?.silencedAt(now) ?? const {},
        countArcAsFree: prefs[c.id]?.countArcAsFree ?? false,
      ),
  };
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The panel of host `h1` ([withContent]: a port forward, commands in the
  /// history, tags and a note; [watched] and [otherWatched] hosts watched).
  Future<void> pump(
    WidgetTester tester, {
    bool withContent = false,
    bool watched = false,
    int otherWatched = 0,
    bool pro = true,
    DateTime? lastConnected,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.now();
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1',
          label: 'hypervisor-b',
          host: '192.168.20.12',
          port: const Value(22),
          monitored: Value(watched),
          note: Value(withContent ? 'The lab hypervisor' : null),
          lastConnected: Value(lastConnected),
          createdAt: now,
          updatedAt: now,
        ));
    for (var i = 0; i < otherWatched; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'w$i', label: 'watched-$i', host: '10.0.0.$i', monitored: const Value(true), createdAt: now, updatedAt: now));
    }
    if (withContent) {
      await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: 'pf1',
            connectionId: 'h1',
            type: 'local',
            bindPort: 8006,
            remoteHost: 'localhost',
            remotePort: 8006,
            label: const Value('Proxmox web UI'),
            createdAt: now,
          ));
      // Two sessions: two commands an hour ago, ten minutes apart, and one
      // a day before.
      final at = now.subtract(const Duration(hours: 1));
      for (final (id, t) in [
        ('c1', at),
        ('c2', at.add(const Duration(minutes: 10))),
        ('c3', at.subtract(const Duration(days: 1))),
      ]) {
        await db.into(db.commandHistory).insert(CommandHistoryCompanion.insert(
              id: id,
              command: 'uptime',
              connectionId: const Value('h1'),
              createdAt: t,
            ));
      }
    }
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(pro)),
      monitoredHostViewsProvider.overrideWith(_views),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: Consumer(builder: (context, ref, _) {
              final item = (ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[])
                  .where((c) => c.connection.id == 'h1')
                  .firstOrNull;
              if (item == null) return const SizedBox();
              return HostPanel(
                card: HostCardData(
                  id: 'h1',
                  name: 'hypervisor-b',
                  subtitle: 'root@192.168.20.12',
                  osId: null,
                  status: HostStatus.offline,
                  hasActiveSession: false,
                  tags: withContent ? const ['lab', 'proxmox'] : const [],
                ),
                item: item,
                onClose: () {},
                onConnect: () {},
                onSwitchTo: (_) {},
                onOpenSftp: () {},
                onOpenTmux: () {},
                onEdit: () {},
              );
            }),
          ),
        ),
      ),
    ));
    await settle(tester);
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  /// A reading of host h1 with its memory at [ramUsedMB] of 1000.
  void reading(int ramUsedMB, {int? arcMB, double cpu = 14, List<FilesystemUsage> mounts = const []}) =>
      container.read(serverStatsProvider.notifier).commitSshStats(
        'h1',
        ServerStats(
          cpuPercent: cpu,
          ramUsedMB: ramUsedMB,
          ramTotalMB: 1000,
          diskPercent: 40,
          loadAverage: const [0.42, 0.3, 0.2],
          uptimeSeconds: 41 * 86400,
          filesystems: mounts,
          collectedAt: DateTime.now(),
          source: MetricSource.ssh,
          zfsArcFreeableMB: arcMB,
        ),
      );

  group('Sections only where they have something to say', () {
    testWidgets('a host with nothing kept: no recent sessions, no port forwards, no tags, no note', (tester) async {
      await pump(tester);
      for (final head in [l10n.hpanelRecentSessions, l10n.hpanelPortForwards, l10n.hpanelTags, l10n.hostPanelNote]) {
        expect(find.text(head.toUpperCase()), findsNothing, reason: head);
      }
      expect(find.text(l10n.hostPanelConnection.toUpperCase()), findsOneWidget, reason: 'how it connects is always said');
      await finish(tester);
    });

    testWidgets('with them: its sessions, its forward and its switch, its tags, its note', (tester) async {
      await pump(tester, withContent: true);
      expect(find.text(l10n.hpanelRecentSessions.toUpperCase()), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('host-panel-session-')),
          findsNWidgets(2), reason: 'commands an hour or more apart are two sessions');
      // How long each lasted, in the one compact style ("10m", "1m"; not "one
      // minute").
      expect(find.text(durationWords(l10n, const Duration(minutes: 10))), findsOneWidget);
      expect(find.text('10m'), findsOneWidget);
      expect(find.text('1m'), findsOneWidget, reason: 'a session of one command lasted at least a minute');
      expect(find.text(l10n.hpanelPortForwards.toUpperCase()), findsOneWidget);
      expect(find.text('8006 → localhost:8006'), findsOneWidget);
      expect(find.text('Proxmox web UI'), findsOneWidget);
      expect(find.byKey(const ValueKey('host-panel-forward-switch-pf1')), findsOneWidget);
      expect(find.byKey(const ValueKey('host-panel-tags')), findsOneWidget);
      expect(find.text('The lab hypervisor'), findsOneWidget);
      await finish(tester);
    });
  });

  testWidgets('the status beside Edit breaks between its parts, never inside one', (tester) async {
    await pump(tester, lastConnected: DateTime.now().subtract(const Duration(days: 1)));
    final status = tester.widget<Text>(find.byKey(const ValueKey('host-panel-status'))).data!;
    expect(status, contains(l10n.hpanelLastSession('').trim().split(' ').first), reason: 'when it last was');
    // "last" was left on the first line (found in a design review).
    expect(status.replaceAll('· ', ''), isNot(contains(' ')));
    await finish(tester);
  });

  group('Watch this host', () {
    testWidgets('adds the host to Server monitor, and its health takes the place of the button', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('host-panel-watch')), findsOneWidget);
      expect(find.text(l10n.hpanelWatchHint), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('host-panel-watch')));
      await settle(tester);
      final row = await tester.runAsync(() => db.connectionsDao.getById('h1'));
      expect(row!.monitored, isTrue);
      expect(find.byKey(const ValueKey('host-panel-watch')), findsNothing);
      expect(find.text(l10n.hpanelWatchHint), findsNothing);
      reading(400);
      await settle(tester);
      expect(find.byKey(const ValueKey('host-panel-metric-ram')), findsOneWidget, reason: 'its figures, as for a watched host');
      await finish(tester);
    });

    testWidgets('on the free plan with as many watched as it allows: says so, and offers the upgrade instead', (tester) async {
      await pump(tester, pro: false, otherWatched: freeMonitorLimit);
      expect(find.byKey(const ValueKey('host-panel-watch')), findsNothing);
      expect(find.text(l10n.monitorAgentlessLimitReached(freeMonitorLimit)), findsOneWidget);
      expect(find.byKey(const ValueKey('host-panel-upgrade')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('on the free plan under its limit, the button is there', (tester) async {
      await pump(tester, pro: false, otherWatched: freeMonitorLimit - 1);
      expect(find.byKey(const ValueKey('host-panel-watch')), findsOneWidget);
      await finish(tester);
    });
  });

  group('Health and its alerts', () {
    Future<void> openAlert(WidgetTester tester, MonitorMetric m) async {
      await tester.tap(find.byKey(ValueKey('host-panel-alert-${m.name}')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('host-alert-menu')), findsOneWidget);
    }

    testWidgets('a metric over its limit is drawn in the warning colour, with where it alerts', (tester) async {
      await pump(tester, watched: true);
      reading(890);
      await settle(tester);
      final ram = find.byKey(const ValueKey('host-panel-metric-ram'));
      final value = tester.widget<Text>(find.descendant(of: ram, matching: find.text('89%')));
      expect(value.style!.color, isNot(ZestColors.textPrimary));
      expect(find.descendant(of: ram, matching: find.text(l10n.hpanelAlertsAt('70%'))), findsOneWidget);
      expect(find.byKey(const ValueKey('host-panel-health-info')), findsOneWidget);
      // The card says so too.
      expect(healthChipsFor(container.read(monitoredHostViewsProvider)['h1'], l10n), isNotEmpty);
      await finish(tester);
    });

    testWidgets('every disk has its Alert, the one over the limit outlined, each opening the disk alert', (tester) async {
      await pump(tester, watched: true);
      reading(400, mounts: const [
        FilesystemUsage(mount: '/', usedBytes: 40, totalBytes: 100, usedPercent: 40),
        FilesystemUsage(mount: '/boot', usedBytes: 91, totalBytes: 100, usedPercent: 91),
      ]);
      await settle(tester);
      for (final m in ['/', '/boot']) {
        expect(
            find.descendant(
                of: find.byKey(ValueKey('host-panel-metric-disk-$m')), matching: find.byKey(ValueKey('host-panel-alert-disk-$m'))),
            findsOneWidget,
            reason: m);
      }
      // /boot had none (found in a design review).
      await tester.tap(find.byKey(const ValueKey('host-panel-alert-disk-/boot')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('host-alert-menu')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await finish(tester);
    });

    testWidgets('Mute: the card and the attention count no longer show it; the panel still does', (tester) async {
      await pump(tester, watched: true);
      reading(890);
      await settle(tester);
      await openAlert(tester, MonitorMetric.ram);
      await tester.tap(find.byKey(const ValueKey('alert-mute')));
      await settle(tester);
      final view = container.read(monitoredHostViewsProvider)['h1'];
      expect(healthChipsFor(view, l10n), isEmpty);
      expect(hostNeedsAttention(view, changedHostKey: false), isFalse);
      // With another metric over as well, the card shows that one alone.
      reading(890, cpu: 95);
      await settle(tester);
      final both = healthChipsFor(container.read(monitoredHostViewsProvider)['h1'], l10n);
      expect([for (final c in both) c.label], ['${l10n.monitorCpu} 95%']);
      expect(find.byKey(const ValueKey('host-panel-metric-ram')), findsOneWidget);
      expect(find.text(l10n.hpanelAlertMuted), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Snooze for an hour ends by itself; Until it recovers ends at a reading back under the limit',
        (tester) async {
      await pump(tester, watched: true);
      reading(890);
      await settle(tester);
      await openAlert(tester, MonitorMetric.ram);
      await tester.tap(find.byKey(const ValueKey('alert-snooze-recovers')));
      await settle(tester);
      expect(container.read(hostAlertPrefsProvider)['h1']!.silences[MonitorMetric.ram]!.kind, MetricSilenceKind.untilRecovers);
      expect(healthChipsFor(container.read(monitoredHostViewsProvider)['h1'], l10n), isEmpty);
      // Still over: still snoozed.
      reading(880);
      await settle(tester);
      expect(container.read(hostAlertPrefsProvider)['h1'], isNotNull);
      // Back under: the snooze is over, and the next time it is over it is said.
      reading(300);
      await settle(tester);
      expect(container.read(hostAlertPrefsProvider)['h1'], isNull);
      reading(890);
      await settle(tester);
      expect(healthChipsFor(container.read(monitoredHostViewsProvider)['h1'], l10n), isNotEmpty);

      await openAlert(tester, MonitorMetric.ram);
      await tester.tap(find.byKey(const ValueKey('alert-snooze-hour')));
      await settle(tester);
      final until = container.read(hostAlertPrefsProvider)['h1']!.silences[MonitorMetric.ram]!.until!;
      expect(until.difference(DateTime.now()).inMinutes, inInclusiveRange(58, 60));
      expect(container.read(hostAlertPrefsProvider)['h1']!.silencedAt(DateTime.now()), {MonitorMetric.ram});
      expect(container.read(hostAlertPrefsProvider)['h1']!.silencedAt(until.add(const Duration(seconds: 1))), isEmpty);
      await finish(tester);
    });

    testWidgets('A limit of its own for this host, and back to the default', (tester) async {
      await pump(tester, watched: true);
      reading(890);
      await settle(tester);
      await openAlert(tester, MonitorMetric.ram);
      await tester.enterText(find.byKey(const ValueKey('alert-custom-field')), '95');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(container.read(monitorThresholdsProvider).resolveFor('h1')[MonitorMetric.ram]!.warn, 95);
      expect(container.read(monitorThresholdsProvider).global.forMetric(MonitorMetric.ram).warn, 70,
          reason: 'only this host');
      expect(healthChipsFor(container.read(monitoredHostViewsProvider)['h1'], l10n), isEmpty, reason: '89% is under 95%');
      await openAlert(tester, MonitorMetric.ram);
      await tester.tap(find.byKey(const ValueKey('alert-default')));
      await settle(tester);
      expect(container.read(monitorThresholdsProvider).overrideFor('h1'), isNull);
      await finish(tester);
    });

    testWidgets('Count ZFS ARC as free memory: on a ZFS host, its memory reads without the ARC', (tester) async {
      await pump(tester, watched: true);
      reading(890, arcMB: 500);
      await settle(tester);
      expect(find.descendant(of: find.byKey(const ValueKey('host-panel-metric-ram')), matching: find.text('89%')), findsOneWidget);
      await openAlert(tester, MonitorMetric.ram);
      await tester.tap(find.byKey(const ValueKey('alert-zfs-arc')));
      await settle(tester);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(container.read(hostAlertPrefsProvider)['h1']!.countArcAsFree, isTrue);
      expect(find.descendant(of: find.byKey(const ValueKey('host-panel-metric-ram')), matching: find.text('39%')), findsOneWidget);
      expect(healthChipsFor(container.read(monitoredHostViewsProvider)['h1'], l10n), isEmpty);
      await finish(tester);
    });

    testWidgets('the Alert menu stays inside the window', (tester) async {
      await pump(tester, watched: true);
      reading(890, arcMB: 500);
      await settle(tester);
      await openAlert(tester, MonitorMetric.ram);
      final menu = tester.getRect(find.byKey(const ValueKey('host-alert-menu')));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.top, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(900));
      expect(menu.bottom, lessThanOrEqualTo(1400));
      await tester.tapAt(const Offset(5, 5));
      await finish(tester);
    });
  });

  testWidgets('Copy SSH command copies the line that connects, port and user included', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('host-panel-copy-ssh')));
    await settle(tester);
    expect(copied, 'ssh 192.168.20.12');
    expect(find.text(l10n.hpanelCopiedSsh), findsOneWidget);
    await finish(tester);
  });

  group('Reading ZFS\'s ARC', () {
    test('the part above its floor, in MB; nothing where the host has no ZFS', () {
      // As the collector's awk prints them: the name and the bytes.
      expect(ServerStatsService.parseZfsArcFreeableMB('size 2147483648\nc_min 536870912\n'), 1536);
      expect(ServerStatsService.parseZfsArcFreeableMB(''), isNull);
      expect(ServerStatsService.parseZfsArcFreeableMB(null), isNull);
      expect(ServerStatsService.parseZfsArcFreeableMB('size 100\nc_min 200'), 0);
    });

    test('memory with and without it', () {
      final s = ServerStats(ramUsedMB: 890, ramTotalMB: 1000, collectedAt: DateTime(2026), zfsArcFreeableMB: 500);
      expect(s.ramPercentWith(arcAsFree: false), closeTo(89, 0.01));
      expect(s.ramPercentWith(arcAsFree: true), closeTo(39, 0.01));
    });
  });

  test('a host with no user, and one on another port', () {
    final now = DateTime(2026);
    ConnectionWithDetails c(int port) => ConnectionWithDetails(
          connection: Connection(
            id: 'x', label: 'x', host: 'db.example.test', port: port, colorIndex: 0, protocol: 'ssh', zlibCompression: false,
            keepAliveSeconds: 0, envVars: '', forwardAgent: false, compatibilityMode: false, sortOrder: 0, sizeTier: 1,
            pinned: false, monitored: false, createdAt: now, updatedAt: now,
          ),
        );
    expect(sshCommandFor(c(22)), 'ssh db.example.test');
    expect(sshCommandFor(c(2222)), 'ssh -p 2222 db.example.test');
  });
}
