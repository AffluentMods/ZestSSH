// Real Argon2id key derivation (the weakest profile deriveKey accepts), which
// can take half a minute a key on a busy machine.
@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';

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
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync/sync_manifest.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/profile/recovery_key_screen.dart';

import '../helpers/memory_store_backend.dart';
import '../helpers/recovery_proof_spy.dart';

/// A store of the person's own that, once [refusing], answers every write
/// with a fault of its own.
class _Store extends MemoryStoreBackend {
  _Store(super.store);

  bool refusing = false;

  @override
  Future<String?> writeObject(Uint8List bytes, {String? ifMatchEtag, bool ifAbsent = false}) async {
    if (refusing) throw SyncFailure.storeAnswered(503, 'Memory PUT failed: HTTP 503');
    return super.writeObject(bytes, ifMatchEtag: ifMatchEtag, ifAbsent: ifAbsent);
  }
}

/// Account and security, Recovery key (3.0): the row says whether
/// the store holds a key, and "Replace" makes a new one through the real
/// screens: the master password (a wrong one is refused in the dialog), the
/// key shown once and saved, then the store holds the new key while the
/// setup steps are left alone.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  const params = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const password = 'correct horse battery staple';
  late Uint8List salt;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List verHash;
  // The password as another device changed it.
  const newPassword = 'a brand new password';
  late Uint8List newSalt;
  late SecretKey newMek;
  late Uint8List newVerHash;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey(password, salt, params: params);
    verHash = await SyncService.computeVerificationHash(mek);
    newSalt = SyncService.generateSalt();
    newMek = await SyncService.deriveKey(newPassword, newSalt, params: params);
    newVerHash = await SyncService.computeVerificationHash(newMek);
  });

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Whether [message] shows, on screen or as a desktop notification.
  bool shows(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Navigator).first));
    return container
        .read(notificationCenterProvider)
        .history
        .any((n) => n.title == message || n.body == message);
  }

  /// Settles until [done], for steps that derive a key (real time).
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    final clock = Stopwatch()..start();
    while (!done() && clock.elapsed < const Duration(minutes: 3)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// What the Account panel asked the recovery proof to be registered with.
  late RecoveryProofSpy proof;

  /// The Account panel with sync set up on a store of its own, as after
  /// setup: [keySeen] is what this device last saw about a recovery key.
  /// With [staleDevice], another device changed the password: the store
  /// holds the new password's material while this device still holds the
  /// old salt and verification value.
  Future<_Store> pumpAccount(WidgetTester tester,
      {bool? keySeen, bool withStore = true, bool staleDevice = false}) async {
    FlutterSecureStorage.setMockInitialValues({
      'sync_setup_complete': 'true',
      if (withStore) ...{
        'sync_dek': base64Encode(await tester.runAsync(dek.extractBytes) as List<int>),
        'sync_verification_hash': base64Encode(verHash),
        'sync_argon2_params': jsonEncode(params),
        'sync_salt': base64Encode(salt),
      },
    });
    SharedPreferences.setMockInitialValues({
      'sync_recovery_key_set': ?keySeen,
    });
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = SettingsService(prefs);
    final backend = _Store(MemoryStore());
    if (withStore) {
      await tester.runAsync(() async {
        const storage = FlutterSecureStorage();
        final v = await backend.push(
          data: await memoryDataService(db, storage, settings).gatherAll(),
          dek: dek,
          salt: staleDevice ? newSalt : salt,
          verificationHash: staleDevice ? newVerHash : verHash,
          wrappedDekPassword: await SyncService.wrapDek(dek, staleDevice ? newMek : mek),
          createOnly: true,
          argon2Params: params,
        );
        await settings.setSyncServerVersion(v.version);
      });
    }

    proof = RecoveryProofSpy();
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
      GoRoute(
        path: Routes.recoveryKey,
        builder: (_, state) => RecoveryKeyScreen(
          mode: state.extra is RecoveryKeyMode ? state.extra as RecoveryKeyMode : RecoveryKeyMode.setup,
        ),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 25, 12))),
        syncIsBringYourOwnProvider.overrideWithValue(true),
        syncBackendProvider.overrideWithValue(backend),
        recoveryProofServiceProvider.overrideWithValue(proof),
        // The real service, without the account-key check that follows a sync.
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

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  testWidgets('a key the store holds: Saved, and Replace', (tester) async {
    await pumpAccount(tester, keySeen: true);
    expect(find.text(l10n.accountRecoveryKeyDesc), findsOneWidget);
    expect(find.text(l10n.zestProfileRecoverySaved), findsOneWidget);
    expect(find.text(l10n.accountRecoveryKeyReplace), findsOneWidget);
    await finish(tester);
  });

  testWidgets('no key on the store: it says so, and offers to make one', (tester) async {
    await pumpAccount(tester, keySeen: false);
    expect(find.text(l10n.accountRecoveryKeyNone), findsOneWidget);
    expect(find.text(l10n.accountRecoveryKeyMake), findsOneWidget);
    expect(find.text(l10n.zestProfileRecoverySaved), findsNothing);
    await finish(tester);
  });

  testWidgets('Replace: a wrong password is refused, the right one makes a new key', (tester) async {
    final backend = await pumpAccount(tester, keySeen: false);
    // The store answers for itself: no key yet.
    expect(find.text(l10n.accountRecoveryKeyMake), findsOneWidget);

    final make = find.text(l10n.accountRecoveryKeyMake);
    await tester.ensureVisible(make);
    await tester.tap(make);
    await settle(tester);
    expect(find.text(l10n.recoveryReplaceTitle), findsOneWidget);

    // A wrong password: the dialog stays and says so.
    await tester.enterText(find.byType(TextField).last, 'not the password');
    await tester.tap(find.text(l10n.profileContinue));
    await settleUntil(tester, () => shows(tester, l10n.recoveryReplaceWrongPassword));
    expect(find.text(l10n.recoveryReplaceWrongPassword), findsOneWidget);
    expect(find.text(l10n.recoveryReplaceTitle), findsOneWidget);
    expect(proof.asked, isEmpty, reason: 'nothing proved, nothing registered');

    // The right one: on to the key.
    await tester.enterText(find.byType(TextField).last, password);
    await tester.tap(find.text(l10n.profileContinue));
    await settleUntil(tester, () => shows(tester, l10n.recoveryReplaceScreenNote));
    expect(find.text(l10n.recoveryReplaceScreenNote), findsOneWidget);
    // The password was proved: the account's recovery proof is registered
    // with its key (in 3.3 it was not).
    expect(proof.asked, hasLength(1));
    expect(await tester.runAsync(proof.asked.single.extractBytes), await tester.runAsync(mek.extractBytes));

    // The key shown is the one that will work: read it, save it, confirm.
    final shown = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((t) => t.data ?? '')
        .firstWhere((t) => t.startsWith('ZEST-'));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.tap(find.text(l10n.recoveryKeyCopy));
    await settle(tester);
    await tester.tap(find.text(l10n.recoveryKeyConfirm));
    await settleUntil(tester, () => shows(tester, l10n.recoveryMadeDone));
    expect(shows(tester, l10n.recoveryMadeDone), isTrue);

    // The store holds it, and it opens the vault the way a restore does.
    final restored = await tester.runAsync(() => backend.pullWithRecoveryKey(shown));
    expect(await tester.runAsync(restored!.dek.extractBytes), await tester.runAsync(dek.extractBytes));
    final stored = SyncManifest.fromBytes(backend.store.bytes!);
    expect(stored.salt, salt, reason: 'the password material is untouched');
    expect(RecoveryKeyService.normalize(shown).length, 24);

    // The setup steps were left alone.
    final setup = await tester.runAsync(() => SyncSetupStateService(const FlutterSecureStorage()).readRecoverySalt());
    expect(setup, isNull);

    // The row now says the key is saved.
    await settle(tester);
    expect(find.text(l10n.zestProfileRecoverySaved), findsOneWidget);
    expect(find.text(l10n.accountRecoveryKeyReplace), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a store that does not take the new key: the question says what it answered, as sync says it, '
      'and nothing is said to be saved', (tester) async {
    final backend = await pumpAccount(tester, keySeen: false);
    final make = find.text(l10n.accountRecoveryKeyMake);
    await tester.ensureVisible(make);
    await tester.tap(make);
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, password);
    await tester.tap(find.text(l10n.profileContinue));
    await settleUntil(tester, () => shows(tester, l10n.recoveryReplaceScreenNote));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.tap(find.text(l10n.recoveryKeyCopy));
    await settle(tester);

    backend.refusing = true;
    await tester.tap(find.text(l10n.recoveryKeyConfirm));
    // The store's fault with the code that says whose storage it is, as the
    // sync card says it.
    final said = l10n.recoveryMakeFailedBody('${l10n.syncStoreFault(503)} (ZS-1201)');
    await settleUntil(tester, () => find.text(said).evaluate().isNotEmpty);
    expect(find.text(l10n.recoveryReplaceFailedTitle), findsOneWidget);
    expect(find.text(said), findsOneWidget);

    // Not tried again: it says so, and nothing is said to be saved.
    await tester.tap(find.text(l10n.cancel));
    await settle(tester);
    expect(shows(tester, l10n.recoveryMakeAbandoned), isTrue);
    expect(shows(tester, l10n.recoveryMadeDone), isFalse);
    await finish(tester);
  });

  testWidgets("a device that missed a password change takes the store's salt once proved", (tester) async {
    final backend = await pumpAccount(tester, keySeen: false, staleDevice: true);
    final make = find.text(l10n.accountRecoveryKeyMake);
    await tester.ensureVisible(make);
    await tester.tap(make);
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, newPassword);
    await tester.tap(find.text(l10n.profileContinue));
    await settleUntil(tester, () => shows(tester, l10n.recoveryReplaceScreenNote));
    expect(find.text(l10n.recoveryReplaceScreenNote), findsOneWidget);

    const storage = FlutterSecureStorage();
    expect(await tester.runAsync(() => storage.read(key: 'sync_salt')), base64Encode(newSalt));
    expect(await tester.runAsync(() => storage.read(key: 'sync_verification_hash')), base64Encode(newVerHash));

    // Leaving the key screen without saving changes nothing on the store.
    final before = backend.store.bytes;
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await settle(tester);
    expect(identical(backend.store.bytes, before), isTrue);
    expect(SyncManifest.fromBytes(backend.store.bytes!).wrappedDekRecovery, isNull);
    expect(find.text(l10n.accountRecoveryKeyMake), findsOneWidget);
    await finish(tester);
  });

  testWidgets('without this device holding the sync key: nothing to replace here', (tester) async {
    await pumpAccount(tester, keySeen: true, withStore: false);
    final replace = find.text(l10n.accountRecoveryKeyReplace);
    await tester.ensureVisible(replace);
    await tester.tap(replace);
    await settle(tester);
    expect(find.text(l10n.recoveryReplaceTitle), findsNothing);
    expect(shows(tester, l10n.syncNowNotSetUp), isTrue);
    await finish(tester);
  });
}
