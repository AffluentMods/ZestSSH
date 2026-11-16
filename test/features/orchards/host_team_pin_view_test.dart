import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/hostkeys/host_team_pin_view.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/orchard_db_fixture.dart';

/// The host panel's team pins (3.0): the Crate that keeps each and
/// the key everyone trusts there; someone who may delete in that Crate can
/// remove it, after saying yes; nobody else sees the button; the Tree shows
/// nothing. A pin made through a jump host shows beside the direct one,
/// each saying which connections it is for, and is removed by itself. Only
/// the pins of the host's own Crate are shown: another Crate's pin of the
/// same address is not the host's.

const _viewCrate = '77777777-7777-4777-8777-777777777777';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  SSHHostKey key(int seed) =>
      SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => (seed + i) & 0xff)));

  /// The host [id], saved at web1.example.com:22, in [crate], as the sync
  /// engine leaves it (inside the engine's own writes).
  Future<void> hostIn(AppDatabase db, String id, String crate) async {
    final at = DateTime(2026, 10, 18);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: 'web1.example.com', createdAt: at, updatedAt: at));
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, 1)", [id, crate]);
  }

  /// An Orchard whose host web1 (h-web1, at web1.example.com:22) is in
  /// [crate], with a pin of its own there for direct connections, as another
  /// device's sync leaves them.
  Future<AppDatabase> orchard(WidgetTester tester, String crate) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await tester.runAsync(() async {
      await seedOrchardAsOwner(db);
      await db.customStatement(
          "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'View', 'connect', ?, 1)",
          [_viewCrate, jsonEncode(switchList(levelSwitches(CrateLevel.connect)))]);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await hostIn(db, 'h-web1', crate);
      final id = teamHostKeyId('web1.example.com', 22, null, crateId: crate);
      await db.customStatement(
          "INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, 'web1.example.com', 22, '', ?)",
          [id, jsonEncode([hostKeyLine(key(1))])]);
      await db.customStatement(
          "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('hostkey', ?, ?, 1)",
          [id, crate]);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });
    return db;
  }

  Future<void> pump(WidgetTester tester, AppDatabase db, {bool recording = false, String hostId = 'h-web1'}) async {
    // A jump host's address is said as recording mode has addresses said.
    SharedPreferences.setMockInitialValues({'recording_mode_enabled': recording});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [databaseProvider.overrideWithValue(db), sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: HostTeamPinBox(hostId: hostId, host: 'web1.example.com', port: 22)),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
  }

  // The pin of web1.example.com:22 for direct connections in Fixture, and each pin's box and button on the panel.
  final direct = teamHostKeyId('web1.example.com', 22, null, crateId: kFixtureCrateId);
  Finder box(String id) => find.byKey(ValueKey('host-team-pin-$id'));
  Finder unpin(String id) => find.byKey(ValueKey('host-team-unpin-$id'));

  /// Takes the panel away and lets what it watched close before the
  /// database does: a jump host's address is said as recording mode has it,
  /// and recording mode watches the hosts of the space on screen.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  /// A pin of web1.example.com:22 for connections through [viaScope], as
  /// another device's sync leaves it, in [crate].
  Future<void> pinnedThrough(WidgetTester tester, AppDatabase db, String viaScope, SSHHostKey k, String crate) async {
    await tester.runAsync(() async {
      final id = teamHostKeyId('web1.example.com', 22, viaScope, crateId: crate);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await db.customStatement(
          "INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, 'web1.example.com', 22, ?, ?)",
          [id, viaScope, jsonEncode([hostKeyLine(k)])]);
      await db.customStatement(
          "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('hostkey', ?, ?, 1)",
          [id, crate]);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });
  }

  testWidgets('the Crate and key everyone trusts; removed after a yes by someone who may delete', (tester) async {
    final db = await orchard(tester, kFixtureCrateId);
    addTearDown(() => tester.runAsync(db.close));
    await pump(tester, db);
    expect(find.text(l10n.hostPanelKeyTeamPinned('Fixture')), findsOneWidget);
    expect(find.textContaining('ssh-ed25519  SHA256:'), findsOneWidget);
    await tester.tap(unpin(direct));
    await tester.pumpAndSettle();
    expect(find.text(l10n.hostPanelUnpinTitle), findsOneWidget);
    expect(find.text(l10n.hostPanelUnpinBody('Fixture')), findsOneWidget, reason: 'alone, no route said');
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => TeamHostKeys(db).pinFor('web1.example.com', 22, crateId: kFixtureCrateId)),
        isNotNull,
        reason: 'declined: kept');
    await tester.tap(unpin(direct));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.hostPanelUnpin).last);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    expect(await tester.runAsync(() => TeamHostKeys(db).pinFor('web1.example.com', 22, crateId: kFixtureCrateId)),
        isNull);
    expect(find.byKey(const ValueKey('host-team-pin')), findsNothing);
  });

  testWidgets('someone who may not delete there sees it, without the button; the Tree shows nothing', (tester) async {
    final db = await orchard(tester, _viewCrate);
    addTearDown(() => tester.runAsync(db.close));
    await pump(tester, db);
    final viewDirect = teamHostKeyId('web1.example.com', 22, null, crateId: _viewCrate);
    expect(find.text(l10n.hostPanelKeyTeamPinned('View')), findsOneWidget);
    expect(box(viewDirect), findsOneWidget);
    expect(unpin(viewDirect), findsNothing);

    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(tree.close));
    await pump(tester, tree);
    expect(find.byKey(const ValueKey('host-team-pin')), findsNothing);
  });

  // A session through a jump host pins its key for that route (the pin's id
  // ends in the route, as known hosts scope it), and the panel asked only
  // for the pin of direct connections: one made through a jump host was
  // never shown, and nothing could remove it.
  testWidgets('a pin made through a jump host shows beside the direct one, each saying its route, and is removed by '
      'itself', (tester) async {
    final db = await orchard(tester, kFixtureCrateId);
    addTearDown(() => tester.runAsync(db.close));
    // Pinned as a session through the jump host pins it.
    await tester.runAsync(() => TeamHostKeys(db)
        .pin('web1.example.com', 22, key(2), viaScope: 'bastion.example.com:22', crateId: kFixtureCrateId));
    final through = teamHostKeyId('web1.example.com', 22, 'bastion.example.com:22', crateId: kFixtureCrateId);
    await pump(tester, db);
    expect(find.text(l10n.hostPanelKeyTeamPinned('Fixture')), findsNWidgets(2));
    expect(box(direct), findsOneWidget);
    expect(box(through), findsOneWidget);
    expect(tester.getTopLeft(box(direct)).dy, lessThan(tester.getTopLeft(box(through)).dy), reason: 'the direct one first');
    final directWords = find.text(l10n.hostPanelTeamPinDirect);
    final throughWords = find.text(l10n.hostPanelTeamPinThrough('bastion.example.com:22'));
    expect(find.descendant(of: box(direct), matching: directWords), findsOneWidget);
    expect(find.descendant(of: box(through), matching: throughWords), findsOneWidget);
    expect(find.descendant(of: box(direct), matching: throughWords), findsNothing);
    expect(find.descendant(of: box(through), matching: directWords), findsNothing);
    // Each shows its own key.
    final fingerprints = [
      for (final id in [direct, through])
        (tester.widget<Text>(find.descendant(of: box(id), matching: find.textContaining('ssh-ed25519  SHA256:'))))
            .data,
    ];
    expect(fingerprints.toSet(), hasLength(2));

    // Removed after a yes, from its own box, the dialog saying which: the direct one stays.
    await tester.tap(unpin(through));
    await tester.pumpAndSettle();
    expect(find.text(l10n.hostPanelUnpinTitle), findsOneWidget);
    expect(find.text('${l10n.hostPanelTeamPinThrough('bastion.example.com:22')}\n\n${l10n.hostPanelUnpinBody('Fixture')}'),
        findsOneWidget);
    await tester.tap(find.text(l10n.hostPanelUnpin).last);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    expect(
        await tester.runAsync(() => TeamHostKeys(db)
            .pinFor('web1.example.com', 22, viaScope: 'bastion.example.com:22', crateId: kFixtureCrateId)),
        isNull);
    expect(await tester.runAsync(() => TeamHostKeys(db).pinFor('web1.example.com', 22, crateId: kFixtureCrateId)),
        isNotNull);
    expect(box(through), findsNothing);
    expect(box(direct), findsOneWidget);
    // Alone again, the direct one says nothing of routes, as before.
    expect(directWords, findsNothing);
    expect(unpin(direct), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a pin through a jump host known by its id, in a Crate where this account may not delete: shown, '
      'without the button', (tester) async {
    final db = await orchard(tester, _viewCrate);
    addTearDown(() => tester.runAsync(db.close));
    await pinnedThrough(tester, db, 'via:3f6c2a90-1b2d-4e5f-8a9b-0c1d2e3f4a5b', key(3), _viewCrate);
    final viewDirect = teamHostKeyId('web1.example.com', 22, null, crateId: _viewCrate);
    final through = teamHostKeyId('web1.example.com', 22, 'via:3f6c2a90-1b2d-4e5f-8a9b-0c1d2e3f4a5b', crateId: _viewCrate);
    await pump(tester, db);
    for (final id in [viewDirect, through]) {
      expect(find.descendant(of: box(id), matching: find.text(l10n.hostPanelKeyTeamPinned('View'))), findsOneWidget);
      expect(unpin(id), findsNothing);
    }
    expect(find.descendant(of: box(through), matching: find.text(l10n.hostPanelTeamPinThroughJumpHost)),
        findsOneWidget);
    expect(find.descendant(of: box(viewDirect), matching: find.text(l10n.hostPanelTeamPinDirect)), findsOneWidget);
  });

  testWidgets("in recording mode, the jump host's address is masked, as every address is", (tester) async {
    addTearDown(() => Redactor.instance.enabled = false);
    final db = await orchard(tester, kFixtureCrateId);
    addTearDown(() => tester.runAsync(db.close));
    await pinnedThrough(tester, db, 'bastion.example.com:22', key(2), kFixtureCrateId);
    final through = teamHostKeyId('web1.example.com', 22, 'bastion.example.com:22', crateId: kFixtureCrateId);
    await pump(tester, db, recording: true);
    final masked = Redactable.address('bastion.example.com:22').display;
    expect(masked, isNot(contains('bastion')));
    expect(find.descendant(of: box(through), matching: find.text(l10n.hostPanelTeamPinThrough(masked))), findsOneWidget);
    expect(find.textContaining('bastion'), findsNothing);
    await finish(tester);
  });

  // The panel listed every pin of the host's address, whichever Crate it was
  // in: a pin someone made in another Crate for the same address showed as
  // the host's.
  testWidgets("a pin another Crate made for the host's address is not shown as the host's; the host's own Crate's is",
      (tester) async {
    // web1 is in View, with View's pin; h-fixture, at the same address, is in Fixture.
    final db = await orchard(tester, _viewCrate);
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(() async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await hostIn(db, 'h-fixture', kFixtureCrateId);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });
    final viewDirect = teamHostKeyId('web1.example.com', 22, null, crateId: _viewCrate);
    await pump(tester, db, hostId: 'h-fixture');
    expect(find.byKey(const ValueKey('host-team-pin')), findsNothing, reason: "View's pin is not h-fixture's");

    // Pinned in Fixture, h-fixture shows Fixture's pin, and only it; web1 shows View's.
    await tester.runAsync(() => TeamHostKeys(db).pin('web1.example.com', 22, key(2), crateId: kFixtureCrateId));
    await pump(tester, db, hostId: 'h-fixture');
    expect(box(direct), findsOneWidget);
    expect(box(viewDirect), findsNothing);
    expect(find.text(l10n.hostPanelKeyTeamPinned('Fixture')), findsOneWidget);
    expect(find.text(l10n.hostPanelKeyTeamPinned('View')), findsNothing);
    expect(unpin(direct), findsOneWidget);
    await pump(tester, db);
    expect(box(viewDirect), findsOneWidget);
    expect(box(direct), findsNothing);

    // A host this space does not have shows none.
    await pump(tester, db, hostId: 'h-elsewhere');
    expect(find.byKey(const ValueKey('host-team-pin')), findsNothing);
    await finish(tester);
  });

  test('in each of the twelve languages, the words for each route are their own, and in the language', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      final said = [
        words.hostPanelTeamPinDirect,
        words.hostPanelTeamPinThrough('bastion.example.com:22'),
        words.hostPanelTeamPinThroughJumpHost,
      ];
      expect(said.toSet(), hasLength(3), reason: '$locale');
      expect(said[1], contains('bastion.example.com:22'), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      expect(said[0], isNot(en.hostPanelTeamPinDirect), reason: '$locale');
      expect(said[1], isNot(en.hostPanelTeamPinThrough('bastion.example.com:22')), reason: '$locale');
      expect(said[2], isNot(en.hostPanelTeamPinThroughJumpHost), reason: '$locale');
    }
  });
}
