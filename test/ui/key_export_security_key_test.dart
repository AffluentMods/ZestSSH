import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_action_dialogs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/redactor.dart';

import '../a11y/a11y_checks.dart';

/// The Keys page's Export dialog says of a security key's key file what the
/// key editor says: it holds no secret (only the key handle and the public
/// key) and signs in only with the security key itself, in place of the
/// private key's warning and of the warning that a file written with no
/// passphrase signs in as the person. A private key keeps both warnings.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late SharedPreferences prefs;

  /// A security key's key file (made-up bytes: a key handle and a public key).
  final skPair = OpenSSHSkKeyPair(
    type: OpenSSHSkKeyPair.ed25519Type,
    publicKey: Uint8List.fromList(List.generate(32, (i) => i + 7)),
    application: 'ssh:',
    flags: OpenSSHSkKeyPair.flagUserPresenceRequired,
    keyHandle: Uint8List.fromList(List.generate(48, (i) => 200 - i)),
    comment: 'demo@example.com',
  );
  final skPem = skPair.toPem();
  final skLine = '${skPair.name} ${base64.encode(skPair.toPublicKey().encode())}';

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done, String what) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: what);
  }

  Future<Identity> seed(WidgetTester tester, {required String pem, required String line}) async {
    late Identity identity;
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      final id = await crud.create(
        label: 'Demo key',
        username: 'demo',
        authMethod: 'publicKey',
        keyType: 'demo',
        publicKeyData: line,
        privateKeyPem: pem,
      );
      identity = (await db.identitiesDao.getById(id))!;
    });
    addTearDown(() => tester.runAsync(db.close));
    return identity;
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        localStateStoreProvider.overrideWithValue(LocalStateStore(db)),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Center(child: child)),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  final note = find.byKey(const ValueKey('keys-export-security-key-note'));
  final warning = find.byKey(const ValueKey('keys-export-private-warning'));
  final openWarning = find.byKey(const ValueKey('keys-export-open-warning'));

  Future<void> chooseNoPassphrase(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('keys-export-protection')));
    await settle(tester);
    await tester.tap(find.text(l10n.keysExportNoPassphrase).last);
    await settle(tester);
  }

  testWidgets('a security key file gets the note that it holds no secret, even written with no passphrase',
      (tester) async {
    final handle = tester.ensureSemantics();
    final identity = await seed(tester, pem: skPem, line: skLine);
    final out = <String, List<int>>{};
    await pump(
      tester,
      KeyExportDialog(
        keyToExport: identity,
        onWrite: (files, {subject, written}) async => out.addAll(files),
      ),
    );
    expect(note, findsOneWidget);
    expect(find.descendant(of: note, matching: find.text(l10n.identityExportSecurityKeyNote)), findsOneWidget);
    expect(warning, findsNothing);
    expect(find.text(l10n.keysExportPrivateWarning), findsNothing);
    await expectA11y(tester, computer: true, where: 'the Keys page export of a security key file');

    await chooseNoPassphrase(tester);
    expect(openWarning, findsNothing, reason: 'written open, it still signs in only with the security key');
    expect(note, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('keys-export-go')));
    await until(tester, () => out.isNotEmpty, 'the files written');
    final private = utf8.decode(out[keyExportFileNames(identity).private]!);
    expect(SSHKeyPair.fromPem(private).single, isA<OpenSSHSkKeyPair>());
    handle.dispose();
    await finish(tester);
  });

  testWidgets('a private key keeps the warning, and the one for a file with no passphrase', (tester) async {
    final made = (await tester.runAsync(() => KeyGenerationService().generateEd25519(comment: 'demo')))!;
    final identity = await seed(tester, pem: made.privatePem, line: made.publicOpenSSH.trim());
    await pump(
      tester,
      KeyExportDialog(keyToExport: identity, onWrite: (files, {subject, written}) async {}),
    );
    expect(warning, findsOneWidget);
    expect(find.text(l10n.keysExportPrivateWarning), findsOneWidget);
    expect(note, findsNothing);
    await chooseNoPassphrase(tester);
    expect(openWarning, findsOneWidget);
    await finish(tester);
  });
}
