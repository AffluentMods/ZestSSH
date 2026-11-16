import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';

import '../visual/shots_util.dart';

/// No reading of a host: nothing runs.
class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

/// The poller's word of each host, with nothing behind it.
class _Poller extends StateNotifier<Map<String, MonitorHostStatus>> implements AgentlessMonitorPoller {
  _Poller(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A phone's Server Monitor while it is turned off, with the text the
/// person's phone makes large (3.0): what it says and its
/// two buttons stood in a column that did not scroll, so at twice the text
/// size the button that turns the monitor on was cut off (by 61 pixels in
/// English, 291 in German, on a phone 390 by 844). A computer's Monitor was
/// made to scroll before (monitor_off_low_window_test.dart).
void main() {
  for (final locale in const [Locale('en'), Locale('de')]) {
    testWidgets('at twice the text size, in $locale: nothing overflows, and the button that turns it on is reached '
        'and pressed', (tester) async {
      await tester.runAsync(loadShotFonts);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        serverStatsProvider.overrideWith((ref) => _NoStats(ref)),
        agentlessMonitorPollerProvider.overrideWith((ref) => _Poller(const {})),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
          home: const Scaffold(body: ServerMonitorScreen()),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      final l = lookupAppLocalizations(locale);
      final enable = find.text(l.monitorAgentlessEnableAction);
      expect(enable, findsOneWidget);
      await tester.ensureVisible(enable);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(enable).bottom, lessThanOrEqualTo(844), reason: 'scrolled into the screen');
      expect(container.read(agentlessMonitorEnabledProvider), isFalse);
      await tester.tap(enable);
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(agentlessMonitorEnabledProvider), isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
