import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

/// Identities kept as the app keeps them, with saving and deleting made to
/// fail on demand.
class _Crud extends IdentityCrudNotifier {
  _Crud(super.dao, super.secrets, super.connections);

  Object? error;
  Object? createError;

  @override
  Future<String> create({
    required String label,
    required String username,
    required String authMethod,
    String? keyType,
    String? publicKeyFingerprint,
    String? publicKeyData,
    String? password,
    String? privateKeyPem,
    String? keyPassphrase,
    int colorIndex = 0,
    int? colorValue,
    bool allowUnattended = false,
    String? passwordRef,
    String? agentSource,
    bool passwordAfterKey = false,
  }) async {
    if (createError != null) throw createError!;
    return super.create(
      label: label,
      username: username,
      authMethod: authMethod,
      keyType: keyType,
      publicKeyFingerprint: publicKeyFingerprint,
      publicKeyData: publicKeyData,
      password: password,
      privateKeyPem: privateKeyPem,
      keyPassphrase: keyPassphrase,
      colorIndex: colorIndex,
      colorValue: colorValue,
      allowUnattended: allowUnattended,
      passwordRef: passwordRef,
      agentSource: agentSource,
      passwordAfterKey: passwordAfterKey,
    );
  }

  @override
  Future<void> delete(String id) async {
    if (error != null) throw error!;
    await super.delete(id);
  }

  @override
  Future<void> update({
    required String id,
    String? label,
    String? username,
    String? authMethod,
    String? keyType,
    String? publicKeyFingerprint,
    String? publicKeyData,
    String? password,
    String? privateKeyPem,
    String? keyPassphrase,
    int? colorIndex,
    int? colorValue,
    bool clearColorValue = false,
    bool? allowUnattended,
    String? passwordRef,
    bool clearPasswordRef = false,
    bool? passwordAfterKey,
    bool clearPassword = false,
  }) async {
    if (error != null) throw error!;
    await super.update(
      id: id,
      label: label,
      username: username,
      authMethod: authMethod,
      keyType: keyType,
      publicKeyFingerprint: publicKeyFingerprint,
      publicKeyData: publicKeyData,
      password: password,
      privateKeyPem: privateKeyPem,
      keyPassphrase: keyPassphrase,
      colorIndex: colorIndex,
      colorValue: colorValue,
      clearColorValue: clearColorValue,
      allowUnattended: allowUnattended,
      passwordRef: passwordRef,
      clearPasswordRef: clearPasswordRef,
      passwordAfterKey: passwordAfterKey,
      clearPassword: clearPassword,
    );
  }
}

