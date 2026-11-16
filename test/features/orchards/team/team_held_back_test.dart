import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';

import 'roles_vaults_fixture.dart';

class _Sync extends Fake implements OrchardSyncCoordinator {
  final kept = <String>[];
  final removed = <String>[];

  @override
  Future<bool> keepHeldBack(String orchardId, String kind, String key, String crateId) async {
    kept.add('$kind $key $crateId');
    return true;
  }

  @override
  Future<bool> removeHeldBack(String orchardId, String kind, String key, String crateId) async {
    removed.add('$kind $key $crateId');
    return true;
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const words = '1 item is held back: two vaults hold it and neither copy could move it';
  final row = find.byKey(const ValueKey('team-attn-held-back'));

  HeldBackItem item(String first, String second, {bool rights = true}) => HeldBackItem(kind: 'host', key: 'prod', copies: [
        HeldBackCopy(
          crateId: first,
          author: 'someone-1',
          editedAt: DateTime.utc(2026, 10, 30, 9).millisecondsSinceEpoch,
          name: 'Prod DB',
          mayKeep: rights,
          mayRemove: rights,
        ),
        HeldBackCopy(crateId: second, mayKeep: false, mayRemove: false),
      ]);

  testWidgets('an owner sees a quiet row, its list names each copy, and Keep and Remove are for the rights held',
      (tester) async {
    final team = await buildRolesVaultsTeam(tester);
    final owner = (await tester.runAsync(team.summary))!;
    final first = owner.crates.first.id;
    final second = owner.crates.last.id;
    final sync = _Sync();
    await pumpRolesVaults(tester, team, page: TeamPage.overview, extra: [
      teamHeldBackProvider(team.orchardId).overrideWith((ref) async => [item(first, second)]),
      orchardSyncProvider.overrideWithValue(sync),
    ]);
    expect(find.text(words), findsOneWidget);
    expect(row, findsOneWidget);

    await tester.tap(find.descendant(of: row, matching: find.text('Review')));
    await settleTeam(tester);
    expect(find.text('Items held back'), findsOneWidget);
    expect(find.text('Prod DB'), findsOneWidget);
    expect(find.textContaining('By '), findsOneWidget);
    expect(find.byKey(ValueKey('held-back-keep-$first')), findsOneWidget);
    expect(find.byKey(ValueKey('held-back-remove-$first')), findsOneWidget);
    expect(find.byKey(ValueKey('held-back-keep-$second')), findsNothing);
    expect(find.byKey(ValueKey('held-back-remove-$second')), findsNothing);

    await tester.tap(find.byKey(ValueKey('held-back-keep-$first')));
    await settleTeam(tester);
    expect(sync.kept, isEmpty, reason: 'it asks first');
    await tester.tap(find.text('Keep this one').last);
    await settleTeam(tester);
    expect(sync.kept, ['host prod $first']);

    await tester.tap(find.byKey(ValueKey('held-back-remove-$first')));
    await settleTeam(tester);
    await tester.tap(find.text('Remove').last);
    await settleTeam(tester);
    expect(sync.removed, ['host prod $first']);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an owner who holds no rights over any copy sees nothing', (tester) async {
    final team = await buildRolesVaultsTeam(tester);
    final owner = (await tester.runAsync(team.summary))!;
    final first = owner.crates.first.id;
    final second = owner.crates.last.id;

    await pumpRolesVaults(tester, team, page: TeamPage.overview, extra: [
      teamHeldBackProvider(team.orchardId).overrideWith((ref) async => [item(first, second, rights: false)]),
    ]);
    expect(row, findsNothing);
    expect(find.text(words), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a member sees nothing', (tester) async {
    final team = await buildRolesVaultsTeam(tester);
    final owner = (await tester.runAsync(team.summary))!;
    final first = owner.crates.first.id;
    final second = owner.crates.last.id;
    final member = OrchardSummary(
      id: owner.id,
      name: owner.name,
      role: team.member,
      can: const {},
      crates: owner.crates.where((c) => !c.ownersOnly).toList(),
      defaultCrateId: owner.defaultCrateId,
    );
    await pumpRolesVaults(tester, team, page: TeamPage.overview, as: member, extra: [
      teamHeldBackProvider(team.orchardId).overrideWith((ref) async => [item(first, second)]),
    ]);
    expect(row, findsNothing);
    expect(find.text(words), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}
