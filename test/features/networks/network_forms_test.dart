import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/networks/engine/network_state.dart' show debugWifiNamesReadHere;
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/state/network_controller.dart';
import 'package:zestssh/features/networks/widgets/network_detail_pane.dart';
import 'package:zestssh/features/networks/widgets/network_simple_form.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Wrap [child] with the providers + localizations the network forms need,
/// stubbing the connections stream so no database is required. The forms
/// watch recording mode (masked name and SSID fields), which is seeded from
/// preferences, so those are supplied too.
Widget _host(Widget child, SharedPreferences prefs) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      connectionsWithDetailsProvider.overrideWith(
        (ref) => Stream.value(const <ConnectionWithDetails>[]),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

Network _net(List<NetworkTrigger> triggers) => Network(
      id: 'n1',
      name: 'Home',
      color: GroupColor.blue,
      icon: LucideIcons.home,
      triggers: triggers,
      isFallback: false,
    );

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  late AppLocalizations l10n;
  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  Widget liveForm(NetworkEditController c) => SingleChildScrollView(
        child: AnimatedBuilder(
          animation: c,
          builder: (_, _) => NetworkSimpleForm(controller: c),
        ),
      );

  // Simple mode as designed: every
  // rule as a row, quick ways to add one, how hosts are reached, the hosts
  // with a rule of their own.
  group('NetworkSimpleForm', () {
    testWidgets('every rule is a row; the quick chips add Ethernet, a VPN, Tailscale as its range', (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = NetworkEditController();
      c.bind(_net(const [SubnetTrigger('10.0.0.0/24'), SsidTrigger('Office demo')]),
          overrideRows: const [], mode: EditorMode.simple);
      addTearDown(c.dispose);

      await tester.pumpWidget(_host(liveForm(c), prefs));
      await tester.pump();
      expect(c.mode, EditorMode.simple, reason: 'two rules are no reason to leave Simple');
      expect(find.text(l10n.netEdIpLabel), findsOneWidget);
      expect(find.text(l10n.netEdWifiLabel), findsOneWidget);
      expect(find.text(l10n.netEdAnyRule), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('network-add-ethernet')));
      await tester.tap(find.byKey(const ValueKey('network-add-tailscale')));
      await tester.pump();
      expect(c.triggers.map((t) => t.toTrigger()).skip(2), const [
        ConnectivityTrigger(ConnectivityKind.ethernet),
        SubnetTrigger('100.64.0.0/10'),
      ]);
      expect(find.text(l10n.netRuleEthernet), findsOneWidget);
      expect(find.text(l10n.netEdTailscaleNote), findsOneWidget, reason: 'what it really checks is said');
    });

    testWidgets("on a Mac no Wi-Fi name is offered, and the note is the Mac's, not the phones'", (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      debugWifiNamesReadHere = false;
      addTearDown(() => debugWifiNamesReadHere = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final c = NetworkEditController();
      c.bind(_net(const [SubnetTrigger('10.0.0.0/24')]), overrideRows: const [], mode: EditorMode.simple);
      addTearDown(c.dispose);
      await tester.pumpWidget(_host(liveForm(c), prefs));
      await tester.pump();
      expect(find.text(l10n.netWifiNamesNotOnMac), findsOneWidget);
      expect(find.text(l10n.netWifiNamesNotOnPhones), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('hosts directly, or through a jump host; the line says which', (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = NetworkEditController();
      c.bind(_net(const [SubnetTrigger('10.0.0.0/24')]), overrideRows: const [], mode: EditorMode.simple);
      addTearDown(c.dispose);

      await tester.pumpWidget(_host(liveForm(c), prefs));
      await tester.pump();
      expect(find.text(l10n.netEdDirectLine), findsOneWidget);
      expect(find.byKey(const ValueKey('network-jump-host')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('network-reach-jump')));
      await tester.pump();
      expect(find.byKey(const ValueKey('network-jump-host')), findsOneWidget);
      expect(find.text(l10n.netEdPickJumpHost), findsOneWidget);

      c.setBringUpVpn('gone');
      await tester.tap(find.byKey(const ValueKey('network-reach-direct')));
      await tester.pump();
      expect(c.bringUpVpn, isNull, reason: 'Directly takes the jump host away');
    });

    testWidgets('host rules: none says so; each one says what is different here', (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = NetworkEditController();
      c.bind(_net(const [SubnetTrigger('10.0.0.0/24')]), overrideRows: const [], mode: EditorMode.simple);
      addTearDown(c.dispose);

      await tester.pumpWidget(_host(liveForm(c), prefs));
      await tester.pump();
      expect(find.text(l10n.netEdHostRulesNone), findsOneWidget);

      c.addOverride('h1').skip = true;
      c.markDirty();
      await tester.pump();
      expect(find.text(l10n.netEdHostRulesNone), findsNothing);
      expect(find.text(l10n.netEdHostSkipped), findsOneWidget);
      await tester.tap(find.text(l10n.netEdHostEdit));
      await tester.pump();
      expect(c.mode, EditorMode.advanced, reason: "a host rule's own fields are Advanced's");
    });
  });

  group('NetworkDetailPane', () {
    testWidgets('no selection renders the ready-to-fill new-network editor',
        (tester) async {
      final c = NetworkEditController();
      addTearDown(c.dispose);

      await tester.pumpWidget(_host(
          NetworkDetailPane(
            controller: c,
            hasSelection: false,
            onNew: () {},
            onSave: () async => true,
            onClose: () {},
            onDelete: () {},
            onModeChanged: (_) {},
          ),
          prefs));

      // The 1.7 redesign dropped the standalone empty state: with nothing
      // selected the pane IS the ready-to-fill new-network editor - a
      // "New network" title over the Simple form - never a blank pane.
      expect(find.byType(NetworkSimpleForm), findsOneWidget);
      expect(find.text(l10n.zestNetworkNewLabel), findsWidgets);
    });
  });
}
