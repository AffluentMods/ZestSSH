// Real Argon2id key derivation (the weakest profile deriveKey accepts), which
// can take half a minute a key on a busy machine.
@Timeout(Duration(minutes: 8))
library;

import 'dart:io' show SocketException;

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../helpers/memory_store_backend.dart';

/// Restoring with a recovery key on the Account page, when it does not go
/// through (3.0): "That recovery key didn't work" is said of
/// a key the store refused, and of nothing else. A store that could not be
/// reached while the key was being tried says that it could not be reached.
/// Until this was held, whatever stopped the restore told the person that
/// their recovery key, the one way back to their data, was wrong.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  const params = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const recoveryKey = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
  const refused = SocketException('Connection refused');
  late Uint8List salt;
  late Uint8List recoverySalt;
  late SecretKey dek;
  late SecretKey kek;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    recoverySalt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    kek = await SyncService.deriveKey(recoveryKey.replaceAll('-', ''), recoverySalt, params: params);
  });

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Whether [message] shows, on screen or as a desktop notification.
  bool shows(WidgetTester tester, String message) {
    if (find.textContaining(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Navigator).first));
    return container
        .read(notificationCenterProvider)
        .history
        .any((n) => '${n.title} ${n.body ?? ''}'.contains(message) || message.startsWith(n.title));
  }

  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    final clock = Stopwatch()..start();
    while (!done() && clock.elapsed < const Duration(minutes: 3)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The Account page on a device where sync is not set up, with a store
  /// that already holds a vault with a recovery key: the page as someone
  /// sees it who lost the master password and has the key in hand.
  Future<_Store> pumpAccount(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = SettingsService(prefs);
    final backend = _Store(MemoryStore());
    await tester.runAsync(() async {
      const storage = FlutterSecureStorage();
      await backend.push(
        data: await memoryDataService(db, storage, settings).gatherAll(),
        dek: dek,
        salt: salt,
        verificationHash: Uint8List(32),
        wrappedDekPassword: await SyncService.wrapDek(dek, SyncService.generateDek()),
        wrappedDekRecovery: await SyncService.wrapDek(dek, kek),
        recoverySalt: recoverySalt,
        recoveryHash: await SyncService.computeRecoveryVerificationHash(kek),
        createOnly: true,
        argon2Params: params,
      );
    });

    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 8, 12))),
        syncIsBringYourOwnProvider.overrideWithValue(true),
        syncBackendProvider.overrideWithValue(backend),
        autoSyncServiceProvider.overrideWith((ref) => AutoSyncService(
              syncDataService: ref.watch(syncDataServiceProvider),
              settingsService: ref.watch(settingsServiceProvider),
              secureStorage: ref.watch(secureStorageProvider),
              resolveBackend: () => backend,
            )),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    await settle(tester);
    return backend;
  }

  /// From the Account page to the question for the recovery key, answered
  /// with [key]. [beforeTheKeyIsTried] runs once the key is typed.
  Future<void> restoreWith(WidgetTester tester, String key, {void Function()? beforeTheKeyIsTried}) async {
    await tester.tap(find.text(l10n.accountSyncSetUp));
    await settleUntil(tester, () => find.text(l10n.profileForgotUseRecovery).evaluate().isNotEmpty);
    await tester.tap(find.text(l10n.profileForgotUseRecovery));
    await settleUntil(tester, () => find.text(l10n.profileRestoreWithRecoveryTitle).evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField).last, key);
    beforeTheKeyIsTried?.call();
    await tester.tap(find.text(l10n.profileContinue).last);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  testWidgets('a key the store refuses: "That recovery key didn\'t work"', (tester) async {
    await pumpAccount(tester);
    await restoreWith(tester, 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ');
    await settleUntil(tester, () => shows(tester, l10n.profileRecoveryKeyDidntWork));
    expect(shows(tester, l10n.profileRecoveryKeyDidntWork), isTrue);
    await finish(tester);
  });

  testWidgets('the store cannot be reached while the right key is tried: that is what is said, not that the key is wrong',
      (tester) async {
    final store = await pumpAccount(tester);
    // (The store in this test is one of the person's own.)
    final network = describeNetworkError(refused, subject: gl10n.errSubjectSyncServer).message;
    await restoreWith(tester, recoveryKey, beforeTheKeyIsTried: () => store.down = refused);
    await settleUntil(tester, () => shows(tester, network) || shows(tester, l10n.profileRecoveryKeyDidntWork));
    expect(shows(tester, l10n.profileRecoveryKeyDidntWork), isFalse,
        reason: 'the key was never judged: the store could not be asked');
    expect(shows(tester, network), isTrue);
    await finish(tester);
  });
}

/// A store the test can take away: while [down] is set, whatever is read
/// from it fails with that.
class _Store extends MemoryStoreBackend {
  _Store(super.store);

  Object? down;

  @override
  Future<RawObject?> readObject() {
    final failure = down;
    if (failure != null) return Future.error(failure);
    return super.readObject();
  }
}
