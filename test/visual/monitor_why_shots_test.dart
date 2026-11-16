import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';

import '../helpers/desktop_mouse.dart';
import 'shots_util.dart';

/// Pictures of Server Monitor saying why a host cannot be checked (3.0),
/// with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/monitor_why_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up. Another
/// language with --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  /// Three hosts whose check failed, each its own way.
  Future<AppDatabase> seeded() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime(2026, 1, 1);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'key-deploy', label: 'deploy key', username: 'deploy', authMethod: 'password', createdAt: now));
    final hosts = {'web': ('web-01', '192.168.10.21'), 'db': ('db-primary', '192.168.10.31'), 'cache': ('cache-01', '192.168.10.41')};
    for (final MapEntry(key: id, value: (label, address)) in hosts.entries) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: address,
            port: const Value(22),
            identityId: const Value('key-deploy'),
            monitored: const Value(true),
            createdAt: now,
            updatedAt: now,
          ));
    }
    return db;
  }

  Map<String, MonitorHostStatus> failures() {
    MonitorHostStatus failed(Object failedWith, {bool signInRefused = false}) => MonitorHostStatus(
        MonitorHostState.error,
        failedWith: failedWith,
        signInRefused: signInRefused,
        updatedAt: DateTime.now());
    return {
      'web': failed(SSHAuthFailError('All authentication methods failed'), signInRefused: true),
      'db': failed(JumpHostFailure(
          label: 'vpn-gateway',
          host: '192.168.10.23',
          port: 22,
          stage: JumpStage.onward,
          cause: SSHChannelOpenError(1, 'open failed'),
          onward: 'db-primary')),
      'cache': failed(TimeoutException('Connection timed out', const Duration(seconds: 10))),
    };
  }

  Future<(AppDatabase, GlobalKey)> shown(WidgetTester tester, String themeId, Size size, Widget screen) async {
    L10nGlobal.update(l10n);
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'agentless_monitor_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final db = await seeded();
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          serverStatsProvider.overrideWith((ref) => _NoStats(ref)),
          agentlessMonitorPollerProvider.overrideWith((ref) => _Poller(failures())),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: Scaffold(body: screen),
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return (db, key);
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (db, key) = await shown(tester, themeId, const Size(1400, 700), const MonitorTableView());
        // The status of each host's row, under the mouse.
        for (final host in ['web', 'db', 'cache']) {
          final pill = find.byKey(ValueKey('monitor-status-$host'));
          await TestMouse(tester).moveOver(pill);
          await tester.pump();
          await saveShot(tester, key, 'monitor_why_${tag}_$host');
        }
        await finish(tester, db);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final (db, key) = await shown(tester, 'graphite', const Size(390, 1100), const ServerMonitorScreen());
      await saveShot(tester, key, 'monitor_why_phone');
      await finish(tester, db);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);
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

class _Poller extends StateNotifier<Map<String, MonitorHostStatus>> implements AgentlessMonitorPoller {
  _Poller(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
