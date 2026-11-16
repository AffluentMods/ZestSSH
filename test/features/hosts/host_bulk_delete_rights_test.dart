import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/widgets/host_bulk_action_bar.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

/// Delete for the hosts selected on a computer (the bar's Delete, and the
/// Delete key through it), in a team's vault: as every list's selection
/// deletes (keys, snippets, port forwards), only the hosts the role may
/// delete go; the question says how many stay; one the database refuses is
/// named afterwards; both stay selected. It asked for every selected host and
/// left the refusal to the database, whose error ended the batch.

const _team = '44444444-4444-4444-8444-444444444444';
const _legacy = '11111111-1111-4111-8111-111111111111';
const _production = '22222222-2222-4222-8222-222222222222';
const _archive = '33333333-3333-4333-8333-333333333333';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// h1 and h3 are in Legacy (the role may do anything), h2 in Production
  /// (the role connects only), h4 in Archive (the screen says the role may
  /// delete; the database's own record says it may not).
  Future<void> pump(WidgetTester tester, Set<String> selected) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
          "VALUES (1, ?, 'Platform team', 'member-role', 1, ?)",
          [_team, _legacy]);
      await db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
          '''(?, 'Legacy', 'manage', '["add","connect","delete","edit","reveal"]', 1), '''
          '''(?, 'Production', 'connect', '["connect"]', 1), '''
          '''(?, 'Archive', 'edit', '["add","connect","edit"]', 1)''',
          [_legacy, _production, _archive]);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      for (final (id, label, crate) in const [
        ('h1', 'web-legacy-1', _legacy),
        ('h2', 'db-production', _production),
        ('h3', 'web-legacy-2', _legacy),
        ('h4', 'db-archive', _archive),
      ]) {
        await db.connectionsDao.insertConnection(ConnectionsCompanion(
          id: Value(id),
          label: Value(label),
          host: const Value('10.0.0.5'),
          port: const Value(22),
          protocol: const Value('ssh'),
          createdAt: Value(DateTime.utc(2026)),
          updatedAt: Value(DateTime.utc(2026)),
        ));
        await db.customStatement(
            "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, 3)",
            [id, crate]);
      }
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });
    addTearDown(() => db.close());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      syncIsActiveProvider.overrideWith((ref) async => true),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      activeSpaceProvider.overrideWith((ref) => const OrchardSpace(_team)),
      // What the screen reads: Production lets this account connect only;
      // Archive, as far as the screen knows, lets it delete.
      activeOrchardProvider.overrideWithValue(const AsyncData(OrchardSummary(
        id: _team,
        name: 'Platform team',
        role: 'member-role',
        defaultCrateId: _legacy,
        crates: [
          CrateSummary(id: _legacy, name: 'Legacy', level: 'manage', switches: CrateSwitches.all),
          CrateSummary(id: _production, name: 'Production', level: 'connect', switches: {CrateSwitches.connect}),
          CrateSummary(id: _archive, name: 'Archive', level: 'manage', switches: CrateSwitches.all),
        ],
      ))),
      itemCratesProvider.overrideWith((ref, kind) => Stream.value(kind == 'host'
          ? const {'h1': _legacy, 'h2': _production, 'h3': _legacy, 'h4': _archive}
          : const <String, String>{})),
    ]);
    addTearDown(container.dispose);
    final select = container.read(hostMultiSelectProvider.notifier)..enter();
    selected.forEach(select.toggle);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: HostBulkActionBar(groups: [], shownOrder: ['h1', 'h2', 'h3', 'h4']),
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<List<String>> hostsLeft(WidgetTester tester) async =>
      [for (final c in (await tester.runAsync(() => db.connectionsDao.getAll()))!) c.id]..sort();

  Set<String> selected() => container.read(hostMultiSelectProvider).selected;
  Finder inQuestion(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

  testWidgets('a host the role may not delete is said in the question, is not deleted and stays selected; the others go',
      (tester) async {
    await pump(tester, {'h1', 'h2', 'h3'});
    await tester.tap(find.byKey(const ValueKey('bulk-delete')));
    await settle(tester);
    // One question, in red, for the two that may go; db-production stays.
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.destructive);
    expect(inQuestion(l10n.hostBulkActionDeleteTitle), findsOneWidget);
    expect(inQuestion(l10n.hostBulkActionDeleteConfirm(2)), findsOneWidget);
    expect(inQuestion(l10n.selectDeleteStay(1)), findsOneWidget);
    await tester.tap(inQuestion(l10n.hostBulkActionDeleteButton(2)));
    await settle(tester);
    expect(await hostsLeft(tester), ['h2', 'h4']);
    expect(container.read(hostMultiSelectProvider).active, isTrue);
    expect(selected(), {'h2'});
    expect(find.text(l10n.selectDeletedToast(l10n.transferWhatHosts(2))), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a host the database refuses is named afterwards and stays selected; the rest go', (tester) async {
    await pump(tester, {'h1', 'h4'});
    await tester.tap(find.byKey(const ValueKey('bulk-delete')));
    await settle(tester);
    expect(inQuestion(l10n.hostBulkActionDeleteConfirm(2)), findsOneWidget);
    expect(inQuestion(l10n.selectDeleteStay(1)), findsNothing);
    await tester.tap(inQuestion(l10n.hostBulkActionDeleteButton(2)));
    await settle(tester);
    expect(await hostsLeft(tester), ['h2', 'h3', 'h4']);
    expect(selected(), {'h4'});
    expect(find.text('${l10n.selectDeletedSome(1, 2, 'db-archive')}. ${l10n.orchardWriteNotAllowed}'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('where the role may delete none of the selected, Delete is off and the Delete key asks nothing',
      (tester) async {
    await pump(tester, {'h2'});
    await tester.tap(find.byKey(const ValueKey('bulk-delete')));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    // The Delete key (the page calls the bar's deleteSelected): said, not asked.
    final bar = tester.state<HostBulkActionBarState>(find.byType(HostBulkActionBar));
    await tester.runAsync(() async {
      final done = bar.deleteSelected();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      return done;
    });
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget);
    expect(await hostsLeft(tester), ['h1', 'h2', 'h3', 'h4']);
    expect(selected(), {'h2'});
    await finish(tester);
  });
}
