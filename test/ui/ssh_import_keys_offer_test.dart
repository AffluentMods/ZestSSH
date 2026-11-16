import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/desktop/dialogs/get_connected_dialogs.dart';

/// Importing from an SSH config offers copies of the private keys its hosts
/// name (IdentityFile), and the offer starts unticked: a private key goes
/// into the vault only when the person asks for it (never
/// by default).
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zest_keys_offer_');
    final key = File('${dir.path}${Platform.pathSeparator}deploy');
    await key.writeAsString('-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n');
    final config = File('${dir.path}${Platform.pathSeparator}config');
    await config.writeAsString('Host web\n  HostName web.example.com\n  User deploy\n  IdentityFile ${key.path}\n');
    FilePicker.platform = _Picker(config.path);
  });

  tearDown(() => dir.delete(recursive: true));

  testWidgets('the keys a config names are offered, unticked', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs!)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                TextButton(onPressed: () => showDesktopSshConfigImport(context, pickFile: true), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // The picked file is read and its keys looked for, off the test's clock.
    for (var i = 0; i < 20 && find.byKey(const ValueKey('ssh-import-keys')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    final offer = find.byKey(const ValueKey('ssh-import-keys'));
    expect(offer, findsOneWidget);
    Checkbox box() => tester.widget<Checkbox>(find.descendant(of: offer, matching: find.byType(Checkbox)));
    expect(box().value, isFalse, reason: 'a private key goes in only when asked for');
    await tester.tap(offer);
    await tester.pump();
    expect(box().value, isTrue);
  });

  testWidgets('a key is read when it goes in, ticked: not held from when it was offered', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs!),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                TextButton(onPressed: () => showDesktopSshConfigImport(context, pickFile: true), child: const Text('open')),
          ),
        ),
      ),
    ));
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.tap(find.text('open'));
    final offer = find.byKey(const ValueKey('ssh-import-keys'));
    for (var i = 0; i < 40 && offer.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(offer, findsOneWidget);
    // It goes away before it is ticked: nothing of it was kept to go in.
    await tester.runAsync(() => File('${dir.path}${Platform.pathSeparator}deploy').delete());
    await tester.tap(offer);
    await tester.pump();
    await tester.tap(find.text(l10n.sshImportButtonCount(1)));
    for (var i = 0; i < 40 && find.byKey(const ValueKey('ssh-import-keys')).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final hosts = (await tester.runAsync(db.connectionsDao.getAll))!;
    expect(hosts.single.note, contains('IdentityFile:'), reason: 'the path stays in its note, as for a key not read');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

class _Picker extends FilePicker {
  _Picker(this.path);

  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([PlatformFile(path: path, name: 'config', size: 0)]);
}
