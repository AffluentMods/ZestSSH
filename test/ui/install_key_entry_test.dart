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
import 'package:zestssh/features/run/install_key_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/utils/redactor.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Install key on hosts (3.0) is offered where a key is: on a computer's
/// Keys screen beside Export public key, and in the phone's key editor; for a
/// key, with its public key or one made from its private key (16 October
/// 2026: a key made in the app kept none, and it was not offered), never for a
/// password. It opens for that key.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTheTestOnly alex@laptop';

  late SharedPreferences prefs;
  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late String withPublic;
  late String password;
  late String bare;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// A key with its public key ("deploy key"), a key without one ("bare
  /// key"), and a password ("ops login").
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        withPublic = await crud.create(
            label: 'deploy key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: 'not read here');
        await db.customStatement('UPDATE identities SET public_key_data = ? WHERE id = ?', [line, withPublic]);
        password = await crud.create(label: 'ops login', username: 'ops', authMethod: 'password', password: 'x');
        bare = await crud.create(
            label: 'bare key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: 'not read here');
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpApp(WidgetTester tester, Widget home, {Size size = const Size(1400, 1600)}) async {
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
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  InstallKeyDialog dialog(WidgetTester tester) => tester.widget<InstallKeyDialog>(find.byType(InstallKeyDialog));

  testWidgets("a computer's Keys screen: beside Export public key for a key, and it opens for that key; for a key "
      'that kept no public key too (it is made from its private key there); not for a password', (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    await pumpApp(tester, const KeysView());
    await tester.tap(find.text('ops login').first);
    await settle(tester);
    expect(find.byKey(const ValueKey('keys-install-on-hosts')), findsNothing);
    await tester.tap(find.text('bare key').first);
    await settle(tester);
    // A key's own actions are there (its details beside the list, 22 October
    // 2026): Copy public key, and Install on hosts at their foot.
    expect(find.byKey(const ValueKey('keys-copy-public')), findsOneWidget, reason: "a key's own buttons are there");
    expect(find.byKey(const ValueKey('keys-install-on-hosts')), findsOneWidget);

    await tester.tap(find.text('deploy key').first);
    await settle(tester);
    final button = find.byKey(const ValueKey('keys-install-on-hosts'));
    expect(button, findsOneWidget);
    expect(find.descendant(of: button, matching: find.text(l10n.installKeyMenu)), findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settle(tester);
    expect(dialog(tester).keyToInstall.id, withPublic);
    await finish(tester);
  });

  testWidgets("the phone's key editor: in its top bar for a key with a public key, and it opens for that key; not "
      'for a password', (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    await pumpApp(tester, IdentityEditScreen(identityId: password, embedded: true, onClose: (_) {}),
        size: const Size(1200, 1600));
    expect(find.byKey(const ValueKey('identity-install-on-hosts')), findsNothing);

    // A key that kept no public key: it is made from its private key there.
    await pumpApp(tester, IdentityEditScreen(identityId: bare, embedded: true, onClose: (_) {}),
        size: const Size(1200, 1600));
    expect(find.byKey(const ValueKey('identity-install-on-hosts')), findsOneWidget);

    await pumpApp(tester, IdentityEditScreen(identityId: withPublic, embedded: true, onClose: (_) {}),
        size: const Size(1200, 1600));
    expect(find.byTooltip(l10n.installKeyMenu), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('identity-install-on-hosts')));
    await settle(tester);
    expect(dialog(tester).keyToInstall.id, withPublic);
    await finish(tester);
  });

  testWidgets("the phone's key editor offers the one list of colours; a pick is kept as its colour, None clears it",
      (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    await pumpApp(tester, IdentityEditScreen(identityId: withPublic, embedded: true, onClose: (_) {}),
        size: const Size(1200, 1600));
    ZestColorPicker picker() => tester.widget<ZestColorPicker>(find.byType(ZestColorPicker));
    expect(picker().presets, AppColors.labelPalette);
    expect(picker().noneSelected, isTrue, reason: 'no colour yet');
    picker().onChanged(AppColors.labelPalette[2]);
    await settle(tester);
    expect(picker().selected, AppColors.labelPalette[2]);
    expect(picker().noneSelected, isFalse, reason: 'orange is a colour here, not the empty default index 0 is');
    picker().onNoneSelected!();
    await settle(tester);
    expect(picker().noneSelected, isTrue);
    await finish(tester);
  });
}
