import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/widgets/crate_filter_chips.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Crates in the host list (3.0): the Orchard on screen shows its
/// Crates as chips with their hosts counted (a host not placed yet counts in
/// the Crate new items go to); picking one filters the list and makes it the
/// Crate new items go to; a move shows at once. Runs with
/// `--dart-define=ZEST_ORCHARDS=true`.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _prod = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _staging = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';

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

  testWidgets('counts, filters, sets where new items go, and follows a move', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final storage = _MemoryStorage();
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
    ]);
    addTearDown(() async {
      container.dispose();
      for (final db in storage.dbs.values) {
        await db.close();
      }
      await tree.close();
    });
    container.read(databaseSessionProvider.notifier).seed(tree);

    late AppDatabase db;
    await tester.runAsync(() async {
      db = await container.read(orchardDatabasesProvider.notifier).open(_orchard);
      // An owner, as the Orchard's record makes one: every Orchard-wide
      // right, and every switch on each Crate.
      await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
          "VALUES (1, ?, 'Acme', 'owner', 1, ?, ?)",
          [_orchard, _prod, jsonEncode(RoleCan.all.toList()..sort())]);
      final all = jsonEncode(CrateSwitches.all.toList()..sort());
      await db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
          "(?, 'Production', 'manage', ?, 1), (?, 'Staging', 'manage', ?, 1)",
          [_prod, all, _staging, all]);
      final now = DateTime(2026, 9, 23);
      for (final id in ['h-1', 'h-2', 'h-3']) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: id,
              host: '10.0.0.1',
              port: const Value(22),
              createdAt: now,
              updatedAt: now,
            ));
      }
      await container.read(spaceControllerProvider).switchTo(const OrchardSpace(_orchard));
      await container.read(cratePlacementProvider)!.place('host', 'h-3', _staging);
    });

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: CrateFilterChips()),
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    await settle();
    final l10n = AppLocalizations.of(tester.element(find.byType(CrateFilterChips)))!;
    Finder chip(String label, int count) => find.ancestor(
          of: find.text('$count'),
          matching: find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
        );
    expect(chip(l10n.crateAll, 3), findsOneWidget);
    expect(chip('Production', 2), findsOneWidget, reason: 'h-1 and h-2 are not placed yet');
    expect(chip('Staging', 1), findsOneWidget);
    expect(find.text(l10n.crateNewAction), findsOneWidget);
    expect(find.text(l10n.crateNewItemsGoTo('Production')), findsOneWidget);

    await tester.tap(find.text('Staging'));
    await settle();
    expect(container.read(selectedCrateFilterProvider), _staging);
    expect(find.text(l10n.crateNewItemsGoTo('Staging')), findsOneWidget);
    // Picking a Crate moved nothing: h-1 and h-2 stay where they were made.
    expect(chip('Production', 2), findsOneWidget);
    expect(chip('Staging', 1), findsOneWidget);

    await tester.runAsync(
        () => container.read(cratePlacementProvider)!.moveItem('host', 'h-1', _staging));
    await settle();
    expect(chip('Production', 1), findsOneWidget);
    expect(chip('Staging', 2), findsOneWidget);
  }, skip: !kOrchardsEnabled);
}
