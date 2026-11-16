import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/screens/session/screen_team_rules.dart';
import 'package:zestssh/providers/core_providers.dart';

/// The team's two rules about remote screens as a host's editor reads them
/// (4.0): from the list of teams, which is read again at every sync.
/// While it is, the editor keeps what it knew: it does not offer a direct
/// connection or a live clipboard switch for those frames.
void main() {
  OrchardSummary team(String id, RecordRules rules) =>
      OrchardSummary(id: id, name: 'Acme', role: 'member', crates: const [], defaultCrateId: null, rules: rules);

  test('your own space has no rules; a team has its own, and another team\'s are not its', () async {
    const both = RecordRules(screensSshOnly: true, screensLockRedirections: true);
    final c = ProviderContainer(overrides: [
      orchardSummariesProvider.overrideWith((ref) async => [team('t-1', both), team('t-2', RecordRules.none)]),
    ]);
    addTearDown(c.dispose);
    await c.read(orchardSummariesProvider.future);
    expect(c.read(screenTeamRulesProvider), ScreenTeamRules.none);
    c.read(activeSpaceProvider.notifier).state = const OrchardSpace('t-1');
    expect(c.read(screenTeamRulesProvider), const ScreenTeamRules(sshOnly: true, lockRedirections: true));
    c.read(activeSpaceProvider.notifier).state = const OrchardSpace('t-2');
    expect(c.read(screenTeamRulesProvider), ScreenTeamRules.none);
    c.read(activeSpaceProvider.notifier).state = const OrchardSpace('t-gone');
    expect(c.read(screenTeamRulesProvider), ScreenTeamRules.none);
  });

  test('while the list of teams is read again, the rules are what they were, then what it says now', () async {
    var rules = const RecordRules(screensSshOnly: true);
    var gate = Completer<void>()..complete();
    // (What the real list watches: a number every sync raises.)
    final version = StateProvider<int>((ref) => 0);
    final c = ProviderContainer(overrides: [
      orchardSummariesProvider.overrideWith((ref) async {
        ref.watch(version);
        await gate.future;
        return [team('t-1', rules)];
      }),
      activeSpaceProvider.overrideWith((ref) => const OrchardSpace('t-1')),
    ]);
    addTearDown(c.dispose);
    final seen = <ScreenTeamRules>[];
    c.listen(screenTeamRulesProvider, (_, now) => seen.add(now), fireImmediately: true);
    await c.read(orchardSummariesProvider.future);
    expect(c.read(screenTeamRulesProvider), const ScreenTeamRules(sshOnly: true));
    // (Before the list was read the first time nothing is known: from here on it is.)
    seen.clear();

    // A sync: the list is read again, and that takes a while.
    gate = Completer<void>();
    rules = const RecordRules(screensSshOnly: true, screensLockRedirections: true);
    c.read(version.notifier).state++;
    await Future<void>.delayed(Duration.zero);
    expect(c.read(orchardSummariesProvider).isLoading, isTrue);
    expect(c.read(activeOrchardProvider).valueOrNull, isNull, reason: 'the team on screen is nobody meanwhile');
    expect(c.read(screenTeamRulesProvider), const ScreenTeamRules(sshOnly: true), reason: 'the rule is not forgotten');

    gate.complete();
    await c.read(orchardSummariesProvider.future);
    expect(c.read(screenTeamRulesProvider), const ScreenTeamRules(sshOnly: true, lockRedirections: true));
    expect(seen, isNot(contains(ScreenTeamRules.none)), reason: 'at no moment after that were there no rules');
  });
}
