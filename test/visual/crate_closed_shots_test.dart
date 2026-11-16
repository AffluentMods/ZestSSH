import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/widgets/notification_toast_overlay.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/offline_warnings.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_trust.dart' show showRecordEntryDetails;
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show VaultCallout;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart' show orchardDatabasesProvider;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' as session;
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_failed_dialog.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/orchards/fake_crate_server.dart';
import 'shots_util.dart';
import '../features/orchards/vaults_window_helper.dart';

/// Pictures of a Crate that its own offline limit has closed on a device
/// (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/crate_closed_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up. Another
/// language with --dart-define=ZEST_SHOT_LOCALE=de.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  late FakeCrateServer server;
  late _MemoryStorage storage;
  late OrchardService alex;
  late String orchardId;

  /// Platform team on alex's device: Production closes after a day away, and
  /// the device has been away for a day and an hour (or for [awayHours]);
  /// Shared has no limit.
  Future<void> build(WidgetTester tester, {int awayHours = 25}) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'uid-alex');
    storage = _MemoryStorage();
    await tester.runAsync(() async {
      final keys = await AccountKeys.generate();
      await server.publish('uid-alex', keys, email: 'alex@example.com');
      alex = OrchardService(
        server: server.as('uid-alex'),
        databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
        author: () async => CrateAuthor(uid: 'uid-alex', keys: keys),
      );
      orchardId = await alex.createOrchard('Platform team', firstCrateName: 'Production', memberRoleName: 'Member');
      final production = server.recordOf(orchardId).crates.keys.single;
      await alex.createCrate(orchardId, 'Shared');
      await alex.setCrateOfflineLimit(orchardId, production, 24);
      await alex.refresh();
      const now = 1790000000;
      attachDeviceContact(
          await alex.databases.open(orchardId),
          DeviceContact(
              read: () => OrchardContact(lastContact: now - awayHours * 3600, latest: now), now: () => now));
    });
    addTearDown(() async {
      for (final db in storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
  }

  /// The Crates page at [size] with [themeId], opened, as the app knows the
  /// service to stand ([reach]).
  Future<GlobalKey> crates(WidgetTester tester, String themeId, Size size, CloudReach reach) async {
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: [
          orchardServiceProvider.overrideWithValue(alex),
          // A notifier of its own for each scope (the page reads it now, and a
          // scope disposes what it made: one shared was disposed twice), on the
          // same databases.
          orchardDatabasesProvider.overrideWith(
              (ref) => OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage)),
          orchardSummariesProvider.overrideWith((ref) async {
            ref.watch(orchardListVersionProvider);
            return [await readOrchardSummary(await alex.databases.open(orchardId), orchardId)];
          }),
          cloudReachStateProvider.overrideWith((ref) => Stream.value(CloudReachState(reach))),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: Scaffold(
            backgroundColor: AppColors.v3Background,
            body: Consumer(
              builder: (context, ref, _) => Align(
                alignment: Alignment.topLeft,
                child: TextButton(
                  onPressed: () => showOrchardCrates(context, ref, orchardId),
                  // The button watches the list so it is read before the tap; the count
                  // it holds is drawn by nothing (it showed as a stray number on every
                  // picture).
                  child: Opacity(opacity: 0, child: Text('${ref.watch(orchardSummariesProvider).valueOrNull?.length ?? ''}')),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.byType(TextButton).first);
    await settle(tester);
    return key;
  }

  /// The card of the Crate the picture is about (Production, after Shared),
  /// scrolled to its header.
  Future<void> showCallout(WidgetTester tester) async {
    final callout = find.byType(VaultCallout).first;
    await tester.ensureVisible(callout);
    await tester.pumpAndSettle();
    await tester.drag(callout, const Offset(0, 160));
    await tester.pumpAndSettle();
  }

  Future<void> pages(WidgetTester tester, String themeId, Size size, String tag) async {
    await build(tester);
    var key = await crates(tester, themeId, size, CloudReach.deviceOffline);
    await showCallout(tester);
    await saveShot(tester, key, 'crate_closed_${tag}_1_offline');
    key = await crates(tester, themeId, size, CloudReach.notResponding);
    await showCallout(tester);
    await saveShot(tester, key, 'crate_closed_${tag}_2_cloud_away');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  /// The Crates page while Production is about to close: the device has
  /// been away for twenty of its twenty-four hours.
  Future<void> closing(WidgetTester tester, String themeId, Size size, String tag) async {
    await build(tester, awayHours: 20);
    final key = await crates(tester, themeId, size, CloudReach.deviceOffline);
    await showCallout(tester);
    await saveShot(tester, key, 'crate_closing_${tag}_1_row');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  /// The notice as a computer shows it: one Crate with the device offline,
  /// then two Crates and all of the Orchard with the service not answering.
  Future<void> notices(WidgetTester tester, String themeId, String tag) async {
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = const Size(900, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    late WidgetRef app;
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: [
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: Scaffold(
            backgroundColor: AppColors.v3Background,
            body: NotificationToastOverlay(
              child: Consumer(builder: (context, ref, _) {
                app = ref;
                return const SizedBox.expand();
              }),
            ),
          ),
        ),
      ),
    ));
    final now = DateTime(2026, 10, 9, 15, 10);
    int secs(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    final center = app.read(notificationCenterProvider.notifier);
    center.show(offlineClosingNotice(
      orchardId: 'o1',
      orchard: l10n.orchardNamed('Platform team'),
      all: null,
      crates: [(name: 'Production', end: secs(DateTime(2026, 10, 9, 19, 30)))],
      lastContact: secs(DateTime(2026, 10, 8, 19, 30)),
      reach: CloudReach.deviceOffline,
      l10n: l10n,
      onAskPass: () {},
      now: now,
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await saveShot(tester, key, 'offline_closing_${tag}_1_notice');
    center.show(offlineClosingNotice(
      orchardId: 'o1',
      orchard: l10n.orchardNamed('Platform team'),
      all: secs(DateTime(2026, 10, 11, 19, 30)),
      crates: [
        (name: 'Production', end: secs(DateTime(2026, 10, 9, 19, 30))),
        (name: 'Customer hosts', end: secs(DateTime(2026, 10, 10, 3, 30))),
      ],
      lastContact: secs(DateTime(2026, 10, 8, 19, 30)),
      reach: CloudReach.notResponding,
      l10n: l10n,
      onAskPass: () {},
      now: now,
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await saveShot(tester, key, 'offline_closing_${tag}_2_notice_more');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  /// The owners' choice of a limit, its list, and the question before a
  /// shorter one is set.
  Future<void> choosing(WidgetTester tester, String themeId, Size size, String tag) async {
    await build(tester, awayHours: 1);
    final key = await crates(tester, themeId, size, CloudReach.answering);
    final production = server.recordOf(orchardId).crates.values.firstWhere((c) => c.offlineHours > 0).id;
    await openVaultTab(tester, production, VaultTab.offline);
    await tester.ensureVisible(find.byKey(ValueKey('crate-offline-$production')));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'crate_limit_${tag}_1_row');
    await tester.tap(find.byKey(ValueKey('crate-offline-$production')));
    await settle(tester);
    await saveShot(tester, key, 'crate_limit_${tag}_2_list');
    await tester.tap(find.text(l10n.orchardRulesOfflineHours(8)).last);
    await settle(tester);
    await saveShot(tester, key, 'crate_limit_${tag}_3_question');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  /// Who connects to a watched Crate's hosts while ZestSSH Cloud cannot be
  /// reached: what its row says, the question before everyone is let in,
  /// the row after, and what an entry of the record shows of a session
  /// that ran with nobody watching.
  Future<void> watchedAway(WidgetTester tester, String themeId, Size size, String tag) async {
    await build(tester, awayHours: 1);
    final production = server.recordOf(orchardId).crates.values.firstWhere((c) => c.offlineHours > 0).id;
    // (Everything that asks the service outside the test's own clock comes
    // before the screen first uses it: a change queued from the screen is
    // one nothing queued from here would ever get past.)
    late RecordEntry entry;
    await tester.runAsync(() async {
      await alex.setCrateWatched(orchardId, production, true);
      alex.unwatchedRan(await alex.keepUnwatchedReport(orchardId,
          crateId: production,
          hostLabel: 'db-primary',
          reason: 'Restoring the database from last night',
          reach: 'notResponding'));
      await alex.unwatchedRound(orchardId);
      await alex.refresh();
      entry = (await LocalRecord.load(await alex.databases.open(orchardId), orchardId)).entries.last;
    });
    final key = await crates(tester, themeId, size, CloudReach.answering);
    final row = find.byKey(ValueKey('crate-unwatched-away-$production'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'crate_away_${tag}_1_owners');
    await tester.tap(find.byKey(ValueKey('crate-unwatched-away-change-$production')));
    await settle(tester);
    await saveShot(tester, key, 'crate_away_${tag}_2_question');
    await tester.tap(find.text(l10n.crateUnwatchedAwayAllow).last);
    await settle(tester);
    await tester.pump(const Duration(seconds: 10));
    await settle(tester);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'crate_away_${tag}_3_everyone');

    // A session that ran so, as its entry of the record opens.
    final page = tester.element(find.byType(Scaffold).first);
    Navigator.of(page, rootNavigator: true).popUntil((route) => route.isFirst);
    await settle(tester);
    unawaited(showRecordEntryDetails(
      page,
      orchardId: orchardId,
      entry: entry,
      words: l10n.teamChangeSessionUnwatched('Production'),
      signer: 'alex@example.com',
      seen: 'Oct 9, 9:14 AM',
    ));
    await settle(tester);
    await saveShot(tester, key, 'crate_away_${tag}_4_entry');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('who connects while ZestSSH Cloud cannot be reached, on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await watchedAway(tester, themeId, const Size(1280, 900), tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('who connects while ZestSSH Cloud cannot be reached, on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await watchedAway(tester, 'graphite', const Size(390, 844), 'phone');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('a Crate about to close, on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await closing(tester, themeId, const Size(1280, 900), tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);

    testWidgets('the notice before a limit closes something ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await notices(tester, themeId, tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('a Crate about to close, on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await closing(tester, 'graphite', const Size(390, 844), 'phone');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('choosing a limit on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await choosing(tester, themeId, const Size(1280, 900), tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('choosing a limit on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await choosing(tester, 'graphite', const Size(390, 844), 'phone');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('the Crates page on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pages(tester, themeId, const Size(1280, 900), tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);

    testWidgets('a connection to one of its hosts, refused, on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        L10nGlobal.update(l10n);
        AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final error = session.ConnectionError(
          host: 'web-01.example.com',
          port: 22,
          errorMessage: saidByApp(l10n.crateClosedOfflineError('Production')),
          connectionLabel: 'web-01',
          username: 'deploy',
          connectionLog: const ['init: Preparing connection to web-01.example.com:22'],
          connectionId: 'h-web-01',
        );
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: ProviderScope(
            overrides: [
              recordingModeProvider.overrideWith((ref) => false),
              // What the session keeps of a host its Crate refused: an
              // owner can sign an offline pass for it.
              session.offlinePassOfferProvider.overrideWith(
                  (ref) => const {'h-web-01': (orchardId: 'orchard-platform', crateId: 'crate-production')}),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: BuiltInThemes.getById(themeId).toThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale(_locale),
              home: Scaffold(
                backgroundColor: AppColors.v3Background,
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showZestModal<void>(
                      context: context,
                      size: ZestModalSize.standard,
                      child: ConnectionFailedDialog(error: error, onRetry: () {}),
                    ),
                    child: const Text(''),
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.byType(TextButton).first);
        await tester.pumpAndSettle();
        await saveShot(tester, key, 'crate_closed_${tag}_3_failed_connection');
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('the Crates page on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pages(tester, 'graphite', const Size(390, 844), 'phone');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
