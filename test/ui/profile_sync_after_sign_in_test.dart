import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

class _Store extends Fake implements SyncBackend {
  _Store({this.hasData = true});

  final bool hasData;
  int pulls = 0;

  /// What a pull answers: else a store that cannot be reached.
  SyncPullResult? pulled;

  @override
  SyncBackendKind get kind => SyncBackendKind.zestServer;

  @override
  Future<void> verifyEntitlement() async {}

  @override
  Future<SyncPullResult> pull() async {
    pulls++;
    return pulled ?? (throw const SocketException('Connection refused'));
  }

  @override
  Future<SyncStatus> getStatus() async => SyncStatus(hasData: hasData, version: 3, blobSize: 2048);
}

class _Api extends Fake implements DeviceSessionsApi {
  _Api(this.devices);

  final List<DeviceSessionInfo> devices;

  @override
  Future<List<DeviceSessionInfo>> list() async => devices;
}

class _Devices extends Fake implements DeviceSessionService {
  _Devices(this.api);

  @override
  final DeviceSessionsApi api;
}

/// The end of a sign-in on a device that is not in the account's sync asks for
/// the sync password at once, in its own words (as a security review asked), with the
/// approval first where another of the account's devices is signed in. Sync now
/// runs the same cycle as the background sync with the keys this device keeps,
/// and asks only where they no longer open the account, saying why. A
/// password manager can fill the field.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late _Store store;

  Future<ProviderContainer> pumpAccount(
    WidgetTester tester, {
    required bool syncSetUp,
    bool hasData = true,
    List<DeviceSessionInfo> devices = const [],
    AutoSyncService? autoSync,
  }) async {
    FlutterSecureStorage.setMockInitialValues({
      if (syncSetUp) 'sync_setup_complete': 'true',
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    store = _Store(hasData: hasData);
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
      recordingModeProvider.overrideWith((ref) => false),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 8, 12))),
      syncBackendProvider.overrideWithValue(store),
      deviceSessionServiceProvider.overrideWithValue(_Devices(_Api(devices))),
      if (autoSync != null) autoSyncServiceProvider.overrideWithValue(autoSync),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ));
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  void ask(ProviderContainer c) {
    final request = c.read(accountTurnSyncOnRequestProvider.notifier);
    request.state = false;
    request.state = true;
  }

  group('the end of a sign-in', () {
    testWidgets('asks for the sync password at once, in its own words, and Not now leaves it be', (tester) async {
      final c = await pumpAccount(tester, syncSetUp: false);
      await settle(tester);
      expect(find.text(en.syncTurnOnTitle), findsNothing, reason: 'nothing by itself');
      ask(c);
      expect(c.read(accountTurnSyncOnRequestProvider), isFalse, reason: 'taken at once: no second page is opened');
      await settle(tester);
      expect(find.text(en.syncTurnOnTitle), findsOneWidget);
      expect(find.text(en.syncTurnOnBody), findsOneWidget);
      expect(find.text(en.syncTurnOnAction), findsOneWidget);
      expect(find.text(en.syncPasswordManagerHint), findsOneWidget);

      final field = tester.widget<TextField>(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)));
      expect(field.autofillHints, contains(AutofillHints.password), reason: 'a password manager can fill it');

      await tester.tap(find.text(en.notNow));
      await settle(tester);
      expect(find.text(en.syncTurnOnTitle), findsNothing);
      expect(await c.read(syncSetupStateServiceProvider).isSyncActive(), isFalse);
      await close(tester);
    });

    testWidgets('another device signed in: the approval comes first, as a button', (tester) async {
      final c = await pumpAccount(tester, syncSetUp: false, devices: [
        DeviceSessionInfo(id: 'a', kind: 'session_token', platform: 'windows', createdAt: DateTime(2026, 10, 1), current: true),
        DeviceSessionInfo(id: 'b', kind: 'registration', platform: 'android', createdAt: DateTime(2026, 10, 2), current: false),
      ]);
      await settle(tester);
      ask(c);
      await settle(tester);
      expect(find.byKey(const ValueKey('join-approve-first')), findsOneWidget);
      expect(find.byKey(const ValueKey('join-approve-from-device')), findsNothing);
      await tester.tap(find.text(en.notNow));
      await settle(tester);
      await close(tester);
    });

    testWidgets('alone on the account: the approval stays a link', (tester) async {
      final c = await pumpAccount(tester, syncSetUp: false, devices: [
        DeviceSessionInfo(id: 'a', kind: 'session_token', platform: 'windows', createdAt: DateTime(2026, 10, 1), current: true),
      ]);
      await settle(tester);
      ask(c);
      await settle(tester);
      expect(find.byKey(const ValueKey('join-approve-first')), findsNothing);
      await tester.tap(find.text(en.notNow));
      await settle(tester);
      await close(tester);
    });

    testWidgets('a sync that has gone meanwhile is not made anew: making one is the person\'s own choice',
        (tester) async {
      final c = await pumpAccount(tester, syncSetUp: false, hasData: false);
      await settle(tester);
      ask(c);
      await settle(tester);
      expect(find.text(en.syncTurnOnTitle), findsNothing);
      expect(find.text(en.profileChooseMasterPassword), findsNothing);
      await close(tester);
    });

    testWidgets('a device already syncing: the request is taken and nothing is asked', (tester) async {
      final c = await pumpAccount(tester, syncSetUp: true);
      await settle(tester);
      ask(c);
      await settle(tester);
      expect(c.read(accountTurnSyncOnRequestProvider), isFalse);
      expect(find.text(en.syncTurnOnTitle), findsNothing);
      await close(tester);
    });
  });

  group('Sync now', () {
    testWidgets('with the keys this device keeps: nothing is asked, and it says the version', (tester) async {
      final sync = _Sync();
      await pumpAccount(tester, syncSetUp: true, autoSync: sync);
      await settle(tester);
      await tester.tap(find.text(en.accountSyncNow));
      await settle(tester);
      expect(sync.calls, 1);
      expect(store.pulls, 0, reason: 'no password to derive anything with');
      expect(find.text(en.profileUnlockSyncNowTitle), findsNothing);
      await close(tester);
    });

    testWidgets('keys that no longer open the account: it asks, and says why', (tester) async {
      final sync = _Sync()..error = const SyncKeysMismatchException('keys');
      await pumpAccount(tester, syncSetUp: true, autoSync: sync);
      store.pulled = SyncPullResult(
        encryptedData: Uint8List(8),
        salt: Uint8List(16),
        version: 3,
        updatedAt: DateTime.utc(2026, 10, 1),
        wrappedDekPassword: Uint8List(60),
      );
      await settle(tester);
      await tester.tap(find.text(en.accountSyncNow));
      await settle(tester);
      expect(sync.calls, 1);
      expect(store.pulls, 1, reason: "the account's salt and settings, for the password");
      expect(find.text(en.profileUnlockSyncNowTitle), findsOneWidget);
      expect(find.text(en.syncPasswordChangedElsewhere), findsOneWidget);
      final field = tester.widget<TextField>(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)));
      expect(field.autofillHints, contains(AutofillHints.password));
      await tester.tap(find.text(en.cancel));
      await settle(tester);
      await close(tester);
    });

    testWidgets('a store that says cloud sync was reset is said, with no password asked', (tester) async {
      final sync = _Sync()..error = const SyncWasResetException('was reset');
      await pumpAccount(tester, syncSetUp: true, autoSync: sync);
      await settle(tester);
      await tester.tap(find.text(en.accountSyncNow));
      await settle(tester);
      expect(store.pulls, 0);
      expect(find.text(en.profileUnlockSyncNowTitle), findsNothing);
      await close(tester);
    });
  });
}

class _Sync extends Fake implements AutoSyncService {
  int calls = 0;
  Object? error;

  @override
  final ValueNotifier<String?> syncError = ValueNotifier<String?>(null);

  @override
  final ValueNotifier<SyncActivity> activity = ValueNotifier<SyncActivity>(const SyncActivity());

  @override
  Future<int> syncNowManual() async {
    calls++;
    if (error != null) throw error!;
    return 7;
  }
}
