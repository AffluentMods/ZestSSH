import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/automation/automation_refusals.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/automation_provider.dart' show AutomationBlocked;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/app_notices.dart';

/// The app's own notices (3.0): back from the background with
/// sessions dropped, and an automation command that was not run (each reason
/// and where its action goes: test/features/automation/automation_refusals_test.dart).
/// In the app's language, and true to what is happening. (On a computer a
/// notice goes to the notification center, where these tests read it.)
void main() {
  Future<(BuildContext, ProviderContainer)> app(WidgetTester tester, {Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    late BuildContext context;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const SizedBox();
        })),
      ),
    ));
    return (context, container);
  }

  AppNotification last(ProviderContainer c) => c.read(notificationCenterProvider).history.first;

  testWidgets('back from the background: connecting again, or disconnected, and Why? explains', (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    var why = 0;
    final (context, c) = await app(tester);
    showResumeNotice(context, dropped: 2, reconnecting: true, onWhy: () => why++);
    expect(last(c).title, en.resumeReconnecting(2));
    expect(last(c).actionLabel, en.resumeWhy);
    last(c).onAction!();
    expect(why, 1);

    showResumeNotice(context, dropped: 1, reconnecting: false, onWhy: () => why++);
    expect(last(c).title, en.resumeDisconnected(1), reason: 'nothing is connecting again');
    expect(last(c).severity, NotificationSeverity.info);
    // Past the time they stay on screen.
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets("in another language, in that language's words", (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    final (context, c) = await app(tester, locale: const Locale('de'));
    showResumeNotice(context, dropped: 3, reconnecting: false, onWhy: () {});
    expect(last(c).title, de.resumeDisconnected(3));
    expect(last(c).actionLabel, de.resumeWhy);
    showAutomationBlockedNotice(context, why: AutomationBlocked.off, actionLabel: de.settingsTitle, onAction: () {});
    expect(last(c).title, de.automationBlockedDisabled);
    expect(last(c).severity, NotificationSeverity.warning);
    await tester.pump(const Duration(seconds: 8));
  });
}