/// The Keys screen on a computer (3.0): its save and
/// delete failures, its question before deleting and its export notices were
/// English in every language, the failures with the raw error glued on, and a
/// list that could not be loaded said "Error:" and the raw error.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  const publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo demo@northwind.example';

  late SharedPreferences prefs;
  late AppDatabase db;
  late _Crud crud;
  late String prod;
  final copied = <String>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    copied.clear();
  });

  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = _Crud(db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        prod = await crud.create(label: 'prod', username: 'deploy', authMethod: 'password', password: 'demo-pass-for-tests');
        await crud.create(label: 'bare', username: 'backup', authMethod: 'publicKey', privateKeyPem: 'not read here');
        await crud.create(
            label: 'signed', username: 'backup', authMethod: 'publicKey', publicKeyData: publicKey, privateKeyPem: 'not read here');
      });

  Future<ProviderContainer> pumpKeys(WidgetTester tester, {List<Override> more = const []}) async {
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
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.physicalSize = const Size(1400, 2600);
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
        ...more,
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: KeysView()),
      ),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(KeysView)));
  }

  /// A key picked, and its editor opened (its private details are behind
  /// Edit).
  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('keys-inspector-edit')));
    await settle(tester);
  }

  String deleteWord(WidgetTester tester) =>
      MaterialLocalizations.of(tester.element(find.byType(KeysView))).deleteButtonTooltip;

  testWidgets('a save that fails says so in the app\'s words, with what was thrown to copy', (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    final c = await pumpKeys(tester);
    await pick(tester, 'prod');
    // A change to save: the name.
    await tester.enterText(
        find.byWidgetPredicate((w) => w is EditableText && w.controller.text == 'prod').first, 'prod-eu');
    await settle(tester);
    crud.error = const FileSystemException('database is locked');
    await tester.tap(find.text(en.save).last);
    await settle(tester);
    final notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.zestKeysNotSaved);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.details, contains('database is locked'));
    await finish(tester);
  });

  testWidgets('deleting asks in the app\'s language; a delete that fails says so, and one that works deletes',
      (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    final c = await pumpKeys(tester);
    await pick(tester, 'prod');
    await tester.tap(find.text(deleteWord(tester)));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.text(en.zestKeysDeleteTitle('prod')), findsOneWidget);
    expect(find.text(en.zestKeysDeleteBody), findsOneWidget);
    expect(find.text(en.zestKeysDeleteFallsBack), findsOneWidget);
    expect(find.text(en.zestKeysDeleteFileUntouched), findsOneWidget);

    crud.error = const FileSystemException('database is locked');
    await tester.tap(find.text(en.zestKeysDeleteConfirm));
    await settle(tester);
    final notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.zestKeysNotDeleted);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.details, contains('database is locked'));
    expect(await tester.runAsync(() => db.identitiesDao.getById(prod)), isNotNull);

    crud.error = null;
    await tester.tap(find.text(deleteWord(tester)));
    await settle(tester);
    await tester.tap(find.text(en.zestKeysDeleteConfirm));
    await settle(tester);
    expect(await tester.runAsync(() => db.identitiesDao.getById(prod)), isNull);
    await finish(tester);
  });

  testWidgets('exporting the public key copies it and says so; a key whose public key cannot be had says so',
      (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    final c = await pumpKeys(tester);
    await pick(tester, 'signed');
    await tester.tap(find.text(en.zestKeysExportPublic));
    await settle(tester);
    expect(copied, [publicKey]);
    expect(c.read(notificationCenterProvider).history.first.title, en.identityPublicKeyCopied);

    // A key keeps no public part where it was made in the app: it is made
    // from the key there (test/ui/keys_kept_test.dart), and
    // a key that cannot be read says there is none.
    await pick(tester, 'bare');
    await tester.tap(find.text(en.zestKeysExportPublic));
    await settle(tester);
    expect(copied, [publicKey], reason: 'nothing more copied');
    expect(c.read(notificationCenterProvider).history.first.title, en.zestKeysNoPublicKey);
    await finish(tester);
  });

  testWidgets('a list that cannot be loaded says so with its details and Try again', (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    await pumpKeys(tester, more: [
      filteredIdentitiesProvider.overrideWith((ref) => Stream.error(StateError('the table is gone'))),
    ]);
    expect(find.byType(LoadErrorState), findsOneWidget);
    expect(find.text(en.homeUnableToLoadIdentities), findsOneWidget);
    expect(find.text(en.retry), findsOneWidget);
    expect(find.textContaining('the table is gone'), findsNothing, reason: 'the raw error is behind Copy details');
    await finish(tester);
  });

  group('a copy of a key (right-click, Duplicate)', () {
    Future<void> rightClick(WidgetTester tester, Finder what) async {
      final gesture = await tester.startGesture(tester.getCenter(what),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await gesture.up();
      await settle(tester);
    }

    testWidgets('signs in by itself: what the key signs in with comes along, unattended runs do not', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await tester.runAsync(() async {
        final keyId = await crud.create(
            label: 'deploy key',
            username: 'deploy',
            authMethod: 'publicKey',
            keyType: 'ed25519',
            publicKeyData: publicKey,
            privateKeyPem: 'PEM-FOR-TESTS',
            keyPassphrase: 'passphrase-for-tests',
            colorIndex: 3,
            allowUnattended: true);
        final key = (await db.identitiesDao.getById(keyId))!;
        final copyId = await crud.duplicate(key, label: 'deploy key (copy)');
        final copy = (await db.identitiesDao.getById(copyId))!;
        expect(copyId, isNot(keyId));
        expect((copy.label, copy.username, copy.authMethod, copy.keyType, copy.publicKeyData, copy.colorIndex),
            ('deploy key (copy)', 'deploy', 'publicKey', 'ed25519', publicKey, 3));
        expect(await crud.getPrivateKey(copyId), 'PEM-FOR-TESTS');
        expect(await crud.getKeyPassphrase(copyId), 'passphrase-for-tests');
        expect(copy.allowUnattended, isFalse, reason: 'turned on for one key on one device, not for its copy');
        expect((await db.identitiesDao.getById(keyId))!.allowUnattended, isTrue);

        final pass = (await db.identitiesDao.getById(prod))!;
        final passCopy = await crud.duplicate(pass, label: 'prod (root)');
        expect(await crud.getPassword(passCopy), 'demo-pass-for-tests');
        expect(await crud.getPrivateKey(passCopy), isNull);

        final managed = (await db.identitiesDao.getById(await crud.create(
            label: 'vaulted', username: 'deploy', authMethod: 'passwordManager', passwordRef: 'op://demo/web-01/password')))!;
        final managedCopy = (await db.identitiesDao.getById(await crud.duplicate(managed, label: 'vaulted (copy)')))!;
        expect(managedCopy.passwordRef, 'op://demo/web-01/password');
      });
    });

    testWidgets('is not made of a key that is not held here or belongs to an authority', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await tester.runAsync(() async {
        for (final method in ['certificate', 'hardwareToken', 'teamCertificate']) {
          final id = await crud.create(label: 'other $method', username: 'deploy', authMethod: method);
          final identity = (await db.identitiesDao.getById(id))!;
          expect(IdentityCrudNotifier.canDuplicate(identity), isFalse, reason: method);
          await expectLater(crud.duplicate(identity, label: 'x'), throwsStateError);
        }
        expect(IdentityCrudNotifier.canDuplicate((await db.identitiesDao.getById(prod))!), isTrue);
      });
    });

    testWidgets('a right-click offers it, makes the copy and opens it', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      final c = await pumpKeys(tester);
      await rightClick(tester, find.text('prod').first);
      expect(find.text(en.commonDuplicate), findsOneWidget);
      await tester.tap(find.text(en.commonDuplicate));
      await settle(tester);
      await settle(tester);

      final all = (await tester.runAsync(() => db.identitiesDao.getAll()))!;
      final copy = all.singleWhere((i) => i.label == en.homeCopyLabelSuffix('prod'));
      expect(copy.username, 'deploy');
      expect(await tester.runAsync(() => crud.getPassword(copy.id)), 'demo-pass-for-tests');
      expect(c.read(notificationCenterProvider).history.first.title, en.homeIdentityDuplicated('prod'));
      // The copy is the one open, ready for another username.
      expect(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == en.homeCopyLabelSuffix('prod')),
          findsOneWidget);
      await finish(tester);
    });

    testWidgets('a copy that could not be made says so, with what was thrown', (tester) async {
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      final c = await pumpKeys(tester);
      crud.createError = const FileSystemException('database is locked');
      await rightClick(tester, find.text('prod').first);
      await tester.tap(find.text(en.commonDuplicate));
      await settle(tester);
      final notice = c.read(notificationCenterProvider).history.first;
      expect(notice.title, en.zestKeysNotSaved);
      expect(notice.details, contains('database is locked'));
      await finish(tester);
    });

    testWidgets('a key that cannot be copied has no menu', (tester) async {
      await build(tester);
      await tester.runAsync(() => crud.create(label: 'token', username: 'deploy', authMethod: 'hardwareToken'));
      addTearDown(() => tester.runAsync(db.close));
      await pumpKeys(tester);
      await rightClick(tester, find.text('token').first);
      expect(find.text(en.commonDuplicate), findsNothing);
      await finish(tester);
    });

    test('a phone\'s Duplicate makes the same copy, where one can be made', () {
      final phone = File('lib/ui/screens/home/home_screen.dart').readAsStringSync();
      expect(phone, contains('.duplicate(identity, label: l10n.homeCopyLabelSuffix(identity.label));'));
      // Every row of the list is made in one place (3.4), and a key's sheet
      // opened from the selection's More asks the same.
      expect('canAddKeys && IdentityCrudNotifier.canDuplicate(identity) ?'.allMatches(phone).length, 1);
      expect(phone, contains('mayAddScreenSpace(ref, watch: false) && IdentityCrudNotifier.canDuplicate(identity)'));
      expect(phone, isNot(contains('onDuplicate: canAddKeys ?')));
    });
  });

  test('every language says them its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      expect(t.zestKeysDeleteTitle('prod'), contains('prod'), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      for (final say in <String Function(AppLocalizations)>[
        (l) => l.zestKeysNotSaved,
        (l) => l.zestKeysNotDeleted,
        (l) => l.zestKeysDeleteTitle('prod'),
        (l) => l.zestKeysDeleteBody,
        (l) => l.zestKeysDeleteFallsBack,
        (l) => l.zestKeysDeleteFileUntouched,
        (l) => l.zestKeysDeleteConfirm,
        (l) => l.zestKeysNoPublicKey,
      ]) {
        expect(say(t), isNot(say(en)), reason: '$locale');
      }
    }
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 5)); // notices time out
}

/// Takes the screen down while the test still runs, so what closes with it
/// (the database's watched queries) finishes here.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}
