import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/orchard_db_fixture.dart';

/// Password manager keys in the key editors (3.0): a key whose
/// password stays in 1Password, Bitwarden or KeePassXC keeps only the
/// reference; the password it held before is removed; one with no item is
/// not saved; a key that stops using one drops the reference. On the phone
/// editor and on the desktop Keys screen.

class _NoTool implements PmProcessRunner {
  @override
  Future<PmProcessResult> run(String executable, List<String> args,
          {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async =>
      const PmProcessResult(1, '', 'not in these tests');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const ref = 'op://Engineering/db-prod/password';

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late OrchardSummary summary;
  late String passwordKey;
  late SharedPreferences prefs;

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        prefs = await SharedPreferences.getInstance();
        db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
        await seedOrchardAsOwner(db);
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        passwordKey = await crud.create(label: 'prod', username: 'deploy', authMethod: 'password', password: 'hunter2');
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        await db.customStatement(
            "INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('key', ?, ?, 1)",
            [passwordKey, kFixtureCrateId]);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
        summary = await readOrchardSummary(db, kFixtureOrchardId);
      });

  List<Override> overrides() => [
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(kFixtureOrchardId)),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        itemCratesProvider('key').overrideWith((ref) => Stream.value({passwordKey: kFixtureCrateId})),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        sharedPreferencesProvider.overrideWithValue(prefs),
        passwordManagersProvider.overrideWith((r) => PasswordManagers(
              runner: _NoTool(),
              settings: () => r.read(passwordManagerSettingsProvider),
              environment: const {'PATH': '/usr/bin'},
              exists: (p) => p == '/usr/bin/op',
              isWindows: false,
              isMacOS: false,
            )),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ];

  Future<void> pumpApp(WidgetTester tester, Widget home, {Size size = const Size(1200, 1400)}) async {
    await tester.runAsync(() async {
      for (final (family, files) in [
        ('GeistSans', ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']),
        ('JetBrainsMono', ['JetBrainsMono-Regular.ttf']),
      ]) {
        final loader = FontLoader(family);
        for (final f in files) {
          loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
        }
        await loader.load();
      }
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: overrides(),
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      ),
    ));
    await settle(tester);
  }

  Future<Identity?> stored(WidgetTester tester, String id) =>
      tester.runAsync(() => db.identitiesDao.getById(id)).then((v) => v);

  Future<String?> secret(WidgetTester tester, String id) => tester.runAsync(() => crud.getPassword(id)).then((v) => v);

  Finder refField() =>
      find.descendant(of: find.byKey(const ValueKey('pm-ref-field')), matching: find.byType(TextField));

  group('phone editor', () {
    testWidgets('a password key moved to a password manager keeps only the reference; the password is gone',
        (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, IdentityEditScreen(identityId: passwordKey, embedded: true, onClose: (_) {}));
      await tester.tap(find.byKey(const ValueKey('auth-password-manager')));
      await settle(tester);
      expect(find.byKey(const ValueKey('pm-editor')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is EditableText && w.obscureText), findsNothing, reason: 'no password here');

      // No item yet: refused, nothing saved.
      await tester.tap(find.byTooltip(l10n.save));
      await settle(tester);
      expect((await stored(tester, passwordKey))!.authMethod, 'password');

      await tester.enterText(refField(), ref);
      await tester.tap(find.byTooltip(l10n.save));
      await settle(tester);
      final key = (await stored(tester, passwordKey))!;
      expect((key.authMethod, PasswordRef.decode(key.passwordRef)?.target), ('passwordManager', ref));
      expect(await secret(tester, passwordKey), isNull, reason: 'the password it held is gone');
      await finish(tester);
    });
  });

  group('desktop Keys screen', () {
    testWidgets('a key becomes a password manager key, then a password key again, which drops the reference',
        (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, const KeysView(), size: const Size(1400, 1000));
      await tester.tap(find.text('prod').first);
      await settle(tester);
      // A team's password is never moved into someone's own vault.
      expect(find.byKey(const ValueKey('pm-move')), findsNothing);
      // Its private details are behind Edit.
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      expect(find.byKey(const ValueKey('pm-move')), findsNothing);
      await tester.tap(find.text(l10n.pmKeyTypeLabel));
      await settle(tester);
      expect(find.text(l10n.pmToolFound('op', '/usr/bin/op')), findsOneWidget);

      // No item yet: refused.
      await tester.tap(find.text(l10n.save).last);
      await settle(tester);
      expect((await stored(tester, passwordKey))!.authMethod, 'password');

      await tester.enterText(refField(), ref);
      await settle(tester);
      await tester.tap(find.text(l10n.save).last);
      await settle(tester);
      var key = (await stored(tester, passwordKey))!;
      expect((key.authMethod, PasswordRef.decode(key.passwordRef)?.target), ('passwordManager', ref));
      expect(await secret(tester, passwordKey), isNull);

      // Back to a password: the reference goes.
      await tester.tap(find.text(l10n.identityPassword).first);
      await settle(tester);
      await tester.enterText(find.byWidgetPredicate((w) => w is EditableText && w.obscureText), 'n3w-pass');
      await settle(tester);
      await tester.tap(find.text(l10n.save).last);
      await settle(tester);
      key = (await stored(tester, passwordKey))!;
      expect((key.authMethod, key.passwordRef), ('password', null));
      expect(await secret(tester, passwordKey), 'n3w-pass');
      await finish(tester);
    });
  });
}

/// Takes the screen down while the test still runs, so what closes with it
/// (the database's watched queries) finishes here.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 5)); // toasts time out
}
