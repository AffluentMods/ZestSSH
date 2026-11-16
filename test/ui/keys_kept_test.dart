// Keys made in the app (found while comparing the five
// versions, in released versions too). A computer's key generator (the Keys
// page's New SSH key and its menu, the palette's Generate SSH key) handed the
// key it made to nobody: "Save & Use This Key" and Done both closed it, and
// the key was gone, though its public key had been shown to copy to a
// server; its passphrase, asked twice, locked nothing. Rotate opened that
// generator. And a key made in the app (generated, pasted or imported) kept
// no public line, so it could not be installed on hosts, a phone did not
// offer to share it, and a computer's Export public key copied its
// fingerprint, saying a public key was copied. Now the generator keeps its
// key through the key form, asking before it is lost; Rotate puts a new key
// in the key's place as Replace key does; and a key's public line is kept,
// or made from its private key where none was.

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/run/install_key_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show KeyType;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart' show KeysPhoneScreen;
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/utils/redactor.dart';

import '../visual/shots_util.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The type and the key of a public line, without what is said after them.
String _bare(String line) => line.split(' ').take(2).join(' ');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final service = KeyGenerationService();

  group("a key's public line", () {
    test('made from its private key as the key was made, Ed25519 and ECDSA; with a name after it, on one line, or '
        'nothing; none from what is no key', () async {
      for (final type in [KeyType.ed25519, KeyType.ecdsaP256]) {
        final made = await service.generate(type, comment: 'deploy@laptop');
        expect(publicKeyLineOf(made.privatePem, comment: 'deploy@laptop'), made.publicOpenSSH, reason: '$type');
        expect(publicKeyLineOf(made.privatePem), _bare(made.publicOpenSSH));
        expect(publicKeyLineOf(made.privatePem, comment: 'two\nlines'), '${_bare(made.publicOpenSSH)} two lines');
      }
      expect(publicKeyLineOf('not a key'), isNull);
    });

    test('a key sealed under a passphrase: made with it, not without', () {
      // (Read with its lines ended as the core's tests end them.)
      String fixture(String name) => File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/$name')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final pem = fixture('id_ed25519');
      expect(publicKeyLineOf(pem), isNull);
      expect(publicKeyLineOf(pem, passphrase: fixture('passphrase').trim()), _bare(fixture('id_ed25519.pub').trim()));
    });

    // An RSA key's line was named by the signature it makes (rsa-sha2-256), which OpenSSH
    // reads but a site taking SSH keys does not, and a phone's exported .pub named every key wrongly
    // (ssh-ssh-ed25519).
    test('an RSA key named by its type, ssh-rsa, from either form of its private key, as ssh-keygen names it; ECDSA '
        'keys of every curve as made', () {
      String fixture(String path) =>
          File('packages/zest_ssh_core/test/fixtures/$path').readAsStringSync().replaceAll('\r\n', '\n');
      final rsa = _bare(fixture('ssh-rsa/id_rsa.pub').trim());
      expect(rsa, startsWith('ssh-rsa AAAA'));
      expect(publicKeyLineOf(fixture('ssh-rsa/id_rsa')), rsa);
      expect(publicKeyLineOf(fixture('ssh-rsa/id_rsa.openssh'), comment: 'deploy'), '$rsa deploy');
      for (final curve in ['nistp256', 'nistp384', 'nistp521']) {
        expect(publicKeyLineOf(fixture('ecdsa-sha2-$curve/id_ecdsa')), _bare(fixture('ecdsa-sha2-$curve/id_ecdsa.pub').trim()),
            reason: curve);
      }
    });

    test('a line kept named the old way is handed out named by its type; any other as it is', () async {
      expect(publicKeyLineNamed('rsa-sha2-256 AAAAB3NzaC1yc2E deploy'), 'ssh-rsa AAAAB3NzaC1yc2E deploy');
      expect(publicKeyLineNamed('rsa-sha2-512 AAAAB3NzaC1yc2E'), 'ssh-rsa AAAAB3NzaC1yc2E');
      expect(publicKeyLineNamed('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 rsa-sha2-256 laptop'),
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 rsa-sha2-256 laptop');
      expect(publicKeyLineNamed('rsa-sha2-2560 AAAA'), 'rsa-sha2-2560 AAAA');

      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      final old = await crud.create(
          label: 'old', username: 'deploy', authMethod: 'publicKey', publicKeyData: 'rsa-sha2-256 AAAAB3NzaC1yc2E old@laptop');
      expect(await crud.publicLineOf((await db.identitiesDao.getById(old))!), 'ssh-rsa AAAAB3NzaC1yc2E old@laptop');
      // And a phone's key form hands out the line it holds so.
      expect(File('lib/ui/screens/identity/identity_edit_screen.dart').readAsStringSync(),
          contains('if (known != null && known.isNotEmpty) return publicKeyLineNamed(known);'));
    });

    test('of a key kept: the line kept with it, else made from its private key and named as the key; none for a '
        'password, nor for a key with no private key', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      final made = await service.generate(KeyType.ed25519);
      final key = await crud.create(
          label: 'deploy key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: made.privatePem);
      final kept = await crud.create(
          label: 'kept',
          username: 'deploy',
          authMethod: 'publicKey',
          privateKeyPem: made.privatePem,
          publicKeyData: 'ssh-ed25519 AAAAkeptForTheTest kept@there');
      final password = await crud.create(label: 'ops', username: 'ops', authMethod: 'password', password: 'x');
      final bare = await crud.create(label: 'bare', username: 'deploy', authMethod: 'publicKey');
      // A key sealed under a passphrase, kept with it.
      String fixture(String name) => File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/$name')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final sealed = await crud.create(
          label: 'sealed',
          username: 'deploy',
          authMethod: 'publicKey',
          privateKeyPem: fixture('id_ed25519'),
          keyPassphrase: fixture('passphrase').trim());
      Future<String?> lineOf(String id) async => crud.publicLineOf((await db.identitiesDao.getById(id))!);
      expect(await lineOf(key), '${_bare(made.publicOpenSSH)} deploy key');
      expect(await lineOf(kept), 'ssh-ed25519 AAAAkeptForTheTest kept@there');
      expect(await lineOf(password), isNull);
      expect(await lineOf(bare), isNull);
      expect(await lineOf(sealed), '${_bare(fixture('id_ed25519.pub').trim())} sealed');
    });

    test("a computer's key form keeps the line of a key set in it, named as the key; none once it is taken away",
        () async {
      final made = await service.generate(KeyType.ed25519);
      final form = KeyEditController();
      addTearDown(form.dispose);
      form.nameController.text = 'laptop key';
      form.setKeyMaterial(privateKeyPem: made.privatePem, fingerprint: made.fingerprint, keyType: 'Ed25519');
      expect(form.publicKeyData, '${_bare(made.publicOpenSSH)} laptop key');
      form.clearKeyMaterial();
      expect(form.publicKeyData, isNull);
    });
  });

  group('on screen', () {
    late SharedPreferences prefs;
    late AppDatabase db;
    late IdentityCrudNotifier crud;
    late List<String> copied;
    var fontsLoaded = false;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      copied = [];
    });

    Future<void> build(WidgetTester tester) async {
      await tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      });
      // Closed after the test, outside its fake clock (inside it, drift's
      // close never finishes).
      addTearDown(() => tester.runAsync(db.close));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    List<Override> overrides() => [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          treeDatabaseProvider.overrideWithValue(db),
          identitiesDaoProvider.overrideWithValue(db.identitiesDao),
          identityCrudProvider.overrideWithValue(crud),
          isProProvider.overrideWith((ref) => _Pro()),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ];

    Future<void> pumpApp(WidgetTester tester, Widget home, {Size size = const Size(1400, 1600)}) async {
      // The fonts the app ships, so its pages are as wide as they are (once).
      if (!fontsLoaded) {
        await tester.runAsync(loadShotFonts);
        fontsLoaded = true;
      }
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => Scaffold(body: home))]);
      addTearDown(router.dispose);
      // The app's own state, which outlives its pages (disposed after the test).
      final container = ProviderContainer(overrides: overrides());
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        key: UniqueKey(),
        container: container,
        child: MaterialApp.router(
          theme: ThemeData(fontFamily: 'GeistSans'),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      await settle(tester);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
    }

    /// The generator, opened as a computer opens it, with a key generated.
    Future<void> generated(WidgetTester tester) async {
      await pumpApp(
          tester,
          Builder(
              builder: (context) => Center(
                  child: TextButton(
                      onPressed: () => KeyGenerationScreen.showAdaptive(context), child: const Text('generate')))));
      await tester.tap(find.text('generate'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'laptop key');
      await tester.ensureVisible(find.text(en.keyGenGenerate));
      await tester.pump();
      // The key is made in real time, as the app makes it.
      await tester.runAsync(() async {
        await tester.tap(find.text(en.keyGenGenerate));
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await settle(tester);
      expect(find.byKey(const ValueKey('key-gen-save')), findsOneWidget);
    }

    /// The public line the generator shows.
    String shownLine(WidgetTester tester) => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((t) => t.data ?? '')
        .firstWhere((s) => s.startsWith('ssh-ed25519 '));

    testWidgets('the generator: Save & Use opens the key form with the key; cancelled there the key is still here; '
        'saved, it is kept with the public line shown, and the generator closes', (tester) async {
      await build(tester);
      await generated(tester);
      expect(find.byKey(const ValueKey('key-gen-passphrase')), findsNothing, reason: 'it locked nothing');
      final line = shownLine(tester);

      await tester.ensureVisible(find.byKey(const ValueKey('key-gen-save')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('key-gen-save')));
      await settle(tester);
      expect(find.byType(IdentityEditScreen), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'laptop key'), findsOneWidget, reason: 'named as generated');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(IdentityEditScreen), findsNothing);
      expect(find.byKey(const ValueKey('key-gen-save')), findsOneWidget, reason: 'the key is still here');

      await tester.tap(find.byKey(const ValueKey('key-gen-save')));
      await settle(tester);
      await tester.enterText(
          find.descendant(of: find.byType(IdentityEditScreen), matching: find.byType(TextFormField)).at(1), 'deploy');
      await tester.ensureVisible(find.text(en.identitySaveIdentity));
      await tester.pump();
      await tester.tap(find.text(en.identitySaveIdentity));
      await settle(tester);
      expect(find.byType(KeyGenerationScreen), findsNothing, reason: 'closed once the key is saved');
      final saved = (await tester.runAsync(() => db.identitiesDao.getAll()))!.single;
      expect((saved.label, saved.username, saved.authMethod, saved.publicKeyData),
          ('laptop key', 'deploy', 'publicKey', line));
      expect(await tester.runAsync(() => crud.getPrivateKey(saved.id)), startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      await finish(tester);
    });

    testWidgets('the generator: closed with its key not kept, it asks first; Cancel stays, Discard closes keeping '
        'nothing', (tester) async {
      await build(tester);
      await generated(tester);
      final done = find.byKey(const ValueKey('key-gen-done'));
      await tester.scrollUntilVisible(done, 200,
          scrollable: find.descendant(of: find.byType(KeyGenerationScreen), matching: find.byType(Scrollable)).first);
      await tester.tap(done);
      await settle(tester);
      expect(find.text(en.zestDiscardTitle), findsOneWidget);
      await tester.tap(find.text(en.zestDiscardCancel));
      await settle(tester);
      expect(find.byKey(const ValueKey('key-gen-save')), findsOneWidget, reason: 'stayed, with its key');

      await tester.tap(done);
      await settle(tester);
      await tester.tap(find.text(en.zestDiscardDiscard));
      await settle(tester);
      expect(find.byType(KeyGenerationScreen), findsNothing);
      expect(await tester.runAsync(() => db.identitiesDao.getAll()), isEmpty);
      await finish(tester);
    });

    testWidgets("a computer's Replace key opens the key's choice, and a key generated there is saved in the key's "
        'place, with its line', (tester) async {
      await build(tester);
      final first = (await tester.runAsync(() => service.generate(KeyType.ed25519)))!;
      final id = (await tester.runAsync(() => crud.create(
          label: 'deploy key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: first.privatePem)))!;
      await pumpApp(tester, const KeysView());
      await tester.tap(find.text('deploy key').first);
      await settle(tester);
      // In the editor, behind Edit, Replace key
      // once: "Rotate" was a second name for it (found in a 3.0 docs check).
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      expect(find.text(en.zestKeysReplaceKey), findsOneWidget, reason: 'one name, once');
      expect(find.text('Rotate'), findsNothing);
      await tester.ensureVisible(find.text(en.zestKeysReplaceKey));
      await tester.pump();
      await tester.tap(find.text(en.zestKeysReplaceKey));
      await settle(tester);
      expect(find.byType(KeySetupDialog), findsOneWidget, reason: 'it opened the generator, whose key went nowhere');
      await tester.runAsync(() async {
        await tester.tap(find.text(en.identityGenerateKey));
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await settle(tester);
      expect(find.byType(KeySetupDialog), findsNothing);
      await tester.tap(find.text(en.zestCommonSave).first);
      await settle(tester);
      final key = (await tester.runAsync(() => db.identitiesDao.getById(id)))!;
      final pem = (await tester.runAsync(() => crud.getPrivateKey(id)))!;
      expect(pem, isNot(first.privatePem), reason: 'a new key in its place');
      expect(key.publicKeyData, publicKeyLineOf(pem, comment: 'deploy key'));
      await finish(tester);
    });

    testWidgets("a computer's Export public key copies the line made from a key that kept none (it copied the "
        'fingerprint)', (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generate(KeyType.ed25519)))!;
      await tester.runAsync(() => crud.create(
          label: 'deploy key',
          username: 'deploy',
          authMethod: 'publicKey',
          privateKeyPem: made.privatePem,
          publicKeyFingerprint: made.fingerprint));
      await pumpApp(tester, const KeysView());
      await tester.tap(find.text('deploy key').first);
      await settle(tester);
      // The key's details beside the list copy it, as the
      // editor's Export public key does.
      await tester.tap(find.byKey(const ValueKey('keys-copy-public')));
      await settle(tester);
      expect(copied.single, '${_bare(made.publicOpenSSH)} deploy key');
      await finish(tester);
    });

    testWidgets('Install on hosts makes the line of a key that kept none; one whose key cannot be read says it has '
        'none', (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generate(KeyType.ed25519)))!;
      // Both made before anything is drawn: a write after the first dialog
      // waits behind its query, which only the test's clock moves.
      final (good, broken) = (await tester.runAsync(() async {
        final good = await crud.create(
            label: 'deploy key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: made.privatePem);
        final broken = await crud.create(
            label: 'broken key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: 'not a key');
        return ((await db.identitiesDao.getById(good))!, (await db.identitiesDao.getById(broken))!);
      }))!;
      await pumpApp(tester, InstallKeyDialog(keyToInstall: good));
      expect(find.byKey(const ValueKey('install-no-key')), findsNothing);
      await pumpApp(tester, InstallKeyDialog(keyToInstall: broken));
      expect(find.byKey(const ValueKey('install-no-key')), findsOneWidget);
      await finish(tester);
    });

    testWidgets("a phone's Share public key: offered for a key that kept no line, and it copies the one made from it",
        (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generate(KeyType.ed25519)))!;
      await tester.runAsync(() => crud.create(
          label: 'phone key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: made.privatePem));
      await pumpApp(tester, const KeysPhoneScreen(), size: const Size(390, 1600));
      // Its own sheet: a long press selects it, and More opens it (3.4).
      await tester.longPress(find.text('phone key'));
      await settle(tester);
      await tester.tap(find.text(en.selectKeyActions));
      await settle(tester);
      await tester.tap(find.text(en.homeSharePublicKey));
      await settle(tester);
      expect(copied.single, '${_bare(made.publicOpenSSH)} phone key');
      await finish(tester);
    });
  });
}
