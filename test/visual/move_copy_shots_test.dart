import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart';
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

import 'shots_util.dart';

/// Pictures of Move to... and Copy to... (3.4): before (the old "Move to
/// vault", a list of one team's vaults, for hosts only) and after (the one
/// place picker, Personal and every vault this account may add to, and the
/// question about what the items use), dark, at a computer's width and a
/// phone's. Made-up teams, vaults, hosts and keys only:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/move_copy_shots_test.dart
///
/// Pictures land in build/shots/move-copy/.

const _acme = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _northwind = '1d3f9b7e-6c2e-4e4b-8a58-3b72d1f0c8e4';
const _prod = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _staging = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';
const _lab = '4a6c2e0c-9f5b-4b7e-8c8b-6ea5a4c3fbb7';
const _audit = '5b7d3f1d-0a6c-4c8f-9d9c-7fb6b5d4acc8';
const _shared = '6c8e4a2e-1b7d-4d9a-8eaa-8ac7c6e5bdd9';

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
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> seedTeam(AppDatabase db, String id, String name, Map<String, String> crates) async {
    await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
        "VALUES (1, ?, ?, 'owner', 1, ?, ?)",
        [id, name, crates.keys.first, jsonEncode(RoleCan.all.toList()..sort())]);
    final all = jsonEncode(CrateSwitches.all.toList()..sort());
    for (final e in crates.entries) {
      await db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation, owners_only) VALUES (?, ?, ?, ?, 1, ?)',
          [e.key, e.value, 'manage', all, e.value == 'Audit' ? 1 : 0]);
    }
  }

  /// A computer's width or a phone's; the app on [space], with made-up data.
  Future<(GlobalKey, ProviderContainer)> pump(WidgetTester tester, {required bool phone, Space space = const TreeSpace()}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'app_theme_id': 'graphite'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = phone ? const Size(412, 860) : const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('graphite');
    AppColors.applyTheme(theme.colorScheme);
    final storage = _MemoryStorage();
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-demo', email: 'sam@example.com')),
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
      final acme = await container.read(orchardDatabasesProvider.notifier).open(_acme);
      await seedTeam(acme, _acme, 'Acme Platform', {_prod: 'Production', _staging: 'Staging', _lab: 'Lab', _audit: 'Audit'});
      final northwind = await container.read(orchardDatabasesProvider.notifier).open(_northwind);
      await seedTeam(northwind, _northwind, 'Northwind', {_shared: 'Shared'});
      final at = DateTime(2026, 11, 1);
      for (final db in [tree, acme]) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'k-deploy', label: 'deploy (ed25519)', username: 'deploy', authMethod: 'publicKey', createdAt: at));
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-bastion', label: 'bastion-eu', host: '203.0.113.10', identityId: const Value('k-deploy'), createdAt: at, updatedAt: at));
        for (final n in ['01', '02', '03']) {
          await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: 'h-web-$n',
              label: 'web-$n',
              host: '10.40.0.$n',
              identityId: const Value('k-deploy'),
              connectViaId: const Value('h-bastion'),
              createdAt: at,
              updatedAt: at));
        }
      }
      await CratePlacement(acme).place('host', 'h-web-01', _staging);
      await container.read(orchardSummariesProvider.future);
      await container.read(spaceControllerProvider).switchTo(space);
    });
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const ValueKey('open-picker'),
                      onPressed: () => showMoveCopyDialog(context, ref,
                          kind: TransferKinds.host, keys: const ['h-web-02', 'h-web-03'], mode: TransferMode.move),
                      child: const Text('Move'),
                    ),
                    TextButton(
                      key: const ValueKey('open-before'),
                      onPressed: () => _showOldMoveToVault(context),
                      child: const Text('Before'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    return (key, container);
  }

  Future<void> done(WidgetTester tester) async {
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  for (final phone in [false, true]) {
    final width = phone ? 'phone' : 'desktop';

    testWidgets('$width: before, the old Move to vault', (tester) async {
      final (key, _) = await pump(tester, phone: phone, space: const OrchardSpace(_acme));
      await tester.tap(find.byKey(const ValueKey('open-before')), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await saveShot(tester, key, 'move-copy/before_${width}_move_to_vault');
      await done(tester);
    }, skip: !shotsEnabled);

    testWidgets('$width: after, the picker and the linked items question', (tester) async {
      final (key, _) = await pump(tester, phone: phone);
      await tester.tap(find.byKey(const ValueKey('open-picker')), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await saveShot(tester, key, 'move-copy/after_${width}_1_picker');
      await tester.tap(find.byKey(const ValueKey('transfer-place-$_acme-$_prod')), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(find.byKey(const ValueKey('transfer-review')), findsOneWidget);
      await saveShot(tester, key, 'move-copy/after_${width}_2_linked_items');
      await done(tester);
    }, skip: !shotsEnabled);

    testWidgets('$width: after, from a team (its vault shown as Here)', (tester) async {
      final (key, _) = await pump(tester, phone: phone, space: const OrchardSpace(_acme));
      await tester.tap(find.byKey(const ValueKey('open-picker')), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await saveShot(tester, key, 'move-copy/after_${width}_3_picker_from_team');
      await done(tester);
    }, skip: !shotsEnabled);
  }
}

/// The dialog 3.3 had (orchard_ui.dart, showMoveToCrateDialog before 3.4), as
/// it drew it: a plain list of the other vaults of the team on screen, hosts
/// only.
Future<void> _showOldMoveToVault(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Move to vault'),
        children: [
          for (final name in ['Production', 'Lab', 'Audit'])
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Row(
                children: [
                  const Icon(LucideIcons.package, size: 16),
                  const SizedBox(width: 10),
                  Expanded(child: Text(name)),
                ],
              ),
            ),
        ],
      ),
    );
