import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
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

import '../fake_crate_server.dart';

/// The demo world's team (the website's) for the Roles and Vaults pages
/// (3.0 UI, as designed), on a real record:
/// "Platform team", run by alex@example.com; the vaults Shared (6 hosts),
/// Production (4 hosts: web-01, web-02, db-primary, cache-01; SFTP only,
/// asks before revealing, sessions logged, certificates on) and Recovery
/// (owners only, the two hypervisors); the roles
/// Developers (Use in Shared, Edit in Production) and Member (Use in
/// Shared); Jordan a Member who holds Production at Connect for two hours,
/// Sam and Priya invited as Members. Nothing on it is anyone's.

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

class RolesVaultsTeam {
  RolesVaultsTeam._(this.server, this.service, this.databases);

  final FakeCrateServer server;
  final OrchardService service;
  final OrchardDatabasesNotifier databases;
  late final String orchardId;
  late final String shared;
  late final String production;
  late final String recovery;
  late final String member;
  late final String developers;
  late final List<ConnectionWithDetails> hosts;
  late final Map<String, String> hostCrates;

  /// The invitation Sam's invite code made, when he used one.
  String? samInvite;

  static const owner = 'uid-alex';
  static const jordan = 'uid-jordan';

  Future<OrchardSummary> summary() async =>
      readOrchardSummary(await databases.open(orchardId), orchardId);
}

/// Builds the team on a fake server; its databases are closed when the test
/// ends.
///
/// With [samByCode] Sam used an invite code four minutes ago (on an Android
/// device), keys checked, and waits to be let in, in place of an invitation
/// to his address.
/// Sam makes his account keys and uses an invite code the owner made for the
/// Member role, four minutes ago: [RolesVaultsTeam.samInvite] is it. Done
/// while the team is built ([buildRolesVaultsTeam] with samByCode), or later,
/// behind a page already showing, where nothing tells the page.
Future<void> samUsesACode(RolesVaultsTeam team) async {
  const sam = 'uid-sam';
  final server = team.server;
  final id = team.orchardId;
  final samKeys = await AccountKeys.generate();
  await server.publish(sam, samKeys, email: 'sam@example.com');
  final made = await team.service.makeInviteCode(id,
      role: team.member,
      expiresIn: 3600,
      shown: const JoinOffer(team: 'Platform team', role: 'Member', vaults: [JoinOfferVault('Shared', 'use')]));
  final samService = OrchardService(
    server: server.as(sam),
    databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: _MemoryStorage()),
    author: () async => CrateAuthor(uid: sam, keys: samKeys),
  );
  team.samInvite = await samService.acceptInviteCode(await samService.previewInviteCode(made.code));
  server.codeUsedAt(id, team.samInvite!, DateTime.now().subtract(const Duration(minutes: 4)));
}

