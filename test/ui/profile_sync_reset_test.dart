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
import 'package:zestssh/services/sync/sync_provider_config.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/sync/sync_now.dart';

/// A store that holds a vault, or none.
class _Store extends Fake implements SyncBackend {
  _Store({required this.holdsVault});

  bool holdsVault;
  int asked = 0;
  int pulls = 0;

  @override
  SyncBackendKind get kind => SyncBackendKind.zestServer;

  @override
  Future<SyncStatus> getStatus() async {
    asked++;
    return SyncStatus(hasData: holdsVault, version: holdsVault ? 3 : 0, blobSize: holdsVault ? 2048 : 0);
  }

  @override
  Future<SyncPullResult> pull() async {
    pulls++;
    throw const SyncException('No sync data found');
  }

  @override
  Future<void> checkConnection() async {}

  /// (An account with Juiced: ZestSSH Cloud keeps its copy.)
  @override
  Future<void> verifyEntitlement() async {}
}

/// The account page and a cloud copy that is gone (3.0): "Sync now" on a
/// device that thinks sync is set up finds the store empty, says so, and
/// with the person's yes sets sync up again; and "Reset cloud sync" is
/// offered where it can be done.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const storage = FlutterSecureStorage();

  late _Store store;

  Future<ProviderContainer> pumpAccount(
    WidgetTester tester, {
    bool signedIn = true,
    bool holdsVault = false,
  }) async {
    FlutterSecureStorage.setMockInitialValues({
      'sync_setup_complete': 'true',
      'sync_setup_step': 'complete',
      'sync_salt': 'c2FsdA==',
    });
    SharedPreferences.setMockInitialValues({'sync_server_version': 12, 'sync_dirty': true});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    store = _Store(holdsVault: holdsVault);
    tester.view.physicalSize = const Size(1000, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      currentUserProvider
          .overrideWith((_) => signedIn ? const UserProfile(uid: 'u1', email: 'you@example.com') : null),
      recordingModeProvider.overrideWith((ref) => false),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 8, 12))),
      syncBackendProvider.overrideWithValue(store),
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

  Future<SyncSetupSnapshot> setupNow(WidgetTester tester) async =>
      (await tester.runAsync(SyncSetupStateService(storage).snapshot))!;

  group('"Sync now" and a store that holds no vault', () {
    testWidgets('it says the cloud copy is gone, and asks nothing of a vault that is not there', (tester) async {
      final c = await pumpAccount(tester);
      await settle(tester);
      requestAccountSyncNow(c.read(accountSyncNowRequestProvider.notifier));
      await settle(tester);

      expect(find.text(l10n.syncGoneTitle), findsOneWidget);
      expect(find.text(l10n.syncGoneBody), findsOneWidget);
      expect(store.asked, greaterThan(0));
      expect(store.pulls, 0, reason: 'there is nothing to pull, and no password to ask for');
      expect((await setupNow(tester)).isComplete, isTrue, reason: 'nothing is changed before the answer');

      await tester.tap(find.text(l10n.notNow));
      await settle(tester);
      expect(find.text(l10n.syncGoneTitle), findsNothing);
      expect((await setupNow(tester)).isComplete, isTrue, reason: 'not now: sync stays as it was');
      expect(await tester.runAsync(() => storage.read(key: 'sync_salt')), 'c2FsdA==');
      expect(find.text(l10n.profileChooseMasterPassword), findsNothing);
      await close(tester);
    });

    testWidgets('with a yes, sync is turned off here and set up again from its start', (tester) async {
      final c = await pumpAccount(tester);
      await settle(tester);
      c.read(syncStatusProvider.notifier).setError('what sync last failed with');
      requestAccountSyncNow(c.read(accountSyncNowRequestProvider.notifier));
      await settle(tester);
      await tester.tap(find.text(l10n.syncSetUpAgain));
      await settle(tester);
      expect(c.read(syncStatusProvider).error, isNull, reason: 'what the page said of the old sync starts over');

      // What this device kept of the copy that is gone is forgotten.
      expect(await tester.runAsync(() => storage.read(key: 'sync_salt')), isNull);
      expect(c.read(settingsServiceProvider).syncServerVersion, 0);
      expect(c.read(settingsServiceProvider).syncDirty, isFalse);
      expect((await setupNow(tester)).isComplete, isFalse);
      // And setup has started: with nothing in the store it makes a new
      // vault, beginning with a new master password.
      expect(find.text(l10n.profileChooseMasterPassword), findsOneWidget);
      expect(store.pulls, 0);

      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      await close(tester);
    });

    testWidgets('a store that holds a vault is synced with as before: nothing is said of a copy gone',
        (tester) async {
      final c = await pumpAccount(tester, holdsVault: true);
      await settle(tester);
      requestAccountSyncNow(c.read(accountSyncNowRequestProvider.notifier));
      await settle(tester);
      expect(find.text(l10n.syncGoneTitle), findsNothing);
      expect(store.pulls, 1, reason: 'it goes on to read the vault');
      expect((await setupNow(tester)).isComplete, isTrue);
      await close(tester);
    });
  });

  group('"Reset cloud sync" in the danger zone', () {
    final row = find.byKey(const ValueKey('reset-cloud-sync'));

    testWidgets('is offered to someone signed in whose store is ZestSSH Cloud', (tester) async {
      await pumpAccount(tester, holdsVault: true);
      await settle(tester);
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(l10n.syncResetTitle)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(l10n.syncResetRowDesc)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(l10n.syncResetRowAction)), findsOneWidget);
      await close(tester);
    });

    testWidgets('its button asks first, and backing out changes nothing', (tester) async {
      await pumpAccount(tester, holdsVault: true);
      await settle(tester);
      await tester.ensureVisible(row);
      await tester.tap(find.descendant(of: row, matching: find.text(l10n.syncResetRowAction)));
      await settle(tester);
      expect(find.text(l10n.syncResetAskTitle), findsOneWidget);
      expect(find.text(l10n.syncResetAskStays), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(find.text(l10n.syncResetAskTitle), findsNothing);
      expect(find.text(l10n.syncResetConfirmSubtitle('you@example.com')), findsNothing,
          reason: 'a no is a no: the email is not asked for next');
      expect((await setupNow(tester)).isComplete, isTrue);
      expect(await tester.runAsync(() => storage.read(key: 'sync_salt')), 'c2FsdA==');
      await close(tester);
    });

    testWidgets('with a yes it asks for the account\'s email next, and backing out there changes nothing',
        (tester) async {
      await pumpAccount(tester, holdsVault: true);
      await settle(tester);
      await tester.ensureVisible(row);
      await tester.tap(find.descendant(of: row, matching: find.text(l10n.syncResetRowAction)));
      await settle(tester);
      await tester.tap(find.text(l10n.profileContinue));
      await settle(tester);
      expect(find.text(l10n.syncResetConfirmSubtitle('you@example.com')), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await settle(tester);
      expect(find.text(l10n.syncResetConfirmSubtitle('you@example.com')), findsNothing);
      expect((await setupNow(tester)).isComplete, isTrue);
      expect(store.asked, 0, reason: 'nothing was asked of the store, and no sign-in was started');
      await close(tester);
    });

    testWidgets('is not offered for a store of one\'s own', (tester) async {
      final c = await pumpAccount(tester, holdsVault: true);
      await settle(tester);
      await tester.runAsync(() => c.read(syncProviderConfigProvider.notifier).save(const SyncProviderConfig(
            kind: SyncBackendKind.webdav,
            webdavUrl: 'https://dav.northwind.example/zest',
            webdavUsername: 'demo',
            webdavPassword: 'demo-password',
          )));
      await settle(tester);
      expect(row, findsNothing);
      await close(tester);
    });

    testWidgets('is not offered to someone signed out', (tester) async {
      await pumpAccount(tester, signedIn: false, holdsVault: true);
      await settle(tester);
      expect(row, findsNothing);
      await close(tester);
    });

    test('the page goes from the question to the email, the reset and how it ended, in that order', () {
      final source = File('lib/ui/screens/profile/profile_screen.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final reset = source.substring(
        source.indexOf('Future<void> _resetCloudSync() async {'),
        source.indexOf('Future<void> _setUpSyncAgain() async {'),
      );
      int at(String text) {
        final i = reset.indexOf(text);
        expect(i, greaterThan(0), reason: text);
        return i;
      }

      final asked = at('if (!await askToResetCloudSync(context, keysElsewhere: kOrchardsEnabled && _keysElsewhere)) return;');
      final typed = at('if (!await confirmSyncResetByEmail(context, ref, account.email)) return;');
      final flow = at('outcome = await SyncResetFlow(');
      final ended = at('if (await showSyncResetOutcome(context, outcome) && mounted) _startSyncSetup();');
      expect(asked, lessThan(typed));
      expect(typed, lessThan(flow));
      expect(flow, lessThan(ended));
      // What the reset is given to work with.
      at('isSameAccount: (fresh) => isSameAccount(account, fresh),');
      at('signInAgain: () => signInAgain(context),');
      at('suspendSync: autoSync.suspend,');
      at('resumeSync: autoSync.resume,');
      at('api: SyncResetApi(),');
      at('disconnectHere: _disconnectSyncHere,');
      at('if (_isResettingSync || _isDeleting) return;');
      at('closeProgress();');
    });
  });
}
