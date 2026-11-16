import 'package:drift/drift.dart' hide isNull, isNotNull;
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
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/orchards/fake_crate_server.dart';
import 'shots_util.dart';

/// Pictures of access on request (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/access_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up. Another
/// language with --dart-define=ZEST_SHOT_LOCALE=de, and the smallest phone
/// the screens are checked on with --dart-define=ZEST_SHOT_SMALL=true.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');
const _small = bool.fromEnvironment('ZEST_SHOT_SMALL');

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

class _Device {
  _Device(this.shared, this.uid, this.keys, {_MemoryStorage? storage}) : storage = storage ?? _MemoryStorage() {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: this.storage);
    service = OrchardService(
      server: shared.as(uid),
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;
  final _MemoryStorage storage;
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;

  _Device again() => _Device(shared, uid, keys, storage: storage);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeCrateServer server;
  late _Device owner;
  late _Device kit;
  late _Device noa;
  late String orchardId;
  late String staging;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 120));
      if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// An Orchard with Production and Staging; kit asks for a Crate they
  /// cannot name, noa holds Staging for three days and asks for more in
  /// Production.
  Future<void> setUpOrchard(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'uid-alex');
    await tester.runAsync(() async {
      final devices = <_Device>[];
      for (final (uid, email) in [
        ('uid-alex', 'alex@example.com'),
        ('uid-kit', 'kit@example.com'),
        ('uid-noa', 'noa@example.com'),
      ]) {
        final keys = await AccountKeys.generate();
        await server.publish(uid, keys, email: email);
        devices.add(_Device(server, uid, keys));
      }
      [owner, kit, noa] = devices;
      orchardId = await owner.service.createOrchard('Platform team', firstCrateName: 'Production', memberRoleName: 'Member');
      staging = await owner.service.createCrate(orchardId, 'Staging');
      final member = server.recordOf(orchardId).roles.values.single;
      for (final (person, email) in [(kit, 'kit@example.com'), (noa, 'noa@example.com')]) {
        await owner.service.invite(orchardId, email: email, role: member.id);
        final invite = (await owner.service.invites(orchardId)).single;
        server.acceptAs(orchardId, invite.id, person.uid);
        await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
        await person.service.refresh();
      }
      await kit.service.requestAccess(orchardId,
          level: CrateLevel.use,
          duration: const Duration(hours: 2),
          note: 'Staging, to check the release before it goes out');
      await owner.service.giveAccess(orchardId,
          uid: 'uid-noa', crateId: staging, level: CrateLevel.edit, duration: const Duration(days: 3));
      await noa.service.requestAccess(orchardId,
          crateId: member.crates.keys.single, level: CrateLevel.edit, duration: const Duration(hours: 8), note: 'On call this week');
      await owner.service.refresh();
    });
    addTearDown(() async {
      for (final d in [owner, kit, noa]) {
        for (final db in d.storage.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
    });
  }

  /// The Team page as [as] sees it, at [size] with [themeId]. Returns the
  /// key the pictures are taken from.
  Future<GlobalKey> show(WidgetTester tester, _Device as, String themeId, Size size, {bool phone = false}) async {
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final view = as.again();
    final summary = (await tester.runAsync(() async {
      await view.service.refresh();
      return readOrchardSummary(await view.databases.open(orchardId), orchardId);
    }))!;
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: [
          orchardServiceProvider.overrideWithValue(view.service),
          orchardDatabasesProvider.overrideWith((ref) => view.databases),
          activeOrchardProvider.overrideWithValue(AsyncData(summary)),
          orchardSummariesProvider.overrideWith((ref) async => [summary]),
          connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
          deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
          activeSidebarNavProvider.overrideWith((ref) => NavSection.team),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: Scaffold(
            backgroundColor: AppColors.v3Background,
            body: phone
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: TeamOverview(orchard: summary, onOpen: (_) {}),
                  )
                : const TeamView(),
          ),
        ),
      ),
    ));
    await settle(tester);
    return key;
  }

  Future<void> closeTop(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(Navigator).first), rootNavigator: true).pop();
    await settle(tester);
  }

  Future<void> everyPicture(WidgetTester tester, String themeId, Size size, String tag, {bool phone = false}) async {
    final l10n = lookupAppLocalizations(const Locale(_locale));
    await setUpOrchard(tester);

    // The owner: who asks, what runs, the way to give.
    var key = await show(tester, owner, themeId, size, phone: phone);
    await saveShot(tester, key, 'access_${tag}_1_owner_page');
    if (phone) {
      await tester.ensureVisible(find.byKey(const ValueKey('team-access')));
      await settle(tester);
      await saveShot(tester, key, 'access_${tag}_1b_owner_section');
    }
    final answer = find.text(l10n.accessAnswer).first;
    await tester.ensureVisible(answer);
    await settle(tester);
    await tester.tap(answer);
    await settle(tester);
    await saveShot(tester, key, 'access_${tag}_2_answer');
    await tester.tap(find.byKey(const ValueKey('access-give-crate')));
    await settle(tester);
    await tester.tap(find.text('Staging').last);
    await settle(tester);
    await saveShot(tester, key, 'access_${tag}_3_answer_picked');
    await closeTop(tester);
    final end = find.text(l10n.accessEndNow).first;
    await tester.ensureVisible(end);
    await settle(tester);
    await tester.tap(end);
    await settle(tester);
    await saveShot(tester, key, 'access_${tag}_4_end');
    await closeTop(tester);

    // Noa: a request waiting, Staging until a set time, the way to ask.
    key = await show(tester, noa, themeId, size, phone: phone);
    if (phone) {
      await tester.ensureVisible(find.byKey(const ValueKey('team-access')));
      await settle(tester);
    }
    await saveShot(tester, key, 'access_${tag}_5_member_page');
    final ask = find.descendant(of: find.byKey(const ValueKey('team-access-ask')), matching: find.text(l10n.accessAskAction));
    await tester.ensureVisible(ask);
    await settle(tester);
    await tester.tap(ask);
    await settle(tester);
    await saveShot(tester, key, 'access_${tag}_6_ask_more');
    await tester.tap(find.byKey(const ValueKey('access-ask-other')));
    await settle(tester);
    await tester.tap(find.text(l10n.accessAskSend));
    await settle(tester);
    await saveShot(tester, key, 'access_${tag}_7_ask_other_no_note');
    await closeTop(tester);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer's theme (its 34 pixel buttons and fields), not a phone's.
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
      await everyPicture(tester, 'graphite', _small ? const Size(360, 640) : const Size(390, 844), 'phone', phone: true);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);
}
