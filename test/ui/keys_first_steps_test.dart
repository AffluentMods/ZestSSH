// The Keys page with nothing saved (4.0, as designed).
// It was one faint key, "No keys yet" and one
// orange New SSH key that did what the orange New key beside the title did,
// while the real ways to add a key were in that button's menu, and nothing
// said which kind of key to make or what one is for. Now a heading, a line on
// what a key is for, What is an SSH key? (the docs' page), one card for each
// way to start, each opening what New key's menu opens, with only the one
// recommended in the brand's colour, and the line for a host that signs in
// with a password; a key file dropped anywhere on the page opens in the new
// key's editor, and what is no private key is refused, said. A phone has the
// same ways as a list.

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show activeOrchardProvider;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show AuthMethod;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/hardware_token_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_detail_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_first_steps.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart' show KeysPhoneScreen;
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/utils/help_links.dart';
import 'package:zestssh/utils/redactor.dart';

import '../visual/shots_util.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No password manager's tool is run in these tests.
class _NoTool implements PmProcessRunner {
  @override
  Future<PmProcessResult> run(String executable, List<String> args,
          {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async =>
      const PmProcessResult(1, '', 'not in these tests');
}

/// A key made for these tests, sealed with [_demoPassphrase]: it opens
/// nothing.
const _sealedKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCL8wTMH8
vRYYkl+Nw7aNqrAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDPJ8PTd0sTg/ymg
QBpy/+Ed3eCIWo0Auo3JLRz2Xq7fAAAAoIL4EUF5rxn/FRvy+zjJzsdTFYkSGuI6C8teDu
1QaeXKXM2nXsJ5ESgWMWK69G3ekDAQuNtrbI3YkdVFAqgQJDc+dOrKQtkmuLCANEGPmytV
r9yAcC8GcKcSEE54xQICP4cLIJ3Tq3KZ3aUJudiogMJEUrjsGAbj8ckchgLcuaeyR75mEw
de+/cZH5OaIz7ohTo5RLqbSAm8/DsVbGXIu5Y=
-----END OPENSSH PRIVATE KEY-----
''';
const _demoPassphrase = 'demo-passphrase';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final service = KeyGenerationService();

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late SharedPreferences prefs;
  late Directory dir;
  late List<Uri> opened;
  var fontsLoaded = false;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('zest_keys_first_');
    opened = [];
    KeysFirstSteps.debugOpenPage = (page) async => opened.add(page);
  });

  tearDown(() => KeysFirstSteps.debugOpenPage = null);

  Future<void> build(WidgetTester tester) async {
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
    });
    // Closed after the test, outside its fake clock.
    addTearDown(() => tester.runAsync(db.close));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  late ProviderContainer container;

  Future<void> pumpApp(WidgetTester tester, Widget home,
      {Size size = const Size(1440, 900), List<Override> extra = const []}) async {
    if (!fontsLoaded) {
      await tester.runAsync(loadShotFonts);
      fontsLoaded = true;
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => Scaffold(body: home)),
      // A phone's pages the ways open.
      GoRoute(
        path: Routes.identityEdit,
        builder: (context, state) =>
            IdentityEditScreen(initialImportedKey: state.extra is InitialImportedKey ? state.extra as InitialImportedKey : null),
      ),
      GoRoute(path: Routes.keyGeneration, builder: (context, state) => const KeyGenerationScreen()),
    ]);
    addTearDown(router.dispose);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      identitiesDaoProvider.overrideWithValue(db.identitiesDao),
      identityCrudProvider.overrideWithValue(crud),
      isProProvider.overrideWith((ref) => _Pro()),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      passwordManagersProvider.overrideWith((r) => PasswordManagers(
            runner: _NoTool(),
            settings: () => r.read(passwordManagerSettingsProvider),
            environment: const {},
            exists: (_) => false,
            isWindows: false,
            isMacOS: false,
          )),
      ...extra,
    ]);
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

  Finder k(String key) => find.byKey(ValueKey(key));

  String write(String name, String text) {
    final path = '${dir.path}${Platform.pathSeparator}$name';
    File(path).writeAsStringSync(text);
    return path;
  }

  /// What the window says while files are dragged over [at], as the plugin's
  /// channel says it.
  Future<void> event(WidgetTester tester, String method, Object? arguments) async {
    final message = const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage('desktop_drop', message, (_) {});
    await tester.pump();
  }

  Future<void> dragOver(WidgetTester tester, Offset at) async {
    await event(tester, 'entered', [at.dx, at.dy]);
    await event(tester, 'updated', [at.dx, at.dy]);
  }

  Future<void> drop(WidgetTester tester, List<String> paths, {Offset at = const Offset(720, 500)}) async {
    await dragOver(tester, at);
    await event(tester, 'performOperation', paths);
    await settle(tester);
  }

  /// Real files are read off the test's clock.
  Future<void> until(WidgetTester tester, Finder found) async {
    for (var i = 0; i < 200 && found.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(found, findsWidgets);
  }

  /// Waits until the computer's notification center was told [words].
  Future<void> told(WidgetTester tester, String words) async {
    bool said() => container.read(notificationCenterProvider).history.any((n) => '${n.title} ${n.body ?? ''}'.contains(words));
    for (var i = 0; i < 200 && !said(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(said(), isTrue, reason: words);
  }

  KeyEditController editor(WidgetTester tester) => tester.widget<KeysDetailPane>(find.byType(KeysDetailPane)).controller;

  group('a computer', () {
    testWidgets('with nothing saved: the heading, the line on what a key is for, What is an SSH key?, the four ways '
        'to start, generate first and the only one in the brand colour, and the line for a password; nothing of the old '
        'page', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      final semantics = tester.ensureSemantics();
      expect(find.text(en.keysFirstTitle), findsOneWidget);
      expect(find.text(en.keysFirstLead), findsOneWidget);
      expect(find.text(en.keysFirstWhatIsKey), findsOneWidget);
      expect(tester.getSemantics(k('keys-first-what-is-key')), isSemantics(isLink: true));
      // Two to a row, in the design's order.
      final generate = tester.getTopLeft(k('keys-first-generate'));
      final import = tester.getTopLeft(k('keys-first-import'));
      final agent = tester.getTopLeft(k('keys-first-agent'));
      final pm = tester.getTopLeft(k('keys-first-pm'));
      expect(import.dy, generate.dy);
      expect(import.dx, greaterThan(generate.dx));
      expect(agent.dx, generate.dx);
      expect(agent.dy, greaterThan(generate.dy));
      expect((pm.dx, pm.dy), (import.dx, agent.dy));
      // Each card one button, read out whole.
      for (final (id, title, line) in [
        ('generate', en.keysFirstGenerateTitle, en.keysFirstGenerateGo),
        ('import', en.keysFirstImportTitle, en.keysFirstImportGo),
        ('agent', en.keysFirstAgentTitle, en.keysFirstAgentGo),
        ('pm', en.keysUiFromPasswordManager, en.pmAddFrom),
      ]) {
        final node = tester.getSemantics(k('keys-first-$id'));
        expect(node, isSemantics(isButton: true), reason: id);
        expect(node.label, allOf(contains(title), contains(line)), reason: id);
      }
      // The import card says a file may be dropped on the page.
      expect(tester.getSemantics(k('keys-first-import')).label, contains(en.keysFirstImportDrop));
      expect(tester.getSemantics(k('keys-first-import')).label, contains(en.keysFirstImportBody));
      // Recommended once, on generate, and its glyph alone in the brand's colour.
      expect(find.text(en.keysFirstRecommended), findsOneWidget);
      expect(find.descendant(of: k('keys-first-generate'), matching: find.text(en.keysFirstRecommended)), findsOneWidget);
      Color glyph(String id, IconData icon) =>
          tester.widget<Icon>(find.descendant(of: k('keys-first-$id'), matching: find.byIcon(icon))).color!;
      expect(glyph('generate', LucideIcons.sparkle), ZestTokens.brandInk);
      expect(glyph('import', LucideIcons.import), ZestTokens.textSecondary);
      expect(glyph('agent', LucideIcons.cpu), ZestTokens.textSecondary);
      expect(glyph('pm', LucideIcons.archive), ZestTokens.textSecondary);
      // The line for a password, under the cards.
      expect(tester.getTopLeft(k('keys-first-new-password')).dy, greaterThan(agent.dy));
      expect(find.text(en.zestKeysNewPassword), findsOneWidget);
      // The old page: one faint key, "No keys yet" and New SSH key.
      expect(find.text(en.keysListNoKeysYetTitle), findsNothing);
      expect(find.text('New SSH key'), findsNothing);
      semantics.dispose();
      await finish(tester);
    });

    testWidgets('What is an SSH key? opens the docs page on SSH keys, in the browser', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      await tester.tap(k('keys-first-what-is-key'));
      await settle(tester);
      expect(opened, [Uri.parse(kZestDocsWhatIsAnSshKey)]);
      expect(kZestDocsWhatIsAnSshKey, 'https://docs.zestssh.com/getting-started/what-is-an-ssh-key/');
      await finish(tester);
    });

    testWidgets('Generate a new key opens the generator, as New key opens it', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      await tester.tap(k('keys-first-generate'));
      await settle(tester);
      expect(find.byType(KeyGenerationScreen), findsOneWidget);
      await finish(tester);
    });

    testWidgets("Import a key file opens the new key's editor, as New key's Import or paste key does, with its key "
        'setup open at Import; cancelled there, the editor stays', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      await tester.tap(k('keys-first-import'));
      await settle(tester);
      expect(find.byType(KeySetupDialog), findsOneWidget);
      expect(find.text(en.identityChooseKeyFile), findsOneWidget, reason: 'the Import tab');
      expect(find.byType(KeysDetailPane), findsOneWidget);
      expect((editor(tester).isCreating, editor(tester).authMethod), (true, AuthMethod.publicKey));
      await tester.tap(find.text(en.cancel).last);
      await settle(tester);
      expect(find.byType(KeySetupDialog), findsNothing);
      expect(find.byType(KeysDetailPane), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a key pasted there goes into the new key, its line made from it', (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generateEd25519(comment: 'demo@example.com')))!;
      await pumpApp(tester, const KeysView());
      await tester.tap(k('keys-first-import'));
      await settle(tester);
      await tester.tap(find.text(en.identityPaste).first);
      await settle(tester);
      await tester.enterText(find.descendant(of: find.byType(KeySetupDialog), matching: find.byType(TextField)), made.privatePem);
      await tester.tap(find.text(en.identityLoadKey));
      await settle(tester);
      expect(find.byType(KeySetupDialog), findsNothing);
      expect(editor(tester).publicKeyFingerprint, made.fingerprint);
      await finish(tester);
    });

    testWidgets('Use the keys in your SSH agent opens the agent, as New key does', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      await tester.tap(k('keys-first-agent'));
      await settle(tester);
      expect(find.byType(HardwareTokenDialog), findsOneWidget);
      await finish(tester);
    });

    testWidgets('From a password manager opens its choice, as New key does', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      await tester.tap(k('keys-first-pm'));
      await settle(tester);
      expect(find.text(en.pmAddNote), findsOneWidget);
      await finish(tester);
    });

    testWidgets("New saved password opens a new password's editor, as New key does", (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      await tester.tap(k('keys-first-new-password'));
      await settle(tester);
      expect((editor(tester).isCreating, editor(tester).authMethod), (true, AuthMethod.password));
      await finish(tester);
    });

    testWidgets('by keyboard: after What is an SSH key?, Tab reaches Generate a new key, and Enter opens it',
        (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      Focus.of(tester.element(k('keys-first-what-is-key'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(Focus.of(tester.element(k('keys-first-generate'))).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byType(KeyGenerationScreen), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a key file dropped on the page: the page is lit while it is dragged over, then the key opens in the '
        "new key's editor, named after its file", (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generateEd25519(comment: 'demo@example.com')))!;
      final path = write('deploy-key', made.privatePem);
      await pumpApp(tester, const KeysView());
      expect(find.text(en.keysDropHint), findsNothing);
      await dragOver(tester, const Offset(720, 500));
      expect(find.text(en.keysDropHint), findsOneWidget, reason: 'lit while dragged over');
      await event(tester, 'performOperation', [path]);
      await until(tester, find.byType(KeysDetailPane));
      expect(find.text(en.keysDropHint), findsNothing);
      final c = editor(tester);
      expect((c.isCreating, c.authMethod, c.publicKeyFingerprint, c.nameController.text),
          (true, AuthMethod.publicKey, made.fingerprint, 'deploy-key'));
      expect(c.publicKeyData, startsWith('ssh-ed25519 '));
      await finish(tester);
    });

    testWidgets('a drag that leaves the page puts its light out, and adds nothing', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysView());
      await dragOver(tester, const Offset(720, 500));
      expect(find.text(en.keysDropHint), findsOneWidget);
      await event(tester, 'exited', null);
      expect(find.text(en.keysDropHint), findsNothing);
      expect(find.byType(KeysDetailPane), findsNothing);
      await finish(tester);
    });

    testWidgets('a key dropped with its .pub: the private key is the one added', (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generateEd25519(comment: 'demo@example.com')))!;
      final key = write('id_ed25519', made.privatePem);
      final pub = write('id_ed25519.pub', '${made.publicOpenSSH}\n');
      await pumpApp(tester, const KeysView());
      await drop(tester, [pub, key]);
      await until(tester, find.byType(KeysDetailPane));
      expect((editor(tester).publicKeyFingerprint, editor(tester).nameController.text), (made.fingerprint, 'id_ed25519'));
      await finish(tester);
    });

    testWidgets('a sealed key: its passphrase asked for, then the editor with the key, kept with its passphrase',
        (tester) async {
      await build(tester);
      final path = write('id_ed25519', _sealedKey);
      await pumpApp(tester, const KeysView());
      await drop(tester, [path]);
      await until(tester, find.text(en.identityKeyPassphrase));
      await tester.enterText(find.byType(TextField).last, _demoPassphrase);
      await tester.tap(find.text(en.passphrasePromptUnlock));
      await until(tester, find.byType(KeysDetailPane));
      expect((editor(tester).keyPassphrase, editor(tester).keyType), (_demoPassphrase, 'ssh-ed25519'));
      await finish(tester);
    });

    for (final (what, files, words) in <(String, List<(String, String)>, String Function(AppLocalizations))>[
      ('a public key alone', [('id_ed25519.pub', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDPJ8PTd0sTg demo@example.com\n')],
          (l) => l.keysDropPublicKey),
      ('a file that is no key', [('notes.txt', 'Dear team,\nthe servers move on Friday.\n')], (l) => l.keyImportNotAKey),
    ]) {
      testWidgets('$what: refused, said, and nothing opens', (tester) async {
        await build(tester);
        await pumpApp(tester, const KeysView());
        await drop(tester, [for (final (name, text) in files) write(name, text)]);
        await told(tester, words(en));
        expect(find.byType(KeysDetailPane), findsNothing);
        expect(await tester.runAsync(() => db.identitiesDao.getAll()), isEmpty);
        await tester.pump(const Duration(seconds: 10));
        await finish(tester);
      });
    }

    testWidgets('two private keys at once: one at a time is said, and nothing opens', (tester) async {
      await build(tester);
      final one = (await tester.runAsync(() => service.generateEd25519(comment: 'one@example.com')))!;
      final two = (await tester.runAsync(() => service.generateEd25519(comment: 'two@example.com')))!;
      await pumpApp(tester, const KeysView());
      await drop(tester, [write('one', one.privatePem), write('two', two.privatePem)]);
      await told(tester, en.keysDropOneAtATime);
      expect(find.byType(KeysDetailPane), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      await finish(tester);
    });

    testWidgets('in a team vault this account may not add to: nothing to start with, as New key is not there, and '
        'nothing is taken by a drop', (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generateEd25519(comment: 'demo@example.com')))!;
      await pumpApp(tester, const KeysView(), extra: [
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace('o-demo')),
        activeOrchardProvider.overrideWithValue(const AsyncData(null)),
      ]);
      expect(find.text(en.keysListNoKeysYetTitle), findsOneWidget);
      expect(k('keys-first-steps'), findsNothing);
      expect(k('keys-new-identity'), findsNothing);
      await drop(tester, [write('deploy-key', made.privatePem)]);
      expect(find.text(en.keysDropHint), findsNothing);
      expect(find.byType(KeysDetailPane), findsNothing);
      await finish(tester);
    });

    testWidgets('a key file dropped while a list is shown opens it too', (tester) async {
      await build(tester);
      await tester.runAsync(() => crud.create(label: 'ops', username: 'ops', authMethod: 'password', password: 'x'));
      final made = (await tester.runAsync(() => service.generateEd25519(comment: 'demo@example.com')))!;
      await pumpApp(tester, const KeysView());
      expect(k('keys-first-steps'), findsNothing, reason: 'a key is saved');
      await drop(tester, [write('laptop', made.privatePem)], at: const Offset(400, 700));
      await until(tester, find.byType(KeysDetailPane));
      expect(editor(tester).publicKeyFingerprint, made.fingerprint);
      await finish(tester);
    });
  });

  group('a phone', () {
    testWidgets('with nothing saved: the same heading and ways as a list, generate recommended and import, no agent or '
        'password manager and no drop, and New saved password a finger high', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysPhoneScreen(), size: const Size(390, 844));
      final semantics = tester.ensureSemantics();
      expect(find.text(en.keysFirstTitle), findsOneWidget);
      expect(find.text(en.keysFirstWhatIsKey), findsOneWidget);
      expect(k('keys-first-generate'), findsOneWidget);
      expect(k('keys-first-import'), findsOneWidget);
      expect(k('keys-first-agent'), findsNothing);
      expect(k('keys-first-pm'), findsNothing);
      expect(tester.getTopLeft(k('keys-first-import')).dy, greaterThan(tester.getTopLeft(k('keys-first-generate')).dy));
      expect(find.descendant(of: k('keys-first-generate'), matching: find.text(en.keysFirstRecommended)), findsOneWidget);
      expect(tester.getSemantics(k('keys-first-import')).label, isNot(contains(en.keysFirstImportDrop)));
      for (final id in ['generate', 'import']) {
        expect(tester.getSize(k('keys-first-$id')).height, greaterThanOrEqualTo(48), reason: id);
        expect(tester.getSemantics(k('keys-first-$id')), isSemantics(isButton: true), reason: id);
      }
      expect(tester.getSize(k('keys-first-new-password')).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(k('keys-first-what-is-key')).height, greaterThanOrEqualTo(48));
      expect(find.text(en.identityNoIdentities), findsNothing, reason: 'the old page');
      semantics.dispose();
      await finish(tester);
    });

    testWidgets("Import a key file: the key setup at Import, and a key loaded there opens in the key's form",
        (tester) async {
      await build(tester);
      final made = (await tester.runAsync(() => service.generateEd25519(comment: 'demo@example.com')))!;
      await pumpApp(tester, const KeysPhoneScreen(), size: const Size(390, 844));
      await tester.tap(k('keys-first-import'));
      await settle(tester);
      expect(find.byType(KeySetupDialog), findsOneWidget);
      expect(find.text(en.identityChooseKeyFile), findsOneWidget);
      await tester.tap(find.text(en.identityPaste).first);
      await settle(tester);
      await tester.enterText(find.descendant(of: find.byType(KeySetupDialog), matching: find.byType(TextField)), made.privatePem);
      await tester.tap(find.text(en.identityLoadKey));
      await settle(tester);
      expect(find.byType(IdentityEditScreen), findsOneWidget);
      final key = tester.widget<IdentityEditScreen>(find.byType(IdentityEditScreen)).initialImportedKey!;
      expect(key.fingerprint, made.fingerprint);
      await finish(tester);
    });

    testWidgets('New saved password opens the key form; Generate a new key the generator', (tester) async {
      await build(tester);
      await pumpApp(tester, const KeysPhoneScreen(), size: const Size(390, 844));
      await tester.tap(k('keys-first-new-password'));
      await settle(tester);
      expect(find.byType(IdentityEditScreen), findsOneWidget);
      expect(tester.widget<IdentityEditScreen>(find.byType(IdentityEditScreen)).initialImportedKey, isNull);
      await finish(tester);

      await build(tester);
      await pumpApp(tester, const KeysPhoneScreen(), size: const Size(390, 844));
      await tester.tap(k('keys-first-generate'));
      await settle(tester);
      expect(find.byType(KeyGenerationScreen), findsOneWidget);
      await finish(tester);
    });
  });
}
