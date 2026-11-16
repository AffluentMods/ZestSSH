import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart' show crateAuthoritiesProvider;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart' show teamWatchedCratesProvider;
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';

/// A vault's Show hosts (Team > Vaults) shows its hosts on the Hosts page.
/// It made that vault the one new hosts go to as well, so looking at a
/// vault's hosts quietly changed where the next host was saved.
void main() {
  const staging = CrateSummary(id: 'c-staging', name: 'Staging', level: 'manage', switches: {CrateSwitches.add});
  const prod = CrateSummary(id: 'c-prod', name: 'Production', level: 'manage', switches: {CrateSwitches.add});
  const orchard = OrchardSummary(
      id: 'o1', name: 'Acme', role: 'owner', crates: [staging, prod], defaultCrateId: 'c-staging', status: 'active');

  testWidgets("a vault's Show hosts shows its hosts and leaves the vault new hosts go to as it was", (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final placement = _Placement();
    late WidgetRef seen;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardSummariesProvider.overrideWith((ref) async => [orchard]),
        teamWatchedCratesProvider('o1').overrideWith((ref) async => const <String>{}),
        crateAuthoritiesProvider('o1').overrideWith((ref) async => const {}),
        cratePlacementProvider.overrideWithValue(placement),
        hostCratesProvider.overrideWith((ref) => Stream.value(const {})),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            seen = ref;
            return const SingleChildScrollView(child: OrchardCratesView(orchardId: 'o1'));
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Production, then its menu (4.0: one vault at a time, Show its hosts in
    // its menu).
    await tester.tap(find.byKey(const ValueKey('vault-item-c-prod')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('crate-more-c-prod')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('crate-show-hosts-c-prod')));
    await tester.pumpAndSettle();

    expect(seen.read(selectedCrateFilterProvider), 'c-prod', reason: "the Hosts page shows Production's hosts");
    expect(placement.defaults, isEmpty, reason: 'new hosts still go to Staging');
  });
}

/// Keeps every vault made the one new items go to; nothing else is asked.
class _Placement implements CratePlacement {
  final defaults = <String>[];

  @override
  Future<void> setDefaultCrate(String crateId) async => defaults.add(crateId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
