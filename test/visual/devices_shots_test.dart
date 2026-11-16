import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/member_devices_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/orchards/fake_crate_server.dart';
import 'shots_util.dart';

/// Pictures of trusted devices (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/devices_shots_test.dart
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
  const rule = RecordRules(trustedDevices: true);
  late FakeCrateServer server;
  late _Device laptop;
  late _Device handset;
  late _Device kit;
  late String orchardId;

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

  /// Lets the dialog on screen look at its request again.
  Future<void> look(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> approve(_Device asking, _Device approver) async {
    final asked = await asking.service.askDeviceApproval(orchardId);
    await approver.service.answerDeviceRequest(orchardId, asked.id);
    await asking.service.deviceAsk(orchardId);
    await approver.service.deviceRequests(orchardId);
    await approver.service.approveDevice(orchardId, asked.id);
    await asking.service.refresh();
  }

  /// Platform team: alex (an owner, on a laptop and a phone) and kit. With
  /// [ruleOn], alex's devices are approved and the rule is on.
  Future<void> setUpOrchard(WidgetTester tester, {bool ruleOn = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'uid-alex');
    await tester.runAsync(() async {
      final alexKeys = await AccountKeys.generate();
      final kitKeys = await AccountKeys.generate();
      await server.publish('uid-alex', alexKeys, email: 'alex@example.com');
      await server.publish('uid-kit', kitKeys, email: 'kit@example.com');
      laptop = _Device(server, 'uid-alex', 'alex@example.com', alexKeys, 'laptop');
      handset = _Device(server, 'uid-alex', 'alex@example.com', alexKeys, 'phone');
      kit = _Device(server, 'uid-kit', 'kit@example.com', kitKeys, 'kit-laptop');
      orchardId = await laptop.service.createOrchard('Platform team', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single;
      await laptop.service.invite(orchardId, email: 'kit@example.com', role: member.id);
      final invite = (await laptop.service.invites(orchardId)).single;
      server.acceptAs(orchardId, invite.id, 'uid-kit');
      await laptop.service.confirmInvite(orchardId, (await laptop.service.invites(orchardId)).single);
      await kit.service.refresh();
      await handset.service.refresh();
      if (ruleOn) {
        await laptop.service.approveThisDevice(orchardId);
        await approve(handset, laptop);
        await laptop.service.setRules(orchardId, rule);
      }
      for (final d in [laptop, handset, kit]) {
        await d.service.refresh();
      }
    });
    addTearDown(() async {
      for (final d in [laptop, handset, kit]) {
        for (final db in d.storage.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
    });
  }

  /// A page of [as]'s at [size] with [themeId]: the Team page, its Overview
  /// alone on a phone, or [body]. Returns the key the pictures are taken
  /// from, and the scope's container.
  Future<(GlobalKey, ProviderContainer)> show(
    WidgetTester tester,
    _Device as,
    String themeId,
    Size size, {
    bool phone = false,
    Widget Function(OrchardSummary orchard)? body,
  }) async {
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
            body: body != null
                ? SingleChildScrollView(
                    padding: EdgeInsets.all(phone ? 16 : 28),
                    child: Align(
                      alignment: Alignment.topLeft,
                      // As wide as a Team page is.
                      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: kTeamPageWidth), child: body(first)),
                    ),
                  )
                : phone
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: TeamOverview(orchard: first, onOpen: (_) {}),
                      )
                    : const TeamView(),
          ),
        ),
      ),
    ));
    await settle(tester);
    return (key, ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)));
  }

  Future<void> closeTop(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(Navigator).first), rootNavigator: true).pop();
    await settle(tester);
  }

  Future<void> everyPicture(WidgetTester tester, String themeId, Size size, String tag, {bool phone = false}) async {
    final l10n = lookupAppLocalizations(const Locale(_locale));

    // Before anything is approved: the Rules page says what the rule takes.
    await setUpOrchard(tester, ruleOn: false);
    var (key, container) = await show(tester, laptop, themeId, size,
        phone: phone, body: (o) => OrchardRulesView(orchardId: o.id, onSaved: () {}));
    await saveShot(tester, key, 'devices_${tag}_1_rules_needs_this');
    await tester.runAsync(() async {
      await laptop.service.approveThisDevice(orchardId);
      await approve(handset, laptop);
    });
    (key, container) = await show(tester, laptop, themeId, size,
        phone: phone, body: (o) => OrchardRulesView(orchardId: o.id, onSaved: () {}));
    await tester.tap(find.byKey(const ValueKey('rule-devices-switch')));
    await settle(tester);
    await saveShot(tester, key, 'devices_${tag}_2_rules_turning_on');
    await tester.pumpWidget(const SizedBox());

    // The rule on. Kit's laptop, held back: the banner (at the top of the
    // team's pages), then the list of kit's devices on its own as the app
    // shows it (the two never share a screen), asking, the words.
    await setUpOrchard(tester);
    (key, container) = await show(tester, kit, themeId, size,
        phone: phone, body: (o) => const OrchardStatusBanner(padding: EdgeInsets.zero));
    await saveShot(tester, key, 'devices_${tag}_3_held_banner');
    (key, container) = await show(tester, kit, themeId, size,
        phone: phone,
        body: (o) => MemberDevicesView(orchard: o, uid: 'uid-kit', name: 'kit@example.com', isMe: true));
    await saveShot(tester, key, 'devices_${tag}_3b_held_devices');
    await tester.tap(find.text(l10n.deviceAskAction).first);
    await settle(tester);
    await saveShot(tester, key, 'devices_${tag}_4_ask_waiting');
    final asked = server.deviceRequestsOf(orchardId).single;
    await tester.runAsync(() => handset.service.answerDeviceRequest(orchardId, asked.id));
    await look(tester);
    await saveShot(tester, key, 'devices_${tag}_5_ask_words');
    await tester.runAsync(() async {
      await handset.service.deviceRequests(orchardId);
      await handset.service.approveDevice(orchardId, asked.id);
    });
    await look(tester);
    await settle(tester);
    await saveShot(tester, key, 'devices_${tag}_6_ask_approved');
    await closeTop(tester);
    await tester.pumpWidget(const SizedBox());

    // Alex's laptop: another device of kit's asks; the dialog through to
    // the words.
    final other = _Device(server, 'uid-kit', 'kit@example.com', kit.keys, 'kit-phone');
    addTearDown(() async {
      for (final db in other.storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
    final again = (await tester.runAsync(() async {
      await other.service.refresh();
      return other.service.askDeviceApproval(orchardId);
    }))!;
    (key, container) = await show(tester, laptop, themeId, size, phone: phone);
    await saveShot(tester, key, 'devices_${tag}_7_owner_page');
    final review = find.descendant(
        of: find.byKey(ValueKey('team-attn-device-${again.id}')), matching: find.text(l10n.teamReview));
    await tester.ensureVisible(review);
    await settle(tester);
    await tester.tap(review);
    await settle(tester);
    await saveShot(tester, key, 'devices_${tag}_8_request_intro');
    await tester.tap(find.text(l10n.profileContinue));
    await settle(tester);
    await tester.runAsync(() => other.service.deviceAsk(orchardId));
    await look(tester);
    await saveShot(tester, key, 'devices_${tag}_9_request_compare');
    await tester.tap(find.text(l10n.deviceRequestApprove));
    await settle(tester);
    await saveShot(tester, key, 'devices_${tag}_10_owner_page_after');

    // A member's devices, in the Members page's panel on a computer, and as
    // the dialog on a phone.
    if (phone) {
      (key, container) = await show(tester, laptop, themeId, size,
          phone: phone,
          body: (o) => MemberDevicesView(orchard: o, uid: 'uid-kit', name: 'kit@example.com', isMe: false));
    } else {
      container.read(teamPageProvider.notifier).state = TeamPage.members;
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('member-uid-kit')));
      await settle(tester);
    }
    await saveShot(tester, key, 'devices_${tag}_11_member_devices');
    final remove = find.byTooltip(l10n.memberDeviceRemove).first;
    await tester.ensureVisible(remove);
    await settle(tester);
    await tester.tap(remove);
    await settle(tester);
    await saveShot(tester, key, 'devices_${tag}_12_remove_confirm');
    await tester.tap(find.text(l10n.memberDeviceRemove).last);
    await settle(tester);
    await tester.pumpWidget(const SizedBox());

    // A removed device says so. (Which of kit's two was removed depends on
    // their codes; both are, here.)
    await tester.runAsync(() async {
      for (final d in await laptop.service.memberDevices(orchardId, 'uid-kit')) {
        await laptop.service.removeDevice(orchardId, uid: 'uid-kit', deviceKey: d.key);
      }
    });
    (key, container) =
        await show(tester, kit, themeId, size, phone: phone, body: (_) => const OrchardStatusBanner(padding: EdgeInsets.zero));
    await saveShot(tester, key, 'devices_${tag}_13_removed_banner');

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
