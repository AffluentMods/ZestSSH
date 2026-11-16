import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/features/networks/widgets/current_network_banner.dart';
import 'package:zestssh/features/networks/widgets/networks_list_view.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show RoleCan;
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/screens/port_forward/port_forward_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';
import 'package:zestssh/ui/widgets/phone_list.dart' show kPhonePageMaxWidth;
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/platform_utils.dart';

import '../features/orchards/team/roles_vaults_fixture.dart';
import '../helpers/quick_wins_fixture.dart';
import '../visual/shots_util.dart';

/// The 3.0 quick wins on a phone (430 by 932) and a tablet (1024 by 1366):
///
/// 1. Monospace means a value to copy (an address, a fingerprint, a command);
///    labels, counts, timers and words are in the app's own type.
/// 2. Chips are for filters and for what needs someone (a legacy key, a host
///    that does not answer, a host over a limit); the rest is plain text.
/// 3. Delete is never on a list row: a port forward's is on its own page, a
///    role's in its editor, each asking first.
/// 4. Monitor leads with the hosts that need attention, the others folded
///    to a few with "Show N more"; the Hosts list keeps the user's order.
///
/// And a computer keeps its look in every screen it shares with them (the
/// desktop stays exactly as it is).
const _mono = 'JetBrainsMono';

/// The font family the span holding [text] is drawn in (its own, or the one
/// it takes from above it), in the first piece of text that holds it.
String? _familyOf(WidgetTester tester, String text) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText, skipOffstage: false))) {
    String? found;
    void visit(InlineSpan span, TextStyle? above) {
      if (found != null || span is! TextSpan) return;
      final style = above == null ? span.style : above.merge(span.style);
      if (span.text != null && span.text!.contains(text)) {
        found = style?.fontFamily ?? '(none)';
        return;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }

    visit(rich.text, null);
    if (found != null) return found;
  }
  fail('No text holds "$text"');
}

