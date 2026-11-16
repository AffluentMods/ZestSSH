import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_action_dialogs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/redactor.dart';

/// The system's save dialog, stood in for: it answers [path] and counts.
class _SaveDialog extends FilePicker {
  _SaveDialog(this.path);
  final String? path;
  final asked = <String?>[];

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    asked.add(fileName);
    return path;
  }
}

/// The export bug, as the app runs it (the export dialog as the Keys page opens it,
/// with nothing of a test put in but the system's save dialog and the share
/// plugin's channel): on a computer the key's files are saved through the save
/// dialog and the share sheet is never called. Before the fix this test fails:
/// the share sheet was called and the save dialog never asked. It runs where
/// the tests run on a computer (Windows, Linux, macOS), which is where the
/// defect was.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const share = MethodChannel('dev.fluttercommunity.plus/share');

  testWidgets('Export, as the Keys page opens it on a computer: saved through the save dialog, no share sheet',
      (tester) async {
    expect(isDesktopPlatform, isTrue, reason: 'this test is about a computer');
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final folder = Directory.systemTemp.createTempSync('zest_key_export_default_');
    addTearDown(() {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    });
    final shared = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(share, (call) async {
      shared.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(share, null));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    late AppDatabase db;
    late IdentityCrudNotifier crud;
    late Identity identity;
    late String pem;
    await tester.runAsync(() async {
      final made = await KeyGenerationService().generateEd25519(comment: 'ops');
      pem = made.privatePem;
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      final id = await crud.create(
        label: 'Ops laptop',
        username: 'ops',
        authMethod: 'publicKey',
        keyType: 'ed25519',
        publicKeyFingerprint: made.fingerprint,
        publicKeyData: made.publicOpenSSH.trim(),
        privateKeyPem: pem,
      );
      identity = (await db.identitiesDao.getById(id))!;
    });
    final names = keyExportFileNames(identity);
    final chosen = p.join(folder.path, names.private);
    final dialog = _SaveDialog(chosen);
    FilePicker.platform = dialog;

    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
        home: Scaffold(body: KeyExportDialog(keyToExport: identity)),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('keys-export-go')));
    for (var i = 0; i < 100 && !File('$chosen.pub').existsSync() && shared.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(shared, isEmpty, reason: 'a computer does not open the share sheet for a key');
    expect(dialog.asked, [names.private], reason: 'the save dialog is asked, once, about the private key file');
    expect(File(chosen).existsSync(), isTrue);
    expect(File(chosen).readAsStringSync().trim(), pem.trim());
    expect(File('$chosen.pub').existsSync(), isTrue);
    expect(find.text(l10n.keysExportFailed), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(db.close);
  });
}
