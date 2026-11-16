import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/redactor.dart';

/// Selecting keys on a computer (3.4), as the hosts are selected: Select on
/// the page's line, a box on each row, a click (or its box) in or out, Shift
/// for a range, Ctrl or Cmd to add one (starting to select), Ctrl+A for every
/// key shown, Esc to stop; the bar at the list's foot; Delete asks once for
/// the batch, in red, and in a team's vault deletes only what the role may,
/// naming what stays.

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

  /// alpha, beta and delta are SSH keys; gamma is a password (its own section,
  /// after the keys).
  Future<void> pump(WidgetTester tester, {bool team = false}) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: team);
      final at = DateTime(2026, 11, 1);
      if (team) {
        await db.customStatement(
            'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
            "VALUES (1, ?, 'Platform team', 'member-role', 1, ?)",
            [_team, _legacy]);
        // The database's own record: Archive does not let this account delete.
        await db.customStatement(
            'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
            '''(?, 'Legacy', 'manage', '["add","connect","delete","edit","reveal"]', 1), '''
            '''(?, 'Production', 'connect', '["connect"]', 1), '''
            '''(?, 'Archive', 'edit', '["add","connect","edit"]', 1)''',
            [_legacy, _production, _archive]);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      }
      for (final (id, label, method) in const [
        ('k1', 'alpha key', 'publicKey'),
        ('k2', 'beta key', 'publicKey'),
        ('k3', 'gamma password', 'password'),
        ('k4', 'delta key', 'publicKey'),
      ]) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: id, label: label, username: 'ops', authMethod: method, createdAt: at));
      }
      if (team) {
        for (final (key, crate) in const [('k1', _legacy), ('k2', _production), ('k3', _legacy), ('k4', _archive)]) {
          await db.customStatement(
              "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('key', ?, ?, 3)",
              [key, crate]);
        }
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      }
    });
    addTearDown(() => db.close());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      syncIsActiveProvider.overrideWith((ref) async => true),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      if (team) ...[
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(_team)),
        // What the screen reads: Production lets this account connect only;
        // Archive, as far as the screen knows, lets it delete (its database
        // says otherwise).
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
        itemCratesProvider.overrideWith((ref, kind) => Stream.value(
            kind == 'key' ? const {'k1': _legacy, 'k2': _production, 'k3': _legacy, 'k4': _archive} : const {})),
      ],
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: KeysView()),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  Set<String> selected() => container.read(keySelectionProvider).selected;
  Finder row(String id) => find.byKey(ValueKey('key-row-menu-$id'));
  Finder box(String id) => find.byKey(ValueKey('key-row-box-$id'));

  Future<void> click(WidgetTester tester, Finder f, {LogicalKeyboardKey? holding}) async {
    if (holding != null) await tester.sendKeyDownEvent(holding);
    await tester.tap(f, kind: PointerDeviceKind.mouse);
    if (holding != null) await tester.sendKeyUpEvent(holding);
    await settle(tester);
  }

  Future<List<String>> keysLeft(WidgetTester tester) async =>
      [for (final i in (await tester.runAsync(() => db.select(db.identities).get()))!) i.id]..sort();

  testWidgets('Select puts a box on every row; a click is in or out; the bar counts; Esc stops', (tester) async {
    await pump(tester);
    expect(box('k1'), findsNothing);
    expect(find.byKey(const ValueKey('key-selection-bar')), findsNothing);
    await click(tester, find.byKey(const ValueKey('keys-select')));
    for (final id in ['k1', 'k2', 'k3', 'k4']) {
      expect(box(id), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('key-selection-head')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-bulk-hint')), findsOneWidget);
    await click(tester, row('k1'));
    await click(tester, row('k2'));
    expect(selected(), {'k1', 'k2'});
    expect(find.text(l10n.hostBulkActionSelectedCount(2)), findsOneWidget);
    // A click on a selected one takes it out; the details never opened.
    await click(tester, row('k1'));
    expect(selected(), {'k2'});
    expect(find.byKey(const ValueKey('keys-inspector-k1')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(container.read(keySelectionProvider).active, isFalse);
    expect(box('k1'), findsNothing);
    await finish(tester);
  });

  testWidgets('Ctrl starts selecting, Shift selects the range in the order shown, Ctrl+A every key shown',
      (tester) async {
    await pump(tester);
    // Not selecting: a Ctrl-click starts it, with that key.
    await click(tester, row('k2'), holding: LogicalKeyboardKey.controlLeft);
    expect(container.read(keySelectionProvider).active, isTrue);
    expect(selected(), {'k2'});
    // The order shown: the SSH keys (alpha, beta, delta), then the passwords.
    expect(container.read(shownItemIdsProvider('key')), ['k1', 'k2', 'k4', 'k3']);
    await click(tester, row('k3'), holding: LogicalKeyboardKey.shiftLeft);
    expect(selected(), {'k2', 'k4', 'k3'});
    // Ctrl+A: every key shown; a search narrows what is shown.
    container.read(identitySearchQueryProvider.notifier).state = 'key';
    await settle(tester);
    expect(container.read(shownItemIdsProvider('key')), ['k1', 'k2', 'k4']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(selected(), {'k1', 'k2', 'k4'});
    await finish(tester);
  });

  testWidgets('Delete asks once, in red, for the batch, and deletes them all (the Delete key too)', (tester) async {
    await pump(tester);
    await click(tester, find.byKey(const ValueKey('keys-select')));
    await click(tester, box('k1'));
    await click(tester, box('k4'));
    await click(tester, find.byKey(const ValueKey('bulk-delete')));
    expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatKeys(2))), findsOneWidget);
    expect(find.text(l10n.selectDeleteKeysBody(2)), findsOneWidget);
    await tester.tap(find.text(l10n.hostBulkActionDeleteButton(2)));
    await settle(tester);
    expect(await keysLeft(tester), ['k2', 'k3']);
    expect(container.read(keySelectionProvider).active, isFalse);
    expect(find.text(l10n.selectDeletedToast(l10n.transferWhatKeys(2))), findsOneWidget);

    // The Delete key asks the same question.
    await click(tester, row('k2'), holding: LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await settle(tester);
    expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatKeys(1))), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
    await settle(tester);
    expect(await keysLeft(tester), ['k3']);
    await tester.pump(const Duration(seconds: 5));
    await finish(tester);
  });

  testWidgets('in a team\'s vault: only what the role may delete goes, what stays is named, and one the database '
      'refuses stays selected', (tester) async {
    await pump(tester, team: true);
    await click(tester, find.byKey(const ValueKey('keys-select')));
    // Move to... and Copy to...: a member may not take a team's keys out.
    expect(find.byKey(const ValueKey('bulk-move-to')), findsNothing);
    expect(find.byKey(const ValueKey('bulk-copy-to')), findsNothing);
    for (final id in ['k1', 'k2', 'k4']) {
      await click(tester, box(id));
    }
    await click(tester, find.byKey(const ValueKey('bulk-delete')));
    // beta is in Production, where the role only connects: it stays, said.
    expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatKeys(2))), findsOneWidget);
    expect(find.text(l10n.selectDeleteStay(1)), findsOneWidget);
    await tester.tap(find.text(l10n.hostBulkActionDeleteButton(2)));
    await settle(tester);
    // delta's vault refuses its delete in the database: it stays, named.
    expect(await keysLeft(tester), ['k2', 'k3', 'k4']);
    expect(selected(), {'k2', 'k4'});
    expect(find.text('${l10n.selectDeletedSome(1, 2, 'delta key')}. ${l10n.orchardWriteNotAllowed}'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await finish(tester);
  });

  testWidgets('in a team\'s vault where the role may delete none of the selected, Delete is not on', (tester) async {
    await pump(tester, team: true);
    await click(tester, find.byKey(const ValueKey('keys-select')));
    await click(tester, box('k2'));
    await click(tester, find.byKey(const ValueKey('bulk-delete')));
    expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatKeys(1))), findsNothing);
    expect(await keysLeft(tester), ['k1', 'k2', 'k3', 'k4']);
    await finish(tester);
  });
}
