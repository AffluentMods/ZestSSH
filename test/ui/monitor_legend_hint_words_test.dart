import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_detail_pane.dart';

import '../visual/shots_util.dart';

/// A host's history chart in Server monitor says how to show or hide a
/// metric in the words of the screen it is on: click on a computer, tap on
/// a phone or a tablet (a phone said "Click a metric", 3.0 screenshots).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() async => loadShotFonts());

  for (final (platform, tap) in [
    (TargetPlatform.windows, false),
    (TargetPlatform.macOS, false),
    (TargetPlatform.linux, false),
    (TargetPlatform.iOS, true),
    (TargetPlatform.android, true),
  ]) {
    for (final locale in const [Locale('en'), Locale('de')]) {
      testWidgets('${platform.name}, ${locale.languageCode}: ${tap ? 'tap' : 'click'}', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(() => tester.runAsync(db.close));
          late ConnectionWithDetails details;
          await tester.runAsync(() async {
            final at = DateTime(2026, 10, 1);
            await db.into(db.connections).insert(ConnectionsCompanion.insert(
                id: 'c1', label: 'web-01', host: '192.168.10.11', createdAt: at, updatedAt: at));
            details = (await db.connectionsDao.watchAllWithDetails().first).single;
          });
          tester.view.physicalSize = const Size(430, 1700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              databaseProvider.overrideWithValue(db),
              monitorHistorySamplesProvider.overrideWith((ref, _) async => const []),
            ],
            child: MaterialApp(
              theme: BuiltInThemes.getById('graphite').toThemeData(),
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SizedBox(
                  height: 1600,
                  child: MonitorDetailPane(
                    details: details,
                    view: const MonitorHostView(bucket: MonitorBucket.healthy, metrics: []),
                    stats: null,
                    onClose: () {},
                    onRefresh: () async {},
                    onViewFailedUnits: () {},
                  ),
                ),
              ),
            ),
          ));
          await tester.pump();
          await tester.pump();
          final l10n = lookupAppLocalizations(locale);
          final hint = tester.widget<Text>(find.byKey(const ValueKey('monitor-legend-hint'))).data;
          expect(hint, tap ? l10n.zestMonLegendHintTap : l10n.zestMonLegendHint);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  test('the touch words say tap, never click, in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n.zestMonLegendHintTap, isNot(l10n.zestMonLegendHint), reason: locale.toString());
      expect(l10n.zestMonLegendHintTap.toLowerCase(), isNot(contains('click')), reason: locale.toString());
    }
  });
}
