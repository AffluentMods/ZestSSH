import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/widgets/notification_bell.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/l10n/time_text.dart';

/// The bell says when each notice came in the page's language (3.0):
/// "just now", "5m", "3h", "2d", and past a week "Sep 28",
/// with "Sep 28, 2026 · 14:05:09" over it, in English in every language.
/// It says them in the one compact style
/// ("5m ago", not "5m").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => NotificationCenter.debugToastsDrawn = null);

  Future<ProviderContainer> pump(WidgetTester tester, Locale locale) async {
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf']) {
        final bytes = File('assets/fonts/$f').readAsBytesSync();
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
      }
      await loader.load().timeout(const Duration(seconds: 30));
    });
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Align(alignment: Alignment.topRight, child: NotificationBell())),
      ),
    ));
    return c;
  }

  for (final locale in const [Locale('de'), Locale('ja')]) {
    testWidgets("a notice's time in the bell, and the day and time over it, in the page's language ($locale)",
        (tester) async {
      NotificationCenter.debugToastsDrawn = true;
      final l = lookupAppLocalizations(locale);
      final c = await pump(tester, locale);
      final nc = c.read(notificationCenterProvider.notifier);
      final now = DateTime.now();
      final before = now.subtract(const Duration(days: 19));
      nc.show(AppNotification(id: 'a', title: 'web-01 is back', severity: NotificationSeverity.info, createdAt: before));
      nc.show(AppNotification(
          id: 'b',
          title: 'db-primary is down',
          severity: NotificationSeverity.error,
          createdAt: now.subtract(const Duration(minutes: 5))));
      nc.show(AppNotification(id: 'c', title: 'Saved the layout', severity: NotificationSeverity.success, createdAt: now));
      await tester.pump();
      await tester.tap(find.byType(NotificationBell));
      await tester.pump();

      expect(find.text(l.timeJustNow), findsOneWidget);
      expect(find.text(l.timeMinutesAgo(5)), findsOneWidget);
      final day = before.year == now.year ? DateFormat.Md(l.localeName).format(before) : DateFormat.y(l.localeName).format(before);
      expect(find.text(day), findsOneWidget, reason: 'past a week the day');
      final over = '${DateFormat.yMMMd(l.localeName).format(before)} · ${DateFormat.Hms(l.localeName).formatPlain(before)}';
      expect(find.byTooltip(over), findsOneWidget, reason: 'the day and the time over it');
      for (final english in const ['Just now', '5m ago']) {
        expect(find.text(english), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 12));
    });
  }
}
