import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/bulk/host_bulk_edit_panel.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/redactor.dart';

/// Edit 42 hosts has a Where field (4.0.1): where the selected hosts are, with
/// Move to... and Copy to..., the same place picker and team rules as the
/// selection bar's. While other fields are changed and not applied its buttons
/// wait; after a move the editor and the selection close. Runs with
/// `--dart-define=ZEST_ORCHARDS=true`.

const _acme = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _prod = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late ProviderContainer container;
  late AppDatabase tree;
  late AppDatabase acme;
  late _MemoryStorage storage;
  var closed = 0;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, {bool team = true}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    closed = 0;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    storage = _MemoryStorage();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
    ]);
    addTearDown(() async {
      container.dispose();
      for (final db in storage.dbs.values) {
        await db.close();
      }
      await tree.close();
    });
    container.read(databaseSessionProvider.notifier).seed(tree);
    await tester.runAsync(() async {
      if (team) {
        acme = await container.read(orchardDatabasesProvider.notifier).open(_acme);
        await acme.customStatement(
            'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
            "VALUES (1, ?, 'Acme', 'owner', 1, ?, ?)",
            [_acme, _prod, jsonEncode(RoleCan.all.toList()..sort())]);
        await acme.customStatement(
            'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
            "(?, 'Production', 'manage', ?, 1)",
            [_prod, jsonEncode(CrateSwitches.all.toList()..sort())]);
      }
      final at = DateTime(2026, 11, 1);
      for (final (id, label, host) in const [('h1', 'web-01', '10.50.0.11'), ('h2', 'web-02', '10.50.0.12')]) {
        await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: id, label: label, host: host, createdAt: at, updatedAt: at));
      }
      await container.read(orchardSummariesProvider.future);
    });
    container.read(hostMultiSelectProvider.notifier).enter();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Row(children: [
            const Expanded(child: SizedBox()),
            HostBulkEditPanel(hostIds: const ['h1', 'h2'], onClose: () => closed++),
          ]),
        ),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets('Where says where the hosts are; Move to... takes both to a team\'s vault and closes the editor',
      (tester) async {
    await pump(tester);
    expect(find.text(l10n.bulkFieldPlace), findsOneWidget);
    expect(find.text(l10n.bulkOnAll(l10n.treeSelectorPersonal, 2)), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('bulk-place-move')));
    await tester.tap(find.byKey(const ValueKey('bulk-place-move')));
    await settle(tester);
    expect(find.text(l10n.transferMoveTitle(l10n.transferWhatHosts(2))), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transfer-place-$_acme-$_prod')));
    await settle(tester);
    final moved = (await tester.runAsync(() => acme.select(acme.connections).get()))!;
    expect(moved.map((c) => c.label).toSet(), {'web-01', 'web-02'});
    for (final c in moved) {
      expect(await tester.runAsync(() => CratePlacement(acme).crateOf('host', c.id)), _prod);
    }
    expect(await tester.runAsync(() => tree.select(tree.connections).get()), isEmpty);
    expect(closed, 1);
    expect(container.read(hostMultiSelectProvider).active, isFalse);
    await finish(tester);
  });

  testWidgets('with a field changed and not applied, Move to... and Copy to... wait, and say why', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('bulk-field-port')), '2222');
    await settle(tester);
    expect(find.text(l10n.bulkPlaceApplyFirst), findsOneWidget);
    for (final key in const ['bulk-place-move', 'bulk-place-copy']) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await settle(tester);
      expect(find.text(l10n.transferMoveTitle(l10n.transferWhatHosts(2))), findsNothing);
      expect(find.text(l10n.transferCopyTitle(l10n.transferWhatHosts(2))), findsNothing);
    }
    expect(closed, 0);
    await finish(tester);
  });

  testWidgets('no team: no Where field (nowhere else to go)', (tester) async {
    await pump(tester, team: false);
    expect(find.text(l10n.bulkFieldPlace), findsNothing);
    expect(find.byKey(const ValueKey('bulk-place-move')), findsNothing);
    await finish(tester);
  });
}
