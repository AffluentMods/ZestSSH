import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/profile_providers.dart'
    show refreshPersonState;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_detail_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_inspector_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/widgets/app_lock_offer.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/utils/redactor.dart';

/// The Keys page goes when the computer shows a terminal in its place, and
/// its editor's unsaved edits went with it, with no word. They are kept in
/// memory now, but for the secrets (a password typed, a private key, its
/// passphrase), and the same editor opens again with them, unsaved. (All
/// names and addresses made up.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late SharedPreferences prefs;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The page, and a switch standing for the shell showing a terminal in its
  /// place (the page goes, as it does there).
  Future<(ProviderContainer, ValueNotifier<bool>)> open(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      crud = IdentityCrudNotifier(
        db.identitiesDao,
        IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()),
        db.connectionsDao,
      );
      await crud.create(
        label: 'Cluster nodes',
        username: 'root',
        authMethod: 'password',
        password: 'demo-stored',
      );
    });
    final container = ProviderContainer(
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
    );
    final pageShown = ValueNotifier(true);
    addTearDown(pageShown.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: pageShown,
              builder: (_, shown, _) =>
                  shown ? const KeysView() : const Text('a terminal'),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return (container, pageShown);
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(minutes: 5));
  }

  KeyEditController editor(WidgetTester tester) =>
      tester.widget<KeysDetailPane>(find.byType(KeysDetailPane)).controller;
  bool unsaved(WidgetTester tester) => tester
      .widget<ZestDetailScaffold>(find.byType(ZestDetailScaffold))
      .isDirty;

  Finder field(TextEditingController c) => find.byWidgetPredicate(
    (w) => w is EditableText && identical(w.controller, c),
  );

  /// Whether anything in the preferences holds [typed] (or is a draft).
  bool prefsHold(String typed) => prefs.getKeys().any(
    (k) =>
        k.toLowerCase().contains('draft') || '${prefs.get(k)}'.contains(typed),
  );

  Future<void> awayAndBack(
    WidgetTester tester,
    ValueNotifier<bool> pageShown,
  ) async {
    pageShown.value = false;
    await settle(tester);
    expect(
      find.byType(KeysView),
      findsNothing,
      reason: 'the page went, as it does for a terminal',
    );
    pageShown.value = true;
    await settle(tester);
  }

  Future<void> newPassword(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('keys-new-identity')));
    await settle(tester);
    await tester.tap(find.text(en.zestKeysNewPassword).last);
    await settle(tester);
    final c = editor(tester);
    await tester.enterText(field(c.nameController), 'Staging box');
    await tester.enterText(field(c.usernameController), 'deploy');
    await tester.enterText(field(c.passwordController), 'typed-secret-1');
    await settle(tester);
  }

  testWidgets(
    'a new key typed, a terminal, the page again: its editor as it was, unsaved, without the password typed; '
    'Save leaves nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await newPassword(tester);
      await awayAndBack(tester, pageShown);

      expect(
        find.byType(KeysDetailPane),
        findsOneWidget,
        reason: 'the editor opens again',
      );
      final c = editor(tester);
      expect(c.isCreating, isTrue);
      expect(c.authMethod, AuthMethod.password);
      expect(c.nameController.text, 'Staging box');
      expect(c.usernameController.text, 'deploy');
      expect(
        c.passwordController.text,
        isEmpty,
        reason: 'a password typed is not kept',
      );
      expect(unsaved(tester), isTrue, reason: 'shown as unsaved');
      expect(prefsHold('Staging box'), isFalse, reason: 'kept in memory only');
      expect(prefsHold('typed-secret-1'), isFalse);

      await tester.enterText(field(c.passwordController), 'typed-secret-2');
      await settle(tester);
      final saving = tester
          .widget<KeysDetailPane>(find.byType(KeysDetailPane))
          .onSave();
      await settle(tester);
      expect(await saving, isTrue);
      final rows = (await tester.runAsync(() => db.identitiesDao.getAll()))!;
      expect(rows.where((i) => i.label == 'Staging box'), hasLength(1));
      expect(container.read(keyDraftsProvider).isEmpty, isTrue);

      await awayAndBack(tester, pageShown);
      expect(
        find.byType(KeysDetailPane),
        findsNothing,
        reason: 'nothing unsaved came back: nothing open, as before',
      );
      await finish(tester, container);
    },
  );

  testWidgets(
    "a saved key edited, a terminal, the page again: that key's editor, its stored password read again, the edit "
    'over it, unsaved; Cancel and Discard leave nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await tester.tap(find.text('Cluster nodes'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      var c = editor(tester);
      expect(c.passwordController.text, 'demo-stored');
      await tester.enterText(field(c.nameController), 'Cluster nodes (prod)');
      await tester.enterText(field(c.passwordController), 'typed-secret-3');
      await settle(tester);
      await awayAndBack(tester, pageShown);

      expect(find.byType(KeysDetailPane), findsOneWidget);
      c = editor(tester);
      expect(c.original?.label, 'Cluster nodes');
      expect(c.nameController.text, 'Cluster nodes (prod)');
      expect(
        c.passwordController.text,
        'demo-stored',
        reason: 'the password as stored, read again; the one typed is not kept',
      );
      expect(unsaved(tester), isTrue);

      // Cancel asks, as before; Discard goes back to the key's details.
      tester
          .widget<ZestDetailScaffold>(find.byType(ZestDetailScaffold))
          .onCancel!();
      await settle(tester);
      await tester.tap(find.text(en.zestDiscardDiscard).last);
      await settle(tester);
      expect(find.byType(KeysInspectorPane), findsOneWidget);
      expect(container.read(keyDraftsProvider).isEmpty, isTrue);
      await awayAndBack(tester, pageShown);
      expect(find.byType(KeysDetailPane), findsNothing);
      final rows = (await tester.runAsync(() => db.identitiesDao.getAll()))!;
      expect(rows.single.label, 'Cluster nodes', reason: 'nothing was saved');
      await finish(tester, container);
    },
  );

  testWidgets(
    "a new key's private key and passphrase are not kept, nor its public half",
    (tester) async {
      final (container, pageShown) = await open(tester);
      await tester.tap(find.byKey(const ValueKey('keys-new-identity')));
      await settle(tester);
      await tester.tap(find.text(en.zestKeysNewPassword).last);
      await settle(tester);
      final c = editor(tester);
      await tester.enterText(field(c.nameController), 'Build runner');
      await tester.enterText(field(c.usernameController), 'ci');
      c.setAuthMethod(AuthMethod.publicKey);
      c
        ..privateKeyPem = 'demo-private-key-material'
        ..keyPassphrase = 'demo-passphrase'
        ..publicKeyFingerprint = 'SHA256:demo'
        ..keyType = 'ssh-ed25519'
        ..publicKeyData = 'ssh-ed25519 AAAAdemo ci';
      await settle(tester);
      await awayAndBack(tester, pageShown);

      final back = editor(tester);
      expect(back.authMethod, AuthMethod.publicKey);
      expect(back.nameController.text, 'Build runner');
      expect(back.privateKeyPem, isNull);
      expect(back.keyPassphrase, isNull);
      expect(back.publicKeyFingerprint, isNull);
      expect(back.publicKeyData, isNull);
      expect(unsaved(tester), isTrue);
      await finish(tester, container);
    },
  );

  test('a kept draft holds nothing secret', () {
    final c = KeyEditController()..bindNew(AuthMethod.password);
    addTearDown(c.dispose);
    c.nameController.text = 'Staging box';
    c.passwordController.text = 'typed-secret-4';
    c.privateKeyPem = 'demo-private-key-material';
    c.keyPassphrase = 'demo-passphrase';
    final d = c.snapshot();
    final fields = [
      d.name,
      d.username,
      d.passwordRef,
      d.authMethod,
      d.colorIndex,
      d.colorValue,
      d.original,
    ];
    expect(fields.join('|'), isNot(contains('typed-secret-4')));
    expect(fields.join('|'), isNot(contains('demo-private-key-material')));
    expect(fields.join('|'), isNot(contains('demo-passphrase')));
  });

  testWidgets('a change of profile forgets the edits, kept or on screen', (
    tester,
  ) async {
    final (container, pageShown) = await open(tester);
    await newPassword(tester);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(keyDraftsProvider).isEmpty, isFalse);

    refreshPersonState(container);
    await settle(tester);
    expect(container.read(keyDraftsProvider).isEmpty, isTrue);
    pageShown.value = true;
    await settle(tester);
    expect(find.byType(KeysDetailPane), findsNothing);

    // On screen as the profile changes: the form goes, and nothing of it is
    // kept for the next profile when the page goes after.
    await newPassword(tester);
    refreshPersonState(container);
    await settle(tester);
    expect(find.byType(KeysDetailPane), findsNothing);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(keyDraftsProvider).isEmpty, isTrue);
    expect(prefsHold('Staging box'), isFalse);
    await finish(tester, container);
  });
}
