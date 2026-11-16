import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show RecordRules;
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/desktop_shell.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart' show accountSetupNeedsAttentionProvider;
import 'package:zestssh/utils/redactor.dart';

import '../../../video/teams_world.dart' show TeamCloud;
import '../../../video/video_monitor.dart' show monitorOverrides;
import '../../../video/video_world.dart'
    show VideoHealth, VideoSessions, demoAccount, demoOsKinds, demoWorkspaces, seedWorld, stubPlugins;
import '../../../visual/shots_util.dart';
import 'roles_vaults_fixture.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart' as ws;

/// The team of the screenshots ("Platform team", roles_vaults_fixture.dart,
/// on a played server) in the whole desktop app, [size] big, in [locale],
/// with the real fonts, the demo fleet of the website and ZestSSH Cloud's
/// team routes made up (as the Teams videos have them, teams_world.dart);
/// the Team destination open on [page].
class TeamShell {
  TeamShell(this.team, this.container);
  final RolesVaultsTeam team;
  final ProviderContainer container;

  /// The app's picture (saveShot).
  final key = GlobalKey();

  void showPage(TeamPage page) {
    container.read(teamPageProvider.notifier).state = page;
    container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
  }
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Before the first [pumpTeamShell] of a test file.
Future<void> setUpTeamShell() async {
  stubPlugins();
  await loadShotFonts();
}

Future<TeamShell> pumpTeamShell(
  WidgetTester tester, {
  required Size size,
  Locale locale = const Locale('en'),
  TeamPage page = TeamPage.overview,
  String themeId = 'graphite',
  DateTime? timedUntil,
}) async {
  final team = await buildRolesVaultsTeam(tester, timedUntil: timedUntil);
  late Map<String, String> kept;
  await tester.runAsync(() async {
    await team.service.setRules(team.orchardId, const RecordRules(requireAppLock: true, noExport: true));
    await team.service.refresh();
    // The team's database keys, which seeding the demo world wipes from the
    // stand-in secure storage: put back below.
    kept = await const FlutterSecureStorage().readAll();
  });
  PackageInfo.setMockInitialValues(
      appName: 'ZestSSH', packageName: 'com.zestssh.app', version: '3.0.0', buildNumber: '300', buildSignature: '');
  final w = await seedWorld(tester, more: (w) async {
    for (final e in kept.entries) {
      await const FlutterSecureStorage().write(key: e.key, value: e.value);
    }
  });
  SharedPreferences.setMockInitialValues({'app_theme_id': themeId, ...demoOsKinds});
  final sp = await SharedPreferences.getInstance();
  addTearDown(() => tester.runAsync(w.db.close));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = BuiltInThemes.getById(themeId);
  AppColors.applyTheme(theme.colorScheme);
  addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
  final cloud = TeamCloud();
  final client = MockClient(cloud.answer);
  Future<String?> bearer() async => 'token';
  const base = 'https://api.example.dev/v1';
  Future<OrchardSummary> read() async => readOrchardSummary(await team.databases.open(team.orchardId), team.orchardId);
  final now = DateTime.now();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(sp),
    databaseProvider.overrideWithValue(w.db),
    treeDatabaseProvider.overrideWithValue(w.db),
    identitiesDaoProvider.overrideWithValue(w.db.identitiesDao),
    identityCrudProvider.overrideWithValue(w.crud),
    healthChecksEnabledProvider.overrideWith((ref) => false),
    currentUserProvider.overrideWith((_) => demoAccount),
    isCloudSyncProvider.overrideWith((ref) => _Juiced()),
    isProProvider.overrideWith((ref) => _Pro()),
    syncedAvatarUrlProvider.overrideWith((ref) => SyncedAvatarNotifier()),
    authStateProvider.overrideWith((_) => const Stream.empty()),
    accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
    appThemeIdProvider.overrideWith((ref) => themeId),
    activeSessionsProvider.overrideWith(VideoSessions.new),
    connectionHealthProvider.overrideWith((ref) => VideoHealth()),
    recordingModeProvider.overrideWith((ref) => false),
    syncHealthClockProvider.overrideWith((ref) => Stream.value(now)),
    syncHealthProvider.overrideWithValue(SyncHealthState(SyncHealth.upToDate, confirmedAt: now)),
    ws.workspacesProvider.overrideWithValue(demoWorkspaces()),
    ...monitorOverrides(),
    orchardServiceProvider.overrideWithValue(team.service),
    orchardDatabasesProvider.overrideWith((ref) => team.databases),
    orchardSummariesProvider.overrideWith((ref) async {
      ref.watch(orchardListVersionProvider);
      return [await read()];
    }),
    activeOrchardProvider.overrideWith((ref) => ref.watch(orchardSummariesProvider).whenData((l) => l.firstOrNull)),
    connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(team.hosts)),
    hostCratesProvider.overrideWith((ref) => Stream.value(team.hostCrates)),
    crateAuthoritiesProvider(team.orchardId).overrideWith((ref) async => productionAuthority(team)),
    deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
    recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
    billingOnThisDeviceProvider.overrideWithValue(true),
    seatsPageOpenerProvider.overrideWithValue((_) async {}),
    orchardDomainsApiProvider.overrideWithValue(OrchardDomainsApi(client: client, baseUrl: base, bearer: bearer)),
    orchardSsoApiProvider.overrideWithValue(OrchardSsoApi(client: client, baseUrl: base, bearer: bearer)),
    orchardDirectoryApiProvider.overrideWithValue(OrchardDirectoryApi(client: client, baseUrl: base, bearer: bearer)),
    orchardBillingApiProvider.overrideWithValue(OrchardBillingApi(client: client, baseUrl: base, bearer: bearer)),
  ]);
  addTearDown(container.dispose);
  final shell = TeamShell(team, container)..showPage(page);
  await tester.pumpWidget(RepaintBoundary(
    key: shell.key,
    child: UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.toThemeData(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const DesktopShell(),
    ),
  ),
  ));
  await settleTeamShell(tester);
  return shell;
}

/// Lets the team's database and crypto work finish, then the frames.
Future<void> settleTeamShell(WidgetTester tester, {int max = 30}) async {
  for (var i = 0; i < max; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 100));
    if (i >= 3 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The app gone, its timers run out.
Future<void> tearDownTeamShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(hours: 7));
}
