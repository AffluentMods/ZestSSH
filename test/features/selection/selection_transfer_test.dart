import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
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
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/redactor.dart';

/// Move to... and Copy to... for a selection (3.4): the one place picker for
/// the whole batch, what the batch's items use asked once (two port forwards
/// through one host: the host asked once), and the batch moved or copied
/// together. Runs with `--dart-define=ZEST_ORCHARDS=true`.

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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1700, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
      acme = await container.read(orchardDatabasesProvider.notifier).open(_acme);
      await acme.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
          "VALUES (1, ?, 'Acme', 'owner', 1, ?, ?)",
          [_acme, _prod, jsonEncode(RoleCan.all.toList()..sort())]);
      await acme.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
          "(?, 'Production', 'manage', ?, 1)",
          [_prod, jsonEncode(CrateSwitches.all.toList()..sort())]);
      final at = DateTime(2026, 11, 1);
      for (final (id, label) in const [('k1', 'deploy key'), ('k2', 'backup key')]) {
        await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: id, label: label, username: 'deploy', authMethod: 'password', createdAt: at));
      }
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h1', label: 'monitoring', host: '10.50.0.21', createdAt: at, updatedAt: at));
      for (final (id, port) in const [('f1', 9090), ('f2', 3000)]) {
        await tree.into(tree.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: id,
            connectionId: 'h1',
            type: 'local',
            bindPort: port,
            remoteHost: 'localhost',
            remotePort: port,
            label: Value('rule $port'),
            createdAt: at));
      }
      await container.read(orchardSummariesProvider.future);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: page),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<void> ctrlClick(WidgetTester tester, Finder f) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(f, kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  final production = find.byKey(const ValueKey('transfer-place-$_acme-$_prod'));

  testWidgets('two port forwards through one host: Copy to... asks about the host once, and both go',
      (tester) async {
    await pump(tester, const PortForwardListView());
    await ctrlClick(tester, find.byKey(const ValueKey('pf-rule-f1')));
    await ctrlClick(tester, find.byKey(const ValueKey('pf-rule-f2')));
    expect(container.read(forwardSelectionProvider).selected, {'f1', 'f2'});
    await tester.tap(find.byKey(const ValueKey('bulk-copy-to')), kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.text(l10n.transferCopyTitle(l10n.transferWhatForwards(2))), findsOneWidget);
    await tester.tap(production);
    await settle(tester);
    expect(find.byKey(const ValueKey('transfer-review')), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-link-host-h1')), findsOneWidget, reason: 'one host, asked once');
    expect(find.text('monitoring'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transfer-go')));
    await settle(tester);
    final rules = (await tester.runAsync(() => acme.select(acme.portForwardRules).get()))!;
    expect(rules.map((r) => r.label).toSet(), {'rule 9090', 'rule 3000'});
    final hosts = (await tester.runAsync(() => acme.select(acme.connections).get()))!;
    expect(hosts, hasLength(1), reason: 'the one host went once, for both');
    expect(rules.map((r) => r.connectionId).toSet(), {hosts.single.id});
    expect(await tester.runAsync(() => tree.select(tree.portForwardRules).get()), hasLength(2), reason: 'copied');
    expect(container.read(forwardSelectionProvider).active, isFalse);
    await finish(tester);
  });

  testWidgets('two keys: Move to... a team\'s vault takes both, and selecting ends', (tester) async {
    await pump(tester, const KeysView());
    await ctrlClick(tester, find.byKey(const ValueKey('key-row-menu-k1')));
    await ctrlClick(tester, find.byKey(const ValueKey('key-row-menu-k2')));
    await tester.tap(find.byKey(const ValueKey('bulk-move-to')), kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.text(l10n.transferMoveTitle(l10n.transferWhatKeys(2))), findsOneWidget);
    await tester.tap(production);
    await settle(tester);
    final moved = (await tester.runAsync(() => acme.select(acme.identities).get()))!;
    expect(moved.map((i) => i.label).toSet(), {'deploy key', 'backup key'});
    for (final key in moved) {
      expect(await tester.runAsync(() => CratePlacement(acme).crateOf('key', key.id)), _prod);
    }
    expect(await tester.runAsync(() => tree.select(tree.identities).get()), isEmpty);
    expect(container.read(keySelectionProvider).active, isFalse);
    await finish(tester);
  });
}
