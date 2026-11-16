import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';

// Under the Server monitor's table, the warning limits every host is held to
// (as designed; the status bar said it too, until a
// later review).
void main() {
  test('the limits in use, the numbers as the language writes them', () {
    final metrics = Map.of(kDefaultThresholds)
      ..[MonitorMetric.cpu] = const MetricThreshold(85, 95)
      ..[MonitorMetric.ram] = const MetricThreshold(80.5, 95)
      ..[MonitorMetric.disk] = const MetricThreshold(90, 97);
    final config = MonitorThresholds(metrics: metrics);
    final en = lookupAppLocalizations(const Locale('en'));
    expect(monitorWarnAtLine(en, config), en.monitorTableWarnAt('85', '80.5', '90'));
    final de = lookupAppLocalizations(const Locale('de'));
    expect(monitorWarnAtLine(de, config), de.monitorTableWarnAt('85', '80,5', '90'));
  });

  test('a limit not set reads the built-in one', () {
    final en = lookupAppLocalizations(const Locale('en'));
    String n(MonitorMetric m) {
      final v = kDefaultThresholds[m]!.warn;
      return v == v.roundToDouble() ? v.round().toString() : '$v';
    }

    expect(monitorWarnAtLine(en, const MonitorThresholds(metrics: {})),
        en.monitorTableWarnAt(n(MonitorMetric.cpu), n(MonitorMetric.ram), n(MonitorMetric.disk)));
  });
}
