import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/ui/screens/settings/sync_backend_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

class _Config extends SyncProviderConfigNotifier {
  _Config(this.initial);

  final SyncProviderConfig initial;
  final saved = <SyncProviderConfig>[];
  Object? error;

  @override
  SyncProviderConfig build() => initial;

  /// (The choice is the one given: nothing to read.)
  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<void> save(SyncProviderConfig config, {bool overUnreadable = false}) async {
    if (error != null) throw error!;
    saved.add(config);
    state = config;
  }
}

class _Setup extends Fake implements SyncSetupStateService {
  _Setup(this.active);

  final bool active;

  @override
  Future<bool> isSyncActive() async => active;
}

/// The storage settings (3.0): a save that failed put
/// the raw error in a sentence with nothing to copy, and its two questions
/// were plain dialogs.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  const dav = 'https://dav.northwind.example/zest';
  const webdav = SyncProviderConfig(
    kind: SyncBackendKind.webdav,
    webdavUrl: dav,
    webdavUsername: 'demo',
    webdavPassword: 'demo-pass-for-tests',
    webdavPath: '/zest',
  );

  Future<ProviderContainer> open(WidgetTester tester, _Config config, {bool active = false}) async {
    tester.view.physicalSize = const Size(1200, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncProviderConfigProvider.overrideWith(() => config),
        syncSetupStateServiceProvider.overrideWithValue(_Setup(active)),
        isSignedInProvider.overrideWithValue(true),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => SyncBackendScreen.showModal(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncBackendScreen), findsOneWidget);
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.text(en.save));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.save));
    await tester.pumpAndSettle();
  }

  testWidgets('a save that fails says so in the app\'s words, with what was thrown to copy', (tester) async {
    final config = _Config(const SyncProviderConfig.zestServer())
      ..error = PlatformException(code: 'demo', message: 'The keystore is locked');
    final c = await open(tester, config);
    await save(tester);
    final notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.syncBackendNotSaved);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.details, contains('The keystore is locked'));
    expect(notice.title, isNot(contains('keystore')));
    expect(find.byType(SyncBackendScreen), findsOneWidget, reason: 'still open, to try again');
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('S3 by plain http is said to be allowed on your own network alone, as WebDAV is (before, '
      'it was taken anywhere, unsaid)', (tester) async {
    SyncProviderConfig s3(String endpoint) => SyncProviderConfig(
          kind: SyncBackendKind.s3,
          s3Endpoint: endpoint,
          s3Region: 'us-east-1',
          s3Bucket: 'zest-demo',
          s3AccessKeyId: 'demo-key',
          s3SecretAccessKey: 'demo-secret',
        );
    await open(tester, _Config(s3('http://minio.example.com:9000')));
    expect(find.text(en.plainHttpOwnNetworkOnly), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await open(tester, _Config(s3('http://192.168.10.20:9000')));
    expect(find.text(en.plainHttpOwnNetworkNote), findsOneWidget);
    expect(find.text(en.plainHttpOwnNetworkOnly), findsNothing);
  });

  testWidgets('one that works says so and closes', (tester) async {
    final config = _Config(const SyncProviderConfig.zestServer());
    final c = await open(tester, config);
    await save(tester);
    expect(config.saved, hasLength(1));
    expect(c.read(notificationCenterProvider).history.first.title, en.syncBackendStorageSettingsSaved);
    expect(find.byType(SyncBackendScreen), findsNothing);
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('leaving with changes asks in the app\'s own dialog: keep editing, or discard', (tester) async {
    final config = _Config(const SyncProviderConfig.zestServer());
    await open(tester, config);
    await tester.tap(find.text(SyncBackendKind.webdav.label));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(en.syncBackendDiscardChangesTitle), findsOneWidget);
    expect(find.text(en.syncBackendDiscardChangesBody), findsOneWidget);
    await tester.tap(find.text(en.syncBackendKeepEditing));
    await tester.pumpAndSettle();
    expect(find.byType(SyncBackendScreen), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.syncBackendDiscard));
    await tester.pumpAndSettle();
    expect(find.byType(SyncBackendScreen), findsNothing);
    expect(config.saved, isEmpty);
  });

  testWidgets('a click into a field, or the storage it has picked again, is no change: it closes asking nothing '
      '(a reported case)', (tester) async {
    final config = _Config(webdav);
    await open(tester, config);
    await tester.tap(find.widgetWithText(TextField, dav));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SyncBackendKind.webdav.label));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(find.byType(SyncBackendScreen), findsNothing);
    expect(config.saved, isEmpty);

    // Its words changed: closing asks.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, dav), '$dav/other');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    await tester.tap(find.text(en.syncBackendDiscard));
    await tester.pumpAndSettle();
    expect(config.saved, isEmpty);
  });

  testWidgets('pointing a store that is in use somewhere else asks in the app\'s own dialog, and Cancel saves nothing',
      (tester) async {
    final config = _Config(webdav);
    final c = await open(tester, config, active: true);
    await tester.ensureVisible(find.text(dav));
    await tester.enterText(find.text(dav), 'https://dav2.northwind.example/zest');
    await tester.pumpAndSettle();
    await save(tester);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(en.syncBackendSwitchStorageTitle), findsOneWidget);
    expect(find.text(en.syncBackendSwitchSameKindBody(SyncBackendKind.webdav.label)), findsOneWidget);
    expect(find.text(en.syncBackendSwitch), findsOneWidget);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(config.saved, isEmpty);
    expect(c.read(notificationCenterProvider).history, isEmpty, reason: 'nothing was tried');
    expect(find.byType(SyncBackendScreen), findsOneWidget);
  });

  testWidgets("storage of one's own says what still reaches ZestSSH's servers, never the synced data; ZestSSH Cloud does not",
      (tester) async {
    await open(tester, _Config(webdav));
    final note = find.byKey(const ValueKey('own-storage-note'));
    expect(note, findsOneWidget);
    expect(find.descendant(of: note, matching: find.text(en.syncBackendOwnStorageNote)), findsOneWidget);
    expect(en.syncBackendOwnStorageNote, contains('signed-in devices'));
    expect(en.syncBackendOwnStorageNote, contains('zestssh.com'));
    await tester.pumpWidget(const SizedBox());
    await open(tester, _Config(const SyncProviderConfig.zestServer()));
    expect(find.byKey(const ValueKey('own-storage-note')), findsNothing, reason: 'everything goes to ZestSSH Cloud there');
  });

  testWidgets('a ZestSSH server of one’s own is not offered', (tester) async {
    await open(tester, _Config(const SyncProviderConfig.zestServer()));
    expect(find.text(SyncBackendKind.webdav.label), findsOneWidget);
    expect(find.text(en.storageSelfHosted), findsNothing);
  });

  testWidgets('a device already using one still sees it, as what it uses', (tester) async {
    await open(
        tester, _Config(const SyncProviderConfig(kind: SyncBackendKind.custom, serverUrl: 'https://sync.northwind.example/v1')));
    expect(find.text(en.storageSelfHosted), findsWidgets);
  });

  test('every language says a save that failed its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      expect(lookupAppLocalizations(locale).syncBackendNotSaved, isNot(en.syncBackendNotSaved), reason: '$locale');
    }
  });
}
