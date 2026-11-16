import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/widgets/current_network_banner.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// The network banner over a phone's tabs (4.0):
/// only where a network of the person's own is in use, never for the
/// Default every place falls back to; forced by the person, the Default
/// shows, with the way back to Automatic.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const office = Network(
    id: 'n-office',
    name: 'Office',
    color: GroupColor.blue,
    icon: LucideIcons.building,
    triggers: [SsidTrigger('office-wifi')],
    isFallback: false,
  );
  final fallback = Network.systemDefault();

  Future<void> pump(WidgetTester tester,
      {required List<Network> networks, required Network inUse, String? forced}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        allNetworksProvider.overrideWith((ref) => Stream.value(networks)),
        effectiveNetworkProvider.overrideWithValue(AsyncData(inUse)),
        manualNetworkOverrideIdProvider.overrideWithValue(forced),
        detectedNetworkMatchProvider.overrideWith((ref) => const Stream.empty()),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: Column(children: [CurrentNetworkBanner()])),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder banner() => find.bySemanticsLabel(RegExp(en.networkBannerSemantics('.*')));

  testWidgets('a network of the person\'s own in use: the banner names it', (tester) async {
    await pump(tester, networks: [office, fallback], inUse: office);
    expect(find.text('Office'), findsOneWidget);
    expect(banner(), findsOneWidget);
  });

  testWidgets('the Default in use, by itself: no banner', (tester) async {
    await pump(tester, networks: [office, fallback], inUse: fallback);
    expect(find.text(fallback.name), findsNothing);
    expect(banner(), findsNothing);
    expect(tester.getSize(find.byType(CurrentNetworkBanner)).height, 0);
  });

  testWidgets('the Default forced by the person: the banner, with Forced, to go back to Automatic', (tester) async {
    await pump(tester, networks: [office, fallback], inUse: fallback, forced: fallback.id);
    expect(find.text(fallback.name), findsOneWidget);
    expect(find.text(en.networkBannerForcedChip), findsOneWidget);
  });

  testWidgets('no network of the person\'s own: no banner, as before', (tester) async {
    await pump(tester, networks: [fallback], inUse: fallback);
    expect(banner(), findsNothing);
  });
}
