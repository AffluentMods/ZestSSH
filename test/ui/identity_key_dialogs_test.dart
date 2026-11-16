import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show KeyType;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Every dialog opened over the page, counted as it opens.
class _Opened extends NavigatorObserver {
  final dialogs = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) dialogs.add(route);
  }
}

/// The key editor's dialogs for its key, in the shell (the dialog rules of
/// 3.4): the key that is set was a dialog of buttons whose Export
/// opened a second dialog (its only choice Copy text), whose Delete opened a
/// second one to type DELETE in, and whose Change key a second one again; the
/// passphrase of a sealed key, pasted or chosen, was asked in a dialog over
/// the key setup dialog. Each now changes the one dialog in place.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final service = KeyGenerationService();
  String fixture(String name) => File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/$name')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late String id;
  late _Opened opened;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> open(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      final made = await service.generate(KeyType.ed25519);
      id = await crud.create(
          label: 'deploy key',
          username: 'deploy',
          authMethod: 'publicKey',
          privateKeyPem: made.privatePem,
          publicKeyFingerprint: made.fingerprint);
    });
    addTearDown(() => tester.runAsync(db.close));
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    opened = _Opened();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        isProProvider.overrideWith((ref) => _Pro()),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        navigatorObservers: [opened],
        home: Scaffold(body: IdentityEditScreen(identityId: id, embedded: true, onClose: (_) {})),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text(l10n.identityManageKey));
    await settle(tester);
  }

  /// [f] inside the dialog (the page names the key too).
  Finder inDialog(Finder f) => find.descendant(of: find.byType(ZestDialogShell), matching: f);

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  testWidgets('the key that is set is one dialog, in the shell: its halves copied by icons on them, Done, Change key '
      'and Delete key in the footer; Delete key asks in its place, with DELETE typed, and takes the key away',
      (tester) async {
    await open(tester);
    expect(opened.dialogs, hasLength(1));
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(inDialog(find.text(l10n.identitySshKeyTitle)), findsOneWidget);
    expect(find.byKey(const ValueKey('identity-key-copy-public')), findsOneWidget);
    expect(find.byKey(const ValueKey('identity-key-copy-private')), findsOneWidget);
    for (final key in ['identity-key-done', 'identity-key-change', 'identity-key-delete']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }

    await tester.tap(find.byKey(const ValueKey('identity-key-delete')));
    await settle(tester);
    expect(opened.dialogs, hasLength(1), reason: 'Delete key asks in the same dialog, not over it');
    expect(inDialog(find.text(l10n.identityDeleteKeyTitle)), findsOneWidget);
    expect(inDialog(find.text(l10n.identitySshKeyTitle)), findsNothing);

    // Not before DELETE is typed.
    await tester.tap(find.byKey(const ValueKey('identity-delete-key-go')));
    await settle(tester);
    expect(inDialog(find.text(l10n.identityDeleteKeyTitle)), findsOneWidget);

    // Cancel goes back to the key; Delete key again, typed, takes it away.
    await tester.tap(inDialog(find.text(l10n.cancel)));
    await settle(tester);
    expect(inDialog(find.text(l10n.identitySshKeyTitle)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('identity-key-delete')));
    await settle(tester);
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('identity-delete-key-typed')), matching: find.byType(TextField)),
        'delete');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('identity-delete-key-go')));
    await settle(tester);
    expect(find.byType(ZestDialogShell), findsNothing);
    expect(opened.dialogs, hasLength(1));
    expect(find.text(l10n.identityManageKey), findsNothing, reason: 'the key is gone from the form');
    expect(find.text(l10n.identityGenerateNewKey), findsOneWidget);
    await finish(tester);
  });

  testWidgets("Change key shows the key setup in the dialog's place, with the tab's action in the footer; a sealed "
      "key's passphrase is asked there too, a wrong one said under the field, and the right one loads the key",
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('identity-key-change')));
    await settle(tester);
    expect(opened.dialogs, hasLength(1), reason: 'the key setup in the same dialog');
    expect(find.byType(KeySetupDialog), findsOneWidget);
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('key-setup-go')), matching: find.text(l10n.identityGenerateKey)),
        findsOneWidget, reason: "the generate tab's action is the main button");

    await tester.tap(find.widgetWithText(Tab, l10n.identityPaste));
    await settle(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('key-setup-go')), matching: find.text(l10n.identityLoadKey)),
        findsOneWidget);
    expect(find.byKey(const ValueKey('key-setup-paste')), findsOneWidget, reason: 'Paste, the side option');
    await tester.enterText(find.widgetWithText(TextField, l10n.identityPasteKeyHint), fixture('id_ed25519'));
    await tester.tap(find.byKey(const ValueKey('key-setup-go')));
    await settle(tester);
    expect(find.byKey(const ValueKey('key-setup-passphrase')), findsOneWidget);
    expect(opened.dialogs, hasLength(1), reason: 'the passphrase in the same dialog, not one over it');
    expect(find.byType(ZestDialogShell), findsOneWidget);

    Finder field() =>
        find.descendant(of: find.byKey(const ValueKey('key-setup-passphrase')), matching: find.byType(TextField));
    await tester.enterText(field(), 'not the passphrase');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('key-setup-decrypt')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await settle(tester);
    expect(find.text(l10n.identityIncorrectPassphrase), findsOneWidget, reason: 'said under the field');
    expect(opened.dialogs, hasLength(1));

    await tester.enterText(field(), fixture('passphrase').trim());
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('key-setup-decrypt')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await settle(tester);
    expect(find.byType(ZestDialogShell), findsNothing, reason: 'the key loaded, the dialog closed');
    expect(opened.dialogs, hasLength(1));
    expect(find.text(l10n.identityManageKey), findsOneWidget);
    await finish(tester);
  });
}
