import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/move_hosts.dart';
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
import 'package:zestssh/utils/redactor.dart';

/// Group changes in a team's vault the role does not allow:
/// Move to group from the selection and New group from it
/// moved every selected host and let the team database's refusal leave the
/// handler, with nothing said; New group made the group first, so a refused
/// move left an empty group queued for the whole team. Now only the hosts
/// the role may change move, the rest is said, a refusal the screen did not
/// see coming is said too, and the new group and its moves are one
/// transaction.

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
  /// change it; the database's own record says it may not). Group "Web" is
  /// there already, in Legacy.
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
          '''(?, 'Archive', 'connect', '["add","connect"]', 1)''',
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
      await db.connectionGroupsDao
          .insertGroup(ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: DateTime.utc(2026)));
      await db.customStatement(
          "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('group', 'g1', ?, 3)",
          [_legacy]);
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
      // Archive, as far as the screen knows, lets it do anything.
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
          : kind == 'group'
              ? const {'g1': _legacy}
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
          body: Column(
            children: [
              _NewGroupButton(),
              Spacer(),
              HostBulkActionBar(groups: [], shownOrder: ['h1', 'h2', 'h3', 'h4']),
            ],
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

  Future<Map<String, String?>> groupOf(WidgetTester tester) async =>
      {for (final c in (await tester.runAsync(() => db.connectionsDao.getAll()))!) c.id: c.groupId};

  Future<List<String>> groups(WidgetTester tester) async =>
      [for (final g in (await tester.runAsync(() => db.connectionGroupsDao.getAll()))!) g.name]..sort();

  Set<String> selected() => container.read(hostMultiSelectProvider).selected;

  Future<void> moveTo(WidgetTester tester, String? groupId) async {
    final bar = tester.state<HostBulkActionBarState>(find.byType(HostBulkActionBar));
    await tester.runAsync(() async {
      final done = bar.moveSelectedTo(groupId);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      return done;
    });
    await settle(tester);
  }

  testWidgets('Move to group moves the hosts the role may change and says the rest stay', (tester) async {
    await pump(tester, {'h1', 'h2'});
    await moveTo(tester, 'g1');
    final now = await groupOf(tester);
    expect(now['h1'], 'g1');
    expect(now['h2'], isNull);
    expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a move the database refuses is said, and the host stays selected', (tester) async {
    await pump(tester, {'h4'});
    await moveTo(tester, 'g1');
    expect((await groupOf(tester))['h4'], isNull);
    expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget);
    expect(selected(), {'h4'});
    await finish(tester);
  });

  testWidgets('New group from a selection the role may not move asks no name and makes no group', (tester) async {
    await pump(tester, {'h2'});
    await tester.tap(find.text('new group'));
    await settle(tester);
    expect(find.text(l10n.hostsHomeNewGroupTitle), findsNothing);
    expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget);
    expect(await groups(tester), ['Web']);
    await finish(tester);
  });

  testWidgets('New group whose move the database refuses leaves no empty group behind', (tester) async {
    await pump(tester, {'h1', 'h4'});
    await tester.tap(find.text('new group'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Databases');
    await tester.tap(find.text(l10n.hostsHomeCreateAndMove));
    await settle(tester);
    expect(await groups(tester), ['Web']);
    final now = await groupOf(tester);
    expect(now['h1'], isNull);
    expect(now['h4'], isNull);
    expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget);
    await finish(tester);
  });

  testWidgets('New group from hosts the role may change makes it and moves them', (tester) async {
    await pump(tester, {'h1', 'h3'});
    await tester.tap(find.text('new group'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'Databases');
    await tester.tap(find.text(l10n.hostsHomeCreateAndMove));
    await settle(tester);
    expect(await groups(tester), ['Databases', 'Web']);
    final now = await groupOf(tester);
    expect(now['h1'], isNotNull);
    expect(now['h3'], now['h1']);
    await finish(tester);
  });
}

class _NewGroupButton extends ConsumerWidget {
  const _NewGroupButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
        onPressed: () => createGroupAndMoveHosts(context, ref, ref.read(hostMultiSelectProvider).selected),
        child: const Text('new group'),
      );
}
