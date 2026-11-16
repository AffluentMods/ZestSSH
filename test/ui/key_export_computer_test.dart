import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_action_dialogs.dart';
import 'package:zestssh/features/keys/key_export_save.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/redactor.dart';

/// On a computer, exporting a key saves its files where the person
/// says in the system's save dialog, and never opens the share sheet (a
/// phone's way: on Linux the share plugin throws for files, so no key could be
/// exported; on Windows the files were deleted under the Share window). The
/// save dialog is stood in for; the files are written to a folder of the
/// test's own. A made-up key.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const share = MethodChannel('dev.fluttercommunity.plus/share');

  late Directory folder;
  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late SharedPreferences prefs;
  late String pem;
  late String line;
  late String fingerprint;
  final shared = <MethodCall>[];

  setUpAll(() async {
    final made = await KeyGenerationService().generateEd25519(comment: 'ops');
    pem = made.privatePem;
    line = made.publicOpenSSH.trim();
    fingerprint = made.fingerprint;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    folder = Directory.systemTemp.createTempSync('zest_key_export_test_');
    shared.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(share, (call) async {
      shared.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(share, null);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  group('saveKeyFilesOnComputer (plain files: nothing of a share sheet, so nothing a Linux build lacks)', () {
    final files = {
      'ops_ed25519': utf8.encode('PRIVATE\n'),
      'ops_ed25519.pub': utf8.encode('ssh-ed25519 AAAA ops\n'),
    };

    test('the first file goes where the person says, the public key beside it under the name chosen', () async {
      final asked = <String>[];
      final restricted = <String>[];
      final chosen = p.join(folder.path, 'id_work');
      final saved = await saveKeyFilesOnComputer(
        files,
        title: 'Save the key file',
        pick: ({required title, required fileName}) async {
          asked.add('$title|$fileName');
          return chosen;
        },
        restrict: (path) async => restricted.add(path),
      );
      expect(asked, ['Save the key file|ops_ed25519'], reason: 'asked once, about the first file');
      expect(saved, [chosen, '$chosen.pub']);
      expect(File(chosen).readAsStringSync(), 'PRIVATE\n');
      expect(File('$chosen.pub').readAsStringSync(), 'ssh-ed25519 AAAA ops\n');
      expect(restricted, [chosen], reason: 'the private key file is kept to its person, the public one is not');
    });

    test('cancelled in the save dialog: null, and nothing is written', () async {
      final saved = await saveKeyFilesOnComputer(
        files,
        title: 't',
        pick: ({required title, required fileName}) async => null,
      );
      expect(saved, isNull);
      expect(folder.listSync(), isEmpty);
    });

    test('a file beside the first is never written over one that is there', () async {
      final chosen = p.join(folder.path, 'id_work');
      File('$chosen.pub').writeAsStringSync('someone else\n');
      final saved = await saveKeyFilesOnComputer(
        files,
        title: 't',
        pick: ({required title, required fileName}) async => chosen,
      );
      expect(File('$chosen.pub').readAsStringSync(), 'someone else\n');
      expect(saved![1], p.join(folder.path, 'id_work (2).pub'));
      expect(File(saved[1]).readAsStringSync(), 'ssh-ed25519 AAAA ops\n');
    });

    test('a public key alone is saved where the person says, and not kept to its person', () async {
      final restricted = <String>[];
      final chosen = p.join(folder.path, 'ops.pub');
      final saved = await saveKeyFilesOnComputer(
        {'ops_ed25519.pub': utf8.encode('ssh-ed25519 AAAA ops\n')},
        title: 't',
        pick: ({required title, required fileName}) async => chosen,
        restrict: (path) async => restricted.add(path),
      );
      expect(saved, [chosen]);
      expect(restricted, isEmpty);
    });

    test('a write that fails leaves no half of a key behind, and says what failed', () async {
      final chosen = p.join(folder.path, 'no such folder', 'id_work');
      await expectLater(
        saveKeyFilesOnComputer(files, title: 't', pick: ({required title, required fileName}) async => chosen),
        throwsA(isA<FileSystemException>()),
      );
      expect(folder.listSync(recursive: true), isEmpty);
    });
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<Identity> seed(WidgetTester tester) async {
    late Identity identity;
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      final id = await crud.create(
        label: 'Ops laptop',
        username: 'ops',
        authMethod: 'publicKey',
        keyType: 'ed25519',
        publicKeyFingerprint: fingerprint,
        publicKeyData: line,
        privateKeyPem: pem,
      );
      identity = (await db.identitiesDao.getById(id))!;
    });
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
        syncIsActiveProvider.overrideWith((ref) async => true),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(db.close);
  }

  testWidgets('Export on a computer: the save dialog is asked, both files are where it said, the app says where, '
      'and the share sheet is never opened', (tester) async {
    final identity = await seed(tester);
    final names = keyExportFileNames(identity);
    final chosen = p.join(folder.path, names.private);
    final asked = <String>[];
    await pump(
      tester,
      KeyExportDialog(
        keyToExport: identity,
        onComputer: true,
        pick: ({required title, required fileName}) async {
          asked.add('$title|$fileName');
          return chosen;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('keys-export-go')));
    for (var i = 0; i < 100 && find.text(l10n.keysExportSavedTitle).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text(l10n.keysExportFailed), findsNothing, reason: 'the export did not fail');
    expect(asked, ['${l10n.keysExportSaveDialog}|${names.private}']);
    expect(File(chosen).readAsStringSync().trim(), pem.trim());
    expect(File('$chosen.pub').readAsStringSync(), '$line\n');
    expect(shared, isEmpty, reason: 'no share sheet on a computer');
    // Where it went, in the dialog every saved file gets.
    expect(find.text(l10n.keysExportSavedTitle), findsOneWidget);
    expect(find.text(l10n.keysExportSavedBesideBody(names.public)), findsOneWidget);
    expect(find.byKey(const ValueKey('file-saved-done')), findsOneWidget);
    expect(find.text(l10n.identityEditExportedFilesMessage(names.private, names.public)), findsNothing,
        reason: 'not "choose where to send them": that is the share sheet\'s');
    await finish(tester);
  });

  testWidgets('Export on a computer, cancelled in the save dialog: nothing written, no error, the question stays',
      (tester) async {
    final identity = await seed(tester);
    await pump(
      tester,
      KeyExportDialog(
        keyToExport: identity,
        onComputer: true,
        pick: ({required title, required fileName}) async => null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('keys-export-go')));
    await settle(tester);
    await settle(tester);
    expect(folder.listSync(), isEmpty);
    expect(shared, isEmpty);
    expect(find.text(l10n.keysExportFailed), findsNothing);
    expect(find.text(l10n.keysExportSavedTitle), findsNothing);
    expect(find.byKey(const ValueKey('keys-export-go')), findsOneWidget, reason: 'to try again');
    await finish(tester);
  });

  test('the key editor\'s own export saves through the same path on a computer; neither call site hands a '
      'computer\'s export to the share sheet', () {
    final editor = File('lib/ui/screens/identity/identity_edit_screen.dart').readAsStringSync();
    final at = editor.indexOf(RegExp(r'if \(isDesktopPlatform\) \{\s+final saved = await saveKeyFilesOnComputer\('));
    expect(at, greaterThan(0));
    expect(at, lessThan(editor.indexOf('await ConnectionShareService.shareFiles(')),
        reason: 'the computer path returns before the share sheet');
    final dialog = File('lib/features/keys/key_action_dialogs.dart').readAsStringSync();
    expect(dialog, contains('widget.onWrite == null && (widget.onComputer ?? isDesktopPlatform)'));
    final saver = File('lib/features/keys/key_export_save.dart').readAsStringSync();
    expect(saver, isNot(contains('share_plus')));
  });
}
