import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../a11y/a11y_checks.dart';
import '../helpers/fake_notifications_plugin.dart';
import '../visual/shots_util.dart';

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;
  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no team here');
  @override
  Future<void> delete(String orchardId) async {}
  @override
  Future<List<String>> list() async => const [];
}

/// Settings > Notifications on a computer (4.0): "Also show as system
/// notifications", off at first, this computer's alone (not synced, kept by
/// Reset all settings' list); on, it starts the system's notifications; on
/// a Mac whose person says no, it stays off and says where to allow them. A
/// tablet's large screen, whose notifications are the system's always, has
/// no such row.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final row = find.byKey(const ValueKey('settings-system-notifications'));
  late ProviderContainer container;
  late SharedPreferences prefs;

  tearDown(() {
    NotificationService.debugReset();
    debugTouchLayout = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), null);
  });

  Future<void> pump(WidgetTester tester, {bool touch = false}) async {
    await tester.runAsync(loadShotFonts);
    debugTouchLayout = touch;
    L10nGlobal.update(en);
    final t = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(t.colorScheme);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kSettingsLastSectionKey: 'notifications'});
    prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1274, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 14, 12))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: t.toThemeData(compact: touch ? false : null),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: SettingsInlineView()),
      ),
    ));
    await settleA11y(tester);
  }

  Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  test("the setting is this computer's, off at first, not synced, and put back by Reset all settings", () {
    expect(SettingsService.resetKeys, contains('desktop_system_notifications'));
    expect(SettingsService.deviceKeys, contains('desktop_system_notifications'));
    expect(SettingsService.isSyncedSettingKey('desktop_system_notifications'), isFalse);
  });

  testWidgets('a computer: the row under Notifications, off at first; turned on, the system\'s notifications start',
      (tester) async {
    final handle = tester.ensureSemantics();
    final fake = FakeNotificationsPlugin();
    NotificationService.debugOs = 'windows';
    NotificationService.debugPlugin = fake;
    await pump(tester);
    expect(find.text(en.notifPrefsSystemComputer), findsOneWidget);
    expect(container.read(desktopSystemNotificationsProvider), isFalse);
    await expectA11y(tester, computer: true, where: 'Settings, Notifications');

    await tester.tap(row);
    await settleA11y(tester);
    expect(container.read(desktopSystemNotificationsProvider), isTrue);
    expect(prefs.getBool('desktop_system_notifications'), isTrue);
    expect(NotificationService.computerSystemNotices, isTrue);
    expect(fake.settings?.windows, isNotNull, reason: 'started for Windows');

    await tester.tap(row);
    await settleA11y(tester);
    expect(prefs.getBool('desktop_system_notifications'), isFalse);
    expect(NotificationService.computerSystemNotices, isFalse);
    handle.dispose();
    await takeDown(tester);
  });

  testWidgets('a Mac whose person says no: the switch stays off, and the way to allow them is said', (tester) async {
    final fake = FakeNotificationsPlugin()..platform = MacOSFlutterLocalNotificationsPlugin();
    NotificationService.debugOs = 'macos';
    NotificationService.debugPlugin = fake;
    final asked = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'), (call) async {
      asked.add(call);
      return call.method == 'requestPermissions' ? false : null;
    });
    await pump(tester);
    await tester.tap(row);
    await settleA11y(tester);
    expect(asked.map((c) => c.method), contains('requestPermissions'));
    expect(container.read(desktopSystemNotificationsProvider), isFalse);
    expect(prefs.getBool('desktop_system_notifications'), isNull);
    expect(NotificationService.computerSystemNotices, isFalse);
    // Said as a computer says a message: a card of the app's notices, with the way to the settings.
    final said = container.read(notificationCenterProvider).history
        .where((n) => '${n.title} ${n.body ?? ''}'.trim() == en.notifPrefsSystemMacDenied);
    expect(said, hasLength(1));
    expect(said.single.actionLabel, en.notificationsOpenSystemSettings);
    await takeDown(tester);
  });

  testWidgets("a tablet's large screen has no such row: its notifications are the system's always", (tester) async {
    await pump(tester, touch: true);
    expect(find.text(en.notifPrefsSystemComputer), findsNothing);
    expect(row, findsNothing);
    await takeDown(tester);
  });
}
