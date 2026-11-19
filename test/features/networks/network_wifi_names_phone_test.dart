import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/pages/network_editor_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';

class _Repo extends Fake implements NetworkRepository {
  @override
  Future<void> update(Network network) async {}
}

/// Wi-Fi name rules on a phone: Android and iOS give the
/// name only to an app with location access, which ZestSSH does not ask for
/// (it tracks nobody), so such a rule could never match there, while the
/// editor offered it and said to grant a permission the app never declares.
/// A phone offers no Wi-Fi name rule, says why and what to use instead, and
/// reads no Wi-Fi name.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  tearDown(() => debugWifiNamesReadHere = null);

  Future<void> open(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const office = Network(
      id: 'office',
      name: 'Office',
      color: GroupColor.gray,
      icon: LucideIcons.wifi,
      triggers: [SubnetTrigger('10.50.0.0/24'), SsidTrigger('Office demo')],
      isFallback: false,
    );
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        networkRepositoryProvider.overrideWithValue(_Repo()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: NetworkEditorPage(network: office, onClose: () {})),
      ),
    ));
    await tester.pump();
  }

  testWidgets('a phone offers no Wi-Fi name rule and says why', (tester) async {
    debugWifiNamesReadHere = false;
    await open(tester);
    expect(find.widgetWithText(InkWell, en.networkEditorTriggerSsid), findsNothing);
    expect(find.byKey(const ValueKey('network-wifi-names-not-read')), findsOneWidget);
    expect(find.text(en.netWifiNamesNotOnPhones), findsOneWidget);
    expect(find.text('Wi-Fi name detection requires location permission on Android'), findsNothing,
        reason: 'it said to grant a permission the app never declares');
  });

  testWidgets("a Mac offers no Wi-Fi name rule either, and says why in a Mac's words (it showed the phones' note)",
      (tester) async {
    debugWifiNamesReadHere = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await open(tester);
    expect(find.widgetWithText(InkWell, en.networkEditorTriggerSsid), findsNothing);
    expect(find.byKey(const ValueKey('network-wifi-names-not-read')), findsOneWidget);
    expect(find.text(en.netWifiNamesNotOnMac), findsOneWidget);
    expect(find.text(en.netWifiNamesNotOnPhones), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a computer offers it, with what reading the name may take', (tester) async {
    debugWifiNamesReadHere = true;
    await open(tester);
    expect(find.text(en.networkEditorTriggerSsid), findsWidgets);
    expect(find.text(en.netWifiNameComputerNote), findsOneWidget);
    expect(find.text(en.netWifiNamesNotOnPhones), findsNothing);
  });

  test('a phone reads no Wi-Fi name', () async {
    debugWifiNamesReadHere = false;
    final state = await readCurrentNetworkState(requestSsid: true);
    expect(state.ssid, isNull);
  });
}
