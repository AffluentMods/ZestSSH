import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
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

/// Pictures of a team's Rules, Sign-in and Seats pages on a computer (as
/// designed), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/team_rules_signin_seats_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up: the team
/// Platform team, alex (its owner), jordan, sam and priya at example.com, and
/// the domain example.dev.

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

/// ZestSSH Cloud's domain, company sign-in, directory and billing routes for
/// the one team, made up.
class _Cloud {
  bool proven = false;

  http.Response json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    final now = DateTime.now().toUtc();
    if (path.contains('/domains')) {
      return json({
        'domains': [
          {
            'domain': 'example.dev',
            'verified': proven,
            if (proven) 'verified_at': now.subtract(const Duration(days: 3)).toIso8601String(),
            'checked_at': now.subtract(const Duration(minutes: 2)).toIso8601String(),
            'txt': 'zestssh-verify=8f3c1e9a2b7d4f60c1e5a9b2',
          },
        ],
      });
    }
    if (path.contains('/sso')) {
      return json({
        'kind': null,
        'active': false,
        'service': {
          'saml': {'acs_url': 'https://auth.example.dev/__/auth/handler', 'entity_id': 'urn:zestssh:orchard:demo'},
          'oidc': {'redirect_uri': 'https://auth.example.dev/__/auth/handler'},
        },
        'domains': [if (proven) 'example.dev'],
      });
    }
    if (path.contains('/directory')) {
      return json({'enabled': false, 'groups': [], 'pending': [], 'held': []});
    }
    if (path.contains('/billing')) {
      return json({
        'seats': {'bought': 4, 'included': 1, 'total': 5, 'used': 4, 'free': 1, 'over': false},
        'business_services': {'state': 'off', 'status': null, 'interval': null, 'quantity': null},
        'prices': {'seat_cents': 10000, 'services_month_cents': 1500, 'services_year_cents': 15000},
      });
    }
    return http.Response(jsonEncode({'code': 'not-found'}), 404);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeCrateServer server;
  late OrchardService service;
  late OrchardDatabasesNotifier databases;
  late _MemoryStorage storage;
  late String orchardId;
  late _Cloud cloud;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 120));
      if (i >= 4 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Platform team: alex (the owner, this device), jordan (a member), sam who
  /// accepted an invitation and waits to be added, and priya invited.
  Future<void> setUpTeam(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'uid-alex');
    storage = _MemoryStorage();
    cloud = _Cloud();
    await tester.runAsync(() async {
      final alexKeys = await AccountKeys.generate();
      final jordanKeys = await AccountKeys.generate();
      final samKeys = await AccountKeys.generate();
      await server.publish('uid-alex', alexKeys, email: 'alex@example.com');
      await server.publish('uid-jordan', jordanKeys, email: 'jordan@example.com');
      await server.publish('uid-sam', samKeys, email: 'sam@example.com');
      databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
      service = OrchardService(
        server: server.as('uid-alex', device: 'laptop'),
        databases: databases,
        author: () async => CrateAuthor(uid: 'uid-alex', keys: alexKeys),
        deviceKeys: DeviceIdentityStore(_Keychain()),
      );
      orchardId = await service.createOrchard('Platform team', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single;
      await service.invite(orchardId, email: 'jordan@example.com', role: member.id);
      final jordan = (await service.invites(orchardId)).single;
      server.acceptAs(orchardId, jordan.id, 'uid-jordan');
      await service.confirmInvite(orchardId, (await service.invites(orchardId)).single);
      await service.invite(orchardId, email: 'sam@example.com', role: member.id);
      final sam = (await service.invites(orchardId)).single;
      server.acceptAs(orchardId, sam.id, 'uid-sam');
      await service.invite(orchardId, email: 'priya@example.com', role: member.id);
      await service.setRules(
          orchardId, const RecordRules(require2fa: true, requireAppLock: true, maxLockMinutes: 15, reauthDays: 30));
      await service.refresh();
    });
    addTearDown(() async {
      for (final db in storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
  }

  /// The Team page on [page], at 1440 by 900, in [themeId].
  Future<(GlobalKey, ProviderContainer)> show(WidgetTester tester, String themeId, TeamPage page) async {
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<OrchardSummary> read() async => readOrchardSummary(await databases.open(orchardId), orchardId);
    final client = MockClient(cloud.answer);
    Future<String?> bearer() async => 'token';
    const base = 'https://api.example.dev/v1';
    final key = GlobalKey();
    final container = ProviderContainer(overrides: [
      orchardServiceProvider.overrideWithValue(service),
      // A notifier of its own over the same databases: each page's scope
      // disposes the one it was given.
      orchardDatabasesProvider.overrideWith(
          (ref) => OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage)),
      orchardSummariesProvider.overrideWith((ref) async {
        ref.watch(orchardListVersionProvider);
        return [await read()];
      }),
      activeOrchardProvider.overrideWith((ref) => ref.watch(orchardSummariesProvider).whenData((list) => list.firstOrNull)),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
      deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-alex', email: 'alex@example.com')),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      billingOnThisDeviceProvider.overrideWithValue(true),
      seatsPageOpenerProvider.overrideWithValue((_) async {}),
      orchardDomainsApiProvider.overrideWithValue(OrchardDomainsApi(client: client, baseUrl: base, bearer: bearer)),
      orchardSsoApiProvider.overrideWithValue(OrchardSsoApi(client: client, baseUrl: base, bearer: bearer)),
      orchardDirectoryApiProvider.overrideWithValue(OrchardDirectoryApi(client: client, baseUrl: base, bearer: bearer)),
      orchardBillingApiProvider.overrideWithValue(OrchardBillingApi(client: client, baseUrl: base, bearer: bearer)),
    ]);
    addTearDown(container.dispose);
    container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
    container.read(teamPageProvider.notifier).state = page;
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(backgroundColor: AppColors.v3Background, body: const TeamView()),
        ),
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  /// Scrolls the page down until [key] is at its top.
  Future<void> scrollTo(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    final scrollable = find.ancestor(of: target, matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final box = tester.getTopLeft(target).dy - tester.getTopLeft(scrollable).dy;
    position.jumpTo((position.pixels + box - 12).clamp(0, position.maxScrollExtent));
    await settle(tester);
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('Rules, Sign-in and Seats on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await setUpTeam(tester);
        var (key, _) = await show(tester, themeId, TeamPage.rules);
        await saveShot(tester, key, 'team_rss_${tag}_1_rules_top');
        await scrollTo(tester, 'rules-on-devices');
        await saveShot(tester, key, 'team_rss_${tag}_2_rules_scrolled');

        (key, _) = await show(tester, themeId, TeamPage.signIn);
        await saveShot(tester, key, 'team_rss_${tag}_3_signin_waiting');
        cloud.proven = true;
        (key, _) = await show(tester, themeId, TeamPage.signIn);
        await saveShot(tester, key, 'team_rss_${tag}_4_signin_proven');

        (key, _) = await show(tester, themeId, TeamPage.seats);
        await saveShot(tester, key, 'team_rss_${tag}_5_seats');
        await scrollTo(tester, 'team-seat-holders');
        await saveShot(tester, key, 'team_rss_${tag}_6_seats_scrolled');

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 5));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }
}
