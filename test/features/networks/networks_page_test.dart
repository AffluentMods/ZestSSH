import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/engine/network_detector.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/pages/networks_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';

/// The computer's Networks page as its design
/// draws it: ACTIVE NOW with why and where this device is, and a way to
/// make a network for it; the networks numbered in the order they are
/// checked, each saying when it applies and what hosts do there; a network
/// being made marked "Not saved yet"; Default last. (All made up.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<AppDatabase> seeded(WidgetTester tester) async => (await tester.runAsync(() async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final repo = NetworkRepository(db.networksDao);
        await repo.ensureDefaultExists();
        await repo.create(const Network(
            id: 'n-example',
            name: 'Example',
            color: GroupColor.blue,
            icon: LucideIcons.building,
            triggers: [SsidTrigger('test')],
            isFallback: false));
        return db;
      }))!;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('Active now says why and where; its button makes a network for this Wi-Fi, not saved yet', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await seeded(tester);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fallback = Network.systemDefault();
    debugWifiNamesReadHere = true;
    addTearDown(() => debugWifiNamesReadHere = null);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentNetworkStateProvider.overrideWith((ref) async => const NetworkState(
            localAddresses: ['10.50.0.42'], connectivityKind: ConnectivityKind.wifi, ssid: 'harbor-5G')),
        detectedNetworkProvider.overrideWith((ref) => Stream.value(fallback)),
        detectedNetworkMatchProvider
            .overrideWith((ref) => Stream.value(NetworkMatch(network: fallback, reason: const AlwaysTrigger()))),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: NetworksPage()),
      ),
    ));
    await settle(tester);

    expect(find.text('${en.netPageWhyDefault} ${en.netPageOnWifi('harbor-5G', '10.50.0.0/24')}'), findsOneWidget);
    expect(find.text('${en.netPageWhen(en.netRuleWifi('test'))} · ${en.netPageDirect}'), findsOneWidget);
    expect(find.text(en.netPageAlwaysLast), findsOneWidget);
    expect(find.text(en.netPageNotSaved), findsNothing, reason: 'an empty new network has no card');

    await tester.tap(find.byKey(const ValueKey('network-make-for-here')));
    await settle(tester);
    expect(find.text(en.netPageNotSaved), findsOneWidget);
    expect(find.byKey(const ValueKey('network-draft-card')), findsOneWidget);
    expect(find.text(en.netEdWifiLabel), findsOneWidget);
    expect(find.text('harbor-5G'), findsWidgets, reason: 'the Wi-Fi as its rule and its name');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(db.close);
  });

  test('a VPN is up whatever the connection under it', () async {
    const vpn = Network(
        id: 'v', name: 'VPN', color: GroupColor.blue, icon: LucideIcons.shield,
        triggers: [ConnectivityTrigger(ConnectivityKind.vpn)], isFallback: false);
    final detector = NetworkDetector(_Repo([vpn, Network.systemDefault()]));
    expect(
        (await detector.detectFromState(
                const NetworkState(localAddresses: [], connectivityKind: ConnectivityKind.wifi, vpnUp: true)))
            .id,
        'v');
    expect(
        (await detector.detectFromState(const NetworkState(localAddresses: [], connectivityKind: ConnectivityKind.wifi)))
            .isFallback,
        isTrue);
  });
}

class _Repo extends Fake implements NetworkRepository {
  _Repo(this.networks);

  final List<Network> networks;

  @override
  Future<List<Network>> list() async => networks;
}
