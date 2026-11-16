import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_words.dart' show offlineSpanWords;
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show offlinePassOfferProvider;
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart';
import 'package:zestssh/utils/error_translator.dart' show saidByApp;
import 'package:zestssh/utils/redactor.dart';

import '../features/orchards/fake_crate_server.dart';
import 'shots_util.dart';
import '../features/orchards/vaults_window_helper.dart';

/// Pictures of an offline pass handed over (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/pass_shots_test.dart
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

/// One device's secure storage.
class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale(_locale));

  late FakeCrateServer server;
  final storages = <_MemoryStorage>[];
  late OrchardService alex;
  late OrchardService kit;
  late String orchardId;
  late String production;

  /// Every device's clock, and when each last reached ZestSSH Cloud.
  late int now;
  final last = <String, int>{};

  OrchardService serviceFor(String uid, AccountKeys keys) {
    final storage = _MemoryStorage();
    storages.add(storage);
    last[uid] = now;
    return OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(
        OrchardDatabaseKeys(const FlutterSecureStorage()),
        storage: storage,
        contact: DeviceContact(read: () => OrchardContact(lastContact: last[uid], latest: now), now: () => now),
      ),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: DeviceIdentityStore(_Keychain()),
    );
  }

  /// Platform team: Production closes on a device after a day away. alex owns
  /// it; kit, a Member, has been at a site with no internet for a day and
  /// an hour.
  Future<void> build(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    OrchardService.debugNow = () => DateTime.fromMillisecondsSinceEpoch(now * 1000);
    server = FakeCrateServer(accountUid: 'uid-alex')..clock = () => DateTime.fromMillisecondsSinceEpoch(now * 1000);
    await tester.runAsync(() async {
      final alexKeys = await AccountKeys.generate();
      final kitKeys = await AccountKeys.generate();
      await server.publish('uid-alex', alexKeys, email: 'alex@example.com');
      await server.publish('uid-kit', kitKeys, email: 'kit@example.com');
      alex = serviceFor('uid-alex', alexKeys);
      orchardId = await alex.createOrchard('Platform team', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single;
      production = member.crates.keys.single;
      await alex.invite(orchardId, email: 'kit@example.com', role: member.id);
      server.acceptAs(orchardId, (await alex.invites(orchardId)).single.id, 'uid-kit');
      await alex.confirmInvite(orchardId, (await alex.invites(orchardId)).single);
      await alex.setCrateOfflineLimit(orchardId, production, 24);
      await alex.refresh();
      kit = serviceFor('uid-kit', kitKeys);
      await kit.refresh();
      await OrchardSyncCoordinator(service: kit, server: kit.server, databases: kit.databases).syncAll();
    });
    now += 25 * 3600;
    last['uid-alex'] = now;
    addTearDown(() async {
      OrchardService.debugNow = DateTime.now;
      for (final s in storages) {
        for (final db in s.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
      storages.clear();
    });
  }

  /// The Crates screen of [service]'s device at [size] with [themeId],
  /// opened. Returns the key the pictures are taken from.
  Future<GlobalKey> crates(WidgetTester tester, OrchardService service, String themeId, Size size) async {
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
          orchardServiceProvider.overrideWithValue(service),
          orchardSummariesProvider.overrideWith((ref) async {
            ref.watch(orchardListVersionProvider);
            return [await readOrchardSummary(await service.databases.open(orchardId), orchardId)];
          }),
          cloudReachStateProvider.overrideWith((ref) => Stream.value(const CloudReachState(CloudReach.deviceOffline))),
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

  Finder k(String key) => find.byKey(ValueKey(key));

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(k(key));
    await tester.pumpAndSettle();
    await tester.tap(k(key));
    await settle(tester);
  }

  Future<void> everyPicture(WidgetTester tester, String themeId, Size size, String tag) async {
    await build(tester);
    server.down = true;

    // The member: the closed Crate's row, the request, and a wrong text.
    var key = await crates(tester, kit, themeId, size);
    await openVaultTab(tester, production, VaultTab.offline);
    await tester.ensureVisible(k('crate-offline-pass-$production'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'pass_${tag}_1_member_crates');
    await tapKey(tester, 'crate-offline-pass-$production');
    await saveShot(tester, key, 'pass_${tag}_2_member_request');
    final ask = tester.widget<HandedCode>(k('pass-hand-code')).text;
    await tester.enterText(k('pass-hand-answer'), ask);
    // A frame, so the button the text enables is enabled before it is tapped
    // (it was tapped while still off, and what follows was never shown).
    await tester.pump();
    await tester.ensureVisible(find.text(l10n.certHandUse));
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    await tester.ensureVisible(k('pass-hand-problem'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'pass_${tag}_3_member_wrong_text');

    // The owner: the row, the request read, the lengths, and signed.
    key = await crates(tester, alex, themeId, size);
    await openVaultTab(tester, production, VaultTab.offline);
    await tester.ensureVisible(k('crate-offline-sign-$production'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'pass_${tag}_4_owner_crates');
    await tapKey(tester, 'crate-offline-sign-$production');
    await tester.enterText(k('cert-sign-request'), ask);
    await tester.pump();
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    await saveShot(tester, key, 'pass_${tag}_5_owner_review');
    await tester.tap(k('pass-sign-lasts'));
    await settle(tester);
    await saveShot(tester, key, 'pass_${tag}_6_owner_lengths');
    await tester.tap(find.text(offlineSpanWords(l10n, 72)).last);
    await settle(tester);
    await tester.ensureVisible(find.text(l10n.certSignConfirm));
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    await saveShot(tester, key, 'pass_${tag}_7_owner_signed');
    final give = tester.widget<HandedCode>(k('cert-sign-code')).text;

    // The member again: done, and the row with the Crate open.
    key = await crates(tester, kit, themeId, size);
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-pass-$production');
    await tester.enterText(k('pass-hand-answer'), give);
    await tester.pump();
    await tester.ensureVisible(find.text(l10n.certHandUse));
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    await saveShot(tester, key, 'pass_${tag}_8_member_done');
    key = await crates(tester, kit, themeId, size);
    await openVaultTab(tester, production, VaultTab.offline);
    await tester.ensureVisible(k('crate-offline-pass-$production'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'pass_${tag}_9_member_open_again');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await everyPicture(tester, themeId, const Size(1280, 900), tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await everyPicture(tester, 'graphite', const Size(390, 844), 'phone');
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);

  // (The computer's dialog for the same is one of the closed Crate's own
  // pictures: crate_closed_shots_test.dart.)
  testWidgets('a connection to a host of a closed Crate, refused, on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      AppColors.applyTheme(BuiltInThemes.getById('graphite').colorScheme);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            recordingModeProvider.overrideWith((ref) => false),
            offlinePassOfferProvider.overrideWith(
                (ref) => const {'h-web-01': (orchardId: 'orchard-platform', crateId: 'crate-production')}),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: BuiltInThemes.getById('graphite').toThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale(_locale),
            home: Scaffold(
              backgroundColor: AppColors.v3Background,
              body: ConnectionErrorView(
                errorMessage: saidByApp(l10n.crateClosedOfflineError('Production')),
                connectionLabel: 'web-01',
                connectionId: 'h-web-01',
                host: 'web-01.example.com',
                port: 22,
                username: 'deploy',
                connectionLog: const ['init: Preparing connection to web-01.example.com:22'],
                onRetry: () {},
                onEditConnection: () {},
                onGoBack: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await saveShot(tester, key, 'pass_phone_10_refused_connection');
      await tester.pumpWidget(const SizedBox());
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
