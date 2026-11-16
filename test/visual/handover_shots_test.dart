import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' as session;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_failed_dialog.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/orchards/fake_crate_server.dart';
import 'shots_util.dart';
import '../features/orchards/vaults_window_helper.dart';

/// Pictures of a certificate handed over (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/handover_shots_test.dart
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
  final storages = <_MemoryStorage>[];
  late OrchardService alex;
  late OrchardService kit;
  late String orchardId;
  late String production;

  OrchardService serviceFor(String uid, AccountKeys keys) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
  }

  Future<void> build(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'uid-alex');
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
      final vault = await alex.createCrate(orchardId, 'Owner keys', ownersOnly: true);
      await alex.setAuthorityKey(orchardId, production,
          keyCrate: vault,
          ttlMinutes: 480,
          principals: {
            member.id: ['deploy'],
            FixedRoles.owner: ['root'],
          },
          keyLabel: 'Production certificate authority');
      await alex.refresh();
      kit = serviceFor('uid-kit', kitKeys);
      await kit.refresh();
    });
    addTearDown(() async {
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

    // The member: the Crate's line, the request, and a wrong text pasted.
    var key = await crates(tester, kit, themeId, size);
    await openVaultTab(tester, production, VaultTab.certificates);
    await saveShot(tester, key, 'handover_${tag}_1_member_crates');
    await tapKey(tester, 'crate-certs-hand-$production');
    await saveShot(tester, key, 'handover_${tag}_2_member_request');
    final ask = tester.widget<HandedCode>(k('cert-hand-code')).text;
    await tester.enterText(k('cert-hand-answer'), ask);
    // A frame, so the button the text enables is enabled before it is tapped
    // (it was tapped while still off, and what follows was never shown).
    await tester.pump();
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    await tester.ensureVisible(k('cert-hand-problem'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'handover_${tag}_3_member_wrong_text');

    // The owner: the Crate's line, the request to enter, read, and signed.
    key = await crates(tester, alex, themeId, size);
    await openVaultTab(tester, production, VaultTab.certificates);
    await saveShot(tester, key, 'handover_${tag}_4_owner_crates');
    await tapKey(tester, 'crate-certs-sign-$production');
    await tester.enterText(k('cert-sign-request'), 'hello');
    await tester.pump();
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    await saveShot(tester, key, 'handover_${tag}_5_owner_not_a_request');
    await tester.enterText(k('cert-sign-request'), ask);
    await tester.pump();
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    await saveShot(tester, key, 'handover_${tag}_6_owner_review');
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    await saveShot(tester, key, 'handover_${tag}_7_owner_signed');
    final give = tester.widget<HandedCode>(k('cert-sign-code')).text;

    // The member again: done.
    key = await crates(tester, kit, themeId, size);
    await openVaultTab(tester, production, VaultTab.certificates);
    await tapKey(tester, 'crate-certs-hand-$production');
    await tester.enterText(k('cert-hand-answer'), give);
    await tester.pump();
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    await saveShot(tester, key, 'handover_${tag}_8_member_done');

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

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('the failed connection that offers it, on a computer ($tag)', (tester) async {
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
          errorMessage: saidByApp('${l10n.teamCertNotAsked} (ZS-1502)'),
          connectionLabel: 'web-01',
          username: 'deploy',
          connectionLog: const ['identity: ERROR getting a team certificate'],
          connectionId: 'h-web-01',
        );
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: ProviderScope(
            overrides: [
              recordingModeProvider.overrideWith((ref) => false),
              session.certificateFromOwnerOfferProvider
                  .overrideWith((ref) => const {'h-web-01': (orchardId: 'o1', crateId: 'c1')}),
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
        await saveShot(tester, key, 'handover_${tag}_9_failed_connection');
        await tester.pumpWidget(const SizedBox());
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
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
