import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_detail_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/widgets/app_lock_offer.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/utils/redactor.dart';

/// The computer's Keys page, like a phone's key editor: Save writes only what
/// the person changed. A key that a sync changed while its editor was open
/// (its name here) keeps that change where the person did not touch the
/// field; it was written back to what the editor had read, and the old value
/// then won on every device. Made-up names.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('a sync renames the key while its editor is open and the person changes only the user: Save keeps '
      'the new name and writes the user', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    late IdentityCrudNotifier crud;
    late String id;
    await tester.runAsync(() async {
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      id = await crud.create(label: 'Cluster nodes', username: 'root', authMethod: 'password', password: 'demo-stored');
    });
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        appLockOfferEnabledProvider.overrideWithValue(false),
        syncIsActiveProvider.overrideWith((ref) async => true),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: KeysView()),
      ),
    ));
    await settle();
    await tester.tap(find.text('Cluster nodes'));
    await settle();
    await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
    await settle();
    final KeyEditController c = tester.widget<KeysDetailPane>(find.byType(KeysDetailPane)).controller;
    expect(c.nameController.text, 'Cluster nodes');

    // Another device's rename arrives while the editor is open.
    await tester.runAsync(() => (db.update(db.identities)..where((t) => t.id.equals(id))).write(IdentitiesCompanion(
          label: const Value('Cluster nodes (prod)'),
          updatedAt: Value(DateTime.now().add(const Duration(minutes: 1))),
        )));

    // The person changes the user only, and saves.
    await tester.enterText(
        find.byWidgetPredicate((w) => w is EditableText && identical(w.controller, c.usernameController)), 'deploy');
    await settle();
    tester.widget<ZestDetailScaffold>(find.byType(ZestDetailScaffold)).onSave!();
    await settle();
    await settle();

    final saved = (await tester.runAsync(() => db.identitiesDao.getById(id)))!;
    expect(saved.username, 'deploy', reason: 'what the person changed is written');
    expect(saved.label, 'Cluster nodes (prod)', reason: 'what the sync changed and the person did not touch is kept');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}
