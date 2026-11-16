import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';

import '../helpers/fake_device_approvals_server.dart';

/// Account, Devices (3.0): "Approve a new device" is there
/// only where this device holds the sync key, on ZestSSH Cloud, and opens
/// the approval. Orchards are built behind a switch, so this runs with
/// `--dart-define=ZEST_ORCHARDS=true`.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpAccount(WidgetTester tester, {required bool syncOn, bool byo = false}) async {
    FlutterSecureStorage.setMockInitialValues({if (syncOn) 'sync_setup_complete': 'true'});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final list = MockClient((req) async => http.Response(
        jsonEncode({
          'sessions': [
            {'id': 'd1', 'kind': 'session_token', 'platform': 'windows', 'current': true},
          ],
        }),
        200));
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        // A still clock: its 30-second ticker would outlive the test.
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 25, 12))),
        syncIsBringYourOwnProvider.overrideWithValue(byo),
        deviceApprovalsApiProvider.overrideWithValue(FakeApprovalServer().device('desktop')),
        deviceSessionServiceProvider.overrideWithValue(DeviceSessionService(
          api: DeviceSessionsApi(client: list, baseUrl: 'https://cloud.test/v1', bearer: () async => 't'),
          store: DeviceSessionStore(const FlutterSecureStorage()),
          firebaseUid: () => null,
          sessionToken: () async => null,
          saveSessionToken: (_) async {},
          labels: () async => const DeviceLabels(platform: 'windows'),
        )),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ));
    await settle(tester);
  }

  final row = find.byKey(const ValueKey('devices-approve'));

  testWidgets('with sync on here: the row, and it opens the approval', (tester) async {
    await pumpAccount(tester, syncOn: true);
    expect(find.text(l10n.devicesApproveTitle), findsOneWidget);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await settle(tester);
    expect(find.text(l10n.approveNone), findsOneWidget, reason: 'the approval opened; nobody is asking');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: !kOrchardsEnabled);

  testWidgets('without sync on this device: no row, it holds no key', (tester) async {
    await pumpAccount(tester, syncOn: false);
    expect(find.text(l10n.devicesSignOutEverywhereDesc), findsOneWidget, reason: 'the Devices section is there');
    expect(row, findsNothing);
    // A device is named in the app's sans, as every row's title is ("Windows"
    // was in the code font).
    final name = tester.widget<Text>(find.byKey(const ValueKey('account-device-name')));
    expect(name.style!.fontFamily, isNot('JetBrainsMono'));
    // "This device" is grey with a device, as a team's devices show it: which
    // one is in hand, not a state (it was
    // green).
    final mark = tester.widget<ZestStatusPill>(find.byKey(const ValueKey('account-device-this')));
    expect((mark.kind, mark.icon, mark.label), (ZestStatusKind.neutral, LucideIcons.monitorCheck, l10n.zestProfileThisDevice));
    // And the Danger zone under the app's own section header, in red.
    final danger = tester.widget<ZestSectionHeader>(
        find.byWidgetPredicate((w) => w is ZestSectionHeader && w.label == l10n.accountDangerZone));
    expect(danger.danger, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: !kOrchardsEnabled);

  testWidgets('with your own storage: no row', (tester) async {
    await pumpAccount(tester, syncOn: true, byo: true);
    expect(find.text(l10n.devicesSignOutEverywhereDesc), findsOneWidget);
    expect(row, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: !kOrchardsEnabled);
}
