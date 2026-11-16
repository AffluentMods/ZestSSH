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
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/utils/redactor.dart';

/// A key's own password, tried after the key, where it is set (3.0, accounts
/// per host, where an identity holds a key and
/// a password): the field below the key in the phone's key editor and on a
/// computer's Keys screen. It shows the password tried after the key, and a
/// save changes it only where the field was changed; one left from before
/// the identity became a key is neither shown nor touched.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late SharedPreferences prefs;
  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late String withOne;
  late String leftOver;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// A key with its own password tried after it ("deploy key"), and a key
  /// with a password left from when it was a password key ("old key").
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        withOne = await crud.create(
            label: 'deploy key',
            username: 'deploy',
            authMethod: 'publicKey',
            privateKeyPem: 'not read here',
            password: 'saved-with-the-key',
            passwordAfterKey: true);
        leftOver = await crud.create(
            label: 'old key', username: 'deploy', authMethod: 'password', password: 'from-before');
        await crud.update(id: leftOver, authMethod: 'publicKey', privateKeyPem: 'not read here');
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpApp(WidgetTester tester, Widget home, {Size size = const Size(1200, 1600)}) async {
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

  Finder field() =>
      find.descendant(of: find.byKey(const ValueKey('password-after-key')), matching: find.byType(EditableText));
  String shown(WidgetTester tester) => tester.widget<EditableText>(field()).controller.text;

  Future<(bool, String?)> stored(WidgetTester tester, String id) async {
    final identity = await tester.runAsync(() => db.identitiesDao.getById(id));
    final password = await tester.runAsync(() => crud.getPassword(id));
    return (identity!.passwordAfterKey, password);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.ensureVisible(field());
    await tester.enterText(field(), text);
    await settle(tester);
  }

  group('phone key editor', () {
    Future<void> open(WidgetTester tester, String id) async {
      await pumpApp(tester, IdentityEditScreen(identityId: id, embedded: true, onClose: (_) {}));
      expect(find.text(l10n.identityPasswordAfterKey), findsOneWidget);
      expect(find.text(l10n.identityPasswordAfterKeyNote), findsOneWidget);
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byTooltip(l10n.save));
      await settle(tester);
    }

    testWidgets('a key with its own password: shown; changed, it is tried; emptied, it is taken off', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await open(tester, withOne);
      expect(shown(tester), 'saved-with-the-key');
      await type(tester, 'changed-one');
      await save(tester);
      expect(await stored(tester, withOne), (true, 'changed-one'));

      await open(tester, withOne);
      await type(tester, '');
      await save(tester);
      expect(await stored(tester, withOne), (false, null));
      await finish(tester);
    });

    testWidgets('a password left from before it was a key: not shown, not touched by a save, replaced when typed',
        (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await open(tester, leftOver);
      expect(shown(tester), '');
      await save(tester);
      expect(await stored(tester, leftOver), (false, 'from-before'));

      await open(tester, leftOver);
      await type(tester, 'tried-after-the-key');
      await save(tester);
      expect(await stored(tester, leftOver), (true, 'tried-after-the-key'));
      await finish(tester);
    });
  });

  group("a computer's Keys screen", () {
    Future<void> open(WidgetTester tester, String label) async {
      await pumpApp(tester, const KeysView(), size: const Size(1400, 1600));
      await tester.tap(find.text(label).first);
      await settle(tester);
      // Its private details are behind Edit.
      await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
      await settle(tester);
      expect(find.text(l10n.identityPasswordAfterKey), findsOneWidget);
      expect(find.text(l10n.identityPasswordAfterKeyNote), findsOneWidget);
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.text(l10n.save).last);
      await settle(tester);
    }

    testWidgets('a key with its own password: shown; changed, it is tried; emptied, it is taken off', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await open(tester, 'deploy key');
      expect(shown(tester), 'saved-with-the-key');
      await type(tester, 'changed-one');
      await save(tester);
      expect(await stored(tester, withOne), (true, 'changed-one'));

      await type(tester, '');
      await save(tester);
      expect(await stored(tester, withOne), (false, null));
      await finish(tester);
    });

    testWidgets('a password left from before it was a key: not shown, not touched by a save, replaced when typed',
        (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await open(tester, 'old key');
      expect(shown(tester), '');
      await tester.enterText(
          find.descendant(of: find.byType(KeysView), matching: find.byType(EditableText)).first, 'old key, renamed');
      await settle(tester);
      await save(tester);
      expect(await stored(tester, leftOver), (false, 'from-before'));

      await type(tester, 'tried-after-the-key');
      await save(tester);
      expect(await stored(tester, leftOver), (true, 'tried-after-the-key'));
      await finish(tester);
    });
  });
}
