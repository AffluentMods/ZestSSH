import 'dart:io';

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
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/sync/sync_now.dart';

/// A store that says it holds a vault, and cannot be read: enough to see
/// that "Sync now" started and asked it for what it holds.
class _Store extends Fake implements SyncBackend {
  int pulls = 0;

  @override
  SyncBackendKind get kind => SyncBackendKind.zestServer;

  @override
  Future<SyncPullResult> pull() async {
    pulls++;
    throw const SocketException('Connection refused');
  }

  @override
  Future<SyncStatus> getStatus() async => const SyncStatus(hasData: true, version: 3, blobSize: 2048);
}

/// The "Sync now" on a notice that says sync paused because this device's
/// keys are no longer the account's (3.0):
/// it asks for the account page's own Sync now, the one that asks for the
/// sync password again. The page takes the request, whether it is opened for
/// it or on screen already, and starts its Sync now as its own button would.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _Store store;

  Future<ProviderContainer> pumpAccount(
    WidgetTester tester, {
    required bool syncSetUp,
    bool askedBefore = false,
  }) async {
    FlutterSecureStorage.setMockInitialValues({
      if (syncSetUp) 'sync_setup_complete': 'true',
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    store = _Store();
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
    ]);
    addTearDown(container.dispose);
    if (askedBefore) requestAccountSyncNow(container.read(accountSyncNowRequestProvider.notifier));
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

  testWidgets('asked before the page is opened: taken when it opens, and its Sync now starts', (tester) async {
    final c = await pumpAccount(tester, syncSetUp: true, askedBefore: true);
    await settle(tester);
    expect(c.read(accountSyncNowRequestProvider), isFalse, reason: 'taken back');
    expect(store.pulls, 1, reason: 'the account is asked for what it holds: Sync now started');
    await close(tester);
  });

  testWidgets('asked while the page is on screen: taken at once, and started once', (tester) async {
    final c = await pumpAccount(tester, syncSetUp: true);
    await settle(tester);
    expect(store.pulls, 0, reason: 'nothing starts by itself');
    requestAccountSyncNow(c.read(accountSyncNowRequestProvider.notifier));
    expect(c.read(accountSyncNowRequestProvider), isFalse, reason: 'taken the moment it is made: no second page is opened over this one');
    await settle(tester);
    expect(store.pulls, 1);
    requestAccountSyncNow(c.read(accountSyncNowRequestProvider.notifier));
    await settle(tester);
    expect(store.pulls, 2, reason: 'asked again, started again');
    await close(tester);
  });

  testWidgets('sync is not set up on this device: the request is taken and nothing starts', (tester) async {
    final c = await pumpAccount(tester, syncSetUp: false, askedBefore: true);
    await settle(tester);
    expect(c.read(accountSyncNowRequestProvider), isFalse);
    expect(store.pulls, 0, reason: 'there is no Sync now to start: the page shows how to set sync up');
    await close(tester);
  });
}
