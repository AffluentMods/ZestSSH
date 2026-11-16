import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// The demo world's fleet (the website's) for the computer's Server monitor
/// table (tests and pictures): every name and address is invented. One host
/// over its RAM limit, two not watched yet, one with no saved login, a
/// FreeBSD router the collector reads only partly, one that asks for a
/// restart, and the rest healthy.
class MonitorFleet {
  MonitorFleet({DateTime? now}) : now = now ?? DateTime.now();

  final DateTime now;

  /// id: (label, address, monitored, colour of its rail or null).
  static const hosts = <String, (String, String, bool, int?)>{
    'hva': ('hypervisor-a', '192.168.20.11', true, 0xFFA879E8),
    'build': ('build-runner', '192.168.10.50', false, null),
    'cache': ('cache-01', '192.168.10.41', false, 0xFF7AA7E0),
    'vpn': ('vpn-gateway', '192.168.10.23', true, 0xFFE6A23C),
    'mon': ('monitoring', '192.168.10.60', true, null),
    'logs': ('log-store', '192.168.10.24', true, null),
    'web1': ('web-01', '192.168.10.21', true, 0xFF4FAE78),
    'web2': ('web-02', '192.168.10.22', true, 0xFF4FAE78),
    'mac': ('mac-studio', '192.168.10.30', true, null),
    'edge': ('edge-router', '192.168.20.1', true, 0xFFE6A23C),
    'db': ('db-primary', '192.168.10.31', true, 0xFF7AA7E0),
    'hvb': ('hypervisor-b', '192.168.20.12', true, 0xFFA879E8),
  };

  /// The warning and critical limits in use: CPU 90/95, RAM 85/95, Disk 85/95.
  static final thresholds = {
    'global': {
      'metrics': {
        'cpu': {'warn': 90, 'crit': 95},
        'ram': {'warn': 85, 'crit': 95},
        'disk': {'warn': 85, 'crit': 95},
        'latency': {'warn': 150, 'crit': 400},
        'swap': {'warn': 60, 'crit': 85},
        'temp': {'warn': 70, 'crit': 85},
      },
      'debounceReadings': 1,
      'checkIntervalMinutes': 5,
    },
    'overrides': <Object>[],
  };

