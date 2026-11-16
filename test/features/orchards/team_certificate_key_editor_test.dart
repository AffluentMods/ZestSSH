import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/orchard_db_fixture.dart';

/// Team certificate keys in the key editors (3.0): where the
/// key's Crate signs certificates, a key can be a team certificate (the user
/// name to sign in as, nothing secret); a key that becomes one keeps nothing
/// it held; where the Crate signs none, the choice is not offered. The key
/// an authority signs with is labelled as such, and deleting it says what
/// that stops first. On the phone editor and on the desktop Keys screen.

const _orchard = kFixtureOrchardId;
const _certCrate = kFixtureCrateId;
const _plainCrate = '77777777-7777-4777-8777-777777777777';
const _vault = '88888888-8888-4888-8888-888888888888';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late OrchardSummary summary;
  late String passwordKey;
  late String plainKey;
  late String authorityKey;
  late String backupKey;
  late TeamDeviceKey caKey;

  late SharedPreferences prefs;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// The Orchard: the fixture Crate (where new keys go) signs certificates
  /// (members as deploy, owners as root) with its key in the owners-only
  /// Crate "Owner keys"; another Crate signs none. A password key in each,
  /// and the authority's key in "Owner keys".
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        caKey = await TeamDeviceKey.generate();
        db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
        await seedOrchardAsOwner(db);
        for (final (id, name, ownersOnly) in [(_plainCrate, 'Staging', 0), (_vault, 'Owner keys', 1)]) {
          await db.customStatement(
              'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation, owners_only) '
              "VALUES (?, ?, 'manage', ?, 1, ?)",
              [id, name, jsonEncode(CrateSwitches.all.toList()..sort()), ownersOnly]);
        }
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        passwordKey = await crud.create(label: 'prod', username: 'deploy', authMethod: 'password', password: 'hunter2');
        plainKey = await crud.create(label: 'stage', username: 'deploy', authMethod: 'password', password: 'hunter3');
        authorityKey = await crud.create(
            label: 'Production certificate authority',
            username: 'ca',
            authMethod: 'publicKey',
            publicKeyData: ed25519KeyLine(caKey.publicKey, 'zestssh-ca-1'),
            privateKeyPem: 'not read here');
        backupKey = await crud.create(
            label: 'backup',
            username: 'backup',
            authMethod: 'publicKey',
            publicKeyData: ed25519KeyLine((await TeamDeviceKey.generate()).publicKey, 'backup'),
            privateKeyPem: 'not read here');
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        await db.customStatement(
            'INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES '
            "('key', ?, ?, 1), ('key', ?, ?, 1), ('key', ?, ?, 1), ('key', ?, ?, 1)",
            [passwordKey, _certCrate, plainKey, _plainCrate, authorityKey, _vault, backupKey, _vault]);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
        summary = await readOrchardSummary(db, _orchard);
      });

  List<Override> overrides() => [
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(_orchard)),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        itemCratesProvider('key')
            .overrideWith((ref) => Stream.value(
                {passwordKey: _certCrate, plainKey: _plainCrate, authorityKey: _vault, backupKey: _vault})),
        crateAuthoritiesProvider(_orchard).overrideWith((ref) async => {
              _certCrate: CrateAuthorityView(
                crateId: _certCrate,
                on: true,
                generation: 1,
                ttlMinutes: 1440,
                principals: const {
                  'owner': ['root'],
                  'role-1': ['deploy'],
                },
                keyCrate: _vault,
                publicKeys: {1: Uint8List.fromList(caKey.publicKey)},
              ),
              // Staging's authority, turned off.
              _plainCrate: CrateAuthorityView(
                crateId: _plainCrate,
                on: false,
                generation: 1,
                ttlMinutes: 1440,
                principals: const {
                  'owner': ['root'],
                },
                keyCrate: _vault,
                publicKeys: {1: Uint8List(32)},
              ),
            }),
        // The key's details beside the Keys list read this device's
        // preferences (a host's system, for its icon).
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ];

  Future<void> pumpApp(WidgetTester tester, Widget home, {Size size = const Size(1200, 1400)}) async {
    // The shipped fonts: the test font draws every glyph as a square, far
    // wider than real text.
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

  group('phone editor', () {
    testWidgets('a new key where the Crate signs certificates: a team certificate, holding nothing', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      String? saved;
      await pumpApp(tester, IdentityEditScreen(embedded: true, onClose: (id) => saved = id));
      expect(find.byKey(const ValueKey('auth-team-certificate')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auth-team-certificate')));
      await settle(tester);
      expect(find.byKey(const ValueKey('team-certificate-note')), findsOneWidget);
      expect(find.textContaining(l10n.identityTeamCertNames('deploy, root')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is EditableText && w.obscureText), findsNothing, reason: 'no password');
      await tester.enterText(find.byType(TextFormField).first, 'Deploy');
      await tester.enterText(find.byType(TextFormField).at(1), 'deploy');
      await tester.tap(find.byTooltip(l10n.save));
      await settle(tester);
      expect(saved, isNotNull);
      final key = (await stored(tester, saved!))!;
      expect(key.authMethod, 'teamCertificate');
      expect(key.username, 'deploy');
      expect(await secret(tester, saved!), isNull);
      await finish(tester);
    });

    testWidgets('a password key that becomes a team certificate keeps nothing it held', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, IdentityEditScreen(identityId: passwordKey, embedded: true, onClose: (_) {}));
      await tester.tap(find.byKey(const ValueKey('auth-team-certificate')));
      await settle(tester);
      await tester.tap(find.byTooltip(l10n.save));
      await settle(tester);
      expect((await stored(tester, passwordKey))!.authMethod, 'teamCertificate');
      expect(await secret(tester, passwordKey), isNull, reason: 'the password is gone');
      await finish(tester);
    });

    testWidgets('where the Crate signs no certificates (its authority off), the choice is not there', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, IdentityEditScreen(identityId: plainKey, embedded: true, onClose: (_) {}));
      expect(find.text(l10n.identityPassword), findsWidgets);
      expect(find.byKey(const ValueKey('auth-team-certificate')), findsNothing);
      await finish(tester);
    });

    testWidgets("deleting the authority's key says what it stops first; declining keeps it", (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, IdentityEditScreen(identityId: authorityKey, embedded: true, onClose: (_) {}));
      await tester.tap(find.byIcon(LucideIcons.trash2));
      await settle(tester);
      expect(find.text(l10n.certAuthorityKeyDeleteTitle), findsOneWidget);
      expect(find.text(l10n.certAuthorityKeyDeleteBody('Fixture')), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(await stored(tester, authorityKey), isNotNull);
      await finish(tester);
    });
  });

  group('desktop Keys screen', () {
    Finder segment(String label) => find.text(label);

    testWidgets("the authority's key is labelled; a key in its Crate may become a team certificate", (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, const KeysView(), size: const Size(1400, 1000));
      await tester.tap(find.text('Production certificate authority').first);
      await settle(tester);
      // Its private details are behind Edit.
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      expect(find.byKey(const ValueKey('key-is-authority')), findsOneWidget);
      expect(find.text(l10n.certAuthorityKeyNote('Fixture')), findsOneWidget);
      expect(segment(l10n.identityTeamCertificate), findsNothing, reason: 'Owner keys signs no certificates');

      // Deleting it says what that stops first; declining keeps it.
      await tester.tap(find.text(MaterialLocalizations.of(tester.element(find.byType(KeysView))).deleteButtonTooltip));
      await settle(tester);
      expect(find.text(l10n.certAuthorityKeyDeleteTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(await stored(tester, authorityKey), isNotNull);

      await tester.tap(find.text('backup').first);
      await settle(tester);
      // Its private details are behind Edit.
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      expect(find.byKey(const ValueKey('key-is-authority')), findsNothing, reason: 'another key in its Crate');

      await tester.tap(find.text('prod').first);
      await settle(tester);
      // Its private details are behind Edit.
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      expect(find.byKey(const ValueKey('key-is-authority')), findsNothing);
      await tester.tap(segment(l10n.identityTeamCertificate));
      await settle(tester);
      expect(find.byKey(const ValueKey('team-certificate-note')), findsOneWidget);
      await tester.tap(find.text(l10n.save).last);
      await settle(tester);
      expect((await stored(tester, passwordKey))!.authMethod, 'teamCertificate');
      expect(await secret(tester, passwordKey), isNull, reason: 'the password is gone');
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
