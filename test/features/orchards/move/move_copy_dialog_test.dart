import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart';
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart';
import 'package:zestssh/features/orchards/move/save_in_field.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';

/// The one place picker and the linked items' question (3.4): Personal and
/// each vault this account may add to, the place the items are in shown and
/// not offered, a vault without add not listed at all; the key a host uses
/// asked about in the same dialog, and the answer kept; what cannot go named
/// with why. Runs with `--dart-define=ZEST_ORCHARDS=true`.

const _acme = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _prod = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _staging = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';
const _ro = '4a6c2e0c-9f5b-4b7e-8c8b-6ea5a4c3fbb7';

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

  late ProviderContainer container;
  late AppDatabase tree;
  late AppDatabase acme;
  late _MemoryStorage storage;

  Future<void> setUpSpaces(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    storage = _MemoryStorage();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
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
    await tester.runAsync(() async {
      acme = await container.read(orchardDatabasesProvider.notifier).open(_acme);
      await acme.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
          "VALUES (1, ?, 'Acme', 'owner', 1, ?, ?)",
          [_acme, _prod, jsonEncode(RoleCan.all.toList()..sort())]);
      final all = jsonEncode(CrateSwitches.all.toList()..sort());
      final readOnly = jsonEncode([CrateSwitches.connect, CrateSwitches.sftp]);
      await acme.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
          "(?, 'Production', 'manage', ?, 1), (?, 'Staging', 'manage', ?, 1), (?, 'Archive', 'connect', ?, 1)",
          [_prod, all, _staging, all, _ro, readOnly]);
      final now = DateTime(2026, 11, 1);
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: 'k1', label: 'deploy-key', username: 'deploy', authMethod: 'publicKey', createdAt: now));
      await IdentitySecretStore.forDatabase(tree, const FlutterSecureStorage())
          .write('k1', IdentitySecret.privateKey, 'PEM');
      for (final (id, key) in [('h1', 'k1'), ('h2', null)]) {
        await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: 'web-$id',
              host: '10.0.0.1',
              identityId: Value(key),
              createdAt: now,
              updatedAt: now,
            ));
      }
      await container.read(orchardSummariesProvider.future);
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, {required List<String> keys, required TransferMode mode}) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(
                  key: const ValueKey('go'),
                  onPressed: () => showMoveCopyDialog(context, ref, kind: TransferKinds.host, keys: keys, mode: mode),
                  child: const Text('go'),
                ),
                SaveInField(value: null, onChanged: (_) {}),
              ],
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('go')));
    await settle(tester);
  }

  Finder place(String? crate) => find.byKey(ValueKey('transfer-place-${crate == null ? 'personal' : _acme}-${crate ?? ''}'));

  testWidgets('lists Personal and every vault this account may add to; the one it is in is not offered', (tester) async {
    await setUpSpaces(tester);
    await open(tester, keys: ['h2'], mode: TransferMode.copy);
    final l10n = AppLocalizations.of(tester.element(find.byKey(const ValueKey('transfer-pick'))))!;
    expect(find.text(l10n.transferCopyTitle(l10n.transferWhatHosts(1))), findsOneWidget);
    expect(place(null), findsOneWidget);
    expect(place(_prod), findsOneWidget);
    expect(place(_staging), findsOneWidget);
    expect(place(_ro), findsNothing, reason: 'a vault without add is not listed');
    expect(find.text('Archive'), findsNothing);
    // Personal is where they are: shown, said, and not offered.
    expect(find.descendant(of: place(null), matching: find.text(l10n.transferHere)), findsOneWidget);
    await tester.tap(place(null));
    await settle(tester);
    expect(find.byKey(const ValueKey('transfer-pick')), findsOneWidget, reason: 'nothing happened');
  }, skip: !kOrchardsEnabled);

  testWidgets('a host with nothing linked goes at once, and it is said', (tester) async {
    await setUpSpaces(tester);
    await open(tester, keys: ['h2'], mode: TransferMode.move);
    await tester.tap(place(_staging));
    await settle(tester);
    expect(find.byKey(const ValueKey('transfer-pick')), findsNothing);
    final hosts = await tester.runAsync(() => acme.select(acme.connections).get());
    expect(hosts!.single.label, 'web-h2');
    expect(await tester.runAsync(() => CratePlacement(acme).crateOf('host', hosts.single.id)), _staging);
    expect(await tester.runAsync(() => tree.select(tree.connections).get()), hasLength(1));
    await tester.pump(const Duration(seconds: 5)); // The line that says so goes.
  }, skip: !kOrchardsEnabled);

  testWidgets('the key a host uses is asked about in the same dialog, and Leave it is kept', (tester) async {
    await setUpSpaces(tester);
    await open(tester, keys: ['h1'], mode: TransferMode.copy);
    await tester.tap(place(_prod));
    await settle(tester);
    final review = find.byKey(const ValueKey('transfer-review'));
    expect(review, findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(review))!;
    expect(find.text(l10n.transferLinksIntro('Acme / Production')), findsOneWidget);
    expect(find.text('deploy-key'), findsOneWidget);
    expect(find.text(l10n.transferLinkMove), findsOneWidget);
    expect(find.text(l10n.transferLinkCopy), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transfer-link-key-k1-leave')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('transfer-go')));
    await settle(tester);
    expect(review, findsNothing);
    final host = (await tester.runAsync(() => acme.select(acme.connections).get()))!.single;
    expect(host.identityId, isNull);
    expect(await tester.runAsync(() => acme.select(acme.identities).get()), isEmpty);
    await tester.pump(const Duration(seconds: 5));
  }, skip: !kOrchardsEnabled);

  testWidgets('Copy it: the host goes with a copy of its key', (tester) async {
    await setUpSpaces(tester);
    await open(tester, keys: ['h1'], mode: TransferMode.move);
    await tester.tap(place(_prod));
    await settle(tester);
    // Copy is what the question starts on.
    await tester.tap(find.byKey(const ValueKey('transfer-go')));
    await settle(tester);
    final host = (await tester.runAsync(() => acme.select(acme.connections).get()))!.single;
    final key = (await tester.runAsync(() => acme.select(acme.identities).get()))!.single;
    expect(host.identityId, key.id);
    expect(await tester.runAsync(() => tree.select(tree.identities).get()), hasLength(1));
    expect((await tester.runAsync(() => tree.select(tree.connections).get()))!.map((c) => c.id), ['h2']);
    await tester.pump(const Duration(seconds: 5));
  }, skip: !kOrchardsEnabled);

  testWidgets('what cannot go is named with why, and the rest goes', (tester) async {
    await setUpSpaces(tester);
    await tester.runAsync(() => tree.into(tree.connections).insert(ConnectionsCompanion.insert(
        id: 'sh', label: 'my-shell', host: 'localhost', protocol: const Value('localShell'),
        createdAt: DateTime(2026), updatedAt: DateTime(2026))));
    await open(tester, keys: ['h2', 'sh'], mode: TransferMode.move);
    await tester.tap(place(_prod));
    await settle(tester);
    final problems = find.byKey(const ValueKey('transfer-problems'));
    expect(problems, findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(problems))!;
    expect(find.text('my-shell'), findsOneWidget);
    expect(find.text(l10n.transferWhyLocalShell), findsOneWidget);
    expect(find.text(l10n.transferMoveButton(l10n.transferWhatHosts(1))), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transfer-go')));
    await settle(tester);
    // The refused one was named before: the dialog shows how it went.
    expect(find.byKey(const ValueKey('transfer-result')), findsOneWidget);
    expect(find.text(l10n.transferMovedSome(1, 2)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transfer-done')));
    await settle(tester);
    expect((await tester.runAsync(() => tree.select(tree.connections).get()))!.map((c) => c.id).toSet(), {'h1', 'sh'});
  }, skip: !kOrchardsEnabled);

  testWidgets('Save in lists the same places, the one new items go to first', (tester) async {
    await setUpSpaces(tester);
    await open(tester, keys: const [], mode: TransferMode.copy);
    final field = find.byKey(const ValueKey('save-in'));
    expect(field, findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(field))!;
    expect(find.descendant(of: field, matching: find.text(l10n.treeSelectorPersonal)), findsOneWidget);
    await tester.tap(field);
    await settle(tester);
    expect(find.byKey(const ValueKey('save-in-personal-')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-in-$_acme-$_prod')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-in-$_acme-$_staging')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-in-$_acme-$_ro')), findsNothing);
  }, skip: !kOrchardsEnabled);

  testWidgets('Save in: a new host made in Personal for a team is saved there, its key asked about first', (tester) async {
    await setUpSpaces(tester);
    String? saved;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              key: const ValueKey('save'),
              // As the host editor saves a new host, with "Save in" on a vault.
              onPressed: () async => saved = await saveNewItemIn(context, ref,
                  place: const SavePlace.vault(_acme, _staging),
                  kind: TransferKinds.host,
                  write: () => ref.read(connectionCrudProvider).create(label: 'new-web', host: '10.50.0.9', identityId: 'k1')),
              child: const Text('save'),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('save')));
    await settle(tester);
    // Asked before anything is kept anywhere: Personal has no new host.
    expect(find.byKey(const ValueKey('transfer-link-key-k1')), findsOneWidget);
    expect(await tester.runAsync(() => tree.select(tree.connections).get()), hasLength(2));
    await tester.tap(find.byKey(const ValueKey('transfer-go')));
    await settle(tester);
    final host = (await tester.runAsync(() => acme.select(acme.connections).get()))!.single;
    expect(host.label, 'new-web');
    expect(saved, host.id);
    expect(await tester.runAsync(() => CratePlacement(acme).crateOf('host', host.id)), _staging);
    final key = (await tester.runAsync(() => acme.select(acme.identities).get()))!.single;
    expect(host.identityId, key.id, reason: 'Copy it, as the question starts on');
    expect(await tester.runAsync(() => tree.select(tree.connections).get()), hasLength(2));
  }, skip: !kOrchardsEnabled);
}
