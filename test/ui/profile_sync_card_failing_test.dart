import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

import '../helpers/memory_store_backend.dart';

/// The Account page's sync row while sync is failing (3.0):
/// it says what stopped it and, where the app is trying again by itself,
/// that it is, the same as the status bar and the Tree's row do.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> pumpAccount(WidgetTester tester, SyncHealthState health) async {
    FlutterSecureStorage.setMockInitialValues({
      'sync_setup_complete': 'true',
      'sync_dek': base64Encode(List<int>.filled(32, 7)),
      'sync_verification_hash': base64Encode(List<int>.filled(32, 9)),
      'sync_argon2_params': jsonEncode(const {'memory': 65536, 'iterations': 3, 'parallelism': 4}),
      'sync_salt': base64Encode(List<int>.filled(16, 3)),
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final backend = MemoryStoreBackend(MemoryStore());
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
        syncHealthProvider.overrideWithValue(health),
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
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  testWidgets('failing, and the app tries again by itself: what stopped it, and that it keeps trying', (tester) async {
    await pumpAccount(
        tester,
        const SyncHealthState(SyncHealth.failing,
            problem: 'The sync server refused the connection.', retrying: true));
    expect(find.text('The sync server refused the connection. ZestSSH keeps trying by itself.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('failing until somebody acts: what stopped it, and no more', (tester) async {
    await pumpAccount(tester, const SyncHealthState(SyncHealth.failing, problem: 'The keys do not match.'));
    expect(find.text('The keys do not match.'), findsOneWidget);
    expect(find.textContaining('keeps trying'), findsNothing);
    await finish(tester);
  });
}
