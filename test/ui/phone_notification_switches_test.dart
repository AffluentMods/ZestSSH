// A phone's switches of what it tells of (found while comparing
// the five versions): security alerts had no switch on a phone, and sync did
// not carry a computer's, so a phone told of every certificate running out
// always; and "Transfer complete" was there, which a phone tells of on the
// screen of the transfer itself, so it changed nothing on the phone. Now a
// phone has the switch of security alerts, sync carries it (and the switch of
// failed transfers, beside that of finished ones), and the phone's screen has
// no switch that changes nothing there.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets("a phone's notification switches: security alerts, which it can turn off; none for a finished "
      'transfer, which a phone tells of where it happens', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: NotificationSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    final alerts = find.byKey(const ValueKey('settings-security-alerts'));
    await tester.ensureVisible(alerts);
    await tester.pumpAndSettle();
    expect(find.text(en.notifPrefsSecurityAlerts), findsOneWidget);
    // What it does is behind its More (4.0).
    expect(find.text(en.notifPrefsSecurityAlertsDesc), findsNothing);
    await tester.tap(find.byKey(ValueKey('settings-row-more-${en.notifPrefsSecurityAlerts}')));
    await tester.pumpAndSettle();
    expect(find.text(en.notifPrefsSecurityAlertsDesc), findsOneWidget);
    expect(tester.widget<SwitchListTile>(alerts).value, isTrue, reason: 'on until turned off');

    await tester.tap(alerts);
    await tester.pumpAndSettle();
    expect(container.read(notifySecurityAlertsProvider), isFalse);
    expect(tester.widget<SwitchListTile>(alerts).value, isFalse, reason: 'and the switch says so');
    expect(prefs.getBool('notify_security_alerts'), isFalse);

    expect(find.text(en.settingsTransferComplete), findsNothing);
    expect(find.text(en.notifPrefsTransferComplete), findsNothing);
    expect(find.text('Transfers'), findsNothing);
    // What a phone does tell of is still there.
    expect(find.text(en.settingsConnectionLost), findsOneWidget);
    expect(find.text(en.notificationsResourceAlerts), findsOneWidget);
  });

  test('sync carries the switches of security alerts and of failed transfers, as those beside them', () {
    for (final key in ['notify_security_alerts', 'notify_transfer_failed', 'notify_transfer_complete', 'notify_connection_lost']) {
      expect(SettingsService.isSyncedSettingKey(key), isTrue, reason: key);
    }
  });
}
