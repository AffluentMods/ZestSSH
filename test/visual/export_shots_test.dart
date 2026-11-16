import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_view.dart' show kTeamPageWidth;
import 'package:zestssh/features/orchards/widgets/team_export_view.dart';
import 'package:zestssh/features/orchards/widgets/team_tracking_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/orchards/fake_crate_server.dart';
import 'shots_util.dart';

/// Pictures of event export (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/export_shots_test.dart
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

class _Device {
  _Device(this.shared, this.uid, this.email, this.keys, this.signIn, {_MemoryStorage? storage, _Keychain? keychain})
      : storage = storage ?? _MemoryStorage(),
        keychain = keychain ?? _Keychain() {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: this.storage);
    service = OrchardService(
      server: shared.as(uid, device: signIn),
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: DeviceIdentityStore(this.keychain),
    );
  }

  final FakeCrateServer shared;
  final String uid;
  final String email;
  final AccountKeys keys;
  final String signIn;
  final _MemoryStorage storage;
  final _Keychain keychain;
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;

  _Device again() => _Device(shared, uid, email, keys, signIn, storage: storage, keychain: keychain);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeCrateServer server;
  late _Device alex;
  late _Device jordan;
  late _Device kit;
  late String orchardId;

  /// What the receiver answers: taken, unless a test says otherwise.
  ExportDelivery? refuse;

  Future<ExportDelivery> post(ExportDestination to, String body) async =>
      refuse ?? const ExportDelivery.delivered(200);

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

  /// Platform team: alex and jordan (owners) and kit (a member).
  Future<void> setUpOrchard(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'uid-alex');
    refuse = null;
    await tester.runAsync(() async {
      final alexKeys = await AccountKeys.generate();
      final jordanKeys = await AccountKeys.generate();
      final kitKeys = await AccountKeys.generate();
      await server.publish('uid-alex', alexKeys, email: 'alex@example.com');
      await server.publish('uid-jordan', jordanKeys, email: 'jordan@example.com');
      await server.publish('uid-kit', kitKeys, email: 'kit@example.com');
      alex = _Device(server, 'uid-alex', 'alex@example.com', alexKeys, 'laptop');
      jordan = _Device(server, 'uid-jordan', 'jordan@example.com', jordanKeys, 'jordan-laptop');
      kit = _Device(server, 'uid-kit', 'kit@example.com', kitKeys, 'kit-laptop');
      orchardId = await alex.service.createOrchard('Platform team', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single;
      for (final (person, role) in [(kit, member.id), (jordan, FixedRoles.owner)]) {
        await alex.service.invite(orchardId, email: person.email, role: role);
        final invite = (await alex.service.invites(orchardId)).single;
        server.acceptAs(orchardId, invite.id, person.uid);
        await alex.service.confirmInvite(orchardId, (await alex.service.invites(orchardId)).single);
      }
      for (final d in [alex, jordan, kit]) {
        await d.service.refresh();
      }
    });
    addTearDown(() async {
      for (final d in [alex, jordan, kit]) {
        for (final db in d.storage.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
    });
  }

  /// What the team records and where its events go, as [as] sees them, at
  /// [size] with [themeId]. Returns the key the pictures are taken from, and
  /// the scope's container.
  Future<(GlobalKey, ProviderContainer)> show(WidgetTester tester, _Device as, String themeId, Size size,
      {bool phone = false}) async {
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final view = as.again();
    Future<OrchardSummary> read() async => readOrchardSummary(await view.databases.open(orchardId), orchardId);
    final first = (await tester.runAsync(() async {
      await view.service.refresh();
      return read();
    }))!;
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: [
          orchardServiceProvider.overrideWithValue(view.service),
          orchardDatabasesProvider.overrideWith((ref) => view.databases),
          orchardEventExporterProvider.overrideWith((ref) => OrchardEventExporter(
                service: () => view.service,
                settings: ExportSettingsStore(view.keychain),
                post: post,
                onChanged: () => ref.read(exportVersionProvider.notifier).state++,
                now: () => DateTime(2026, 10, 2, 14, 5),
              )),
          orchardSummariesProvider.overrideWith((ref) async {
            ref.watch(orchardListVersionProvider);
            return [await read()];
          }),
          activeOrchardProvider.overrideWith(
              (ref) => ref.watch(orchardSummariesProvider).whenData((list) => list.firstOrNull)),
          connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
          deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
          orchardSsoProvider.overrideWith((ref, id) async => const OrchardSso(kind: SsoKind.saml, active: false)),
          currentUserProvider.overrideWithValue(UserProfile(uid: as.uid, email: as.email)),
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
            body: SingleChildScrollView(
              padding: EdgeInsets.all(phone ? 16 : 28),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  // As wide as a Team page is.
                  constraints: const BoxConstraints(maxWidth: kTeamPageWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TeamTrackingPanel(orchard: first),
                      const SizedBox(height: 16),
                      TeamExportPanel(orchard: first),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    return (key, ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)));
  }

  Finder byKey(String k) => find.byKey(ValueKey(k));

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await settle(tester);
    await tester.tap(f);
    await settle(tester);
  }

  Future<void> everyPicture(WidgetTester tester, String themeId, Size size, String tag, {bool phone = false}) async {
    final l10n = lookupAppLocalizations(const Locale(_locale));
    await setUpOrchard(tester);

    // Nothing recorded: nothing to send on.
    var (key, container) = await show(tester, alex, themeId, size, phone: phone);
    await saveShot(tester, key, 'export_${tag}_1_needs_activity');
    await tester.runAsync(() => alex.service.setTracking(orchardId, const RecordTracking(activity: true)));
    (key, container) = await show(tester, alex, themeId, size, phone: phone);
    await saveShot(tester, key, 'export_${tag}_2_off');

    // Setting it up: what is wrong, a test event, asking first, the key.
    await tap(tester, byKey('team-export-set-up'));
    await saveShot(tester, key, 'export_${tag}_3_setup');
    await tester.enterText(byKey('export-address'), 'http://logs.example.com/ingest');
    await tester.enterText(byKey('export-header-name'), 'Authorization');
    await tap(tester, byKey('export-save'));
    await saveShot(tester, key, 'export_${tag}_4_setup_wrong');
    await tester.enterText(byKey('export-address'), 'https://logs.example.com/ingest');
    await tester.enterText(byKey('export-header-value'), 'Splunk 0f3c-example-token');
    await tap(tester, byKey('export-test'));
    await saveShot(tester, key, 'export_${tag}_5_setup_tested');
    await tap(tester, byKey('export-save'));
    await saveShot(tester, key, 'export_${tag}_6_confirm');
    await tester.tap(find.text(l10n.exportTurnOn).last);
    await settle(tester);
    await saveShot(tester, key, 'export_${tag}_7_key');
    await tap(tester, byKey('export-done-close'));
    await tester.pump(const Duration(seconds: 6));
    await saveShot(tester, key, 'export_${tag}_8_on_here');

    // The receiver stops taking events.
    refuse = const ExportDelivery.failed(ExportFailure.refused, status: 503);
    await tester.runAsync(() async {
      await alex.service.createCrate(orchardId, 'Vault', ownersOnly: true);
      await container.read(orchardEventExporterProvider).round(orchardId);
    });
    await settle(tester);
    await saveShot(tester, key, 'export_${tag}_9_failed');
    refuse = null;
    await tap(tester, byKey('team-export-turn-off'));
    await saveShot(tester, key, 'export_${tag}_10_turn_off');
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    await tester.pumpWidget(const SizedBox());

    // Another owner, and a member.
    (key, container) = await show(tester, jordan, themeId, size, phone: phone);
    await saveShot(tester, key, 'export_${tag}_11_another_owner');
    await tap(tester, byKey('team-export-move'));
    await saveShot(tester, key, 'export_${tag}_12_take_over');
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    (key, container) = await show(tester, kit, themeId, size, phone: phone);
    await saveShot(tester, key, 'export_${tag}_13_member');

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
        await everyPicture(tester, themeId, const Size(1100, 900), tag);
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