/// Runs [body] drawn as a phone's or a tablet's ([touch]) or a computer's.
void _test(String name, Future<void> Function(WidgetTester tester) body, {bool touch = true}) {
  testWidgets(name, (tester) async {
    debugTouchLayout = touch;
    debugDefaultTargetPlatformOverride = touch ? TargetPlatform.android : TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugTouchLayout = null;
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> _pumpMonitor(WidgetTester tester, Size size) async {
  final theme = BuiltInThemes.getById('graphite');
  AppColors.applyTheme(theme.colorScheme);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fleet = QuickWinsFleet();
  final db = (await tester.runAsync(fleet.database))!;
  final prefs = (await tester.runAsync(fleet.preferences))!;
  addTearDown(() => tester.runAsync(db.close));
  await tester.pumpWidget(
      fleet.app(fleet.overrides(db, prefs), const ServerMonitorScreen(), theme: theme.toThemeData()));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unpumpMonitor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Future<void> _pumpToolbar(WidgetTester tester, Size size) async {
  tester.view.physicalSize = Size(size.width, 120);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: TerminalToolbar(
          sessionId: 's1',
          status: SessionStatus.connected,
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          port: 22,
          connectedAt: DateTime.now().subtract(const Duration(minutes: 12, seconds: 7)),
          onDisconnect: () {},
          onBack: () {},
          onSettings: () {},
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _unpumpToolbar(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();

  for (final (tag, size) in [('phone', quickWinsPhone), ('tablet', quickWinsTablet)]) {
    group('$tag ${size.width.toInt()}x${size.height.toInt()}', () {
      _test('Keys: who and what kind as plain text, a legacy key the one chip, the fingerprint monospace',
          (tester) async {
        await pumpQuickWins(tester, const KeysPhoneScreen(), size);
        final meta = tester.widget<Text>(find.byKey(const ValueKey('key-meta-k-ops')));
        expect(meta.textSpan!.toPlainText(), allOf(contains('deploy'), contains('Ed25519'), contains('Default')));
        expect(_familyOf(tester, 'deploy'), isNot(_mono), reason: 'a username is not a value to copy');
        expect(find.byKey(const ValueKey('key-legacy-k-nas')), findsOneWidget, reason: 'an RSA key needs someone');
        expect(find.byKey(const ValueKey('key-legacy-k-ops')), findsNothing);
        expect(find.text('DEFAULT'), findsNothing, reason: 'Default is plain text, not a badge');
        expect(_familyOf(tester, 'SHA256:Hq3v'), _mono, reason: 'a fingerprint is a value');
        // The theme's colours: the app's section headers, and no fixed teal
        // or amber; the fingerprint line in a text colour that reads (a
        // teal SSH KEYS, an amber PASSWORDS and a fingerprint at half
        // strength).
        expect(tester.widget(find.byKey(const ValueKey('keys-section-keys'))), isA<ZestSectionHeader>());
        expect(tester.widget(find.byKey(const ValueKey('keys-section-passwords'))), isA<ZestSectionHeader>());
        final fingerprint = tester.widget<Text>(find.byKey(const ValueKey('key-fingerprint-k-ops'))).style!.color!;
        expect(fingerprint, ZestTokens.textTertiary);
        expect(ZestColors.contrast(fingerprint, AppColors.surface), greaterThan(4.5));
        expect(tester.widget<Container>(find.byKey(const ValueKey('key-edge-k-ops'))).color, isNull,
            reason: 'a key with no colour of its own has no coloured edge');
        for (final fixed in [const Color(0xFF26A69A), const Color(0xFFE8A030)]) {
          final painted = [
            for (final w in tester.allWidgets)
              if ((w is Icon && w.color == fixed) ||
                  (w is Text && w.style?.color == fixed) ||
                  (w is Container && w.color == fixed) ||
                  (w is CircleAvatar && w.backgroundColor?.withValues(alpha: 1) == fixed))
                w,
          ];
          expect(painted, isEmpty, reason: '$fixed');
        }
        await unpumpQuickWins(tester);
      });

      _test('Port forwarding: no Delete on a row; the rule\'s own page has it, asks, then deletes', (tester) async {
        final (key: _, container: _, :db) = await pumpQuickWins(tester, const PortForwardsPhoneScreen(), size);
        expect(find.byIcon(LucideIcons.trash2), findsNothing, reason: 'Delete never sits on a list row');
        expect(find.text('AUTO'), findsNothing, reason: 'Auto is plain text, not a chip');
        expect(_familyOf(tester, '127.0.0.1:3000'), _mono, reason: 'addresses and ports are values');
        expect(_familyOf(tester, 'Manual'), isNot(_mono), reason: 'words are not');
        await tester.tap(find.text('Orders database'));
        await settleQuickWins(tester);
        await tester.tap(find.byKey(const ValueKey('forward-delete')));
        await settleQuickWins(tester);
        // It asks first.
        expect(find.text('Delete port forward'), findsWidgets);
        await tester.tap(find.text('Delete').last);
        await settleQuickWins(tester);
        final left = await tester.runAsync(() => db.select(db.portForwardRules).get());
        expect(left!.map((r) => r.id), isNot(contains('pf-db')));
        expect(find.byKey(const ValueKey('forward-delete')), findsNothing, reason: 'its page closed');
        await unpumpQuickWins(tester);
      });

      _test('Port forwarding, a rule\'s page: the app\'s own fields and switch, in one column, and it still checks',
          (tester) async {
        // (It was Material's outlined form with floating names, 1000 pixels
        // wide on a tablet.)
        await pumpQuickWins(tester, const PortForwardsPhoneScreen(), size);
        await tester.tap(find.text('Orders database'));
        await settleQuickWins(tester);
        for (final key in [
          'pf-touch-name',
          'pf-touch-port',
          'pf-touch-destination-host',
          'pf-touch-destination-port',
          'pf-touch-bind-address',
        ]) {
          expect(tester.widget(find.byKey(ValueKey(key))), isA<ZestField>(), reason: key);
        }
        for (final field in tester.widgetList<InputDecorator>(find.byType(InputDecorator))) {
          expect(field.decoration.labelText, isNull, reason: 'no floating name');
          expect(field.decoration.border, InputBorder.none, reason: 'no outlined box');
        }
        expect(find.byType(SwitchListTile), findsNothing);
        expect(
            find.descendant(of: find.byKey(const ValueKey('pf-touch-auto-start')), matching: find.byType(ZestSwitch)),
            findsOneWidget);
        final form = tester.getRect(
            find.descendant(of: find.byKey(const ValueKey('pf-touch-column')), matching: find.byType(ListView)).first);
        expect(form.width, size.width < kPhonePageMaxWidth ? size.width : kPhonePageMaxWidth);
        expect(form.center.dx, size.width / 2);
        // An empty port is still refused when it is saved.
        await tester.enterText(
            find.descendant(of: find.byKey(const ValueKey('pf-touch-port')), matching: find.byType(TextField)), '');
        await tester.tap(find.text('Save'));
        await settleQuickWins(tester);
        expect(
            find.descendant(of: find.byKey(const ValueKey('pf-touch-port')), matching: find.text('Required')),
            findsOneWidget);
        await unpumpQuickWins(tester);
      });

      _test('Hosts: a host that does not answer keeps a clear status, in the user\'s order', (tester) async {
        await pumpQuickWins(tester, const HomeScreen(), size);
        expect(find.byKey(const ValueKey('phone-host-unreachable-c4')), findsOneWidget);
        expect(find.byKey(const ValueKey('phone-host-unreachable-c0')), findsNothing);
        // The order is the list's own (by name here): nothing moves the host
        // with a problem up.
        final names = ['db-primary', 'edge-router', 'hypervisor-b', 'log-store', 'mac-studio', 'web-01', 'web-02'];
        final ys = [for (final n in names) tester.getTopLeft(find.text(n)).dy];
        expect(ys, orderedEquals([...ys]..sort()));
        expect(_familyOf(tester, 'deploy@192.168.10.31:22'), _mono, reason: 'an address is a value');
        expect(_familyOf(tester, 'HOSTS'), isNot(_mono), reason: 'a section label is not');
        await unpumpQuickWins(tester);
      });

      _test('Manage and Monitor: the network banner under the tab\'s own title, as on every tab', (tester) async {
        // (On Manage it sat above the title;
        // Monitor, the other tab with a bar of its own, had it there too.)
        await pumpQuickWins(tester, const HomeScreen(), size);
        final tabs = find.byKey(const ValueKey('phone-tab-bar'));
        // Hosts first, Manage the third tab, Monitor the fourth (a tablet below
        // the large screen has the phone's tabs since 4.0).
        for (final i in [0, 2, 3]) {
          await tester.tap(find.descendant(of: tabs, matching: find.byKey(ValueKey('phone-tab-$i'))));
          await settleQuickWins(tester);
          final banner = find.byType(CurrentNetworkBanner);
          expect(banner, findsOneWidget, reason: 'tab $i');
          final bars = find.byType(AppBar);
          expect(bars, findsOneWidget, reason: 'tab $i');
          expect(tester.getRect(banner).top, greaterThanOrEqualTo(tester.getRect(bars).bottom - 0.5), reason: 'tab $i');
        }
        await unpumpQuickWins(tester);
      });

      _test('Hosts and Networks: one column, as wide on both, centred, its search and its list on one left edge',
          (tester) async {
        // (On a tablet the hosts' search ran the full width over the centred
        // list, and Networks hugged the left at another width, as a design
        // review found.)
        final wide = size.width < kPhonePageMaxWidth ? size.width : kPhonePageMaxWidth;
        await pumpQuickWins(tester, const HomeScreen(), size);
        final search = tester.getRect(find.byType(QuickConnectBar));
        final list = tester.getRect(find.byType(PhoneHostsList));
        expect(search.left, list.left);
        expect(search.right, list.right);
        final hosts = tester.getRect(find.byKey(const ValueKey('phone-hosts')));
        expect(hosts.width, wide);
        expect(hosts.center.dx, size.width / 2);
        await unpumpQuickWins(tester);

        await pumpQuickWins(tester, const NetworksMobileScreen(), size);
        final networks = tester.getRect(
            find.descendant(of: find.byType(NetworksListView), matching: find.byType(ListView)).first);
        expect(networks.width, wide);
        expect(networks.center.dx, size.width / 2);
        await unpumpQuickWins(tester);
      });

      _test('Sessions: a group\'s count is plain text, its address monospace', (tester) async {
        await pumpQuickWins(tester, const HomeScreen(), size,
            extra: [activeSessionsProvider.overrideWith(QuickWinsSessions.new)]);
        await tester.tap(find.descendant(
            of: find.byKey(const ValueKey('phone-tab-bar')),
            // Sessions: the second tab since 3.1 (a tablet's third went with
            // its tabs, 4.0).
            matching: find.byKey(const ValueKey('phone-tab-1'))));
        await settleQuickWins(tester);
        expect(find.byKey(const ValueKey('sessions-group-count')), findsNWidgets(2));
        expect(tester.widget<Text>(find.text('192.168.10.21')).style?.fontFamily, _mono);
        await unpumpQuickWins(tester);
      });

      _test('Snippets: category, variables and Confirm as one line of plain text; the command monospace',
          (tester) async {
        await pumpQuickWins(tester, const Scaffold(body: SnippetsScreen()), size);
        final meta = find.byKey(const ValueKey('snippet-meta-s3'));
        expect(meta, findsOneWidget);
        expect(find.descendant(of: meta, matching: find.textContaining('Confirm')), findsOneWidget);
        expect(_familyOf(tester, 'df -h'), _mono);
        expect(_familyOf(tester, 'DEPLOY'), isNot(_mono));
        await unpumpQuickWins(tester);
      });

      _test('Snippets, its own page: New snippet and the menu in the bar, as every list page, the search alone',
          (tester) async {
        await pumpQuickWins(tester, const SnippetsPhoneScreen(), size);
        final bar = find.byType(AppBar);
        for (final key in const ['snippets-new', 'snippets-menu']) {
          // Once, in the bar (they sat beside the search field).
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
          expect(find.descendant(of: bar, matching: find.byKey(ValueKey(key))), findsOneWidget, reason: key);
        }
        expect(find.descendant(of: bar, matching: find.byType(TextField)), findsNothing);
        await unpumpQuickWins(tester);
      });

      _test('Monitor: problems first, the others folded to a few; chips only where a host needs someone',
          (tester) async {
        await _pumpMonitor(tester, size);
        final attention = find.byKey(const ValueKey('monitor-attention-header'));
        expect(attention, findsOneWidget);
        double y(String text) => tester.getTopLeft(find.text(text, skipOffstage: false)).dy;
        // Critical, then a warning, then a login missing; all before the others.
        expect(y('log-store'), lessThan(y('hypervisor-a')));
        expect(y('hypervisor-a'), lessThan(y('vpn-gateway')));
        expect(tester.getTopLeft(attention).dy, lessThan(y('log-store')));
        expect(find.widgetWithText(ZestStatusPill, 'Critical'), findsOneWidget);
        expect(find.byKey(const ValueKey('monitor-source-text-logs')), findsNothing, reason: 'every card was via SSH: none says it');
        expect(_familyOf(tester, '96%'), isNot(_mono), reason: 'a percentage is not a value to copy');
        expect(_familyOf(tester, '192.168.10.24:22'), _mono);
        // The others: three, then the rest behind Show 6 more.
        final more = find.byKey(const ValueKey('monitor-show-more'));
        await tester.scrollUntilVisible(more, 300, scrollable: find.byType(Scrollable).first);
        expect(find.descendant(of: more, matching: find.text('Show 6 more')), findsOneWidget);
        expect(find.text('Healthy', skipOffstage: false), findsWidgets);
        expect(find.widgetWithText(ZestStatusPill, 'Healthy'), findsNothing, reason: 'Healthy is plain text');
        await tester.tap(more);
        await tester.pump();
        // All nine now, Show fewer under them.
        await tester.scrollUntilVisible(find.byKey(const ValueKey('monitor-show-fewer')), 300,
            scrollable: find.byType(Scrollable).first);
        expect(find.byKey(const ValueKey('monitor-show-more')), findsNothing);
        await _unpumpMonitor(tester);
      });

      _test('Monitor: its chips fade out at the edge where more wait, its cards where they go under the bar',
          (tester) async {
        // (The chips were cut hard at a phone's edge, and a card scrolled
        // under the background monitoring bar left a sliver of itself, as a
        // design review found.)
        await _pumpMonitor(tester, size);
        final chips = find.byKey(const ValueKey('monitor-summary-fade'));
        expect(tester.widget<ZestScrollFade>(chips).axis, Axis.horizontal);
        expect(
            find.descendant(
                of: chips, matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right)),
            findsOneWidget);
        final list = find.byKey(const ValueKey('monitor-list-fade'));
        expect(tester.widget<ZestScrollFade>(list).axis, Axis.vertical);
        expect(find.descendant(of: list, matching: find.byKey(const ValueKey('monitor-attention-header'))), findsOneWidget);
        await _unpumpMonitor(tester);
      });

      _test('Terminal bar: the timer is plain text in the app\'s own type', (tester) async {
        await _pumpToolbar(tester, size);
        final duration = find.byKey(const ValueKey('terminal-bar-duration'));
        expect(duration, findsOneWidget);
        expect(tester.widget<Text>(duration).style?.fontFamily, isNot(_mono));
        await _unpumpToolbar(tester);
      });

      _test('Team roles: no Delete on a row; the role\'s editor has it and asks where its members go',
          (tester) async {
        final team = await buildRolesVaultsTeam(tester);
        await pumpRolesVaults(tester, team,
            page: TeamPage.roles, size: size, body: const TeamPhonePageScreen(page: TeamPage.roles));
        expect(find.byKey(const ValueKey('delete')), findsNothing);
        await tester.tap(find.descendant(
            of: find.byKey(ValueKey('role-${team.developers}')), matching: find.byKey(const ValueKey('edit'))));
        await settleTeam(tester);
        await tester.tap(find.byKey(const ValueKey('role-delete')));
        await settleTeam(tester);
        expect(find.text('Delete Developers?'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });

      _test('Team roles: an owner opens Admin like a role (no name to type), asked about before the first change',
          (tester) async {
        final team = await buildRolesVaultsTeam(tester);
        await pumpRolesVaults(tester, team,
            page: TeamPage.roles, size: size, body: const TeamPhonePageScreen(page: TeamPage.roles));
        await tester.tap(find.byKey(const ValueKey('role-admin')));
        await settleTeam(tester);
        expect(find.byKey(const ValueKey('role-name')), findsNothing, reason: "Admin's name is Admin's");
        expect(find.byKey(const ValueKey('role-delete')), findsNothing);
        expect(find.byKey(const ValueKey('role-admin-reset')), findsNothing, reason: 'nothing changed yet');
        final remove = find.byKey(const ValueKey('role-can-${RoleCan.remove}'));
        await tester.ensureVisible(remove);
        await tester.pumpAndSettle();
        await tester.tap(remove);
        await tester.pump();
        await tester.tap(find.text('Save'));
        await settleTeam(tester);
        expect(find.text('Change the Admin role?'), findsOneWidget);
        await tester.tap(find.text('Change Admin'));
        await settleTeam(tester);
        final record = team.server.recordOf(team.orchardId);
        expect(record.adminRole!.can, RoleCan.all.difference({RoleCan.remove}));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });

      _test('Team roles: the role\'s editor has Duplicate, which opens a new role filled in from it',
          (tester) async {
        final team = await buildRolesVaultsTeam(tester);
        await pumpRolesVaults(tester, team,
            page: TeamPage.roles, size: size, body: const TeamPhonePageScreen(page: TeamPage.roles));
        final before = team.server.recordOf(team.orchardId).roles.length;
        await tester.tap(find.descendant(
            of: find.byKey(ValueKey('role-${team.developers}')), matching: find.byKey(const ValueKey('edit'))));
        await settleTeam(tester);
        final duplicate = find.byKey(const ValueKey('role-duplicate'));
        await tester.ensureVisible(duplicate);
        await tester.pumpAndSettle();
        await tester.tap(duplicate);
        await settleTeam(tester);
        final name = find.descendant(of: find.byKey(const ValueKey('role-name')), matching: find.byType(TextField));
        expect(tester.widget<TextField>(name).controller!.text, 'Developers (copy)');
        await tester.tap(find.text('Save'));
        await settleTeam(tester);
        expect(team.server.recordOf(team.orchardId).roles.length, before + 1);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
    });
  }

  // "Waiting for you" broke
  // "sam@example.com" across two lines on a phone.
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('${platform.name} 430x932: Waiting for you keeps an address on one line, its actions beside it',
        (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.runAsync(loadShotFonts);
        final team = await buildRolesVaultsTeam(tester, samByCode: true);
        await pumpRolesVaults(tester, team,
            page: TeamPage.members,
            size: quickWinsPhone,
            body: const TeamPhonePageScreen(page: TeamPage.members));
        final address = find.byKey(ValueKey('waiting-address-${team.samInvite}'));
        expect(find.descendant(of: address, matching: find.text('sam@example.com')), findsOneWidget);
        final paragraph =
            tester.renderObject<RenderParagraph>(find.descendant(of: address, matching: find.byType(RichText)).first);
        expect(paragraph.didExceedMaxLines, isFalse, reason: 'whole');
        expect(tester.getSize(address).height, lessThan(24), reason: 'one line');
        expect(find.byKey(ValueKey('invite-confirm-${team.samInvite}')), findsOneWidget);
        expect(find.byKey(ValueKey('invite-withdraw-${team.samInvite}')), findsOneWidget);
        expect(find.byType(TeamRolePill), findsNothing, reason: 'the role is plain text');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group('a computer keeps its look', () {
    _test('the section label is monospace and its count a badge', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: ZestSectionHeader(label: 'Hosts', count: 7))));
      expect(_familyOf(tester, 'HOSTS'), _mono);
      expect(find.byKey(const ValueKey('section-count-text')), findsNothing);
      expect(find.text('7'), findsOneWidget);
    }, touch: false);

    _test('the terminal bar\'s timer is a monospace chip', (tester) async {
      await _pumpToolbar(tester, const Size(1440, 900));
      expect(find.byKey(const ValueKey('terminal-bar-duration')), findsNothing);
      expect(_familyOf(tester, ':'), _mono);
      await _unpumpToolbar(tester);
    }, touch: false);

    _test('Server monitor: no sections, a pill for every host, via SSH a chip', (tester) async {
      await _pumpMonitor(tester, const Size(1440, 1400));
      expect(find.byKey(const ValueKey('monitor-attention-header')), findsNothing);
      expect(find.byKey(const ValueKey('monitor-show-more')), findsNothing);
      expect(find.widgetWithText(ZestStatusPill, 'Healthy'), findsWidgets);
      expect(find.byKey(const ValueKey('monitor-source-text-logs')), findsNothing);
      expect(_familyOf(tester, '96%'), _mono);
      await _unpumpMonitor(tester);
    }, touch: false);

    _test('Snippets: the meta chips', (tester) async {
      await pumpQuickWins(tester, const Scaffold(body: SnippetsScreen()), const Size(1440, 900));
      expect(find.byKey(const ValueKey('snippet-meta-s3')), findsNothing);
      expect(find.text('Confirm'), findsOneWidget);
      await unpumpQuickWins(tester);
    }, touch: false);

    _test('the port forward editor is a dialog with no Delete in it', (tester) async {
      await pumpQuickWins(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPortForwardEditor(
                  context,
                  initial: const PortForwardResult(
                      id: 'pf-db',
                      type: 'local',
                      bindAddress: '127.0.0.1',
                      bindPort: 5433,
                      remoteHost: 'localhost',
                      remotePort: 5432,
                      autoStart: false,
                      label: 'Orders database'),
                  onDelete: () async => true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
          const Size(1440, 900));
      await tester.tap(find.text('open'));
      await settleQuickWins(tester);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byKey(const ValueKey('forward-delete')), findsNothing);
      await unpumpQuickWins(tester);
    }, touch: false);

    _test('the Roles dialog keeps Delete on each role\'s row', (tester) async {
      final team = await buildRolesVaultsTeam(tester);
      await pumpRolesVaults(tester, team,
          page: TeamPage.roles, body: SingleChildScrollView(child: OrchardRolesView(orchardId: team.orchardId)));
      expect(find.byKey(const ValueKey('delete')), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, touch: false);

    _test('the Members dialog keeps its chips (You, the role, Keys checked)', (tester) async {
      final team = await buildRolesVaultsTeam(tester, samByCode: true);
      await pumpRolesVaults(tester, team,
          page: TeamPage.members, body: SingleChildScrollView(child: OrchardMembersView(orchardId: team.orchardId)));
      expect(find.byKey(ValueKey('waiting-address-${team.samInvite}')), findsNothing);
      expect(find.byType(TeamRolePill), findsWidgets);
      expect(find.byKey(const ValueKey('member-status-text')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, touch: false);
  });
}
