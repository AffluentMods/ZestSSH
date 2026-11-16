import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/pages/network_editor_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

class _Repo extends Fake implements NetworkRepository {
  final updated = <Network>[];

  @override
  Future<void> create(Network network) => update(network);

  @override
  Future<void> update(Network network) async => updated.add(network);
}

/// The network editor's "Auto-connect VPN host" (found by a check of
/// the docs against the code): it was saved and read into a
/// connection's route, and nothing ever brought a VPN up, so it is gone. A
/// network that has one keeps it through a save.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets('the editor offers no VPN to bring up, and a save keeps what a network had', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = _Repo();
    const office = Network(
      id: 'office',
      name: 'Office',
      color: GroupColor.gray,
      icon: LucideIcons.wifi,
      triggers: [SubnetTrigger('10.50.0.0/24')],
      isFallback: false,
      bringUpVpn: 'vpn-host',
    );
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        networkRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: NetworkEditorPage(network: office, onClose: () {})),
      ),
    ));
    await tester.pump();
    expect(find.text('Auto-connect VPN host'), findsNothing);
    expect(find.text('Before reaching hosts on this network, bring up this VPN host'), findsNothing);
    // No select of hosts (the app's selects took the place of Material's
    // dropdowns; the guard test keeps those out).
    expect(find.byType(ZestSelect<String?>), findsNothing);

    await tester.tap(find.text(en.networkEditorSave));
    await tester.pump();
    await tester.pump();
    expect(repo.updated.single.bringUpVpn, 'vpn-host');
  });
}
