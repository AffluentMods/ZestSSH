// Real Argon2id key derivation: the account's (the weakest profile deriveKey
// accepts) and, where sync is set up here, the default one, which can take
// half a minute a key on a busy machine.
@Timeout(Duration(minutes: 8))
library;

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
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
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

import '../helpers/memory_store_backend.dart';
import '../helpers/recovery_proof_spy.dart';

/// The recovery proof (lib/services/account/recovery_proof.dart) is what lets
/// a lock-out recovery keep the synced data, and it can only be made where
/// the sync password was just proved. Every way this device comes to hold a
/// proved key asks for it to be registered: the setup flow's set up, join
/// and recovery-key restore (none did; a check of 3.3
/// found it registered only from the Account page), and the Account page's
/// join at the end of a sign-in.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const password = 'the sync password';
  const storage = FlutterSecureStorage();

  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;
  late String recoveryKey;
  late Uint8List recoverySalt;
  late SecretKey recoveryKek;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey(password, salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
    recoveryKey = RecoveryKeyService.generateRecoveryKey();
    recoverySalt = RecoveryKeyService.generateRecoverySalt();
    recoveryKek = await SyncService.deriveKey(RecoveryKeyService.normalize(recoveryKey), recoverySalt, params: fast);
  });

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Settles until [done], for steps that derive a key (real time).
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    final clock = Stopwatch()..start();
    while (!done() && clock.elapsed < const Duration(minutes: 4)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<List<int>> bytesOf(WidgetTester tester, SecretKey key) async => (await tester.runAsync(key.extractBytes))!;

  /// The account's synced data on a store of the person's own, pushed by
  /// another device ([withData]), with a recovery key where [withRecovery].
  Future<MemoryStoreBackend> store(WidgetTester tester, SharedPreferences prefs,
      {bool withData = true, bool withRecovery = false}) async {
    final backend = MemoryStoreBackend(MemoryStore());
    if (!withData) return backend;
    await tester.runAsync(() async {
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      await other.connectionsDao.insertConnection(ConnectionsCompanion(
        id: const Value('web'),
        label: const Value('web-1'),
        host: const Value('web.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        createdAt: Value(DateTime.utc(2026, 11, 1)),
        updatedAt: Value(DateTime.utc(2026, 11, 1)),
      ));
      await backend.push(
        data: await memoryDataService(other, storage, SettingsService(prefs)).gatherAll(),
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: await SyncService.wrapDek(dek, mek),
        wrappedDekRecovery: withRecovery ? await SyncService.wrapDek(dek, recoveryKek) : null,
        recoverySalt: withRecovery ? recoverySalt : null,
        recoveryHash: withRecovery ? await SyncService.computeRecoveryVerificationHash(recoveryKek) : null,
        createOnly: true,
        argon2Params: fast,
      );
      await other.close();
    });
    return backend;
  }

  /// Stops the background sync a finished setup starts, and ends the test.
  Future<void> finish(WidgetTester tester) async {
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    container.read(autoSyncServiceProvider).stopAutoSync();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  group('the Account page', () {
    testWidgets('the end of a sign-in: the sync password typed to join registers its proof', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final backend = await store(tester, prefs);
      final proof = RecoveryProofSpy();
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 5, 12))),
        syncIsBringYourOwnProvider.overrideWithValue(true),
        syncBackendProvider.overrideWithValue(backend),
        recoveryProofServiceProvider.overrideWithValue(proof),
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
      await settle(tester);

      final request = container.read(accountTurnSyncOnRequestProvider.notifier);
      request.state = false;
      request.state = true;
      await settleUntil(tester, () => find.text(l10n.syncTurnOnTitle).evaluate().isNotEmpty);
      await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), password);
      await tester.pump();
      await tester.tap(find.text(l10n.syncTurnOnAction));
      await settleUntil(tester, () => proof.asked.isNotEmpty);

      expect(proof.asked, hasLength(1));
      expect(await bytesOf(tester, proof.asked.single), await bytesOf(tester, mek));
      await settle(tester);
      await finish(tester);
    });

    // (Proved on the old setup flow until 3.4.2; nothing opened that flow, and
    // it is gone: proved here, on the account page.)
    testWidgets('a wrong sync password registers nothing', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final backend = await store(tester, prefs);
      final proof = RecoveryProofSpy();
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 5, 12))),
        syncIsBringYourOwnProvider.overrideWithValue(true),
        syncBackendProvider.overrideWithValue(backend),
        recoveryProofServiceProvider.overrideWithValue(proof),
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
      await settle(tester);

      final request = container.read(accountTurnSyncOnRequestProvider.notifier);
      request.state = false;
      request.state = true;
      await settleUntil(tester, () => find.text(l10n.syncTurnOnTitle).evaluate().isNotEmpty);
      await tester.enterText(
          find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), 'not the sync password');
      await tester.pump();
      await tester.tap(find.text(l10n.syncTurnOnAction));
      // The key derivation runs for real: given its time, then looked at.
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(proof.asked, isEmpty);
      await settle(tester);
      await finish(tester);
    });
  });
}
