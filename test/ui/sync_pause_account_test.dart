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
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';

import '../helpers/memory_store_backend.dart';

/// The Account page's Sync card, with sync set up (3.0; a way to
/// pause sync without removing it, and to choose when it runs, by hand only
/// included): Pause, for an hour, a day
/// or until resumed, says until when and that Sync now still syncs, and
/// Resume ends it; the Sync Mode row says when sync runs by itself and
/// changes it, to every change, every so many minutes or hours, or only by
/// hand.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SettingsService settings;
  late _Counting sync;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpAccount(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'sync_setup_complete': 'true',
      'sync_dek': base64Encode(List<int>.filled(32, 7)),
      'sync_verification_hash': base64Encode(List<int>.filled(32, 9)),
      'sync_argon2_params': jsonEncode(const {'memory': 65536, 'iterations': 3, 'parallelism': 4}),
      'sync_salt': base64Encode(List<int>.filled(16, 3)),
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    settings = SettingsService(prefs);
    await settings.setLastSyncTime(DateTime.now());
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
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime.now())),
        syncIsBringYourOwnProvider.overrideWithValue(true),
        syncBackendProvider.overrideWithValue(backend),
        autoSyncServiceProvider.overrideWith((ref) {
          sync = _Counting(
            syncDataService: ref.watch(syncDataServiceProvider),
            settingsService: ref.watch(settingsServiceProvider),
            secureStorage: ref.watch(secureStorageProvider),
            resolveBackend: () => backend,
          );
          ref.onDispose(sync.dispose);
          return sync;
        }),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.tap(target);
    await settle(tester);
  }

  testWidgets('Pause for an hour: paused until then, and Sync now still there; Resume ends it', (tester) async {
    await pumpAccount(tester);
    expect(find.text(l10n.settingsInlineStatusOn), findsOneWidget);
    expect(find.text(l10n.accountSyncNow), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const ValueKey('sync-pause')));
    expect(find.text(l10n.syncPauseTitle), findsOneWidget);
    expect(find.text(l10n.syncPauseNote), findsOneWidget);
    final before = DateTime.now();
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-pause-hour')));
    final until = settings.syncPause!.until!;
    expect(until.difference(before).inMinutes, inInclusiveRange(59, 60));
    expect(find.text(l10n.accountSyncPausedPill), findsOneWidget);
    expect(find.text(l10n.settingsInlineStatusOn), findsNothing);
    expect(find.text(l10n.accountSyncPausedUntil(syncPausedUntilText(until, 'en'))), findsOneWidget);
    expect(find.text(l10n.accountSyncNow), findsOneWidget, reason: 'Sync now still syncs');

    await tapAndSettle(tester, find.byKey(const ValueKey('sync-resume')));
    expect(settings.syncPause, isNull);
    expect(find.text(l10n.accountSyncPausedPill), findsNothing);
    expect(find.text(l10n.settingsInlineStatusOn), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-pause')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Pause until resumed: says so; a day: until the same time tomorrow; the dialog closed: nothing',
      (tester) async {
    await pumpAccount(tester);
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-pause')));
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-pause-untilResumed')));
    expect(settings.syncPause, isNotNull);
    expect(settings.syncPause!.until, isNull);
    expect(find.text(l10n.accountSyncPausedIndefinitely), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-resume')));

    await tapAndSettle(tester, find.byKey(const ValueKey('sync-pause')));
    final before = DateTime.now();
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-pause-day')));
    expect(settings.syncPause!.until!.difference(before).inHours, inInclusiveRange(23, 24));
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-resume')));

    await tapAndSettle(tester, find.byKey(const ValueKey('sync-pause')));
    await tester.tapAt(const Offset(5, 5)); // away from the dialog
    await settle(tester);
    expect(settings.syncPause, isNull);
    await finish(tester);
  });

  testWidgets('Sync Mode: every 15 minutes at first; every 2 hours, by hand only, or on every change', (tester) async {
    await pumpAccount(tester);
    expect(find.text(l10n.settingsSyncMode), findsOneWidget);
    expect(find.text(l10n.settingsSyncIntervalMinutes(15)), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const ValueKey('sync-schedule')));
    // Every choice, with what Instant and Manual mean.
    for (final minutes in [5, 10, 15, 30]) {
      expect(find.text(l10n.settingsSyncIntervalMinutes(minutes)), findsWidgets);
    }
    expect(find.text(l10n.settingsSyncIntervalHour), findsOneWidget);
    for (final hours in [2, 6, 24]) {
      expect(find.text(l10n.settingsSyncIntervalHours(hours)), findsOneWidget);
    }
    expect(find.text(l10n.syncInstantDescPull(5)), findsOneWidget);
    expect(find.text(l10n.syncModeManualDesc), findsOneWidget);
    final starts = sync.starts;
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-schedule-auto120')));
    expect(settings.syncMode, 'auto');
    expect(settings.syncIntervalMinutes, 120);
    expect(sync.starts, starts + 1, reason: 'it runs by itself as now chosen, from now');
    expect(find.text(l10n.settingsSyncIntervalHours(2)), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const ValueKey('sync-schedule')));
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-schedule-manual')));
    expect(settings.syncMode, 'manual');
    expect(settings.syncIntervalMinutes, 120, reason: 'kept for when it runs by itself again');
    expect(find.text(l10n.settingsSyncModeManual), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const ValueKey('sync-schedule')));
    await tapAndSettle(tester, find.byKey(const ValueKey('sync-schedule-instant')));
    expect(settings.syncMode, 'instant');
    expect(find.text(l10n.settingsSyncModeInstant), findsOneWidget);
    await finish(tester);
  });

  test('when a pause ends: the time where it is today, the day and the time where it is not', () {
    final now = DateTime(2026, 10, 15, 9);
    expect(syncPausedUntilText(DateTime(2026, 10, 15, 14, 30), 'en', now: now), '2:30 PM');
    expect(syncPausedUntilText(DateTime(2026, 10, 16, 9), 'en', now: now), 'Oct 16 9:00 AM');
  });
}

/// The app's sync, counting how often it was started (each time it is to run
/// by itself as the settings say, from now).
class _Counting extends AutoSyncService {
  _Counting({
    required super.syncDataService,
    required super.settingsService,
    required super.secureStorage,
    required super.resolveBackend,
  });

  int starts = 0;

  @override
  void startAutoSync() {
    starts++;
    super.startAutoSync();
  }
}
