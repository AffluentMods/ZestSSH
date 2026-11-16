import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/bulk/host_bulk_edit.dart';
import 'package:zestssh/features/hosts/bulk/host_bulk_edit_panel.dart';
import 'package:zestssh/features/hosts/state/kex_refused_hosts.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart' show teamWatchedCratesProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The bulk editor ("Edit 42 hosts"):
/// every field as the hosts have it now, mixed values said as the design
/// says them, only what is changed written, and a team's vault the person may
/// only connect in left out, or, where the database refuses it, the whole
/// edit refused as a single edit is.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _loadGeistSans() async {
  final loader = FontLoader('GeistSans');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/GeistSans-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load().timeout(const Duration(seconds: 30));
}

const _legacy = '11111111-1111-4111-8111-111111111111';
const _production = '22222222-2222-4222-8222-222222222222';
const _orchard = '44444444-4444-4444-8444-444444444444';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);
  final at = DateTime(2026, 10, 28);

  late AppDatabase db;
  late ProviderContainer container;
  late List<(HostBulkOutcome, int)> applied;
  late List<Set<String>> unselected;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> host(String id, {String? key, int port = 22, bool compat = false}) =>
      db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(id),
        host: Value('10.20.4.${id.length}'),
        port: Value(port),
        identityId: Value(key),
        compatibilityMode: Value(compat),
        createdAt: Value(at),
        updatedAt: Value(at),
      ));

  /// The editor of [ids], on a computer (or a phone's sheet's layout, with
  /// [phone]); in a team's space with [team] (what each host's vault is, and
  /// what this account may do in each vault as the screen reads it).
  Future<void> pump(
    WidgetTester tester,
    List<String> ids, {
    bool phone = false,
    Set<String> refused = const {},
    ({Map<String, String> vaults, Set<String> legacySwitches, Set<String> productionSwitches})? team,
    Future<void> Function()? seed,
  }) async {
    await tester.runAsync(_loadGeistSans);
    tester.view.physicalSize = phone ? const Size(412, 900) : const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: team != null);
    addTearDown(db.close);
    if (team != null) {
      await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
          "VALUES (1, ?, 'Platform team', 'member-role', 1, ?)",
          [_orchard, _legacy]);
      // The database's own record: Production lets this account connect only.
      await db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
          '''(?, 'Legacy', 'edit', '["add","connect","edit","reveal"]', 1), '''
          '''(?, 'Production', 'connect', '["connect"]', 1)''',
          [_legacy, _production]);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    }
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-root', label: 'deploy key', username: 'root', authMethod: 'publicKey', createdAt: at));
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-admin', label: 'admin key', username: 'admin', authMethod: 'publicKey', createdAt: at));
    await seed?.call();
    if (team != null) {
      for (final e in team.vaults.entries) {
        await db.customStatement(
            "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, 3)",
            [e.key, e.value]);
      }
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    }
    applied = [];
    unselected = [];
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
      if (team != null) ...[
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(_orchard)),
        activeOrchardProvider.overrideWithValue(AsyncData(OrchardSummary(
          id: _orchard,
          name: 'Platform team',
          role: 'member-role',
          defaultCrateId: _legacy,
          crates: [
            CrateSummary(id: _legacy, name: 'Legacy', level: 'edit', switches: team.legacySwitches),
            CrateSummary(id: _production, name: 'Production', level: 'connect', switches: team.productionSwitches),
          ],
        ))),
        itemCratesProvider.overrideWith((ref, kind) => Stream.value(kind == 'host' ? team.vaults : const {})),
        teamWatchedCratesProvider.overrideWith((ref, id) async => const <String>{}),
      ],
    ]);
    addTearDown(container.dispose);
    for (final id in refused) {
      container.read(kexRefusedHostsProvider.notifier).refused(id);
    }
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: phone
              ? HostBulkEditPanel(
                  phone: true,
                  hostIds: ids,
                  onClose: () {},
                  onApplied: (o, s) => applied.add((o, s)),
                  onUnselect: unselected.add,
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Expanded(child: SizedBox()),
                    HostBulkEditPanel(
                      hostIds: ids,
                      onClose: () {},
                      onApplied: (o, s) => applied.add((o, s)),
                      onUnselect: unselected.add,
                    ),
                  ],
                ),
        ),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester);
  }

  testWidgets('every field starts as the hosts have it: one value "on all", two "on" each, more as different keys',
      (tester) async {
    await pump(tester, ['db-01', 'db-02', 'app-01'], seed: () async {
      await host('db-01', key: 'k-root');
      await host('db-02', key: 'k-root');
      await host('app-01', key: 'k-admin', port: 2222);
    });
    expect(find.text(l10n.bulkEditTitle(3)), findsOneWidget);
    expect(find.text(l10n.bulkEditSubtitle), findsOneWidget);
    expect(find.text(l10n.bulkKeep('root on 2, admin on 1')), findsOneWidget, reason: 'the design\'s "root on 30, admin on 12"');
    final port = tester.widget<TextField>(find.byKey(const ValueKey('bulk-field-port')));
    expect(port.decoration?.hintText, l10n.bulkKeep('22 on 2, 2222 on 1'));
    expect(find.text(l10n.bulkKeep('deploy key on 2, admin key on 1')), findsOneWidget);
    expect(find.text(l10n.bulkKeep(l10n.bulkOnAll('none', 3))), findsOneWidget, reason: 'no jump host on any');
    expect(find.text(l10n.bulkNow(l10n.bulkOnAll('off', 3))), findsOneWidget, reason: 'Compatibility mode now');
    expect(find.text(l10n.bulkNoChanges), findsOneWidget);
    final apply = tester.widget(find.byKey(const ValueKey('bulk-edit-apply')));
    expect((apply as dynamic).onPressed, isNull, reason: 'nothing changed: nothing to apply');
    expect(find.text(l10n.bulkSharedOnly), findsNothing, reason: 'your own space has no vaults');
    await finish(tester);
  });

  testWidgets('more than two keys between them: "3 different keys"', (tester) async {
    await pump(tester, ['a', 'b', 'c'], seed: () async {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'k-ops', label: 'ops key', username: 'ops', authMethod: 'publicKey', createdAt: at));
      await host('a', key: 'k-root');
      await host('b', key: 'k-admin');
      await host('c', key: 'k-ops');
    });
    expect(find.text(l10n.bulkKeep(l10n.bulkDifferentKeys(3))), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a field changed is said, and only it is written; Keep as is takes it back', (tester) async {
    await pump(tester, ['db-01', 'db-02', 'app-01'], seed: () async {
      await host('db-01', key: 'k-root');
      await host('db-02', key: 'k-root');
      await host('app-01', key: 'k-admin', port: 2222);
    });
    await tap(tester, find.byKey(const ValueKey('bulk-compat-all')));
    expect(find.text(l10n.bulkChanged), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-compat-warning')), findsOneWidget, reason: 'what turning it on costs');
    expect(find.text(l10n.bulkChangeCount(1)), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('bulk-keep-bulk-card-compat')));
    expect(find.text(l10n.bulkChanged), findsNothing);
    expect(find.text(l10n.bulkNoChanges), findsOneWidget);

    await tap(tester, find.byKey(const ValueKey('bulk-compat-all')));
    await tester.enterText(find.byKey(const ValueKey('bulk-field-port')), '70000');
    await tester.pump();
    expect(find.text(l10n.connectionPortInvalid), findsOneWidget);
    expect((tester.widget(find.byKey(const ValueKey('bulk-edit-apply'))) as dynamic).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('bulk-field-port')), '');
    await tester.pump();
    expect(find.text(l10n.bulkApply(3)), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('bulk-edit-apply')));
    expect(applied, hasLength(1));
    expect(applied.single.$1.changed, ['db-01', 'db-02', 'app-01']);
    final r = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
    expect({for (final c in r) c.id: (c.compatibilityMode, c.port, c.identityId)}, {
      'db-01': (true, 22, 'k-root'),
      'db-02': (true, 22, 'k-root'),
      'app-01': (true, 2222, 'k-admin'),
    });
    await finish(tester);
  });

  testWidgets('hosts refused for an old key exchange: "On for the 1 that needs it", named, and only it is turned on',
      (tester) async {
    await pump(tester, ['legacy-db-01', 'legacy-db-02', 'legacy-app-02'], refused: {'legacy-db-02'}, seed: () async {
      for (final id in ['legacy-db-01', 'legacy-db-02', 'legacy-app-02']) {
        await host(id);
      }
    });
    expect(find.text(l10n.bulkCompatNeeding(1)), findsOneWidget);
    expect(find.text(l10n.bulkCompatRefused('legacy-db-02')), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('bulk-compat-needing')));
    await tap(tester, find.byKey(const ValueKey('bulk-edit-apply')));
    final r = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
    expect({for (final c in r) c.id: c.compatibilityMode},
        {'legacy-db-01': false, 'legacy-db-02': true, 'legacy-app-02': false});
    await finish(tester);
  });

  testWidgets('tags: Add, Remove or Replace, the tags typed', (tester) async {
    await pump(tester, ['a', 'b'], seed: () async {
      await host('a');
      await host('b');
      await db.connectionTagsDao.setTagsForConnection('a', ['linux']);
      await db.connectionTagsDao.setTagsForConnection('b', ['linux']);
    });
    expect(find.text(l10n.bulkNow(l10n.bulkOnAll('linux', 2))), findsOneWidget);
    final input = find.descendant(of: find.byKey(const ValueKey('bulk-tags-field')), matching: find.byType(TextField));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'eol');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text(l10n.bulkChangeCount(1)), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('bulk-edit-apply')));
    expect(await tester.runAsync(() => db.connectionTagsDao.getTagsForConnection('b')), ['eol', 'linux']);
    await finish(tester);
  });

  testWidgets('on a phone: its sheet\'s layout, the cards first, the fields under them', (tester) async {
    await pump(tester, ['a', 'b', 'c'], phone: true, seed: () async {
      for (final id in ['a', 'b', 'c']) {
        await host(id, key: 'k-root');
      }
    });
    expect(find.text(l10n.bulkEditSubtitleShort), findsOneWidget);
    final compat = tester.getTopLeft(find.byKey(const ValueKey('bulk-card-compat'))).dy;
    final tags = tester.getTopLeft(find.byKey(const ValueKey('bulk-card-tags'))).dy;
    final user = tester.getTopLeft(find.byKey(const ValueKey('bulk-field-username'))).dy;
    expect(compat < tags && tags < user, isTrue, reason: 'Compatibility mode, Tags, then the connection');
    // Every host would be turned on alike: the phone's switch.
    expect(find.byKey(const ValueKey('bulk-compat-switch')), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('bulk-compat-switch')));
    expect(find.text(l10n.bulkChanged), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  group('a team\'s vaults', () {
    final vaults = {
      'legacy-db-01': _legacy,
      'legacy-db-02': _legacy,
      'legacy-pay-01': _production,
      'legacy-pay-02': _production,
    };
    Future<void> seed() async {
      for (final id in vaults.keys) {
        await host(id);
      }
    }

    testWidgets('a host the role only connects to is left out, said with its vault; Unselect them; the rest written',
        (tester) async {
      await pump(tester, [...vaults.keys],
          team: (
            vaults: vaults,
            legacySwitches: {CrateSwitches.add, CrateSwitches.connect, CrateSwitches.edit},
            productionSwitches: {CrateSwitches.connect},
          ),
          seed: seed);
      expect(find.text(l10n.bulkSkippedTitle(2)), findsOneWidget);
      expect(find.text(l10n.bulkSkippedIn(2, 'legacy-pay-01, legacy-pay-02', 'Production')), findsOneWidget);
      expect(find.text(l10n.bulkSharedOnly), findsOneWidget);
      expect(find.text(l10n.bulkCompatAll(2)), findsOneWidget, reason: 'the design\'s "On for all 40": what is written');
      await tap(tester, find.byKey(const ValueKey('bulk-skipped-unselect')));
      expect(unselected, [
        {'legacy-pay-01', 'legacy-pay-02'},
      ]);
      await tap(tester, find.byKey(const ValueKey('bulk-compat-all')));
      expect(find.text(l10n.bulkApply(2)), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('bulk-edit-apply')));
      expect(applied.single.$2, 2, reason: 'two skipped');
      final r = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
      expect({for (final c in r) c.id: c.compatibilityMode},
          {'legacy-db-01': true, 'legacy-db-02': true, 'legacy-pay-01': false, 'legacy-pay-02': false});
      await finish(tester);
    });

    testWidgets('where the vault refuses the write itself, the edit is refused as a single edit is, and nothing written',
        (tester) async {
      // The screen's copy says Production may be edited; the database's own
      // record says connect only: its write guard refuses, as it refuses a
      // single edit of the host.
      final both = {'legacy-db-01': _legacy, 'legacy-pay-01': _production};
      await pump(tester, [...both.keys],
          team: (
            vaults: both,
            legacySwitches: {CrateSwitches.add, CrateSwitches.connect, CrateSwitches.edit},
            productionSwitches: {CrateSwitches.connect, CrateSwitches.edit},
          ),
          seed: () async {
        await host('legacy-db-01');
        await host('legacy-pay-01');
      });
      expect(find.byKey(const ValueKey('bulk-skipped')), findsNothing, reason: 'as the screen reads it, both may change');
      await tap(tester, find.byKey(const ValueKey('bulk-compat-all')));
      await tap(tester, find.byKey(const ValueKey('bulk-edit-apply')));
      expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget, reason: 'the words a single edit has');
      expect(applied, isEmpty);
      final r = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
      expect({for (final c in r) c.id: c.compatibilityMode}, {'legacy-db-01': false, 'legacy-pay-01': false},
          reason: 'one transaction: not even the host that may be changed');
      await tester.pump(const Duration(seconds: 12));
      await finish(tester);
    });
  });
}
