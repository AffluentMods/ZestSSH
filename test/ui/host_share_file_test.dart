// A host shared as a `.zest` file, on screen (found while
// comparing the five versions): a phone's Share wrote one, and nothing in
// the app read one back. Import hosts did not offer it, and Restore, which
// takes `.zest` files, said it was not a backup; a computer could not write
// one. Now Import hosts and Restore add one, asking for a sealed file's
// password until it opens it and showing what the file holds first, and a
// computer's Hosts page saves a host as one where it is told.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show KeyType;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart';
import 'package:zestssh/ui/screens/connection/incoming_share_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/file_manager.dart' show systemPath;

import '../helpers/desktop_mouse.dart';
import '../visual/shots_util.dart';

/// A file picker that picks [pick] and saves to [save] (null: cancelled).
class _Picker extends FilePicker {
  _Picker({this.pick, this.save});

  final String? pick;
  final String? save;
  String? savedAs;

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
      pick == null ? null : FilePickerResult([PlatformFile(path: pick, name: pick!.split(Platform.pathSeparator).last, size: 0)]);

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
    savedAs = fileName;
    return save;
  }
}

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
}

class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final now = DateTime.utc(2026, 10, 16);
  late Directory temp;
  var fontsLoaded = false;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('zest_host_file_ui_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async => temp.path);
    FlutterSecureStorage.setMockInitialValues({});
    // The messages as a phone shows them, on screen.
    debugTopSnackBarOnPhone = true;
  });

  tearDown(() {
    debugTopSnackBarOnPhone = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Lets what runs outside the test's clock (files, a worker) finish, until
  /// [until] is on screen where one is given.
  Future<void> settle(WidgetTester tester, {Finder? until, int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      if (until != null && until.evaluate().isNotEmpty) break;
    }
    await tester.pump();
  }

  /// A host file of web 01 (port 2222, user deploy, a forward started on its
  /// own where it was shared), written by Share: sealed under [sealedWith]
  /// with the private key [pem] where they are given.
  Future<String> hostFile(WidgetTester tester, {String? pem, String? sealedWith}) async {
    final sender = AppDatabase.forTesting(NativeDatabase.memory());
    final path = await tester.runAsync(() async {
      final crud = IdentityCrudNotifier(sender.identitiesDao,
          IdentitySecretStore.forDatabase(sender, const FlutterSecureStorage()), sender.connectionsDao);
      final keyId = await crud.create(
          label: 'deploy key', username: 'deploy', authMethod: pem == null ? 'password' : 'publicKey', privateKeyPem: pem);
      await sender.into(sender.connections).insert(ConnectionsCompanion.insert(
            id: 'c1',
            label: 'web 01',
            host: 'web-01.example.com',
            port: const Value(2222),
            identityId: Value(keyId),
            createdAt: now,
            updatedAt: now,
          ));
      await sender.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
        id: 'f1',
        connectionId: 'c1',
        type: 'local',
        bindAddress: const Value('127.0.0.1'),
        bindPort: 8080,
        remoteHost: 'db.internal',
        remotePort: 80,
        autoStart: const Value(true),
        createdAt: now,
      ));
      final written = await ConnectionShareService.exportConnection(
        connection: (await sender.connectionsDao.getById('c1'))!,
        identity: await sender.identitiesDao.getById(keyId),
        portForwardRules: await sender.portForwardRulesDao.getByConnection('c1'),
        privateKeyPem: pem,
        encryptionPassword: sealedWith,
      );
      // Where someone who was sent it keeps it.
      final kept = File('${temp.path}${Platform.pathSeparator}web_01.zest');
      await File(written).copy(kept.path);
      await sender.close();
      return kept.path;
    });
    return path!;
  }

  /// The app with a button that does [action], over the Tree [db].
  Future<void> pumpApp(WidgetTester tester, AppDatabase db, Future<void> Function(BuildContext, WidgetRef) action,
      {bool recording = false}) async {
    tester.view.physicalSize = const Size(1400, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(onPressed: () => action(context, ref), child: const Text('go')),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Adds the host shown in the dialog open now, and checks it is said.
  Future<void> add(WidgetTester tester) async {
    await tester.tap(find.text(l10n.incomingShareAddConnection));
    await settle(tester, until: find.text(l10n.qrScanConnectionAdded));
    expect(find.text(l10n.qrScanConnectionAdded), findsOneWidget);
    // (The message goes by itself.)
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  testWidgets('a sealed host file asks for its password until it opens the file, shows what it holds and what came '
      'with it, and is added into your Tree, its forwards not started', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final made = (await tester.runAsync(() => KeyGenerationService().generate(KeyType.ed25519)))!;
    final path = await hostFile(tester, pem: made.privatePem, sealedWith: 'a long enough password');
    await pumpApp(tester, db, (context, ref) => importHostShareFile(context, path: path));
    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.hostShareSealedTitle));
    expect(find.text(l10n.hostShareSealedTitle), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'not the password');
    await tester.tap(find.text(l10n.accountImportAction));
    await settle(tester, until: find.text(l10n.hostShareWrongPassword), rounds: 600);
    expect(find.text(l10n.hostShareWrongPassword), findsOneWidget, reason: 'said under the field, which stays');

    await tester.enterText(find.byType(TextField), 'a long enough password');
    await tester.tap(find.text(l10n.accountImportAction));
    await settle(tester, until: find.byType(IncomingShareDialog), rounds: 600);
    expect(find.byType(IncomingShareDialog), findsOneWidget);
    expect(find.text(l10n.hostShareTrust), findsOneWidget);
    expect(find.text(l10n.incomingShareTrustSource), findsNothing, reason: 'it came in a file');
    expect(find.text('web 01'), findsOneWidget);
    expect(find.text('web-01.example.com:2222'), findsOneWidget);
    expect(find.text('deploy'), findsOneWidget);
    expect(find.text(l10n.hostShareWithKey), findsOneWidget);
    expect(find.text(l10n.hostShareWithPassword), findsNothing, reason: 'none was shared');
    expect(find.textContaining('db.internal:80'), findsOneWidget);
    expect(find.text(l10n.incomingShareSectionSourceUrl.toUpperCase()), findsNothing, reason: 'a file has no URL');
    expect(await db.connectionsDao.getAll(), isEmpty, reason: 'nothing before it is added');

    await add(tester);
    final hosts = await db.connectionsDao.getAll();
    expect([for (final h in hosts) (h.label, h.host, h.port)], [('web 01', 'web-01.example.com', 2222)]);
    final key = (await db.identitiesDao.getById(hosts.single.identityId!))!;
    expect((key.username, key.authMethod), ('deploy', 'publicKey'));
    final forwards = await db.portForwardRulesDao.getByConnection(hosts.single.id);
    expect([for (final f in forwards) (f.remoteHost, f.autoStart)], [('db.internal', false)]);
  });

  testWidgets('while the screen is recorded, a host file is shown only once recording is turned off, as it is; '
      'Cancel there adds nothing (it was shown as stand-ins, and could be added unseen)',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final path = await hostFile(tester);
    await pumpApp(tester, db, (context, ref) => importHostShareFile(context, path: path), recording: true);
    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.recModeRevealTitle), rounds: 600);
    expect(find.byType(IncomingShareDialog), findsNothing);
    await tester.tap(find.text(l10n.recModeRevealCancel));
    await settle(tester);
    expect(find.byType(IncomingShareDialog), findsNothing);
    expect(await db.connectionsDao.getAll(), isEmpty);

    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.recModeRevealTitle), rounds: 600);
    await tester.tap(find.text(l10n.recModeRevealDisable));
    await settle(tester, until: find.byType(IncomingShareDialog), rounds: 600);
    expect(find.text('web 01'), findsOneWidget, reason: 'as it is');
    await add(tester);
    expect(await db.connectionsDao.getAll(), hasLength(1));
  });

  testWidgets('a file that is not a host shared from ZestSSH is said to be so, a backup as a backup, and nothing is '
      'added', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final sep = Platform.pathSeparator;
    final backup = '${temp.path}${sep}zestssh_backup.zest';
    final other = '${temp.path}${sep}notes.zest';
    final broken = '${temp.path}${sep}broken.zest';
    await tester.runAsync(() async {
      await File(backup).writeAsBytes([...utf8.encode('ZEST'), 3, 0, 2, ...utf8.encode('{}')]);
      await File(other).writeAsString('{"hosts": []}');
      // One that says it is a shared host, with no address.
      await File(broken).writeAsString(jsonEncode({
        'version': 1,
        'type': 'zestssh_connection',
        'connection': {'label': 'web 01', 'host': ''},
      }));
    });
    var path = backup;
    await pumpApp(tester, db, (context, ref) => importHostShareFile(context, path: path));
    // A backup is told apart, and offered where it goes.
    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.importFoundBackup));
    expect(find.text(l10n.importWrongTitle(l10n.cloudImpZest)), findsOneWidget);
    expect(find.text(l10n.importItAction), findsOneWidget);
    expect(find.byType(IncomingShareDialog), findsNothing);
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();
    for (final (file, said) in [
      (other, l10n.hostShareNotShare),
      (broken, l10n.hostShareNotShare),
    ]) {
      path = file;
      await tester.tap(find.text('go'));
      await settle(tester, until: find.text(said));
      expect(find.text(said), findsOneWidget, reason: file);
      expect(find.byType(IncomingShareDialog), findsNothing);
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
    }
    expect(await db.connectionsDao.getAll(), isEmpty);
  });

  testWidgets('Restore given a file that is no backup says what it is, and offers its import, whatever it is called', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final temp = await tester.runAsync(() => Directory.systemTemp.createTemp('zest_restore_other_'));
    addTearDown(() => tester.runAsync(() => temp!.delete(recursive: true)));
    final sep = Platform.pathSeparator;
    final config = '${temp!.path}${sep}servers.zest';
    final key = '${temp.path}${sep}id_ed25519';
    final notes = '${temp.path}${sep}notes.txt';
    await tester.runAsync(() async {
      await File(config).writeAsString('Host web1\n  HostName 203.0.113.10\n');
      await File(key).writeAsString('-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n');
      await File(notes).writeAsString('Dear team,\nnothing of ours\n');
    });
    addTearDown(() => FilePicker.platform = _Picker(pick: null));
    FilePicker.platform = _Picker(pick: config);
    await pumpApp(tester, db, runBackupImport);
    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.importFoundSshConfig));
    expect(find.text(l10n.importWrongTitle(l10n.importKindBackup)), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();

    FilePicker.platform = _Picker(pick: key);
    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.importFoundKey));
    expect(find.text(l10n.importWrongTitle(l10n.importKindBackup)), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();

    // Nothing it can tell, and not called a backup: as it was said before.
    FilePicker.platform = _Picker(pick: notes);
    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.settingsSelectZestFile));
    expect(find.text(l10n.settingsSelectZestFile), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
  });

  testWidgets('Restore given a host file says what it is, and adds the host from there', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final path = await hostFile(tester);
    FilePicker.platform = _Picker(pick: path);
    await pumpApp(tester, db, runBackupImport);
    await tester.tap(find.text('go'));
    await settle(tester, until: find.text(l10n.backupIsHostShare));
    expect(find.text(l10n.backupIsHostShare), findsOneWidget);
    await tester.tap(find.text(l10n.hostShareAddIt));
    await settle(tester, until: find.byType(IncomingShareDialog));
    expect(find.text('web-01.example.com:2222'), findsOneWidget);
    expect(find.text(l10n.hostShareWithKey), findsNothing);
    await add(tester);
    expect([for (final h in await db.connectionsDao.getAll()) h.host], ['web-01.example.com']);
  });

  testWidgets('Import hosts offers a ZestSSH host file, which is picked and added', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final path = await hostFile(tester);
    FilePicker.platform = _Picker(pick: path);
    await pumpApp(tester, db, (context, ref) => openImportHosts(context));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.cloudImpZest), findsOneWidget);
    expect(find.text(l10n.cloudImpZestDesc), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-source-zest')));
    await tester.pumpAndSettle();
    await settle(tester, until: find.byType(IncomingShareDialog));
    expect(find.text('web 01'), findsOneWidget);
    await add(tester);
    expect([for (final h in await db.connectionsDao.getAll()) h.label], ['web 01']);
  });

  testWidgets("the share dialog offers what a host's key has to share, and nothing it has not", (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    for (final (password, key) in [(false, false), (true, false), (false, true), (true, true)]) {
      await tester.pumpWidget(ProviderScope(
        key: ValueKey((password, key)),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<ShareOptions>(
                context: context,
                builder: (_) => ShareOptionsDialog(connectionLabel: 'web 01', offerPassword: password, offerKey: key),
              ),
              child: const Text('share'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('share'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.homeShareIncludePassword), password ? findsOneWidget : findsNothing);
      expect(find.text(l10n.homeShareIncludePrivateKey), key ? findsOneWidget : findsNothing);
    }
  });

  test('a key keeps a private key a file may carry where it is a key or a certificate', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final kept = <String, bool>{};
    for (final method in ['publicKey', 'certificate', 'password', 'passwordManager', 'hardwareToken']) {
      await db.into(db.identities).insert(
          IdentitiesCompanion.insert(id: method, label: method, username: 'ops', authMethod: method, createdAt: now));
      kept[method] = keepsPrivateKey((await db.identitiesDao.getById(method))!);
    }
    expect(kept, {'publicKey': true, 'certificate': true, 'password': false, 'passwordManager': false, 'hardwareToken': false});
  });

  desktopTest("a computer's Hosts page saves a host as a .zest file where it is told, says where it went, and leaves "
      'nothing in the temporary folder', (tester) async {
    if (!fontsLoaded) {
      await tester.runAsync(loadShotFonts);
      fontsLoaded = true;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    debugTopSnackBarOnPhone = null;
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final out = Directory('${temp.path}${Platform.pathSeparator}out')..createSync();
    final target = '${out.path}${Platform.pathSeparator}web-01.zest';
    final picker = _Picker(save: target);
    FilePicker.platform = picker;
    await tester.runAsync(() async {
      // A key with no password in use: its private key may be offered, not a password.
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'i-root', label: 'root key', username: 'root', authMethod: 'publicKey', createdAt: now));
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-web',
            label: 'web-01',
            host: 'web-01.example.com',
            identityId: const Value('i-root'),
            createdAt: now,
            updatedAt: now,
          ));
    });
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      recordingModeProvider.overrideWith((ref) => false),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      serverStatsProvider.overrideWith(_NoStats.new),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HostsHomePage(onConnectTo: (_) {})),
      ),
    ));
    await settle(tester, rounds: 6);
    await TestMouse(tester).rightClick(find.text('web-01').first);
    await settle(tester, rounds: 6);
    // Under Organize (4.0: the menu grouped).
    await tester.tap(find.byKey(const ValueKey('host-menu-organize')));
    await settle(tester, rounds: 6);
    await tester.tap(find.text(l10n.hostShareSaveFile));
    await settle(tester, until: find.byType(ShareOptionsDialog));
    expect(find.text(l10n.homeShareIncludePrivateKey), findsOneWidget);
    expect(find.text(l10n.homeShareIncludePassword), findsNothing);
    await tester.tap(find.text(l10n.homeShare).last);
    await settle(tester, until: find.text(l10n.hostShareSaved));
    expect(find.text(l10n.hostShareSaved), findsOneWidget);
    expect(find.text(l10n.hostShareSavedBody), findsOneWidget);
    // Where it went: its name first, its folder under it, in the system's
    // style (the dialog rules of 3.4).
    expect(find.text('web-01.zest'), findsOneWidget, reason: 'where it went');
    expect(find.text(systemPath(out.path)), findsOneWidget, reason: 'its folder');
    expect(picker.savedAs, 'web-01.zest');
    final bytes = (await tester.runAsync(() => File(target).readAsBytes()))!;
    expect(ConnectionShareService.isShareFile(bytes), isTrue);
    expect(ConnectionShareService.isSealedShare(bytes), isFalse);
    expect(utf8.decode(bytes), contains('web-01.example.com'));
    expect(
        temp.listSync().where((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith(ConnectionShareService.shareFolderPrefix)),
        isEmpty,
        reason: 'the file written for it is gone');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });
}
