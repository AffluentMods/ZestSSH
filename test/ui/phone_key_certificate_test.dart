import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/ssh_cert_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/ssh_cert/ssh_cert_signer.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/cert_import_dialog.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;
import 'package:zestssh/utils/redactor.dart';

import '../a11y/a11y_checks.dart';

/// A phone adds an OpenSSH certificate to a key from the key's own editor
/// (the 4.0 platform comparison: the certificate dialogs were only on a
/// computer's Keys page, which a large tablet has too, so a phone was the one
/// device without them; its editor said "Certificates are added in the
/// desktop app"). The row opens the same Import certificate, with this key
/// picked where the certificate is for it; once attached the editor holds a
/// key with its certificate, and a Save keeps the certificate.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(l10n));

  late SharedPreferences prefs;
  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late String keyId;
  late String certificateLine;
  late String otherCertificateLine;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    debugTouchLayout = true;
  });
  tearDown(() => debugTouchLayout = null);

  String certificateFor(String pem, SSHKeyPair authority) => '${SshCertAlgorithm.ed25519.name} '
      '${base64.encode(SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: SSHKeyPair.fromPem(pem).single.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 7,
          type: SshCertType.user,
          keyId: 'deploy',
          principals: const ['deploy'],
          validAfter: DateTime.utc(2026, 9, 1),
          validBefore: DateTime.utc(2036, 9, 1),
        ),
        caKey: authority,
      ))} deploy@demo';

  /// A saved key ("deploy key"), a certificate signed for it, and one signed
  /// for another key.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        final keys = KeyGenerationService();
        final mine = await keys.generateEd25519(comment: 'deploy');
        final other = await keys.generateEd25519(comment: 'other');
        final authority = SSHKeyPair.fromPem((await keys.generateEd25519(comment: 'authority')).privatePem).single;
        keyId = await crud.create(
          label: 'deploy key',
          username: 'deploy',
          authMethod: 'publicKey',
          keyType: 'ssh-ed25519',
          publicKeyFingerprint: mine.fingerprint,
          publicKeyData: mine.publicOpenSSH,
          privateKeyPem: mine.privatePem,
        );
        certificateLine = certificateFor(mine.privatePem, authority);
        otherCertificateLine = certificateFor(other.privatePem, authority);
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> open(WidgetTester tester) async {
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
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: IdentityEditScreen(identityId: keyId, embedded: true, onClose: (_) {})),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(db.close);
  }

  Finder row() => find.byKey(const ValueKey('identity-add-certificate'));

  Future<void> paste(WidgetTester tester, String line) async {
    await tester.tap(row());
    await settle(tester);
    expect(find.byType(CertImportDialog), findsOneWidget);
    await tester.enterText(
        find.descendant(of: find.byType(CertImportDialog), matching: find.byType(TextField)).first, line);
    await settle(tester);
  }

  testWidgets('a saved key has Add certificate; the certificate for it is picked, attached, and kept by a Save',
      (tester) async {
    await build(tester);
    await open(tester);
    expect(find.textContaining('added in the desktop app'), findsNothing, reason: 'no "added in the desktop app"');
    await tester.ensureVisible(row());
    await settle(tester);
    expect(find.descendant(of: row(), matching: find.text(l10n.identityAddCertificate)), findsOneWidget);
    expect(find.descendant(of: row(), matching: find.text(l10n.identityAddCertificateDesc)), findsOneWidget);
    expect(tester.getSize(row()).height, greaterThanOrEqualTo(48), reason: "a finger's row");

    await paste(tester, certificateLine);
    // This key is picked at once: Attach is ready.
    await tester.tap(find.text(l10n.certImportAttachCertificate));
    await settle(tester);
    expect(find.byType(CertImportDialog), findsNothing);
    var saved = (await tester.runAsync<Identity?>(() => db.identitiesDao.getById(keyId)))!;
    expect(saved.authMethod, 'certificate');
    expect(saved.certKeyId, 'deploy');
    expect(await tester.runAsync(() => ProviderScope.containerOf(tester.element(row()))
        .read(sshCertServiceProvider)
        .loadCertForIdentity(keyId)), isNotNull);

    // The editor follows: a key with its certificate, which Save keeps.
    expect(find.descendant(of: row(), matching: find.text(l10n.identityReplaceCertificate)), findsOneWidget);
    expect(find.text(l10n.identityKeyLoaded('ssh-ed25519')), findsOneWidget, reason: 'its key is still shown');
    await tester.tap(find.byTooltip(l10n.save));
    await settle(tester);
    saved = (await tester.runAsync<Identity?>(() => db.identitiesDao.getById(keyId)))!;
    expect(saved.authMethod, 'certificate');
    expect(saved.publicKeyData, isNotNull);
    expect(await tester.runAsync(() => crud.getPrivateKey(keyId)), isNotNull);
    await finish(tester);
  });

  testWidgets('a certificate for another key is not attached to this one', (tester) async {
    await build(tester);
    await open(tester);
    await tester.ensureVisible(row());
    await settle(tester);
    await paste(tester, otherCertificateLine);
    expect(find.text(l10n.certImportNoCompatibleIdentity), findsOneWidget);
    await tester.tap(find.text(l10n.certImportAttachCertificate));
    await settle(tester);
    expect(find.byType(CertImportDialog), findsOneWidget, reason: 'Attach does nothing with no key picked');
    expect((await tester.runAsync<Identity?>(() => db.identitiesDao.getById(keyId)))!.authMethod, 'publicKey');
    await finish(tester);
  });

  testWidgets("the row is held to a phone's accessibility checks: one button a screen reader names and presses, "
      "a finger's size, its words and icons readable", (tester) async {
    await build(tester);
    await open(tester);
    await tester.ensureVisible(row());
    await settle(tester);
    final node = tester.getSemantics(find.text(l10n.identityAddCertificate)).getSemanticsData();
    expect(node.label, contains(l10n.identityAddCertificate));
    expect(node.label, contains(l10n.identityAddCertificateDesc));
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    expect(tester.getSize(row()).height, greaterThanOrEqualTo(48));
    // The whole editor, at a finger's sizes, with nothing let off (its name
    // and user name fields were 40 high on a phone, its choice pills 36 and
    // the colour picker's Custom 36, until 4.0).
    await expectA11y(tester, computer: false, where: 'phone key editor with Add certificate');
    await finish(tester);
  });
}