/// [timedUntil]: when what Jordan holds for a set time ends (two hours from now when not given),
/// for a test whose result must not depend on the time of day it runs at.
Future<RolesVaultsTeam> buildRolesVaultsTeam(WidgetTester tester,
    {bool timed = true, bool samByCode = false, DateTime? timedUntil}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final storage = _MemoryStorage();
  final server = FakeCrateServer(accountUid: RolesVaultsTeam.owner);
  final hostsDb = AppDatabase.forTesting(NativeDatabase.memory());
  late RolesVaultsTeam team;
  await tester.runAsync(() async {
    final keys = <String, AccountKeys>{};
    for (final (uid, email) in [
      (RolesVaultsTeam.owner, 'alex@example.com'),
      (RolesVaultsTeam.jordan, 'jordan@example.com'),
    ]) {
      keys[uid] = await AccountKeys.generate();
      await server.publish(uid, keys[uid]!, email: email);
    }
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final service = OrchardService(
      server: server.as(RolesVaultsTeam.owner),
      databases: databases,
      author: () async => CrateAuthor(uid: RolesVaultsTeam.owner, keys: keys[RolesVaultsTeam.owner]!),
    );
    team = RolesVaultsTeam._(server, service, databases);
    final id = team.orchardId =
        await service.createOrchard('Platform team', firstCrateName: 'Shared', memberRoleName: 'Member');
    final first = server.recordOf(id).roles.values.single;
    team.member = first.id;
    team.shared = first.crates.keys.single;
    team.production = await service.createCrate(id, 'Production');
    team.recovery = await service.createCrate(id, 'Recovery', ownersOnly: true);
    team.developers = await service.saveRole(id,
        name: 'Developers',
        can: const {},
        crates: {team.shared: levelSwitches(CrateLevel.use), team.production: levelSwitches(CrateLevel.edit)});
    await service.moveRoleTo(id, team.developers, 0);
    await service.setCrateAllow(id, team.production, {CrateSwitches.sftp});
    await service.setCrateConfirmReveal(id, team.production, true);
    await service.setCrateConfirmReveal(id, team.recovery, true);
    await service.setCrateSessionLogs(id, team.production, true);

    // Jordan joins as a Member; Sam and Priya are invited.
    await service.invite(id, email: 'jordan@example.com', role: team.member);
    final invite = (await service.invites(id)).single;
    server.acceptAs(id, invite.id, RolesVaultsTeam.jordan);
    await service.confirmInvite(id, (await service.invites(id)).single);
    if (samByCode) {
      await samUsesACode(team);
    } else {
      await service.invite(id, email: 'sam@example.com', role: team.member);
    }
    await service.invite(id, email: 'priya@example.com', role: team.member);
    if (timed) {
      await service.giveAccess(id,
          uid: RolesVaultsTeam.jordan,
          crateId: team.production,
          level: CrateLevel.connect,
          duration: timedUntil == null ? const Duration(hours: 2) : timedUntil.difference(DateTime.now()));
    }
    await service.refresh();

    // The hosts of the demo fleet, each in its vault.
    final at = DateTime(2026, 10, 20);
    final placed = <String, String>{};
    for (final (name, address, crate) in [
      ('vpn-gateway', '192.168.10.23', team.shared),
      ('log-store', '192.168.10.24', team.shared),
      ('mac-studio', '192.168.10.30', team.shared),
      ('build-runner', '192.168.10.50', team.shared),
      ('monitoring', '192.168.10.60', team.shared),
      ('edge-router', '192.168.20.1', team.shared),
      ('web-01', '192.168.10.21', team.production),
      ('web-02', '192.168.10.22', team.production),
      ('db-primary', '192.168.10.31', team.production),
      ('cache-01', '192.168.10.41', team.production),
      ('hypervisor-a', '192.168.20.11', team.recovery),
      ('hypervisor-b', '192.168.20.12', team.recovery),
    ]) {
      await hostsDb.into(hostsDb.connections).insert(ConnectionsCompanion.insert(
            id: 'h-$name',
            label: name,
            host: address,
            port: const Value(22),
            createdAt: at,
            updatedAt: at,
          ));
      placed['h-$name'] = crate;
    }
    team.hosts = [
      for (final c in await hostsDb.select(hostsDb.connections).get()) ConnectionWithDetails(connection: c),
    ];
    team.hostCrates = placed;
  });
  addTearDown(() async {
    for (final db in [...storage.dbs.values, hostsDb]) {
      try {
        await db.close();
      } catch (_) {}
    }
  });
  return team;
}

/// Production's certificate authority, as the record would have it: on,
/// each certificate a day.
Map<String, CrateAuthorityView> productionAuthority(RolesVaultsTeam team) => {
      team.production: CrateAuthorityView(
        crateId: team.production,
        on: true,
        generation: 1,
        ttlMinutes: 1440,
        principals: const {
          'owner': ['root'],
          'admin': ['deploy'],
        },
        keyCrate: team.recovery,
        publicKeys: {1: Uint8List(32)},
        myUserNames: const ['root'],
      ),
    };

/// The Team destination on [page] for [team]'s owner (or as [as] says),
/// [size] big, in [themeId]; or [body] in its place. Returns the key its
/// pictures are taken from, and the providers.
Future<({GlobalKey key, ProviderContainer container})> pumpRolesVaults(
  WidgetTester tester,
  RolesVaultsTeam team, {
  required TeamPage page,
  OrchardSummary? as,
  String themeId = 'graphite',
  Size size = const Size(1440, 900),
  Locale locale = const Locale('en'),
  Future<void> Function(WidgetTester tester)? settle,
  Widget? body,
  List<Override> extra = const [],
}) async {
  final theme = BuiltInThemes.getById(themeId);
  AppColors.applyTheme(theme.colorScheme);
  addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final summary = as ?? (await tester.runAsync(team.summary))!;
  final container = ProviderContainer(overrides: [
    orchardServiceProvider.overrideWithValue(team.service),
    orchardDatabasesProvider.overrideWith((ref) => team.databases),
    activeOrchardProvider.overrideWithValue(AsyncData(summary)),
    orchardSummariesProvider.overrideWith((ref) async => [summary]),
    connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(team.hosts)),
    hostCratesProvider.overrideWith((ref) => Stream.value(team.hostCrates)),
    crateAuthoritiesProvider(team.orchardId).overrideWith((ref) async => productionAuthority(team)),
    deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
    recordingModeProvider.overrideWith((ref) => false),
    recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
    ...extra,
  ]);
  addTearDown(container.dispose);
  container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
  container.read(teamPageProvider.notifier).state = page;
  final key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(
    key: key,
    child: UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(backgroundColor: AppColors.v3Background, body: body ?? const TeamView()),
      ),
    ),
  ));
  await (settle ?? settleTeam)(tester);
  return (key: key, container: container);
}

/// Lets the database and crypto work finish, then the frames.
Future<void> settleTeam(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
    if (i >= 3 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}
