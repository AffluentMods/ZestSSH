// Real Argon2id key derivation (the weakest profile deriveKey accepts) for
// the account's sync password, once.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

import '../helpers/fake_device_approvals_server.dart';
import '../helpers/memory_store_backend.dart';

/// Account, Sync, "Set up sync" on a second device (3.0),
/// the join the app really runs: the unlock dialog offers "Approve from
/// another device" beside the password; a desktop that holds the key
/// answers, both screens show the same words, the desktop sends, and this
/// device joins with the account's data and the same key, without the sync
/// password. A host only this device had goes up with the first sync. Orchards
/// are built behind a switch, so this runs with
/// `--dart-define=ZEST_ORCHARDS=true`.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SecretKey dek;
  late Uint8List salt;
  late Uint8List verHash;
  late Uint8List wrapped;

  setUpAll(() async {
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    final mek = await SyncService.deriveKey('the sync password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
    wrapped = await SyncService.wrapDek(dek, mek);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  ConnectionsCompanion host(String id) => ConnectionsCompanion(
        id: Value(id),
        label: Value('$id-1'),
        host: Value('$id.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        createdAt: Value(DateTime.utc(2026, 9, 25)),
        updatedAt: Value(DateTime.utc(2026, 9, 25)),
      );

  /// This device signed in, sync not set up; the account's data (two hosts)
  /// already in the store; this device has a host of its own.
  Future<({MemoryStoreBackend backend, FakeApprovalServer server, AppDatabase db})> pumpAccount(
      WidgetTester tester, {bool byo = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final backend = MemoryStoreBackend(MemoryStore());
    final server = FakeApprovalServer();
    final phoneDb = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(phoneDb.close);

    await tester.runAsync(() async {
      // The account's synced data, pushed by the desktop.
      final desktop = AppDatabase.forTesting(NativeDatabase.memory());
      for (final id in ['web', 'db']) {
        await desktop.connectionsDao.insertConnection(host(id));
      }
      await backend.push(
        data: await memoryDataService(desktop, storage, SettingsService(prefs)).gatherAll(),
        dek: dek,
        salt: salt,
        verificationHash: verHash,
        wrappedDekPassword: wrapped,
        createOnly: true,
        argon2Params: fast,
      );
      await desktop.close();
      // This device already had a host of its own.
      await phoneDb.connectionsDao.insertConnection(host('laptop'));
    });

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
        databaseProvider.overrideWithValue(phoneDb),
        treeDatabaseProvider.overrideWithValue(phoneDb),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 25, 12))),
        syncBackendProvider.overrideWithValue(backend),
        syncIsBringYourOwnProvider.overrideWithValue(byo),
        deviceApprovalsApiProvider.overrideWithValue(server.device('phone')),
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
    return (backend: backend, server: server, db: phoneDb);
  }

  testWidgets('Set up sync, Approve from another device: joined with the key, no password typed', (tester) async {
    final (:backend, :server, db: phoneDb) = await pumpAccount(tester);
    expect(find.byKey(const ValueKey('devices-approve')), findsNothing, reason: 'no key here yet');

    final setUp = find.text(l10n.accountSyncSetUp);
    await tester.ensureVisible(setUp);
    await tester.tap(setUp);
    await settle(tester);
    expect(find.text(l10n.profileUnlockCloudSync), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('join-approve-from-device')));
    await settle(tester);
    expect(find.text(l10n.askWaiting), findsOneWidget);

    // The desktop answers; both screens show the same words.
    final id = server.rows.keys.single;
    final give = (await tester.runAsync(() => ApprovalGive.answer(server.device('desktop'), id)))!;
    await tester.pump(kDeviceApprovalPoll);
    await settle(tester);
    final onDesktop = (await tester.runAsync(() => give.awaitReveal(wait: (_) async {})))!;
    expect(tester.widget<ApprovalWords>(find.byKey(const ValueKey('ask-words'))).words, onDesktop);

    final dekBytes = Uint8List.fromList((await tester.runAsync(dek.extractBytes))!);
    await tester.runAsync(() => give.send(SyncHandover(
          dek: dekBytes,
          verificationHash: verHash,
          argon2Params: fast,
          salt: salt,
        )));
    await tester.pump(kDeviceApprovalPoll);
    await settle(tester);

    late List<String> hosts;
    await tester.runAsync(() async => hosts = (await phoneDb.connectionsDao.getAll()).map((c) => c.id).toList());
    expect(hosts.toSet(), {'web', 'db', 'laptop'});
    late Map<String, String> kept;
    await tester.runAsync(() async => kept = await storage.readAll());
    expect(kept['sync_dek'], base64Encode(dekBytes));
    expect(kept['sync_verification_hash'], base64Encode(verHash));
    expect(kept['sync_salt'], base64Encode(salt));
    expect(kept['sync_setup_complete'], 'true');
    // The first sync after joining takes this device's own host up.
    Future<Set<String>> inStore() async {
      final pulled = await backend.pull();
      final data = await SyncService.decrypt(pulled.encryptedData, dek);
      return {for (final c in data['connections'] as List) (c as Map)['id'] as String};
    }
    var stored = <String>{};
    for (var i = 0; i < 50 && !stored.contains('laptop'); i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        stored = await inStore();
      });
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(stored, {'web', 'db', 'laptop'});
    expect(server.rows, isEmpty, reason: 'collected once');
    expect(find.byKey(const ValueKey('devices-approve')), findsOneWidget,
        reason: 'with the key here, this device can approve the next one');

    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    container.read(autoSyncServiceProvider).stopAutoSync();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: !kOrchardsEnabled);

  testWidgets('with your own storage, the unlock dialog offers no approval', (tester) async {
    await pumpAccount(tester, byo: true);
    final setUp = find.text(l10n.accountSyncSetUp);
    await tester.ensureVisible(setUp);
    await tester.tap(setUp);
    await settle(tester);
    expect(find.text(l10n.profileUnlockCloudSync), findsOneWidget);
    expect(find.byKey(const ValueKey('join-approve-from-device')), findsNothing);
    expect(find.text(l10n.profileForgotUseRecovery), findsOneWidget, reason: 'the other ways in stay');
    await tester.tap(find.text(l10n.cancel));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: !kOrchardsEnabled);
}
