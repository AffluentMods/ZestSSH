import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';
import 'package:zestssh/utils/platform_utils.dart';

import '../features/orchards/team/roles_vaults_fixture.dart';
import '../helpers/quick_wins_fixture.dart';
import 'shots_util.dart';

/// Pictures of the 3.0 quick wins on a phone (430 by 932) and a tablet below
/// the large screen (800 by 1280): monospace for values only, chips only for filters and what needs
/// someone, no Delete on a list row, problems first on Monitor. Made-up demo
/// data only (the demo fleet's 192.168.10.x and 192.168.20.x):
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/quick_wins_shots_test.dart
///
/// Pictures land in build/shots/qw-*.png.
const _orchards = bool.fromEnvironment('ZEST_ORCHARDS');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();

  /// A picture's test, drawn as a phone's or a tablet's (Android), with the
  /// real fonts and shadows.
  void shot(String name, Future<void> Function(WidgetTester tester) body, {bool skip = false}) {
    testWidgets(name, (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      realShadows();
      try {
        await tester.runAsync(loadShotFonts);
        await body(tester);
      } finally {
        plainShadows();
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    }, skip: skip);
  }

  for (final (tag, size) in [('phone', quickWinsPhone), ('tablet', quickWinsTablet)]) {
    shot('home tabs, $tag', (tester) async {
      final (:key, container: _, db: _) = await pumpQuickWins(tester, const HomeScreen(), size,
          extra: [activeSessionsProvider.overrideWith(QuickWinsSessions.new)]);
      await saveShot(tester, key, 'qw-hosts-$tag');
      final bar = find.byKey(const ValueKey('phone-tab-bar'));
      // The phone's tabs since 3.1, a tablet's below the large screen too
      // (4.0): Hosts, Sessions, Manage, Monitor, More.
      const tabs = [(1, 'sessions'), (2, 'manage'), (4, 'more')];
      for (final (i, name) in tabs) {
        await tester.tap(find.descendant(of: bar, matching: find.byKey(ValueKey('phone-tab-$i'))));
        await settleQuickWins(tester);
        await saveShot(tester, key, 'qw-$name-$tag');
      }
      await unpumpQuickWins(tester);
    }, skip: !shotsEnabled);

    shot('keys, forwards, networks and settings, $tag', (tester) async {
      for (final (name, page) in [
        ('keys', const KeysPhoneScreen()),
        ('forwards', const PortForwardsPhoneScreen()),
        ('networks', const NetworksMobileScreen()),
        ('settings', Scaffold(appBar: AppBar(title: const Text('Settings')), body: const SettingsBody(bottomPadding: 16))),
      ]) {
        final (:key, container: _, db: _) = await pumpQuickWins(tester, page, size);
        await saveShot(tester, key, 'qw-$name-$tag');
        if (name == 'forwards') {
          // A rule's own page, where its Delete is now.
          await tester.tap(find.text('Orders database'));
          await settleQuickWins(tester);
          await saveShot(tester, key, 'qw-forward-edit-$tag');
        }
        await unpumpQuickWins(tester);
      }
    }, skip: !shotsEnabled);

    shot('monitor, $tag', (tester) async {
      final theme = BuiltInThemes.getById('graphite');
      AppColors.applyTheme(theme.colorScheme);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fleet = QuickWinsFleet();
      final db = (await tester.runAsync(fleet.database))!;
      final prefs = (await tester.runAsync(fleet.preferences))!;
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: fleet.app(fleet.overrides(db, prefs), const ServerMonitorScreen(), theme: theme.toThemeData()),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await saveShot(tester, key, 'qw-monitor-$tag');
      // The others, folded to a few, and the button that shows the rest.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('monitor-show-more')), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      await saveShot(tester, key, 'qw-monitor-folded-$tag');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(db.close);
    }, skip: !shotsEnabled);

    shot('terminal bar, $tag', (tester) async {
      final theme = BuiltInThemes.getById('graphite');
      AppColors.applyTheme(theme.colorScheme);
      tester.view.physicalSize = Size(size.width, 120);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: ProviderScope(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.toThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: TerminalToolbar(
                sessionId: 's1',
                status: SessionStatus.connected,
                connectionLabel: 'web-01',
                host: '192.168.10.21',
                port: 22,
                username: 'deploy',
                connectedAt: DateTime.now().subtract(const Duration(minutes: 12, seconds: 7)),
                onDisconnect: () {},
                onBack: () {},
                onSettings: () {},
                onSnippets: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await saveShot(tester, key, 'qw-terminal-bar-$tag');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }, skip: !shotsEnabled);

    shot('team members and roles, $tag', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      for (final page in [TeamPage.members, TeamPage.roles]) {
        final (:key, container: _) =
            await pumpRolesVaults(tester, team, page: page, size: size, body: TeamPhonePageScreen(page: page));
        await saveShot(tester, key, 'qw-team-${page.name}-$tag');
        if (page == TeamPage.roles) {
          // A role's editor, where its Delete is now.
          await tester.tap(find.byKey(const ValueKey('edit')).first);
          await settleTeam(tester);
          await saveShot(tester, key, 'qw-team-role-edit-$tag');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      }
    }, skip: !shotsEnabled || !_orchards);
  }
}
