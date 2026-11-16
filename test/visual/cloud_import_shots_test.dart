import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/cloud_tls.dart';
import 'package:zestssh/features/cloud_import/ui/cloud_accounts_view.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/connection/share_link_add.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

import 'shots_util.dart';

/// Pictures of Import hosts (3.0 cloud import), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/cloud_import_shots_test.dart
///
/// Pictures land in build/shots/.

final l10n = lookupAppLocalizations(const Locale('en'));

const _machines = [
  CloudMachine(provider: CloudProvider.aws, id: 'i-1', name: 'api-prod-1', publicAddress: '203.0.113.14', where: 'us-east-1a', tags: ['env:prod']),
  CloudMachine(provider: CloudProvider.aws, id: 'i-2', name: 'api-prod-2', publicAddress: '203.0.113.15', where: 'us-east-1b', tags: ['env:prod']),
  CloudMachine(provider: CloudProvider.aws, id: 'i-3', name: 'worker-eu', publicAddress: '198.51.100.9', where: 'eu-central-1a', tags: ['env:prod']),
  CloudMachine(provider: CloudProvider.aws, id: 'i-4', name: 'bastion', publicAddress: '203.0.113.10', where: 'us-east-1a', tags: ['role:bastion']),
  CloudMachine(provider: CloudProvider.aws, id: 'i-5', name: 'win-build', publicAddress: '198.51.100.3', where: 'us-east-1c', os: CloudOs.windows),
  CloudMachine(provider: CloudProvider.aws, id: 'i-6', name: 'batch-spot', where: 'us-west-2a', running: false),
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<GlobalKey> pump(WidgetTester tester,
      {Size size = const Size(1440, 1000), required Widget Function(BuildContext) opener, AppDatabase? db, String themeId = 'graphite'}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId});
    final prefs = await SharedPreferences.getInstance();
    final data = db ?? AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(data.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
          databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(data)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: Builder(builder: opener)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return key;
  }

  Widget dialogOpener(BuildContext context, {Object? error}) => Center(
        child: TextButton(
          onPressed: () => showZestModal<ImportHostsResult>(
            context: context,
            size: ZestModalSize.large,
            child: ImportHostsDialog(
              scan: (p, f) async {
                if (error != null) throw error;
                return _machines;
              },
              probe: (base) async => const CloudCertificate(
                sha256: 'D2:93:C9:44:ED:19:1C:66:05:72:E1:C4:F2:0C:B6:33:88:71:60:CD:18:CD:D5:1A:C6:CA:63:85:FF:6C:F0:70',
                subject: 'CN=pve.test',
                issuer: 'CN=pve.test',
              ),
            ),
          ),
          child: const Text('open'),
        ),
      );

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField)), text);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('Import hosts, every step', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime.utc(2026, 9, 26);
    String link(String id, String a, String n, {bool gone = false}) =>
        CloudLink(provider: CloudProvider.aws, machineId: id, label: 'AWS production', address: a, name: n, gone: gone).encode();
    await db.connectionsDao.insertConnection(ConnectionsCompanion.insert(
        id: 'h1', label: 'api-prod-2', host: '203.0.113.11', cloudSource: Value(link('i-2', '203.0.113.11', 'api-prod-2')), createdAt: at, updatedAt: at));
    await db.connectionsDao.insertConnection(ConnectionsCompanion.insert(id: 'h2', label: 'my bastion', host: '203.0.113.10', createdAt: at, updatedAt: at));
    await db.connectionsDao.insertConnection(ConnectionsCompanion.insert(
        id: 'h3', label: 'old-api', host: '203.0.113.2', cloudSource: Value(link('i-0', '203.0.113.2', 'old-api')), createdAt: at, updatedAt: at));
    final key = await pump(tester, opener: dialogOpener, db: db);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Every source, files and apps and clouds, on one step.
    await saveShot(tester, key, 'cloud_0_apps');
    await tester.tap(find.byKey(const ValueKey('cloud-source-aws')));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'cloud_1_source');

    await type(tester, 'cloud-account-name', 'AWS production');
    await type(tester, 'cloud-field-keyId', 'AKIAIOSFODNN7EXAMPLE');
    await type(tester, 'cloud-field-secret', 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY');
    await tester.tap(find.byKey(const ValueKey('cloud-how-to')));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'cloud_2_connect_aws');

    await press(tester, l10n.cloudImpScan);
    await saveShot(tester, key, 'cloud_3_choose');

    // The destinations are read from the database, which answers outside
    // the test's clock: waited for, so the picture is of step 4 (it was the
    // list of step 3 again).
    await press(tester, l10n.cloudImpNext);
    for (var i = 0; i < 50 && find.byKey(const ValueKey('cloud-group')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-group')), findsOneWidget, reason: 'step 4, Destination');
    await saveShot(tester, key, 'cloud_4_destination');
    plainShadows();
  }, skip: !shotsEnabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // The first step as the 4.0 mockup draws it, in Ember, the
  // theme the mockup is drawn in.
  testWidgets('Import hosts, the first step in Ember', (tester) async {
    final key = await pump(tester, opener: dialogOpener, themeId: 'default_dark');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'cloud_0_apps_ember');
    plainShadows();
  }, skip: !shotsEnabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Import hosts, Proxmox certificate and a failure', (tester) async {
    final key = await pump(tester, opener: (c) => dialogOpener(c, error: CloudError(CloudErrorKind.notAllowed, status: 403, detail: 'GET https://192.168.20.10:8006/api2/json/cluster/resources -> 403')));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-source-proxmox')));
    await tester.pumpAndSettle();
    await type(tester, 'cloud-field-url', '192.168.20.10');
    await type(tester, 'cloud-field-token', 'root@pam!zestssh=0a1b2c3d-aaaa-bbbb-cccc-1234567890ab');
    await press(tester, l10n.cloudImpScan);
    await type(tester, 'cloud-certificate-paste', '24:E8:BD:E5:AB:3F:B2:0D:82:B6:6C:9E:08:CC:01:18:66:D5:22:C1:F4:88:7C:3F:9E:2F:FE:13:BB:BB:26:E1');
    // Past the 120 ms the turned-off main button takes to change: one frame
    // after the typing caught it halfway (the orange fill with grey words).
    await tester.pump(const Duration(milliseconds: 200));
    await saveShot(tester, key, 'cloud_5_proxmox_certificate');
    await type(tester, 'cloud-certificate-paste', 'D2:93:C9:44:ED:19:1C:66:05:72:E1:C4:F2:0C:B6:33:88:71:60:CD:18:CD:D5:1A:C6:CA:63:85:FF:6C:F0:70');
    await press(tester, l10n.cloudImpCertTrust);
    await saveShot(tester, key, 'cloud_6_error');
    plainShadows();
  }, skip: !shotsEnabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Import hosts on a phone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final key = await pump(tester, size: const Size(390, 844), opener: dialogOpener);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'cloud_7a_phone_apps', pixelRatio: 2);
    await tester.ensureVisible(find.byKey(const ValueKey('cloud-source-digitalocean')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-source-digitalocean')));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'cloud_7_phone_source', pixelRatio: 2);
    await type(tester, 'cloud-field-token', 'dop_v1_example');
    await press(tester, l10n.cloudImpScan);
    await saveShot(tester, key, 'cloud_8_phone_choose', pixelRatio: 2);
    debugDefaultTargetPlatformOverride = null;
    plainShadows();
  }, skip: !shotsEnabled);

  testWidgets('Settings, cloud accounts', (tester) async {
    final key = await pump(tester, size: const Size(760, 520), opener: (context) => const SingleChildScrollView(child: CloudAccountsTiles()));
    final container = ProviderScope.containerOf(tester.element(find.byType(CloudAccountsTiles)));
    await container.read(cloudAccountsProvider.notifier).keep(CloudAccount(
          id: 'a1',
          provider: CloudProvider.hetzner,
          label: 'Hetzner CI',
          fields: const {CloudField.token: 'x'},
          checkedAt: DateTime(2026, 9, 26, 9, 30),
          found: 7,
        ));
    await container.read(cloudAccountsProvider.notifier).keep(const CloudAccount(
          id: 'a2',
          provider: CloudProvider.tailscale,
          label: 'Home tailnet',
          fields: {CloudField.token: 'y'},
          problem: CloudErrorKind.signIn,
          problemDetail: 'GET https://api.tailscale.com/api/v2/tailnet/-/devices -> 401',
        ));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'cloud_9_settings_accounts');
    plainShadows();
  }, skip: !shotsEnabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // A share link: offered from the clipboard (a computer), and pasted, one
  // that does not read refused under the field.
  final shareLink = ConnectionShareUrlService.buildShareUrl(label: 'web 01', host: 'web-01.example.com', port: 2222, user: 'deploy').toString();

  Widget clipboardOpener(BuildContext context) => Center(
        child: TextButton(
          onPressed: () => showZestModal<ImportHostsResult>(
            context: context,
            size: ZestModalSize.large,
            child: ImportHostsDialog(readClipboard: () async => shareLink),
          ),
          child: const Text('open'),
        ),
      );

  Widget pasteOpener(BuildContext context) =>
      Center(child: TextButton(onPressed: () => showPasteShareLink(context), child: const Text('open')));

  Future<void> refused(WidgetTester tester) async {
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('share-link-field')), matching: find.byType(EditableText)), 'zestssh://share?d=eyJ2IjoxLCJob3N0Ijo');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('share-link-continue')));
    await tester.pumpAndSettle();
  }

  for (final themeId in ['graphite', 'default_light']) {
    testWidgets('Import hosts, a share link ($themeId)', (tester) async {
      final key = await pump(tester, opener: clipboardOpener, themeId: themeId);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await saveShot(tester, key, 'cloud_10_share_clipboard_$themeId');
      final paste = await pump(tester, size: const Size(1100, 640), opener: pasteOpener, themeId: themeId);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await saveShot(tester, paste, 'cloud_11_share_paste_$themeId');
      await refused(tester);
      await saveShot(tester, paste, 'cloud_12_share_refused_$themeId');
      plainShadows();
    }, skip: !shotsEnabled, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('Import hosts, a share link on a phone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final key = await pump(tester, size: const Size(390, 844), opener: pasteOpener);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await refused(tester);
    await saveShot(tester, key, 'cloud_13_phone_share_paste', pixelRatio: 2);
    debugDefaultTargetPlatformOverride = null;
    plainShadows();
  }, skip: !shotsEnabled);
}