  Future<AppDatabase> database() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 1, 1);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'key-ops', label: 'Ops laptop', username: 'deploy', authMethod: 'key', createdAt: at));
    for (final MapEntry(key: id, value: (label, address, monitored, colour)) in hosts.entries) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: address,
            port: const Value(22),
            identityId: Value(id == 'vpn' ? null : 'key-ops'),
            monitored: Value(monitored),
            colorValue: Value(colour),
            createdAt: at,
            updatedAt: at,
          ));
    }
    return db;
  }

  ServerStats _stats({
    double? cpu,
    double? ram,
    double? swap,
    double? disk,
    double? load,
    int? ping,
    int? upDays,
    int? updates,
    bool? reboot,
    String? os,
    bool proc = true,
  }) =>
      ServerStats(
        cpuPercent: cpu,
        ramUsedMB: ram == null ? null : (ram * 160).round(),
        ramTotalMB: ram == null ? null : 16000,
        swapPercent: swap,
        // A Linux host read over SSH with no swap figure has none (SwapTotal 0).
        noSwap: swap == null && proc,
        diskPercent: disk,
        loadAverage: load == null ? null : [load, load, load],
        pingMs: ping,
        uptimeSeconds: upDays == null ? (proc ? 3600 * 5 : null) : upDays * 86400 + 3600,
        updatesTotal: updates,
        restartRequired: reboot,
        osName: os,
        collectedAt: now.subtract(const Duration(minutes: 2)),
        source: MetricSource.ssh,
      );

  /// The latest reading of every watched host that has one.
  Map<String, ServerStats> get stats => {
        'hva': _stats(cpu: 31, ram: 89, swap: 0, disk: 54, load: 2.14, ping: 3, upDays: 41),
        'mon': _stats(cpu: 9, ram: 38, disk: 31, load: 0.31, ping: 2, upDays: 23),
        'logs': _stats(cpu: 6, ram: 50, swap: 3, disk: 44, load: 0.14, ping: 2, upDays: 12, updates: 12),
        'web1': _stats(cpu: 22, ram: 72, swap: 0, disk: 38, load: 0.42, ping: 1, upDays: 6),
        'web2': _stats(cpu: 18, ram: 64, disk: 41, load: 0.37, ping: 1, upDays: 6, updates: 23, reboot: true),
        'mac': _stats(cpu: 11, ram: 13, disk: 13, load: 1.18, ping: 1, proc: false),
        'edge': _stats(disk: 21, ping: 1, os: 'FreeBSD 14.1-RELEASE', proc: false),
        'db': _stats(cpu: 27, ram: 58, disk: 61, load: 0.88, ping: 1, upDays: 23),
        'hvb': _stats(cpu: 24, ram: 71, disk: 47, load: 1.62, ping: 3, upDays: 41),
      };

  /// What the background checks say of the watched hosts.
  Map<String, MonitorHostStatus> get statuses => {
        for (final id in stats.keys) id: MonitorHostStatus(MonitorHostState.ok, updatedAt: now),
        'vpn': MonitorHostStatus(MonitorHostState.needsCredentials, updatedAt: now),
      };

  MonitorSample _sample(String id, int i, {required bool ok, double? ram}) => MonitorSample(
        id: i,
        connectionId: id,
        capturedAt: now.subtract(Duration(minutes: (24 - i) * 5)),
        ok: ok,
        resolutionSeconds: 300,
        cpuPercent: ok ? 5 : null,
        ramPercent: ok ? (ram ?? 20) : null,
        diskPercent: ok ? 20 : null,
      );

  /// The stored checks of each host: 24 good ones for the healthy hosts, the
  /// last six over the RAM limit for hypervisor-a, a few failed ones for
  /// vpn-gateway (no saved login), none for the hosts not watched.
  List<MonitorSample> samplesFor(String id) => switch (id) {
        'hva' => [for (var i = 0; i < 24; i++) _sample(id, i, ok: true, ram: i >= 18 ? 89 : 60)],
        'vpn' => [for (var i = 0; i < 6; i++) _sample(id, i, ok: false)],
        'build' || 'cache' => const [],
        _ => [for (var i = 0; i < 24; i++) _sample(id, i, ok: true)],
      };

  /// Shared preferences with background checks on and the limits above.
  Future<SharedPreferences> preferences() async {
    SharedPreferences.setMockInitialValues({
      'agentless_monitor_enabled': true,
      'monitor_threshold_config_v1': jsonEncode(thresholds),
    });
    return SharedPreferences.getInstance();
  }

  List<Override> overrides(AppDatabase db, SharedPreferences prefs, {bool pro = true}) => [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        isProProvider.overrideWith((ref) => FleetPro(pro)),
        serverStatsProvider.overrideWith((ref) => FleetStats(ref, stats)),
        agentlessMonitorPollerProvider.overrideWith((ref) => FleetPoller(statuses)),
        monitorRecentSamplesProvider.overrideWith((ref, id) async => samplesFor(id)),
      ];

  Widget app(List<Override> overrides, Widget child, {ThemeData? theme, Locale locale = const Locale('en')}) =>
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(body: child),
        ),
      );
}

class FleetPro extends StateNotifier<bool> implements ProStatusNotifier {
  FleetPro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stats that are there from the start and never polled for.
class FleetStats extends ServerStatsNotifier {
  FleetStats(super.ref, Map<String, ServerStats> initial) {
    state = initial;
  }

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

class FleetPoller extends StateNotifier<Map<String, MonitorHostStatus>> implements AgentlessMonitorPoller {
  FleetPoller(super.state);

  @override
  void retry([String? id]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
