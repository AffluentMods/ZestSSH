import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;
import 'package:zestssh/utils/redactor.dart';

import '../a11y/a11y_checks.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The key file of a key made on a security key (made-up bytes: a key
/// handle and a public key, nothing secret), as the FIDO2 keys keep it in
/// the private key's place.
OpenSSHSkKeyPair _skKey({bool ecdsa = false}) => OpenSSHSkKeyPair(
      type: ecdsa ? OpenSSHSkKeyPair.ecdsaType : OpenSSHSkKeyPair.ed25519Type,
      publicKey: ecdsa
          ? Uint8List.fromList([0x04, ...List.generate(64, (i) => i + 1)])
          : Uint8List.fromList(List.generate(32, (i) => i + 7)),
      application: 'ssh:',
      flags: OpenSSHSkKeyPair.flagUserPresenceRequired,
      keyHandle: Uint8List.fromList(List.generate(48, (i) => 200 - i)),
      comment: 'demo@example.com',
    );

/// Exporting a key from the key editor asks first. A private key gets the
/// warning that the file signs in as the person; a security key's key file
/// holds no secret (only the key handle and the public key) and is useless
/// without the security key itself, so it gets a lighter note saying exactly
/// that instead.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('isSecurityKeyFile', () {
    test('an Ed25519 or a P-256 security key file is one', () {
      expect(isSecurityKeyFile(_skKey().toPem()), isTrue);
      expect(isSecurityKeyFile(_skKey(ecdsa: true).toPem()), isTrue);
    });

    test('one sealed under a passphrase is told by its public key, which is not sealed', () {
      final sealed = OpenSSHKeyPairs(
        cipherName: 'aes256-ctr',
        kdfName: 'bcrypt',
        kdfOptions: OpenSSHBcryptKdfOptions(Uint8List.fromList(List.generate(16, (i) => i)), 16),
        publicKeys: [_skKey().toPublicKey().encode()],
        privateKeyBlob: Uint8List.fromList(List.generate(64, (i) => i)),
      ).toPem();
      expect(isSecurityKeyFile(sealed), isTrue);
    });

    test('a private key, or what is not a key, is not', () async {
      final ed25519 = await KeyGenerationService().generateEd25519(comment: 'demo');
      expect(isSecurityKeyFile(ed25519.privatePem), isFalse);
      expect(isSecurityKeyFile(''), isFalse);
      expect(isSecurityKeyFile('not a key'), isFalse);
      expect(isSecurityKeyFile('-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----'), isFalse);
    });
  });

  group('the export dialog', () {
    late AppDatabase db;

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    /// The editor of a key whose private key slot holds [pem].
    Future<void> open(WidgetTester tester, String pem, {Size size = const Size(1400, 1800)}) async {
      AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      late String id;
      late IdentityCrudNotifier crud;
      await tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        id = await crud.create(
            label: 'demo key', username: 'demo', authMethod: 'publicKey', privateKeyPem: pem, keyType: 'demo');
      });
      addTearDown(() => tester.runAsync(db.close));
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
          theme: BuiltInThemes.getById('default_dark').toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: IdentityEditScreen(identityId: id, embedded: true, onClose: (_) {})),
        ),
      ));
      await settle(tester);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
    }

    final export = find.byTooltip(l10n.identityExportPrivateKey);
    // The dialog's Cancel (the editor has one of its own).
    final dialogCancel = find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(l10n.cancel));

    Future<void> tapExport(WidgetTester tester) async {
      expect(export, findsOneWidget);
      await tester.tap(export);
      await settle(tester);
    }

    testWidgets('a security key file gets the note that it holds no secret, not the private key warning',
        (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, _skKey().toPem());
      await tapExport(tester);

      expect(find.text(l10n.identityExportSecurityKeyTitle), findsOneWidget);
      expect(find.text(l10n.identityExportSecurityKeyNote), findsOneWidget);
      expect(find.text(l10n.identityExportPrivateKeyWarning), findsNothing);
      expect(find.text(l10n.settingsExportLabel), findsOneWidget);
      await expectA11y(tester, computer: true, where: 'the security key export note on a computer');

      // Cancelled: nothing is exported and the dialog is gone.
      await tester.tap(dialogCancel);
      await settle(tester);
      expect(find.text(l10n.identityExportSecurityKeyNote), findsNothing);
      handle.dispose();
      await finish(tester);
    });

    testWidgets('on a phone the note is a sheet a finger can use', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugTouchLayout = true;
      final handle = tester.ensureSemantics();
      try {
        await open(tester, _skKey(ecdsa: true).toPem(), size: const Size(412, 900));
        await tapExport(tester);
        expect(find.text(l10n.identityExportSecurityKeyNote), findsOneWidget);
        expect(find.text(l10n.identityExportPrivateKeyWarning), findsNothing);
        await expectA11y(tester, computer: false, where: 'the security key export note on a phone');
        await tester.tap(dialogCancel);
        await settle(tester);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTouchLayout = null;
        handle.dispose();
      }
    });

    testWidgets('a private key still gets the warning that the file signs in as the person', (tester) async {
      final made = (await tester.runAsync(() => KeyGenerationService().generateEd25519(comment: 'demo')))!;
      await open(tester, made.privatePem);
      await tapExport(tester);
      expect(find.text(l10n.identityExportPrivateKey), findsWidgets);
      expect(find.text(l10n.identityExportPrivateKeyWarning), findsOneWidget);
      expect(find.text(l10n.identityExportSecurityKeyNote), findsNothing);
      await tester.tap(dialogCancel);
      await settle(tester);
      await finish(tester);
    });
  });
}
