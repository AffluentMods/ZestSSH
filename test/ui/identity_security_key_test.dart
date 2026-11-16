import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/fido/fido_key_pair.dart';
import 'package:zestssh/services/fido/fido_platform.dart';
import 'package:zestssh/services/fido/fido_signer.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/utils/redactor.dart';

import '../services/fido/soft_key.dart';
import '../services/fido/test_phone.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The key editor on a phone offers a key made on a security key (4.0): the
/// key is made on the security key held to the phone, and what comes back,
/// its key file with nothing secret in it, becomes this key as any key
/// does. A computer, which leaves a security key to the system's SSH agent,
/// does not offer it.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late String id;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// The editor of a key with no key set yet.
  Future<void> open(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      id = await crud.create(label: 'deploy key', username: 'deploy', authMethod: 'publicKey');
    });
    addTearDown(() => tester.runAsync(db.close));
    tester.view.physicalSize = const Size(1400, 1800);
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

  final option = find.byKey(const ValueKey('key-option-security-key'));

  String plain(String text) => text.replaceAll(' ', ' ');

  /// Whether [message] was said: on screen, or as a computer's notice.
  bool said(WidgetTester tester, String message) =>
      find.text(message).evaluate().isNotEmpty ||
      ProviderScope.containerOf(tester.element(find.byType(IdentityEditScreen)))
          .read(notificationCenterProvider)
          .history
          // (A notice keeps its last two words together with a space that does not break.)
          .any((n) => plain(n.title) == message || plain(n.body ?? '') == message);

  tearDown(() {
    debugSpeaksToSecurityKeys = null;
    fidoSigner = FidoSigner();
  });

  testWidgets('a computer does not offer it: the key file of a security key comes in by Paste or Import', (tester) async {
    debugSpeaksToSecurityKeys = false;
    await open(tester);
    expect(find.text(l10n.identityImportFromFile), findsOneWidget);
    expect(option, findsNothing);
    await finish(tester);
  });

  testWidgets('a phone offers it; the key is made on the security key held to it and becomes this key', (tester) async {
    debugSpeaksToSecurityKeys = true;
    final soft = SoftKey();
    fidoSigner = FidoSigner(
      platform: TestPhone(waysNow: const FidoWays(nfc: true, nfcOn: true, usb: false))..cards.add(SoftNfcCard(soft)),
    );
    await open(tester);
    expect(option, findsOneWidget);
    expect(find.descendant(of: option, matching: find.text(l10n.fidoMakeOption)), findsOneWidget);
    expect(find.descendant(of: option, matching: find.text(l10n.fidoMakeOptionDesc)), findsOneWidget);

    await tester.ensureVisible(option);
    await tester.tap(option);
    await settle(tester);
    expect(find.byKey(const ValueKey('fido-make-key')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fido-make-go')));
    await settle(tester);

    // The key was made on the security key (one makeCredential), and the editor holds its key file.
    expect(soft.commands.where((c) => c == 0x01), hasLength(1));
    expect(said(tester, l10n.identitySshKeyLoaded(OpenSSHSkKeyPair.ed25519Type)), isTrue);
    expect(option, findsNothing, reason: 'the key is set: its options are gone');
    expect(find.text(l10n.identityManageKey), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a key that cannot be made says why, and nothing is set', (tester) async {
    debugSpeaksToSecurityKeys = true;
    fidoSigner = FidoSigner(
      platform: TestPhone(waysNow: const FidoWays(nfc: true, nfcOn: true, usb: false))
        ..cards.add(SoftNfcCard(SoftKey(makesEd25519: false))),
    );
    await open(tester);
    await tester.ensureVisible(option);
    await tester.tap(option);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('fido-make-go')));
    await settle(tester);
    expect(said(tester, l10n.fidoFailCannotMake), isTrue);
    expect(option, findsOneWidget);
    await finish(tester);
  });
}
